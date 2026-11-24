#!/usr/bin/env bash
# Generate the Vaultwarden wizard files for this stack.
# Vaultwarden uses OIDC through Tinyauth. It does not read CONSUL_ADDR.
# Consul is still required by the root setup. The Vaultwarden container does
# not use Consul.
# Safe to run again: it rewrites the managed keys and keeps the other lines.
# It never prints secret values. It prints paths only.
# The official image runs as uid 1000 and listens on port 80.
#
# Usage:
#   setup.sh vaultwarden                          Run the Vaultwarden wizard.
#   setup.sh vaultwarden clean [--data] [--yes]   Remove the vaultwarden
#                                                 configuration. With --data
#                                                 also remove the vaultwarden
#                                                 data. Ask for confirmation
#                                                 unless --yes is set.
#
# Non-interactive environment variables:
#   STACK_DOMAIN                     Stack domain. Read from the environment,
#                                    then the root .env, then sh.lan.
#   VAULTWARDEN_DOMAIN               Public Vaultwarden URL. Default:
#                                    https://vaultwarden.<STACK_DOMAIN>.
#   VAULTWARDEN_OIDC_ISSUER          OIDC issuer. Required when no local
#                                    Tinyauth exists. Must start with https://.
#   VAULTWARDEN_OIDC_CLIENT_ID       OIDC client ID. Default: vaultwarden.
#   VAULTWARDEN_OIDC_CLIENT_SECRET   OIDC client secret. When empty, the
#                                    wizard reads the Tinyauth client secret
#                                    file or keeps the existing secret.
#   VAULTWARDEN_SSO_SIGNUPS          yes or no. Allow new users through SSO.
#                                    Default: yes.
#   VAULTWARDEN_ROTATE_OIDC_SECRET   1 to replace the existing OIDC secret with
#                                    the supplied or Tinyauth secret. Default 0.
#   VAULTWARDEN_ADMIN_TOKEN          Optional admin token. Writes the secret
#                                    file config/vaultwarden/secrets/admin_token
#                                    with no prompt.
#   VAULTWARDEN_SMTP_HOST            Optional SMTP settings. Writes SMTP_HOST,
#   VAULTWARDEN_SMTP_FROM            SMTP_FROM, SMTP_PORT, SMTP_SECURITY, and
#   VAULTWARDEN_SMTP_PORT            SMTP_USERNAME with no prompt.
#   VAULTWARDEN_SMTP_SECURITY        VAULTWARDEN_SMTP_PASSWORD writes the secret
#   VAULTWARDEN_SMTP_USERNAME        file config/vaultwarden/secrets/smtp_password.
#   VAULTWARDEN_SMTP_PASSWORD
#   PUBLIC_IP                        Compose only. This wizard does not read it.
#
# The Tinyauth client secret lives at config/tinyauth/secrets/oidc/vaultwarden
# when the local Tinyauth wizard created it. The wizard reads that file when it
# exists. The operator adds the Tinyauth client with the name "vaultwarden" and
# the redirect URI https://vaultwarden.<STACK_DOMAIN>/identity/connect/oidc-signin.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly CONFIG_DIR="config/vaultwarden"
readonly SECRETS_DIR="config/vaultwarden/secrets"
readonly ENV_FILE="config/vaultwarden/vaultwarden.env"
readonly OIDC_SECRET_FILE="config/vaultwarden/secrets/oidc-client-secret"
readonly ADMIN_SECRET_FILE="config/vaultwarden/secrets/admin_token"
readonly SMTP_SECRET_FILE="config/vaultwarden/secrets/smtp_password"
readonly STORE_DIR="data/vaultwarden/store"
readonly TINYAUTH_SETUP="state/tinyauth/setup.sh"
readonly TINYAUTH_SECRET="config/tinyauth/secrets/oidc/vaultwarden"

readonly DEFAULT_STACK_DOMAIN="sh.lan"
readonly DEFAULT_CLIENT_ID="vaultwarden"
readonly APP_UID=1000
readonly APP_GID=1000

# Print one value from a KEY=VALUE file. Print nothing when the key is absent.
read_env_value() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  { grep -E "^${key}=" "$file" || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/"
}

