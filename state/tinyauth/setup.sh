#!/usr/bin/env bash
# Generate the Tinyauth wizard files for this stack.
# Safe to run again: it keeps existing secrets unless rotation is asked for.
# It never prints secret values. It prints paths only.
#
# Usage:
#   setup.sh tinyauth                          Run the Tinyauth wizard.
#   setup.sh tinyauth clean [--data] [--yes]   Remove the tinyauth configuration.
#                                              With --data also remove the tinyauth data.
#                                              Ask for confirmation unless --yes is given.
#
# Non-interactive environment variables:
#   STACK_DOMAIN            Stack domain. The issuer becomes https://tinyauth.<domain>.
#                           Read from the environment, then the root .env, then sh.lan.
#   TINYAUTH_LDAP_LOCAL     yes to use the LLDAP service in this repo. Default: yes.
#   TINYAUTH_LDAP_ADDRESS   LDAP URL. Required when TINYAUTH_LDAP_LOCAL=no.
#                           Interactive default for local LLDAP: ldap://lldap:3890.
#   TINYAUTH_LDAP_BASEDN    LDAP base DN. Read from config/lldap/lldap_config.toml when
#                           that file exists, else required for non-interactive runs.
#   TINYAUTH_OBSERVER_AUTO  yes to create the observer in LLDAP automatically. Default: yes.
#                           Falls back to manual instructions when the local admin
#                           password, the API, or docker is not available.
#   TINYAUTH_LDAP_BINDDN    Observer bind DN for manual mode.
#   TINYAUTH_LDAP_BINDPASSWORD  Observer bind password for manual mode.
#   LLDAP_HTTP_URL          LLDAP HTTP base URL for the GraphQL API.
#                           Default: http://localhost:17170.
#   LLDAP_ADMIN_USER        LLDAP admin username for auto-create. Default: admin.
#   TINYAUTH_CLIENTS        Client definitions. Format:
#                           'name:https://uri1,https://uri2;other:https://uri3'
#                           Each name uses letters, digits, and hyphens.
#   TINYAUTH_ROTATE_CLIENTS  Set to 1 to replace existing OIDC client secrets.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly CONFIG_DIR="config/tinyauth"
readonly SECRETS_DIR="config/tinyauth/secrets"
readonly OIDC_SECRETS_DIR="config/tinyauth/secrets/oidc"
readonly STORE_DIR="data/tinyauth/store"
readonly ENV_FILE="config/tinyauth/tinyauth.env"
readonly LDAP_SECRET_FILE="config/tinyauth/secrets/ldap-observer"
readonly LLDAP_CONFIG_FILE="config/lldap/lldap_config.toml"

readonly DEFAULT_LDAP_ADDRESS="ldap://lldap:3890"
readonly DEFAULT_BASE_DN="dc=home,dc=lan"
readonly DEFAULT_STACK_DOMAIN="sh.lan"
readonly DEFAULT_LLDAP_HTTP_URL="http://localhost:17170"
readonly DEFAULT_ADMIN_USER="admin"
readonly OBSERVER_USER="ta-observer"
readonly OBSERVER_GROUP="lldap_strict_readonly"

# Return 0 when the argument is a valid LDAP base DN.
is_valid_base_dn() {
  [[ "$1" =~ ^([a-zA-Z0-9-]+=[a-zA-Z0-9-]+)(,[a-zA-Z0-9-]+=[a-zA-Z0-9-]+)*$ ]]
}

# Return 0 when the argument is a valid LDAP URL with a scheme and a host.
is_valid_ldap_address() {
  [[ "$1" =~ ^(ldap|ldaps)://[A-Za-z0-9][A-Za-z0-9.:_-]*$ ]]
}

# Return 0 when the argument is a valid OIDC client name.
# Names use lowercase letters, digits, and hyphens between words.
is_valid_client_name() {
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# Return 0 when the argument is an HTTPS redirect URI with a host.
is_valid_redirect_uri() {
  [[ "$1" =~ ^https://[A-Za-z0-9][A-Za-z0-9.:_-]*(/[^[:space:],;]*)?$ ]]
}

# Return 0 when the argument is a valid stack domain.
is_valid_stack_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,252})$ ]]
}

