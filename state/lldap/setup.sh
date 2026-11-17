#!/usr/bin/env bash
# Generate the LLDAP wizard files for this stack.
# Safe to run again: it rewrites lldap_config.toml and keeps the secret files.
# The wizard generates a missing secret file. It never prints secret values.
# It prints paths only.
#
# Usage:
#   setup.sh lldap                          Run the LLDAP wizard.
#   setup.sh lldap clean [--data] [--yes]   Remove the lldap configuration.
#                                            With --data also remove the lldap data.
#                                            Ask for confirmation unless --yes is set.
#
# Non-interactive environment variables:
#   LLDAP_BASE_DN     LDAP base DN. Required when stdin is not a TTY.
#                     Interactive default: dc=home,dc=lan.
#   LLDAP_ADMIN_USER  Admin username. Default: admin.
#   STACK_DOMAIN      Stack domain. The HTTP URL becomes http://lldap.<domain>.
#                     Read from the environment, then from the root .env, then
#                     from the built-in default (sh.lan).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly CONFIG_DIR="config/lldap"
readonly SECRETS_DIR="config/lldap/secrets"
readonly CONFIG_FILE="config/lldap/lldap_config.toml"

# The wizard writes each secret to one file with mode 600.
# LLDAP reads these files through its _FILE environment variables.
readonly JWT_SECRET_FILE="${SECRETS_DIR}/jwt_secret"
readonly KEY_SEED_FILE="${SECRETS_DIR}/key_seed"
readonly USER_PASS_FILE="${SECRETS_DIR}/ldap_user_pass"

readonly DB_PATH="sqlite:///data/lldap.sqlite?mode=rwc"
readonly DEFAULT_BASE_DN="dc=home,dc=lan"
readonly DEFAULT_ADMIN_USER="admin"
readonly DEFAULT_STACK_DOMAIN="sh.lan"

# Return 0 when the argument is a valid LDAP base DN.
# The value is a comma-separated list of components. Each component is
# attribute=value. Attributes and values are alphanumeric or hyphen.
is_valid_base_dn() {
  [[ "$1" =~ ^([a-zA-Z0-9-]+=[a-zA-Z0-9-]+)(,[a-zA-Z0-9-]+=[a-zA-Z0-9-]+)*$ ]]
}

# Return 0 when the argument is a valid admin username.
# The value starts with a letter or a digit. The rest are letters, digits,
# dots, underscores, or hyphens. Maximum 64 characters.
is_valid_admin_user() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$ ]]
}

# Print the STACK_DOMAIN value from the root .env file. Print nothing when the
# file or the line is missing.
read_env_stack_domain() {
  if [ ! -f .env ]; then
    return 0
  fi
  { grep -E '^STACK_DOMAIN=' .env || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/" -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# Resolve the stack domain. Set stack_domain and stack_domain_source.
# The order is: STACK_DOMAIN from the environment, then the root .env, then the
# built-in default. The compose file uses the same default.
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

# Return 0 when the argument is a valid stack domain.
# Letters, digits, dots, and hyphens. At least one character.
is_valid_stack_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,252})$ ]]
}

# Print the contents of one secret file.
# Print nothing when the file is missing or empty.
read_secret_file() {
  local path="$1"
  [ -s "$path" ] || return 0
  cat "$path"
}

# Write one secret to a file with mode 600.
# Write to a temporary file first. Keep the old file when a write fails.
write_secret_file() {
  local path="$1"
  local value="$2"
  (
    umask 077
    printf '%s' "$value" >"${path}.tmp"
    mv "${path}.tmp" "$path"
  )
  chmod 0600 "$path"
}

usage_clean() {
  echo "usage: setup.sh lldap clean [--data] [--yes]" >&2
}