# Print the STACK_DOMAIN value from the root .env file.
read_env_stack_domain() {
  read_env_value STACK_DOMAIN .env
}

# Resolve the stack domain. Set stack_domain and stack_domain_source.
# The order is: the environment, then the root .env, then sh.lan.
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

# Return 0 when the argument is a valid stack domain.
# Letters, digits, dots, and hyphens. At least one character.
is_valid_stack_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,252})$ ]]
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

# Print the argument with an https:// scheme when it has no scheme.
normalize_public_url() {
  case "$1" in
  http://* | https://*) printf '%s\n' "$1" ;;
  *) printf 'https://%s\n' "$1" ;;
  esac
}

# Return 0 when the argument is an HTTPS URL with a host.
is_valid_https_url() {
  [[ "$1" =~ ^https://[A-Za-z0-9][A-Za-z0-9.:_-]*(/[^[:space:]]*)?$ ]]
}

# Return 0 when the argument is a valid OIDC client ID.
# The value has no whitespace.
is_valid_client_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:@/-]*$ ]]
}

# Return 0 when the argument is yes, no, or the value true, false, 1, or 0.
is_yes_no() {
  case "$1" in
  [Yy] | [Yy][Ee][Ss] | [Nn] | [Nn][Oo] | 0 | 1 | true | false) return 0 ;;
  *) return 1 ;;
  esac
}

# Print true when the yes-or-no argument means yes. Print false otherwise.
yes_no_to_bool() {
  case "$1" in
  [Yy] | [Yy][Ee][Ss] | 1 | true) printf 'true\n' ;;
  *) printf 'false\n' ;;
  esac
}

# Read one secret file. Print nothing when the file is missing or empty.
read_secret_file() {
  local path="$1"
  [ -s "$path" ] || return 0
  cat "$path"
}

# Write one secret to a file with mode 0600 and no trailing newline.
write_secret_file() {
  local path="$1" value="$2"
  (
    umask 077
    printf '%s' "$value" >"${path}.tmp"
    mv "${path}.tmp" "$path"
  )
  chmod 0600 "$path"
}

# Make one secret file readable by uid 1000.
# Use chown first. When chown fails, use chgrp with mode 0640.
# Print a warning when neither method works. Never print the value.
make_secret_readable() {
  local path="$1"
  if chown "${APP_UID}:${APP_GID}" "$path" 2>/dev/null; then
    chmod 0600 "$path"
    return 0
  fi
  if chgrp "$APP_GID" "$path" 2>/dev/null; then
    chmod 0640 "$path"
    return 0
  fi
  echo "warning: cannot give uid $APP_UID read access to $path." >&2
  echo "warning: Set the owner or group by hand. The container runs as uid $APP_UID." >&2
  return 1
}

# Create the data store with mode 0700 and owner 1000:1000 when possible.
prepare_store_dir() {
  mkdir -p "$STORE_DIR"
  chmod 0700 "$STORE_DIR"
  if chown "${APP_UID}:${APP_GID}" "$STORE_DIR" 2>/dev/null; then
    return 0
  fi
  echo "warning: cannot set the owner of $STORE_DIR to $APP_UID:$APP_GID." >&2
  echo "warning: The container runs as uid $APP_UID. Set the owner by hand." >&2
  return 1
}

# Create the secret directory with mode 0700 and owner 1000:1000 when possible.
# The container mounts the directory and runs as uid 1000. It must traverse it.
prepare_secrets_dir() {
  mkdir -p "$SECRETS_DIR"
  chmod 0700 "$SECRETS_DIR"
  if chown "${APP_UID}:${APP_GID}" "$SECRETS_DIR" 2>/dev/null; then
    return 0
  fi
  echo "warning: cannot set the owner of $SECRETS_DIR to $APP_UID:$APP_GID." >&2
  echo "warning: The container runs as uid $APP_UID and must traverse this directory." >&2
  echo "warning: Set the owner by hand." >&2
  return 1
}