# Print the env key prefix for one client name. Viper map keys use underscores.
client_env_prefix() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_'
}

# Print the value of one KEY=VALUE line from a file.
# Print nothing when the file or the line is missing.
read_env_value() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  { grep -E "^${key}=" "$file" || true; } | tail -n1 | cut -d= -f2-
}

# Print the STACK_DOMAIN value from the root .env file.
read_env_stack_domain() {
  if [ ! -f .env ]; then
    return 0
  fi
  { grep -E '^STACK_DOMAIN=' .env || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/" -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# Resolve the stack domain and set stack_domain plus stack_domain_source.
resolve_stack_domain() {
  if [ -n "${STACK_DOMAIN:-}" ]; then
    stack_domain="$STACK_DOMAIN"
    stack_domain_source="env"
    return 0
  fi
  local candidate
  candidate="$(read_env_stack_domain)"
  if [ -n "$candidate" ]; then
    stack_domain="$candidate"
    stack_domain_source="envfile"
    return 0
  fi
  stack_domain="$DEFAULT_STACK_DOMAIN"
  stack_domain_source="default"
}

# Print an STE error for an invalid stack domain and exit 1.
stack_domain_invalid() {
  echo "error: '$stack_domain' is not a valid stack domain. Use letters, digits, dots, and hyphens." >&2
  case "$stack_domain_source" in
  env)
    echo "error: STACK_DOMAIN came from the environment." >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid STACK_DOMAIN." >&2
    echo "error: Fix .env by hand or set STACK_DOMAIN." >&2
    ;;
  esac
  exit 1
}

# Print the value of one key from the local LLDAP config file.
# The wizard writes that file with a double-quoted value on one line.
read_lldap_config_value() {
  local key="$1"
  [ -f "$LLDAP_CONFIG_FILE" ] || return 0
  { grep -E "^${key} = " "$LLDAP_CONFIG_FILE" || true; } | head -n1 | cut -d'"' -f2
}

# Resolve a removal target and make sure it stays inside the base directory.
# Print the resolved absolute path. Return 1 when the target escapes the base.
resolve_removal_target() {
  local target="$1" base="$2" resolved
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath -m -- "$target")" || {
      echo "error: Cannot resolve '$target'." >&2
      return 1
    }
  else
    resolved="$target"
  fi
  case "$resolved" in
  "$base" | "$base"/*)
    printf '%s\n' "$resolved"
    return 0
    ;;
  *)
    echo "error: Refusing to remove '$resolved'. It is not inside '$base'." >&2
    return 1
    ;;
  esac
}

usage_clean() {
  echo "usage: setup.sh tinyauth clean [--data] [--yes]" >&2
}

# Remove the tinyauth configuration, and with --data also the tinyauth data.
# Never touch state/, .env, other services, or paths outside the two trees.
clean_service() {
  local with_data=0 assume_yes=0 flag
  for flag in "$@"; do
    case "$flag" in
    --data) with_data=1 ;;
    --yes) assume_yes=1 ;;
    *)
      echo "error: Unknown flag '$flag'." >&2
      usage_clean
      exit 2
      ;;
    esac
  done

  if [ -L "$REPO_ROOT/config/tinyauth" ]; then
    echo "error: '$REPO_ROOT/config/tinyauth' is a symlink. Refusing to remove it." >&2
    exit 1
  fi
  if [ "$with_data" -eq 1 ] && [ -L "$REPO_ROOT/data/tinyauth" ]; then
    echo "error: '$REPO_ROOT/data/tinyauth' is a symlink. Refusing to remove it." >&2
    exit 1
  fi

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/tinyauth" "$REPO_ROOT/config/tinyauth")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/tinyauth" "$REPO_ROOT/data/tinyauth")" || exit 1
  fi

  local -a remove_paths=()
  local path
  if [ -d "$config_target" ]; then
    while IFS= read -r path; do
      remove_paths+=("$path")
    done < <(find "$config_target" -mindepth 1 | LC_ALL=C sort)
    remove_paths+=("$config_target")
  fi
  if [ "$with_data" -eq 1 ] && [ -d "$data_target" ]; then
    remove_paths+=("$data_target")
  fi

  if [ "${#remove_paths[@]}" -eq 0 ]; then
    echo "Nothing to remove."
    return 0
  fi

  echo "This will remove:"
  for path in "${remove_paths[@]}"; do
    echo "  $path"
  done

  if [ "$assume_yes" -eq 0 ]; then
    if [ -t 0 ]; then
      local prompt answer
      if [ "$with_data" -eq 1 ]; then
        prompt="Remove the configuration AND DATA for tinyauth? This deletes the litefs-backed database. [y/N] "
      else
        prompt="Remove the configuration for tinyauth? [y/N] "
      fi
      if ! read -r -p "$prompt" answer; then
        answer=""
      fi
      case "${answer:-N}" in
      [Yy] | [Yy][Ee][Ss]) ;;
      [Nn] | [Nn][Oo] | "")
        echo "Aborted. Nothing removed."
        return 0
        ;;
      *)
        echo "error: Answer Y or N." >&2
        return 1
        ;;
      esac
    else
      echo "Aborted. Nothing removed."
      echo "hint: Pass --yes to remove without a prompt."
      return 0
    fi
  fi

  rm -rf -- "$config_target"
  if [ "$with_data" -eq 1 ]; then
    rm -rf -- "$data_target"
  fi
  local removed_path
  for removed_path in "${remove_paths[@]}"; do
    echo "removed: $removed_path"
  done
  echo "Removed the tinyauth configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the tinyauth data."
  fi
  echo "Run 'bash setup.sh tinyauth' to generate fresh files for a future install."
  echo "hint: the litefs cluster state in consul is not removed."
  return 0
}

# Print manual observer steps. Use this when auto-create cannot run.
print_manual_observer_steps() {
  echo "Create the observer user in LLDAP by hand:"
  echo "  1. Open the LLDAP web UI and select the Users tab."
  echo "  2. Create a user named $OBSERVER_USER with an email address and a password."
  echo "  3. Open the user details and select group memberships."
  echo "  4. Add the user to the $OBSERVER_GROUP group."
  echo "  5. Enter the bind DN and the password for that user below."
  echo "hint: the typical bind DN is uid=$OBSERVER_USER,ou=people,<base DN>."
}

# Quote a string as a JSON string. python3 prints the quoted value.
json_quote() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

# Print the value of one string field from a flat JSON response.
json_field() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | cut -d'"' -f4
}

# Log in to LLDAP and print the bearer token on stdout.
lldap_login() {
  local admin_user="$1" admin_pass="$2" payload response
  payload="$(printf '{"username":%s,"password":%s}' \
    "$(json_quote "$admin_user")" "$(json_quote "$admin_pass")")"
  response="$(printf '%s' "$payload" | curl -fsS \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "$LLDAP_HTTP_URL/auth/simple/login")" || return 1
  printf '%s' "$response" | json_field token
}

# Send a GraphQL request and print the response on stdout.
graphql_request() {
  local token="$1" body="$2"
  printf '%s' "$body" | curl -fsS \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    --data-binary @- \
    "$LLDAP_HTTP_URL/api/graphql"
}

# Return 0 when a GraphQL response has no top-level errors.
graphql_ok() {
  if printf '%s' "$1" | grep -q '"errors"'; then
    return 1
  fi
  return 0
}

# Create the observer in LLDAP through the GraphQL API and set its password.
# Return 1 when any step fails. The caller then uses the manual path.
auto_create_observer() {
  local admin_user="$1" admin_pass="$2" base_dn="$3"
  command -v curl >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  command -v docker >/dev/null 2>&1 || return 1
  [ -n "$admin_pass" ] || return 1

  local token login_response observer_email group_id body response
  login_response="$(lldap_login "$admin_user" "$admin_pass")" || return 1
  token="$login_response"
  [ -n "$token" ] || return 1

  observer_email="${OBSERVER_USER}@${base_dn//dc=/}"
  observer_email="${observer_email//,/.}"
  # The dollar signs below are GraphQL variables, not shell variables.
  # shellcheck disable=SC2016
  body="$(printf '{"query":"mutation CreateUser($user: CreateUserInput!) { createUser(user: $user) { id } }","variables":{"user":{"id":%s,"email":%s,"displayName":%s}}}' \
    "$(json_quote "$OBSERVER_USER")" "$(json_quote "$observer_email")" \
    "$(json_quote 'Tinyauth LDAP observer')")"
  response="$(graphql_request "$token" "$body")" || return 1
  graphql_ok "$response" || return 1

  body='{"query":"query GetGroupList { groups { id displayName } }"}'
  response="$(graphql_request "$token" "$body")" || return 1
  graphql_ok "$response" || return 1
  group_id="$(printf '%s' "$response" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for group in data.get("data", {}).get("groups", []):
        if group.get("displayName") == "lldap_strict_readonly":
            print(group["id"])
            break
except Exception:
    pass
')"
  [ -n "$group_id" ] || return 1

  # shellcheck disable=SC2016
  body="$(printf '{"query":"mutation AddUserToGroup($user: String!, $group: Int!) { addUserToGroup(userId: $user, groupId: $group) { ok } }","variables":{"user":%s,"group":%s}}' \
    "$(json_quote "$OBSERVER_USER")" "$group_id")"
  response="$(graphql_request "$token" "$body")" || return 1
  graphql_ok "$response" || return 1

  # The upstream helper sets the password through the OPAQUE endpoints.
  # It lives in the LLDAP image. Pass the value through the environment so
  # it does not appear in the docker command line.
  if ! (
    export LLDAP_USER_PASSWORD="$observer_password"
    docker compose exec -T -e LLDAP_USER_PASSWORD \
      lldap /app/lldap_set_password \
      --base-url http://127.0.0.1:17170 \
      --token "$token" \
      --username "$OBSERVER_USER"
  ) >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Write a secret file with mode 0600 and no trailing newline.
write_secret_file() {
  local path="$1" value="$2"
  (
    umask 077
    printf '%s' "$value" >"$path"
  )
  chmod 0600 "$path"
}

# Return 0 when the line's key is one that this wizard manages.
is_managed_key() {
  local key="$1"
  case "$key" in
  TINYAUTH_APPURL | TINYAUTH_DATABASE_PATH | \
    TINYAUTH_OIDC_PRIVATEKEYPATH | TINYAUTH_OIDC_PUBLICKEYPATH | \
    TINYAUTH_LDAP_* | TINYAUTH_OIDC_CLIENTS_*) return 0 ;;
  *) return 1 ;;
  esac
}

# The clean subcommand removes the tinyauth configuration and data.
if [ "${1:-}" = "clean" ]; then
  shift
  clean_service "$@"
  exit 0
fi

# Step 1: fail early when openssl is missing.
if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl is not on PATH. Install openssl first." >&2
  exit 1
fi

# Step 2: resolve and validate the stack domain before writing anything.
resolve_stack_domain
if ! is_valid_stack_domain "$stack_domain"; then
  stack_domain_invalid
fi
readonly ISSUER="https://tinyauth.${stack_domain}"
readonly DISCOVERY_URL="${ISSUER}/.well-known/openid-configuration"

# Step 3: resolve the LDAP source and the base DN.
local_ldap=1
ldap_address="$DEFAULT_LDAP_ADDRESS"
base_dn=""
if [ -t 0 ]; then
  if ! read -r -p "Use the LLDAP service in this repo? [Y/n] " answer; then
    answer=""
  fi
  case "${answer:-Y}" in
  [Yy] | [Yy][Ee][Ss]) local_ldap=1 ;;
  [Nn] | [Nn][Oo]) local_ldap=0 ;;
  *)
    echo "error: Answer Y or N." >&2
    exit 1
    ;;
  esac
else
  case "${TINYAUTH_LDAP_LOCAL:-yes}" in
  [Yy] | [Yy][Ee][Ss] | 1) local_ldap=1 ;;
  [Nn] | [Nn][Oo] | 0) local_ldap=0 ;;
  *)
    echo "error: TINYAUTH_LDAP_LOCAL must be yes or no." >&2
    exit 1
    ;;
  esac
fi

if [ "$local_ldap" -eq 1 ]; then
  base_dn="$(read_lldap_config_value ldap_base_dn)"
  if [ -t 0 ] && [ -z "$base_dn" ]; then
    if ! read -r -p "LDAP base DN? [$DEFAULT_BASE_DN] " answer; then
      answer=""
    fi
    base_dn="${answer:-$DEFAULT_BASE_DN}"
  fi
else
  if [ -t 0 ]; then
    if ! read -r -p "LDAP address? [$DEFAULT_LDAP_ADDRESS] " answer; then
      answer=""
    fi
    ldap_address="${answer:-$DEFAULT_LDAP_ADDRESS}"
    if ! read -r -p "LDAP base DN? [$DEFAULT_BASE_DN] " answer; then
      answer=""
    fi
    base_dn="${answer:-$DEFAULT_BASE_DN}"
  else
    ldap_address="${TINYAUTH_LDAP_ADDRESS:-}"
    base_dn="${TINYAUTH_LDAP_BASEDN:-}"
  fi
fi

if [ "$local_ldap" -eq 0 ] && [ -n "${TINYAUTH_LDAP_BASEDN:-}" ]; then
  base_dn="$TINYAUTH_LDAP_BASEDN"
fi
if [ -z "$base_dn" ]; then
  echo "error: LDAP base DN is not set." >&2
  echo "error: Set TINYAUTH_LDAP_BASEDN or run the lldap wizard first." >&2
  exit 1
fi
if ! is_valid_base_dn "$base_dn"; then
  echo "error: '$base_dn' is not a valid LDAP base DN." >&2
  echo "error: Use comma-separated attribute=value components." >&2
  exit 1
fi
if ! is_valid_ldap_address "$ldap_address"; then
  echo "error: '$ldap_address' is not a valid LDAP URL." >&2
  echo "error: Use ldap://host:port or ldaps://host:port." >&2
  exit 1
fi

# Step 4: resolve the observer user.
observer_auto=1
if [ -t 0 ]; then
  if ! read -r -p "Create the observer user in LLDAP automatically? [Y/n] " answer; then
    answer=""
  fi
  case "${answer:-Y}" in
  [Yy] | [Yy][Ee][Ss]) observer_auto=1 ;;
  [Nn] | [Nn][Oo]) observer_auto=0 ;;
  *)
    echo "error: Answer Y or N." >&2
    exit 1
    ;;
  esac
else
  case "${TINYAUTH_OBSERVER_AUTO:-yes}" in
  [Yy] | [Yy][Ee][Ss] | 1) observer_auto=1 ;;
  [Nn] | [Nn][Oo] | 0) observer_auto=0 ;;
  *)
    echo "error: TINYAUTH_OBSERVER_AUTO must be yes or no." >&2
    exit 1
    ;;
  esac
fi

mkdir -p "$SECRETS_DIR" "$OIDC_SECRETS_DIR" "$STORE_DIR"
chmod 0700 "$CONFIG_DIR" "$SECRETS_DIR" "$OIDC_SECRETS_DIR" "$STORE_DIR"

observer_dn=""
observer_password=""
observer_state="kept"
if [ -s "$LDAP_SECRET_FILE" ]; then
  observer_password="$(cat "$LDAP_SECRET_FILE")"
  observer_dn="$(read_env_value TINYAUTH_LDAP_BINDDN "$ENV_FILE")"
  echo "Keeping the existing observer password at $LDAP_SECRET_FILE."
else
  observer_state="created"
  observer_dn="uid=${OBSERVER_USER},ou=people,${base_dn}"
  observer_password="$(openssl rand -hex 24)"

  admin_pass="$(read_lldap_config_value ldap_user_pass)"
  admin_user="${LLDAP_ADMIN_USER:-$DEFAULT_ADMIN_USER}"
  LLDAP_HTTP_URL="${LLDAP_HTTP_URL:-$DEFAULT_LLDAP_HTTP_URL}"
  export LLDAP_HTTP_URL

  auto_ok=0
  if [ "$observer_auto" -eq 1 ] && [ -n "$admin_pass" ]; then
    if auto_create_observer "$admin_user" "$admin_pass" "$base_dn"; then
      auto_ok=1
    fi
  fi

  if [ "$auto_ok" -eq 1 ]; then
    echo "Created the observer user in LLDAP."
    echo "Added the observer user to the $OBSERVER_GROUP group."
    echo "Set the observer password with the LLDAP password helper."
  else
    if [ "$observer_auto" -eq 1 ]; then
      echo "warning: Automatic observer creation did not finish." >&2
    fi
    print_manual_observer_steps
    if [ -t 0 ]; then
      if ! read -r -p "Observer bind DN? [$observer_dn] " answer; then
        answer=""
      fi
      observer_dn="${answer:-$observer_dn}"
      if ! read -r -s -p "Observer password? " answer; then
        echo >&2
        echo "error: No observer password was entered." >&2
        exit 1
      fi
      echo >&2
      [ -n "$answer" ] || {
        echo "error: No observer password was entered." >&2
        exit 1
      }
      observer_password="$answer"
    else
      observer_dn="${TINYAUTH_LDAP_BINDDN:-$observer_dn}"
      observer_password="${TINYAUTH_LDAP_BINDPASSWORD:-}"
      if [ -z "$observer_password" ]; then
        echo "error: TINYAUTH_LDAP_BINDPASSWORD is not set." >&2
        echo "error: Set it or run the wizard on a terminal." >&2
        exit 1
      fi
    fi
  fi
  write_secret_file "$LDAP_SECRET_FILE" "$observer_password"
fi

# Step 5: collect the OIDC clients. Existing secret files are kept.
declare -a client_names=()
declare -A client_uris=()
if [ -d "$OIDC_SECRETS_DIR" ]; then
  for secret_path in "$OIDC_SECRETS_DIR"/*; do
    [ -f "$secret_path" ] || continue
    client_name="$(basename "$secret_path")"
    is_valid_client_name "$client_name" || continue
    client_names+=("$client_name")
    client_uris["$client_name"]=""
  done
fi

add_client_answer() {
  local name="$1" uris="$2" existing key seen
  if ! is_valid_client_name "$name"; then
    echo "error: '$name' is not a valid client name." >&2
    echo "error: Use lowercase letters, digits, and hyphens between words." >&2
    return 1
  fi
  if [ -z "$uris" ]; then
    echo "error: client '$name' has no redirect URI." >&2
    return 1
  fi
  local -a uris_array=()
  IFS=',' read -r -a uris_array <<<"$uris"
  local uri
  for uri in "${uris_array[@]}"; do
    if ! is_valid_redirect_uri "$uri"; then
      echo "error: '$uri' is not a valid redirect URI." >&2
      echo "error: Use an HTTPS URL such as https://app.example.com/callback." >&2
      return 1
    fi
  done

  key="$(client_env_prefix "$name")"
  for existing in "${client_names[@]}"; do
    if [ "$key" = "$(client_env_prefix "$existing")" ]; then
      seen="$existing"
      break
    fi
  done
  if [ -z "${seen:-}" ]; then
    client_names+=("$name")
  fi
  client_uris["$name"]="$uris"
  return 0
}

if [ -n "${TINYAUTH_CLIENTS:-}" ]; then
  IFS=';' read -r -a entries <<<"$TINYAUTH_CLIENTS"
  for entry in "${entries[@]}"; do
    [ -n "$entry" ] || continue
    client_name="${entry%%:*}"
    redirect_uris="${entry#*:}"
    add_client_answer "$client_name" "$redirect_uris"
  done
elif [ -t 0 ]; then
  while true; do
    if ! read -r -p "Add an OIDC client? [y/N] " answer; then
      answer=""
    fi
    case "${answer:-N}" in
    [Yy] | [Yy][Ee][Ss]) ;;
    [Nn] | [Nn][Oo] | "") break ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
    if ! read -r -p "Client name? " client_name; then
      exit 1
    fi
    if ! read -r -p "Redirect URIs, comma-separated? " redirect_uris; then
      exit 1
    fi
    add_client_answer "$client_name" "$redirect_uris" || exit 1
  done
fi

# Step 6: write the environment file. Keep lines this wizard does not own.
tmp_env="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    case "$line" in
    '' | \#*) printf '%s\n' "$line" >>"$tmp_env" ;;
    *)
      if is_managed_key "$key"; then
        continue
      fi
      printf '%s\n' "$line" >>"$tmp_env"
      ;;
    esac
  done <"$ENV_FILE"
fi

{
  printf '# Generated by state/tinyauth/setup.sh.\n'
  printf '# Do not commit this file. Secrets stay in 0600 files under secrets/.\n'
  printf 'TINYAUTH_APPURL=%s\n' "$ISSUER"
  printf 'TINYAUTH_DATABASE_PATH=/data/tinyauth.db\n'
  printf 'TINYAUTH_OIDC_PRIVATEKEYPATH=/data/oidc/private.pem\n'
  printf 'TINYAUTH_OIDC_PUBLICKEYPATH=/data/oidc/public.pem\n'
  printf 'TINYAUTH_LDAP_ADDRESS=%s\n' "$ldap_address"
  printf 'TINYAUTH_LDAP_BASEDN=%s\n' "$base_dn"
  printf 'TINYAUTH_LDAP_BINDDN=%s\n' "$observer_dn"
  printf 'TINYAUTH_LDAP_BINDPASSWORDFILE=/etc/tinyauth/secrets/ldap-observer\n'
  printf 'TINYAUTH_LDAP_SEARCHFILTER=(uid=%%s)\n'
  ldap_insecure=true
  case "$ldap_address" in
  ldaps://*) ldap_insecure=false ;;
  esac
  printf 'TINYAUTH_LDAP_INSECURE=%s\n' "$ldap_insecure"
} >>"$tmp_env"

rotate="${TINYAUTH_ROTATE_CLIENTS:-0}"
for client_name in "${client_names[@]}"; do
  prefix="$(client_env_prefix "$client_name")"
  secret_path="${OIDC_SECRETS_DIR}/${client_name}"
  uris="${client_uris[$client_name]}"
  if [ -z "$uris" ]; then
    uris="$(read_env_value "TINYAUTH_OIDC_CLIENTS_${prefix}_TRUSTEDREDIRECTURIS" "$ENV_FILE")"
  fi
  if [ -z "$uris" ]; then
    echo "error: client '$client_name' has no redirect URIs on record." >&2
    echo "error: Pass TINYAUTH_CLIENTS with the URIs for that client." >&2
    rm -f "$tmp_env"
    exit 1
  fi
  client_state="kept"
  if [ ! -s "$secret_path" ] || [ "$rotate" = "1" ]; then
    client_state="created"
    client_id="$(openssl rand -hex 12)"
    client_secret="$(openssl rand -hex 32)"
    write_secret_file "$secret_path" "$client_secret"
  else
    client_id="$(read_env_value "TINYAUTH_OIDC_CLIENTS_${prefix}_CLIENTID" "$ENV_FILE")"
    if [ -z "$client_id" ]; then
      client_id="$(openssl rand -hex 12)"
    fi
  fi
  {
    printf 'TINYAUTH_OIDC_CLIENTS_%s_CLIENTID=%s\n' "$prefix" "$client_id"
    printf 'TINYAUTH_OIDC_CLIENTS_%s_CLIENTSECRETFILE=/etc/tinyauth/secrets/oidc/%s\n' "$prefix" "$client_name"
    printf 'TINYAUTH_OIDC_CLIENTS_%s_TRUSTEDREDIRECTURIS=%s\n' "$prefix" "$uris"
    printf 'TINYAUTH_OIDC_CLIENTS_%s_NAME=%s\n' "$prefix" "$client_name"
  } >>"$tmp_env"
  echo "Configured client '$client_name' (secret $client_state) at $secret_path."
done

chmod 0640 "$tmp_env"
mv "$tmp_env" "$ENV_FILE"

# Step 7: print the summary. Never print secret values.
echo "Configured the tinyauth configuration:"
echo "  $ENV_FILE"
echo "  $LDAP_SECRET_FILE (observer secret $observer_state)"
echo "  $OIDC_SECRETS_DIR (client secrets, mode 0600)"
echo "Issuer: $ISSUER"
echo "Discovery URL: $DISCOVERY_URL"
echo "LDAP address: $ldap_address"
echo "Base DN: $base_dn"
echo "hint: LiteFS elects a primary through a consul lease (key tinyauth/litefs)."
echo "hint: only the litefs primary can write the database."
echo "Next step: docker compose up -d tinyauth"
echo "hint: the caddy vhost for tinyauth.$stack_domain lands on feature/caddy."