# Resolve a removal target and make sure it stays inside the base directory.
# Print the resolved absolute path. Return 1 when the target escapes the base.
resolve_removal_target() {
  local target="$1"
  local base="$2"
  local resolved
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

# Remove the lldap configuration, and with --data also the lldap data.
# Never touches state/, .env, other services, or anything outside the
# resolved config/lldap and data/lldap directories.
clean_service() {
  local with_data=0
  local assume_yes=0
  local flag
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

  # Refuse to operate when a domain directory is a symlink.
  if [ -L "$REPO_ROOT/config/lldap" ]; then
    echo "error: '$REPO_ROOT/config/lldap' is a symlink. Refusing to remove it." >&2
    exit 1
  fi
  if [ "$with_data" -eq 1 ] && [ -L "$REPO_ROOT/data/lldap" ]; then
    echo "error: '$REPO_ROOT/data/lldap' is a symlink. Refusing to remove it." >&2
    exit 1
  fi

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/lldap" "$REPO_ROOT/config/lldap")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/lldap" "$REPO_ROOT/data/lldap")" || exit 1
  fi

  # Collect the paths to remove. Print each path under config/lldap.
  # For data/lldap print the tree root only; a store can be very large.
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
      local prompt
      if [ "$with_data" -eq 1 ]; then
        prompt="Remove the configuration AND DATA for lldap? This deletes the litefs-backed database. [y/N] "
      else
        prompt="Remove the configuration for lldap? [y/N] "
      fi
      local answer
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

  echo "Removed the lldap configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the lldap data."
  fi
  echo "Run 'bash setup.sh lldap' to generate fresh secrets for a future install."
  echo "hint: the litefs cluster state in consul is not removed. Run the consul wizard clean to reset it."
  return 0
}

# The clean subcommand removes the lldap configuration and data.
# Without --data only config/lldap is removed. The data is never removed without --data.
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

# Step 2: resolve the stack domain before anything is written.
resolve_stack_domain
if ! is_valid_stack_domain "$stack_domain"; then
  stack_domain_invalid
fi
readonly STACK_DOMAIN_RESOLVED="$stack_domain"
readonly HTTP_URL="http://lldap.${STACK_DOMAIN_RESOLVED}"

# Step 3: collect the answers. Use the environment when stdin is not a TTY.
# Nothing is written before every answer has been validated.
base_dn=""
admin_user=""
if [ -t 0 ]; then
  default_base_dn="$DEFAULT_BASE_DN"
  if ! read -r -p "LDAP base DN? [$default_base_dn] " base_dn_answer; then
    base_dn_answer=""
  fi
  if [ -n "$base_dn_answer" ]; then
    if ! is_valid_base_dn "$base_dn_answer"; then
      echo "error: '$base_dn_answer' is not a valid LDAP base DN." >&2
      echo "error: Use comma-separated attribute=value components, for example dc=example,dc=com." >&2
      exit 1
    fi
    base_dn="$base_dn_answer"
  else
    base_dn="$default_base_dn"
  fi
  if ! read -r -p "Admin username? [$DEFAULT_ADMIN_USER] " admin_answer; then
    admin_answer=""
  fi
  if [ -n "$admin_answer" ]; then
    if ! is_valid_admin_user "$admin_answer"; then
      echo "error: '$admin_answer' is not a valid admin username." >&2
      echo "error: Use 1 to 64 characters. Start with a letter or a digit. Use letters, digits, dots, underscores, or hyphens." >&2
      exit 1
    fi
    admin_user="$admin_answer"
  else
    admin_user="$DEFAULT_ADMIN_USER"
  fi
else
  base_dn="${LLDAP_BASE_DN:-}"
  if [ -z "$base_dn" ]; then
    echo "error: LLDAP_BASE_DN is not set." >&2
    echo "error: Set LLDAP_BASE_DN, for example dc=example,dc=com." >&2
    exit 1
  fi
  if ! is_valid_base_dn "$base_dn"; then
    echo "error: LLDAP_BASE_DN '$base_dn' is not a valid LDAP base DN." >&2
    echo "error: Use comma-separated attribute=value components, for example dc=example,dc=com." >&2
    exit 1
  fi
  admin_user="${LLDAP_ADMIN_USER:-$DEFAULT_ADMIN_USER}"
  if ! is_valid_admin_user "$admin_user"; then
    echo "error: LLDAP_ADMIN_USER '$admin_user' is not a valid admin username." >&2
    echo "error: Use 1 to 64 characters. Start with a letter or a digit. Use letters, digits, dots, underscores, or hyphens." >&2
    exit 1
  fi