# Write an optional secret file. Keep the existing file when the value is empty.
# Print one state word: created, rotated, kept, or absent. Never print the value.
write_optional_secret() {
  local path="$1" value="$2" state="absent"
  if [ -n "$value" ]; then
    if [ -s "$path" ]; then
      state="rotated"
    else
      state="created"
    fi
    write_secret_file "$path" "$value"
  elif [ -s "$path" ]; then
    state="kept"
  fi
  if [ -s "$path" ]; then
    chmod 0600 "$path"
    make_secret_readable "$path" || true
  fi
  printf '%s\n' "$state"
}

# Return 0 when the line is one header that this wizard writes.
is_generated_header() {
  case "$1" in
  '# Generated by state/vaultwarden/setup.sh.' | \
    '# Do not commit this file. Secrets stay in 0600 files under secrets/.' | \
    '# Do not commit this file. The OIDC secret stays in a 0600 file under secrets/.') return 0 ;;
  *) return 1 ;;
  esac
}

# Return 0 when the key is one that this wizard manages.
is_managed_key() {
  local key="$1"
  case "$key" in
  DOMAIN | SSO_ENABLED | SSO_ONLY | SSO_AUTHORITY | SSO_CLIENT_ID | \
    SSO_CLIENT_SECRET_FILE | SSO_SCOPES | SSO_PKCE | SSO_SIGNUPS_ALLOWED | \
    SSO_SIGNUPS_MATCH_EMAIL | SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION | \
    SIGNUPS_ALLOWED | SENDS_ALLOWED | USER_ATTACHMENT_LIMIT | \
    ORG_ATTACHMENT_LIMIT | USER_SEND_LIMIT | SIGNUPS_VERIFY | \
    REQUIRE_DEVICE_EMAIL | ENABLE_WEBSOCKET | IP_HEADER | ADMIN_TOKEN | \
    ADMIN_TOKEN_FILE | SMTP_PASSWORD | SMTP_PASSWORD_FILE) return 0 ;;
  *) return 1 ;;
  esac
}

# Return 0 when an optional environment variable sets this key.
# The optional values never prompt. An unset variable keeps a manual line.
optional_key_is_set() {
  local key="$1"
  case "$key" in
  SMTP_HOST) [ -n "${VAULTWARDEN_SMTP_HOST:-}" ] ;;
  SMTP_FROM) [ -n "${VAULTWARDEN_SMTP_FROM:-}" ] ;;
  SMTP_PORT) [ -n "${VAULTWARDEN_SMTP_PORT:-}" ] ;;
  SMTP_SECURITY) [ -n "${VAULTWARDEN_SMTP_SECURITY:-}" ] ;;
  SMTP_USERNAME) [ -n "${VAULTWARDEN_SMTP_USERNAME:-}" ] ;;
  *) return 1 ;;
  esac
}

# Return 0 when the value has no newline.
is_single_line() {
  case "$1" in
  *$'\n'* | *$'\r'*) return 1 ;;
  *) return 0 ;;
  esac
}

usage_clean() {
  echo "usage: setup.sh vaultwarden clean [--data] [--yes]" >&2
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

# Remove the vaultwarden configuration. With --data also remove the data.
# Never touch state/, .env, other services, or paths outside the two trees.
clean_service() {
  local with_data=0 assume_yes=0 flag
  for flag in "$@"; do
    case "$flag" in
    --data)
      with_data=1
      ;;
    --yes)
      assume_yes=1
      ;;
    *)
      echo "error: Unknown flag '$flag'." >&2
      usage_clean
      exit 2
      ;;
    esac
  done

  if [ -L "$REPO_ROOT/config/vaultwarden" ]; then
    echo "error: '$REPO_ROOT/config/vaultwarden' is a symlink. Refusing to remove it." >&2
    exit 1
  fi
  if [ "$with_data" -eq 1 ] && [ -L "$REPO_ROOT/data/vaultwarden" ]; then
    echo "error: '$REPO_ROOT/data/vaultwarden' is a symlink. Refusing to remove it." >&2
    exit 1
  fi

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/vaultwarden" "$REPO_ROOT/config/vaultwarden")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/vaultwarden" "$REPO_ROOT/data/vaultwarden")" || exit 1
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
        prompt="Remove the configuration AND DATA for vaultwarden? This deletes the SQLite database. [y/N] "
      else
        prompt="Remove the configuration for vaultwarden? [y/N] "
      fi
      if ! read -r -p "$prompt" answer; then
        answer=""
      fi
      case "${answer:-N}" in
      [Yy] | [Yy][Ee][Ss])
        ;;
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
  echo "Removed the vaultwarden configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the vaultwarden data."
  fi
  echo "Run 'bash setup.sh vaultwarden' to generate fresh files for a future install."
  return 0
}

# The clean subcommand removes the vaultwarden configuration and data.
if [ "${1:-}" = "clean" ]; then
  shift
  clean_service "$@"
  exit 0
fi

# Step 1: resolve the stack domain and the local Tinyauth state.
resolve_stack_domain
if ! is_valid_stack_domain "$stack_domain"; then
  stack_domain_invalid
fi
readonly STACK_DOMAIN_RESOLVED="$stack_domain"

local_tinyauth=0
if [ -f "$TINYAUTH_SETUP" ] && [ -r "$TINYAUTH_SETUP" ]; then
  local_tinyauth=1
fi

default_issuer=""
if [ "$local_tinyauth" -eq 1 ]; then
  default_issuer="https://tinyauth.${STACK_DOMAIN_RESOLVED}"
fi

# Step 2: resolve the answers. Read the environment first, then the existing
# answer file, then the default. Nothing is written before validation.
if [ -n "${VAULTWARDEN_DOMAIN:-}" ]; then
  public_url="$(normalize_public_url "$VAULTWARDEN_DOMAIN")"
else
  public_url="https://vaultwarden.${STACK_DOMAIN_RESOLVED}"
fi

issuer=""
if [ -n "${VAULTWARDEN_OIDC_ISSUER:-}" ]; then
  issuer="$VAULTWARDEN_OIDC_ISSUER"
elif [ -n "$(read_env_value SSO_AUTHORITY "$ENV_FILE")" ]; then
  issuer="$(read_env_value SSO_AUTHORITY "$ENV_FILE")"
else
  issuer="$default_issuer"
fi

client_id=""
if [ -n "${VAULTWARDEN_OIDC_CLIENT_ID:-}" ]; then
  client_id="$VAULTWARDEN_OIDC_CLIENT_ID"
elif [ -n "$(read_env_value SSO_CLIENT_ID "$ENV_FILE")" ]; then
  client_id="$(read_env_value SSO_CLIENT_ID "$ENV_FILE")"
else
  client_id="$DEFAULT_CLIENT_ID"
fi

signups=""
if [ -n "${VAULTWARDEN_SSO_SIGNUPS:-}" ]; then
  signups="$VAULTWARDEN_SSO_SIGNUPS"
elif [ -n "$(read_env_value SSO_SIGNUPS_ALLOWED "$ENV_FILE")" ]; then
  signups="$(read_env_value SSO_SIGNUPS_ALLOWED "$ENV_FILE")"
else
  signups="yes"
fi

rotate=0
case "${VAULTWARDEN_ROTATE_OIDC_SECRET:-0}" in
0 | 1) rotate="${VAULTWARDEN_ROTATE_OIDC_SECRET:-0}" ;;
*)
  echo "error: VAULTWARDEN_ROTATE_OIDC_SECRET must be 0 or 1." >&2
  exit 1
  ;;
esac

client_secret="${VAULTWARDEN_OIDC_CLIENT_SECRET:-}"
secret_source=""
if [ -n "$client_secret" ]; then
  secret_source="environment"
elif [ "$local_tinyauth" -eq 1 ] && [ -s "$TINYAUTH_SECRET" ]; then
  client_secret="$(read_secret_file "$TINYAUTH_SECRET")"
  secret_source="tinyauth"
fi