fi

# Step 4: create the config directories with strict modes.
# The runtime creates the data directory. The wizard never writes data/.
mkdir -p "$SECRETS_DIR"
chmod 0700 "$CONFIG_DIR"
chmod 0700 "$SECRETS_DIR"

# Step 5: reuse the existing secrets. Generate fresh secrets for anything missing.
# LLDAP reads jwt_secret, key_seed, and ldap_user_pass from files.
secret_state="kept"
reused=0
jwt_secret="$(read_secret_file "$JWT_SECRET_FILE")"
key_seed="$(read_secret_file "$KEY_SEED_FILE")"
ldap_user_pass="$(read_secret_file "$USER_PASS_FILE")"
if [ -z "$jwt_secret" ]; then
  jwt_secret="$(openssl rand -hex 32)"
else
  reused=$((reused + 1))
fi
if [ -z "$key_seed" ]; then
  key_seed="$(openssl rand -hex 32)"
else
  reused=$((reused + 1))
fi
if [ -z "$ldap_user_pass" ]; then
  ldap_user_pass="$(openssl rand -hex 12)"
else
  reused=$((reused + 1))
fi
if [ "$reused" -eq 3 ]; then
  secret_state="kept"
elif [ "$reused" -eq 0 ]; then
  secret_state="created"
else
  secret_state="regenerated"
fi

# Write each secret to a separate file. Never write a secret into the config file.
write_secret_file "$JWT_SECRET_FILE" "$jwt_secret"
write_secret_file "$KEY_SEED_FILE" "$key_seed"
write_secret_file "$USER_PASS_FILE" "$ldap_user_pass"

# Step 6: write the config file. It holds no secrets.
# It is mode 0600 in a mode 0700 directory.
(
  umask 077
  {
    printf '# LLDAP configuration. Generated by state/lldap/setup.sh.\n'
    printf '# Do not commit this file. Regenerate it with: bash setup.sh lldap\n'
    printf '# The SQLite database lives on the litefs mount at /data/lldap.sqlite.\n'
    printf '# The secrets live in the secrets directory. LLDAP reads them through _FILE variables.\n'
    printf 'database_url = "%s"\n' "$DB_PATH"
    printf 'ldap_base_dn = "%s"\n' "$base_dn"
    printf 'ldap_user_dn = "%s"\n' "$admin_user"
    printf 'http_url = "%s"\n' "$HTTP_URL"
    printf 'http_port = 17170\n'
    printf 'ldap_port = 3890\n'
  } >"$CONFIG_FILE"
)
chmod 0600 "$CONFIG_FILE"

# Step 7: print the summary. Never print secret values.
echo "Configured the lldap configuration:"
echo "  $CONFIG_FILE"
echo "  $SECRETS_DIR (secrets $secret_state)"
echo "HTTP URL: $HTTP_URL"
echo "Base DN: $base_dn"
echo "Admin username: $admin_user"
echo "hint: The SQLite database lives on the litefs mount at /data/lldap.sqlite."
echo "hint: LiteFS elects a single primary through a consul lease (key lldap/litefs)."
echo "hint: Only the litefs primary can write the database."
echo "hint: LLDAP reads its secrets from files in $SECRETS_DIR. Back that directory up."
echo "hint: In integrated mode the entrypoint reads the Consul management token from config/consul/secrets/agent.hcl."
echo "hint: LLDAP must run on the elected primary in integrated mode."
echo "Next step: docker compose up -d lldap"
echo "Next step: open $HTTP_URL (needs the caddy service)"