# Step 3: ask the questions when stdin is a terminal.
if [ -t 0 ]; then
  if [ -n "$issuer" ]; then
    if ! read -r -p "OIDC issuer URL? [$issuer] " answer; then
      answer=""
    fi
  else
    if ! read -r -p "OIDC issuer URL? " answer; then
      answer=""
    fi
  fi
  if [ -n "$answer" ]; then
    issuer="$answer"
  fi

  if ! read -r -p "OIDC client ID? [$client_id] " answer; then
    answer=""
  fi
  if [ -n "$answer" ]; then
    client_id="$answer"
  fi

  if [ "$secret_source" = "tinyauth" ]; then
    echo "Using the Tinyauth client secret at $TINYAUTH_SECRET."
    echo "hint: Change the secret in the Tinyauth client, then run the wizard again."
  else
    if [ -s "$OIDC_SECRET_FILE" ]; then
      if ! read -r -s -p "OIDC client secret? Leave empty to keep the existing secret: " answer; then
        answer=""
      fi
    else
      if ! read -r -s -p "OIDC client secret? " answer; then
        answer=""
      fi
    fi
    echo >&2
    if [ -n "$answer" ]; then
      client_secret="$answer"
      secret_source="answer"
    fi
  fi

  if ! read -r -p "Allow new users through SSO? [Y/n] " answer; then
    answer=""
  fi
  case "${answer:-Y}" in
  [Yy] | [Yy][Ee][Ss]) signups="yes" ;;
  [Nn] | [Nn][Oo]) signups="no" ;;
  *)
    echo "error: Answer Y or N." >&2
    exit 1
    ;;
  esac
fi

# Step 4: validate every answer before any file is written.
if ! is_valid_https_url "$public_url"; then
  echo "error: '$public_url' is not a valid public URL." >&2
  echo "error: Use an HTTPS URL such as https://vaultwarden.example.com." >&2
  exit 1
fi
if [ -z "$issuer" ]; then
  echo "error: The OIDC issuer is not set." >&2
  echo "error: Set VAULTWARDEN_OIDC_ISSUER or run the wizard on a terminal." >&2
  exit 1
fi
if ! is_valid_https_url "$issuer"; then
  echo "error: '$issuer' is not a valid OIDC issuer." >&2
  echo "error: The issuer must start with https:// and have a host." >&2
  exit 1
fi
if [ -z "$client_id" ]; then
  echo "error: The OIDC client ID is not set." >&2
  echo "error: Set VAULTWARDEN_OIDC_CLIENT_ID or run the wizard on a terminal." >&2
  exit 1
fi
if ! is_valid_client_id "$client_id"; then
  echo "error: '$client_id' is not a valid OIDC client ID." >&2
  echo "error: Use letters, digits, dots, underscores, hyphens, and no whitespace." >&2
  exit 1
fi
if ! is_yes_no "$signups"; then
  echo "error: VAULTWARDEN_SSO_SIGNUPS must be yes or no." >&2
  exit 1
fi
case "$client_secret" in
*$'\n'* | *$'\r'*)
  echo "error: The OIDC client secret must not contain a newline." >&2
  exit 1
  ;;
esac
if [ -n "${VAULTWARDEN_ADMIN_TOKEN:-}" ] && ! is_single_line "$VAULTWARDEN_ADMIN_TOKEN"; then
  echo "error: VAULTWARDEN_ADMIN_TOKEN must not contain a newline." >&2
  exit 1
fi
for name in VAULTWARDEN_SMTP_HOST VAULTWARDEN_SMTP_FROM VAULTWARDEN_SMTP_PORT \
  VAULTWARDEN_SMTP_SECURITY VAULTWARDEN_SMTP_USERNAME VAULTWARDEN_SMTP_PASSWORD; do
  value="${!name:-}"
  if [ -n "$value" ] && ! is_single_line "$value"; then
    echo "error: $name must not contain a newline." >&2
    exit 1
  fi
done
if [ -z "$client_secret" ] && [ ! -s "$OIDC_SECRET_FILE" ]; then
  echo "error: The OIDC client secret is not set." >&2
  echo "error: Set VAULTWARDEN_OIDC_CLIENT_SECRET or run the wizard on a terminal." >&2
  exit 1
fi

readonly PUBLIC_URL_RESOLVED="$public_url"
readonly ISSUER_RESOLVED="$issuer"
readonly CLIENT_ID_RESOLVED="$client_id"
SIGNUPS_BOOL="$(yes_no_to_bool "$signups")"
readonly SIGNUPS_BOOL

# Step 5: create the directory layout with strict modes.
mkdir -p "$CONFIG_DIR"
chmod 0700 "$CONFIG_DIR"
prepare_secrets_dir || true
prepare_store_dir || true

# Step 6: write the secret. Existing values are kept unless rotation is asked
# for, a new answer was given, or the local Tinyauth secret changed.
secret_state="kept"
if [ -n "$client_secret" ]; then
  if [ ! -s "$OIDC_SECRET_FILE" ]; then
    write_secret_file "$OIDC_SECRET_FILE" "$client_secret"
    secret_state="created"
  elif [ "$rotate" = "1" ]; then
    write_secret_file "$OIDC_SECRET_FILE" "$client_secret"
    secret_state="rotated"
  elif [ "$secret_source" = "tinyauth" ] || [ "$secret_source" = "answer" ]; then
    write_secret_file "$OIDC_SECRET_FILE" "$client_secret"
    secret_state="updated"
  elif [ "$secret_source" = "environment" ]; then
    echo "Kept the existing OIDC client secret at $OIDC_SECRET_FILE."
    echo "hint: Set VAULTWARDEN_ROTATE_OIDC_SECRET=1 to replace it."
  fi
else
  if [ "$rotate" = "1" ]; then
    echo "warning: VAULTWARDEN_ROTATE_OIDC_SECRET=1 has no new secret to write." >&2
    echo "warning: Set VAULTWARDEN_OIDC_CLIENT_SECRET or add the Tinyauth client secret." >&2
  fi
fi
chmod 0600 "$OIDC_SECRET_FILE"
make_secret_readable "$OIDC_SECRET_FILE" || true

# Step 6b: write the optional admin token and SMTP password to secret files.
# An unset variable keeps an existing file. Never print the values.
admin_state="$(write_optional_secret "$ADMIN_SECRET_FILE" "${VAULTWARDEN_ADMIN_TOKEN:-}")"
smtp_state="$(write_optional_secret "$SMTP_SECRET_FILE" "${VAULTWARDEN_SMTP_PASSWORD:-}")"

# Step 7: write the environment file. Keep lines that this wizard does not own.
tmp_env="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    case "$line" in
    '')
      printf '\n' >>"$tmp_env"
      ;;
    \#*)
      if is_generated_header "$line"; then
        continue
      fi
      printf '%s\n' "$line" >>"$tmp_env"
      ;;
    *)
      if is_managed_key "$key" || optional_key_is_set "$key"; then
        continue
      fi
      printf '%s\n' "$line" >>"$tmp_env"
      ;;
    esac
  done <"$ENV_FILE"
fi
{
  printf '# Generated by state/vaultwarden/setup.sh.\n'
  printf '# Do not commit this file. Secrets stay in 0600 files under secrets/.\n'
  printf 'DOMAIN=%s\n' "$PUBLIC_URL_RESOLVED"
  printf 'SSO_ENABLED=true\n'
  printf 'SSO_ONLY=true\n'
  printf 'SSO_AUTHORITY=%s\n' "$ISSUER_RESOLVED"
  printf 'SSO_CLIENT_ID=%s\n' "$CLIENT_ID_RESOLVED"
  printf 'SSO_CLIENT_SECRET_FILE=/run/secrets/vaultwarden/oidc-client-secret\n'
  printf 'SSO_SCOPES=email profile\n'
  printf 'SSO_PKCE=true\n'
  printf 'SSO_SIGNUPS_ALLOWED=%s\n' "$SIGNUPS_BOOL"
  printf 'SSO_SIGNUPS_MATCH_EMAIL=true\n'
  printf 'SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=false\n'
  printf 'SIGNUPS_ALLOWED=false\n'
  printf 'SENDS_ALLOWED=false\n'
  printf 'USER_ATTACHMENT_LIMIT=0\n'
  printf 'ORG_ATTACHMENT_LIMIT=0\n'
  printf 'USER_SEND_LIMIT=0\n'
  printf 'SIGNUPS_VERIFY=false\n'
  printf 'REQUIRE_DEVICE_EMAIL=false\n'
  printf 'ENABLE_WEBSOCKET=true\n'
  printf 'IP_HEADER=X-Real-IP\n'
  if [ -s "$ADMIN_SECRET_FILE" ]; then
    printf 'ADMIN_TOKEN_FILE=/run/secrets/vaultwarden/admin_token\n'
  fi
  if [ -s "$SMTP_SECRET_FILE" ]; then
    printf 'SMTP_PASSWORD_FILE=/run/secrets/vaultwarden/smtp_password\n'
  fi
  if [ -n "${VAULTWARDEN_SMTP_HOST:-}" ]; then
    printf 'SMTP_HOST=%s\n' "$VAULTWARDEN_SMTP_HOST"
  fi
  if [ -n "${VAULTWARDEN_SMTP_FROM:-}" ]; then
    printf 'SMTP_FROM=%s\n' "$VAULTWARDEN_SMTP_FROM"
  fi
  if [ -n "${VAULTWARDEN_SMTP_PORT:-}" ]; then
    printf 'SMTP_PORT=%s\n' "$VAULTWARDEN_SMTP_PORT"
  fi
  if [ -n "${VAULTWARDEN_SMTP_SECURITY:-}" ]; then
    printf 'SMTP_SECURITY=%s\n' "$VAULTWARDEN_SMTP_SECURITY"
  fi
  if [ -n "${VAULTWARDEN_SMTP_USERNAME:-}" ]; then
    printf 'SMTP_USERNAME=%s\n' "$VAULTWARDEN_SMTP_USERNAME"
  fi
} >>"$tmp_env"
chmod 0600 "$tmp_env"
mv "$tmp_env" "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# Step 8: print the summary. Never print secret values.
echo "Configured the vaultwarden wizard files:"
echo "  $ENV_FILE"
echo "  $SECRETS_DIR (secret files, mode 0700)"
echo "  $OIDC_SECRET_FILE (OIDC secret $secret_state)"
if [ "$admin_state" != "absent" ]; then
  echo "  $ADMIN_SECRET_FILE (admin token $admin_state)"
fi
if [ "$smtp_state" != "absent" ]; then
  echo "  $SMTP_SECRET_FILE (SMTP password $smtp_state)"
fi
echo "  $STORE_DIR (mode 0700)"
echo "Public URL: $PUBLIC_URL_RESOLVED"
echo "OIDC issuer: $ISSUER_RESOLVED"
echo "OIDC client ID: $CLIENT_ID_RESOLVED"
echo "OIDC callback: ${PUBLIC_URL_RESOLVED}/identity/connect/oidc-signin"
echo "SSO signups allowed: $SIGNUPS_BOOL"
if [ -s "$ADMIN_SECRET_FILE" ]; then
  echo "Admin panel: enabled by $ADMIN_SECRET_FILE."
else
  echo "Admin panel: disabled."
fi
if [ -s "$SMTP_SECRET_FILE" ] || [ -n "${VAULTWARDEN_SMTP_HOST:-}" ] ||
  [ -n "${VAULTWARDEN_SMTP_FROM:-}" ]; then
  echo "SMTP: configured."
else
  echo "SMTP: off."
fi
if [ "$local_tinyauth" -eq 1 ]; then
  echo "Tinyauth: local at https://tinyauth.${STACK_DOMAIN_RESOLVED}"
else
  echo "Tinyauth: external"
fi
echo "hint: Create the Tinyauth client named '$CLIENT_ID_RESOLVED' with the redirect URI ${PUBLIC_URL_RESOLVED}/identity/connect/oidc-signin."
echo "hint: The master password is still required. SSO only disables password login."
echo "hint: Attachments and Sends are disabled. The official image has no S3 support."
if [ -s "$SMTP_SECRET_FILE" ] || [ -n "${VAULTWARDEN_SMTP_HOST:-}" ]; then
  echo "hint: SMTP is configured. Invites, email verification, and email 2FA can work."
else
  echo "hint: No SMTP is configured. Invites, email verification, and email 2FA are unavailable."
fi
if [ -s "$ADMIN_SECRET_FILE" ]; then
  echo "hint: The admin panel is enabled. Remove $ADMIN_SECRET_FILE to disable it."
else
  echo "hint: The admin panel is off by default. Set VAULTWARDEN_ADMIN_TOKEN to add it."
fi
echo "hint: Vaultwarden is single-node. Do not run two nodes on one SQLite file."
echo "hint: Back up $STORE_DIR and the files in $SECRETS_DIR."
echo "Next step: docker compose up -d vaultwarden"
