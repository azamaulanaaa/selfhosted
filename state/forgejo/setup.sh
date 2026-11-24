#!/usr/bin/env bash
# Generate the Forgejo wizard files for this stack.
# Consul is mandatory. The root dispatcher resolves CONSUL_ADDR. This wizard
# reads CONSUL_ADDR and writes the consul-template configuration.
# This wizard never asks about Consul.
# Safe to run again: it keeps existing secrets unless rotation is asked for.
# It never prints secret values. It prints paths only.
#
# The root dispatcher (setup.sh) calls this script. It can also run standalone.
#
# Usage:
#   setup.sh forgejo                          Run the Forgejo wizard.
#   setup.sh forgejo clean [--data] [--yes]   Remove the forgejo configuration.
#                                             With --data also remove the forgejo data.
#                                             Ask for confirmation unless --yes is given.
#
# Non-interactive environment variables:
#   STACK_DOMAIN              Base domain for the stack. Read from the environment,
#                             then the root .env, then sh.lan.
#   CONSUL_ADDR               Consul address. Read from the environment, then the
#                             root .env, then http://consul:8500. The value
#                             http://consul:8500 selects local Consul. Any other
#                             value selects remote Consul.
#   OIDC_ENABLED              Set to 1 to require OIDC answers. Default 0.
#   LITEFS_ENABLED            Set to 1 to enable LiteFS and peer replication. Default 0.
#   FORGEJO_APP_NAME          Display name for the forge. Default: Forgejo.
#   FORGEJO_OIDC_ISSUER_URL   OIDC issuer URL. Required when OIDC_ENABLED=1.
#                             Must start with https://.
#   FORGEJO_OIDC_CLIENT_ID    OIDC client ID. Required when OIDC_ENABLED=1.
#   FORGEJO_OIDC_CLIENT_SECRET  OIDC client secret. When empty, an existing secret
#                             file is kept. Interactive runs prompt for it.
#   FORGEJO_OIDC_PROVIDER_NAME Name shown for the OIDC provider. Default: oidc.
#   FORGEJO_OIDC_AUTO_REGISTER  yes to create accounts for new OIDC users. Default: no.
#   FORGEJO_PEER_GIT_PORT     Port used by peer git pushes. Asked only when
#                             LITEFS_ENABLED=1. Default 3000.
#   FORGEJO_ROTATE_SECRETS    1 to replace the OIDC client secret and the Forgejo
#                             secret key. Default 0.
#   TLS_ENABLED               1 uses https://forgejo.<STACK_DOMAIN>/ as ROOT_URL.
#                             0 uses http://<PUBLIC_IP>:3000/ as ROOT_URL.
#                             For Caddy with the internal CA and the domain URL,
#                             set TLS_ENABLED=1 and CADDY_TLS_MODE=internal.
#   STACK_ROOTLESS            1 runs the container as root for rootless nerdctl.
#                             0 runs it as uid 1000 and gid 1000. Read from the
#                             environment, then the root .env, then 0.
#                             This wizard does not chown. The host user owns the
#                             files, and container root can read them.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly CONFIG_DIR="config/forgejo"
readonly SECRETS_DIR="config/forgejo/secrets"
readonly STORE_DIR="data/forgejo/store"
readonly ENV_FILE="config/forgejo/forgejo.env"
readonly CT_FILE="config/forgejo/consul-template.hcl"
readonly OIDC_SECRET_FILE="config/forgejo/secrets/oidc-client-secret"
readonly FORGEJO_SECRET_FILE="config/forgejo/secrets/secret-key"

readonly DEFAULT_STACK_DOMAIN="sh.lan"
readonly DEFAULT_APP_NAME="Forgejo"
readonly DEFAULT_OIDC_PROVIDER="oidc"
readonly DEFAULT_PEER_GIT_PORT="3000"

# Print one value from the root .env file. Print nothing when the key is absent.
read_root_env_value() {
  local key="$1" value
  [ -f .env ] || return 0
  value="$({ grep -E "^${key}=" .env || true; } | tail -n1 | cut -d= -f2-)"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

# Print 1 when a capability flag is on. Print 0 otherwise.
resolve_flag() {
  local key="$1" value
  value="$(printenv "$key" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    value="$(read_root_env_value "$key")"
  fi
  case "$value" in
  1) printf '1' ;;
  *) printf '0' ;;
  esac
}

litefs_enabled="$(resolve_flag LITEFS_ENABLED)"
oidc_enabled="$(resolve_flag OIDC_ENABLED)"
rootless="$(resolve_flag STACK_ROOTLESS)"
readonly litefs_enabled oidc_enabled rootless

# Print the STACK_DOMAIN value from the root .env file.
read_env_stack_domain() {
  if [ ! -f .env ]; then
    return 0
  fi
  { grep -E '^STACK_DOMAIN=' .env || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/" -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# Resolve the stack domain. Set stack_domain and stack_domain_source.
resolve_stack_domain() {
  if [ -n "${STACK_DOMAIN:-}" ]; then
    stack_domain="$STACK_DOMAIN"
    stack_domain_source="env"
    return 0
  fi
  candidate="$(read_env_stack_domain)"
  if [ -n "$candidate" ]; then
    stack_domain="$candidate"
    stack_domain_source="envfile"
    return 0
  fi
  stack_domain="$DEFAULT_STACK_DOMAIN"
  stack_domain_source="default"
}

# Print an STE error for an invalid resolved stack domain and exit 1.
stack_domain_invalid() {
  case "$stack_domain_source" in
  env)
    echo "error: STACK_DOMAIN '$stack_domain' is not a valid base domain." >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid STACK_DOMAIN '$stack_domain'." >&2
    echo "error: Fix .env by hand or set STACK_DOMAIN." >&2
    ;;
  *)
    echo "error: '$stack_domain' is not a valid base domain." >&2
    ;;
  esac
  echo "error: Use lowercase labels separated by dots. Use at least two labels." >&2
  exit 1
}

# Return 0 when the argument is a valid base domain.
is_valid_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Return 0 when the argument is a valid Consul address.
# A valid address starts with http:// or https://, has a host, and has no whitespace.
is_valid_consul_addr() {
  local addr="$1"
  if [ -z "$addr" ] || [[ "$addr" =~ [[:space:]] ]]; then
    return 1
  fi
  if [[ ! "$addr" =~ ^https?:// ]]; then
    return 1
  fi
  local rest="${addr#*://}"
  local host="${rest%%[/?#]*}"
  if [ -z "$host" ] || [[ "$host" == :* ]]; then
    return 1
  fi
  return 0
}

# Resolve CONSUL_ADDR. Set consul_addr and consul_mode.
# The order is: the process environment, then the root .env file, then
# http://consul:8500. One trailing slash does not change the comparison with
# the local address.
resolve_consul_addr() {
  local candidate=""
  local source="none"
  if [ -n "${CONSUL_ADDR+x}" ]; then
    candidate="$CONSUL_ADDR"
    source="env"
  elif [ -f .env ] && grep -qE '^CONSUL_ADDR=' .env; then
    candidate="$(read_root_env_value CONSUL_ADDR)"
    source="envfile"
  fi
  if [ "$source" = "none" ]; then
    candidate="http://consul:8500"
    source="default"
  fi
  if ! is_valid_consul_addr "$candidate"; then
    case "$source" in
    env)
      echo "error: CONSUL_ADDR '$candidate' is not valid. Use http:// or https://, a host, and no whitespace." >&2
      ;;
    envfile)
      echo "error: The root .env holds the invalid CONSUL_ADDR '$candidate'." >&2
      echo "error: Fix .env by hand or set CONSUL_ADDR." >&2
      ;;
    *)
      echo "error: '$candidate' is not valid. Use http:// or https://, a host, and no whitespace." >&2
      ;;
    esac
    exit 1
  fi
  consul_addr="$candidate"
  if [ "${consul_addr%/}" = "http://consul:8500" ]; then
    consul_mode="local"
  else
    consul_mode="remote"
  fi
}

# Return 0 when the argument is an HTTPS URL with a host.
is_valid_issuer_url() {
  [[ "$1" =~ ^https://[A-Za-z0-9][A-Za-z0-9.:_-]*(/[^[:space:]]*)?$ ]]
}

# Return 0 when the argument is a valid OIDC client ID.
is_valid_client_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Return 0 when the argument is a valid provider name.
is_valid_provider_name() {
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# Return 0 when the argument is a TCP port from 1 to 65535.
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Return 0 when the argument is yes or no.
is_yes_no() {
  case "$1" in
  [Yy] | [Yy][Ee][Ss] | [Nn] | [Nn][Oo] | 0 | 1 | true | false) return 0 ;;
  *) return 1 ;;
  esac
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
  echo "usage: setup.sh forgejo clean [--data] [--yes]" >&2
}

# Remove the forgejo configuration. With --data also remove the forgejo data.
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

  if [ -L "$REPO_ROOT/config/forgejo" ]; then
    echo "error: '$REPO_ROOT/config/forgejo' is a symlink. Refusing to remove it." >&2
    exit 1
  fi
  if [ "$with_data" -eq 1 ] && [ -L "$REPO_ROOT/data/forgejo" ]; then
    echo "error: '$REPO_ROOT/data/forgejo' is a symlink. Refusing to remove it." >&2
    exit 1
  fi

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/forgejo" "$REPO_ROOT/config/forgejo")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/forgejo" "$REPO_ROOT/data/forgejo")" || exit 1
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
        prompt="Remove the configuration AND DATA for forgejo? This deletes the litefs-backed database and git repositories. [y/N] "
      else
        prompt="Remove the configuration for forgejo? [y/N] "
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
  echo "Removed the forgejo configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the forgejo data."
  fi
  echo "Run 'bash setup.sh forgejo' to generate fresh files for a future install."
  echo "hint: The litefs cluster state in consul is not removed."
  return 0
}

# The clean subcommand removes the forgejo configuration and data.
if [ "${1:-}" = "clean" ]; then
  shift
  clean_service "$@"
  exit 0
fi

# Write a secret file with mode 0600 and no trailing newline.
write_secret_file() {
  local path="$1" value="$2"
  (
    umask 077
    printf '%s' "$value" >"$path"
  )
  chmod 0600 "$path"
}

# Print the value of one KEY=VALUE line from a file.
read_env_value() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  { grep -E "^${key}=" "$file" || true; } | tail -n1 | cut -d= -f2-
}

# Return 0 when the line's key is one that this wizard manages.
is_managed_key() {
  local key="$1"
  case "$key" in
  FORGEJO_APP_NAME | FORGEJO_OIDC_ISSUER_URL | FORGEJO_OIDC_CLIENT_ID | \
    FORGEJO_OIDC_PROVIDER_NAME | FORGEJO_OIDC_AUTO_REGISTER | \
    FORGEJO_PEER_GIT_PORT | FORGEJO_OIDC_CLIENT_SECRET_FILE | \
    FORGEJO_SECRET_KEY_FILE) return 0 ;;
  *) return 1 ;;
  esac
}

# Step 1: fail early when openssl is missing.
if ! command -v openssl >/dev/null 2>&1; then
  echo "error: openssl is not on PATH. Install openssl first." >&2
  exit 1
fi

# Step 2: resolve and validate the stack domain.
resolve_stack_domain
if ! is_valid_domain "$stack_domain"; then
  stack_domain_invalid
fi

# Step 2b: resolve and validate the Consul address. Consul is mandatory.
resolve_consul_addr

# Step 3: collect the answers. Use the environment when stdin is not a TTY.
# Resolve one value from the environment, then the existing answer file, then
# the default. Print the resolved value.
resolve_answer() {
  local env_value="$1" key="$2" default_value="$3" saved
  if [ -n "$env_value" ]; then
    printf '%s' "$env_value"
    return 0
  fi
  saved="$(read_env_value "$key" "$ENV_FILE")"
  if [ -n "$saved" ]; then
    printf '%s' "$saved"
    return 0
  fi
  printf '%s' "$default_value"
}

app_name="$(resolve_answer "${FORGEJO_APP_NAME:-}" FORGEJO_APP_NAME "$DEFAULT_APP_NAME")"
issuer_url="$(resolve_answer "${FORGEJO_OIDC_ISSUER_URL:-}" FORGEJO_OIDC_ISSUER_URL "")"
client_id="$(resolve_answer "${FORGEJO_OIDC_CLIENT_ID:-}" FORGEJO_OIDC_CLIENT_ID "")"
client_secret="${FORGEJO_OIDC_CLIENT_SECRET:-}"
provider_name="$(resolve_answer "${FORGEJO_OIDC_PROVIDER_NAME:-}" FORGEJO_OIDC_PROVIDER_NAME "$DEFAULT_OIDC_PROVIDER")"
auto_register="$(resolve_answer "${FORGEJO_OIDC_AUTO_REGISTER:-}" FORGEJO_OIDC_AUTO_REGISTER "no")"
peer_git_port="$(resolve_answer "${FORGEJO_PEER_GIT_PORT:-}" FORGEJO_PEER_GIT_PORT "$DEFAULT_PEER_GIT_PORT")"
rotate=0

if [ -t 0 ]; then
  if ! read -r -p "Base domain for the stack? [$stack_domain] " domain_answer; then
    domain_answer=""
  fi
  if [ -n "$domain_answer" ]; then
    if ! is_valid_domain "$domain_answer"; then
      echo "error: '$domain_answer' is not a valid base domain." >&2
      echo "error: Use lowercase labels separated by dots. Use at least two labels." >&2
      exit 1
    fi
    stack_domain="$domain_answer"
  fi

  if ! read -r -p "Display name for the forge? [$app_name] " name_answer; then
    name_answer=""
  fi
  app_name="${name_answer:-$app_name}"

  if [ "$oidc_enabled" -eq 1 ]; then
    if ! read -r -p "OIDC issuer URL? " issuer_url; then
      issuer_url=""
    fi
    if ! read -r -p "OIDC client ID? " client_id; then
      client_id=""
    fi
    if ! read -r -s -p "OIDC client secret? " secret_answer; then
      secret_answer=""
    fi
    echo >&2
    if [ -n "$secret_answer" ]; then
      client_secret="$secret_answer"
    fi

    if ! read -r -p "Name shown for the OIDC provider? [$provider_name] " provider_answer; then
      provider_answer=""
    fi
    provider_name="${provider_answer:-$provider_name}"

    if ! read -r -p "Create accounts for new OIDC users? [y/N] " auto_answer; then
      auto_answer=""
    fi
    case "${auto_answer:-N}" in
    [Yy] | [Yy][Ee][Ss]) auto_register="yes" ;;
    [Nn] | [Nn][Oo] | "") auto_register="no" ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
  fi

  if [ "$litefs_enabled" -eq 1 ]; then
    if ! read -r -p "Port used by peer git pushes? [$peer_git_port] " port_answer; then
      port_answer=""
    fi
    peer_git_port="${port_answer:-$peer_git_port}"
  fi

  if [ -f "$OIDC_SECRET_FILE" ]; then
    if ! read -r -p "Rotate the OIDC secret and the Forgejo secret key? [y/N] " rotate_answer; then
      rotate_answer=""
    fi
    case "${rotate_answer:-N}" in
    [Yy] | [Yy][Ee][Ss]) rotate=1 ;;
    [Nn] | [Nn][Oo] | "") rotate=0 ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
  fi
else
  case "${FORGEJO_ROTATE_SECRETS:-0}" in
  0 | 1) rotate="${FORGEJO_ROTATE_SECRETS:-0}" ;;
  *)
    echo "error: FORGEJO_ROTATE_SECRETS must be 0 or 1." >&2
    exit 1
    ;;
  esac
fi

# Step 4: validate every answer before any file is written.
if [ "$oidc_enabled" -eq 1 ]; then
  if [ -z "$issuer_url" ]; then
    echo "error: The OIDC issuer URL is not set." >&2
    echo "error: Set FORGEJO_OIDC_ISSUER_URL or run the wizard on a terminal." >&2
    exit 1
  fi
  if ! is_valid_issuer_url "$issuer_url"; then
    echo "error: '$issuer_url' is not a valid OIDC issuer URL." >&2
    echo "error: Use an HTTPS URL such as https://auth.example.com." >&2
    exit 1
  fi
  if [ -z "$client_id" ]; then
    echo "error: The OIDC client ID is not set." >&2
    echo "error: Set FORGEJO_OIDC_CLIENT_ID or run the wizard on a terminal." >&2
    exit 1
  fi
  if ! is_valid_client_id "$client_id"; then
    echo "error: '$client_id' is not a valid OIDC client ID." >&2
    echo "error: Use letters, digits, dots, underscores, and hyphens." >&2
    exit 1
  fi
fi
if [ -z "$provider_name" ] || ! is_valid_provider_name "$provider_name"; then
  echo "error: '$provider_name' is not a valid provider name." >&2
  echo "error: Use lowercase letters, digits, and hyphens between words." >&2
  exit 1
fi
if ! is_yes_no "$auto_register"; then
  echo "error: '$auto_register' is not a yes or no value." >&2
  exit 1
fi
if [ "$litefs_enabled" -eq 1 ] && ! is_valid_port "$peer_git_port"; then
  echo "error: '$peer_git_port' is not a valid port. Use 1 to 65535." >&2
  exit 1
fi

case "$auto_register" in
[Yy] | [Yy][Ee][Ss] | 1 | true) auto_register="true" ;;
*) auto_register="false" ;;
esac

# Step 5: create the directory layout with strict modes.
# The host user owns these files. A rootless container runs as root and reads
# them. This wizard never changes the owner.
mkdir -p "$CONFIG_DIR"
mkdir -p "$SECRETS_DIR"
mkdir -p "$STORE_DIR"
chmod 0750 "$CONFIG_DIR"
chmod 0700 "$SECRETS_DIR"
chmod 0700 "$STORE_DIR"

# Step 6: write the secrets. Existing files are kept unless rotation or a new
# value was asked for. Never print the values.
oidc_state="disabled"
if [ "$oidc_enabled" -eq 1 ]; then
  oidc_state="kept"
  if [ -z "$client_secret" ]; then
    if [ ! -s "$OIDC_SECRET_FILE" ]; then
      echo "error: The OIDC client secret is not set." >&2
      echo "error: Set FORGEJO_OIDC_CLIENT_SECRET or run the wizard on a terminal." >&2
      exit 1
    fi
  else
    if [ ! -s "$OIDC_SECRET_FILE" ] || [ "$rotate" = "1" ]; then
      if [ -s "$OIDC_SECRET_FILE" ]; then
        oidc_state="rotated"
      else
        oidc_state="created"
      fi
      write_secret_file "$OIDC_SECRET_FILE" "$client_secret"
    fi
  fi
  chmod 0600 "$OIDC_SECRET_FILE"
fi

secret_key_state="kept"
if [ ! -s "$FORGEJO_SECRET_FILE" ] || [ "$rotate" = "1" ]; then
  if [ -s "$FORGEJO_SECRET_FILE" ]; then
    secret_key_state="rotated"
  else
    secret_key_state="created"
  fi
  forgejo_secret="$(openssl rand -hex 32)"
  write_secret_file "$FORGEJO_SECRET_FILE" "$forgejo_secret"
fi
chmod 0600 "$FORGEJO_SECRET_FILE"

# Step 7: write the consul-template configuration. The wizard writes the
# resolved Consul address. The entrypoint selects the token source at boot and
# writes it to the runtime token file.
{
  printf '# Generated by state/forgejo/setup.sh. Do not edit.\n'
  printf '# Run the wizard again to regenerate this file.\n'
  printf 'consul {\n'
  printf '  address = "%s"\n' "$consul_addr"
  printf '  token_file = "/run/forgejo/consul-token"\n'
  printf '}\n'
  printf '\n'
  printf 'template {\n'
  printf '  source = "/etc/consul-template/templates/app.ini.tpl"\n'
  printf '  destination = "/run/forgejo/app.ini"\n'
  printf '  backup = false\n'
  printf '  perms = "0640"\n'
  printf '  command = "/usr/local/bin/entrypoint.sh --render-fixed"\n'
  printf '  command_timeout = "10s"\n'
  printf '}\n'
  printf '\n'
  printf 'template {\n'
  printf '  source = "/etc/consul-template/templates/post-receive.tpl"\n'
  printf '  destination = "/run/forgejo/post-receive"\n'
  printf '  backup = false\n'
  printf '  perms = "0755"\n'
  printf '  command = "/usr/local/bin/entrypoint.sh --install-hooks"\n'
  printf '  command_timeout = "30s"\n'
  printf '}\n'
} >"$CT_FILE"
chmod 0640 "$CT_FILE"

# Step 8: write the answer file. Keep lines this wizard does not own.
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
  printf '# Generated by state/forgejo/setup.sh.\n'
  printf '# Do not commit this file. Secrets stay in 0600 files under secrets/.\n'
  printf 'FORGEJO_APP_NAME=%s\n' "$app_name"
  if [ "$oidc_enabled" -eq 1 ]; then
    printf 'FORGEJO_OIDC_ISSUER_URL=%s\n' "$issuer_url"
    printf 'FORGEJO_OIDC_CLIENT_ID=%s\n' "$client_id"
    printf 'FORGEJO_OIDC_PROVIDER_NAME=%s\n' "$provider_name"
    printf 'FORGEJO_OIDC_AUTO_REGISTER=%s\n' "$auto_register"
    printf 'FORGEJO_OIDC_CLIENT_SECRET_FILE=/etc/forgejo/secrets/oidc-client-secret\n'
  fi
  if [ "$litefs_enabled" -eq 1 ]; then
    printf 'FORGEJO_PEER_GIT_PORT=%s\n' "$peer_git_port"
  fi
  printf 'FORGEJO_SECRET_KEY_FILE=/etc/forgejo/secrets/secret-key\n'
} >>"$tmp_env"
chmod 0640 "$tmp_env"
mv "$tmp_env" "$ENV_FILE"

# Step 9: print the summary. Never print secret values.
echo "Configured the forgejo wizard files:"
echo "  $ENV_FILE"
echo "  $CT_FILE"
echo "  $FORGEJO_SECRET_FILE (Forgejo secret key $secret_key_state)"
if [ "$oidc_enabled" -eq 1 ]; then
  echo "  $OIDC_SECRET_FILE (OIDC secret $oidc_state)"
  echo "OIDC issuer: $issuer_url"
  echo "OIDC client ID: $client_id"
  echo "OIDC provider name: $provider_name"
else
  echo "OIDC is off. Forgejo uses built-in authentication."
fi
echo "Consul: $consul_addr ($consul_mode)"
echo "Base domain: $stack_domain"
if [ "$consul_mode" = "local" ]; then
  echo "Mode: integrated with local Consul."
else
  echo "Mode: standalone with remote Consul."
fi
if [ "$rootless" = "1" ]; then
  echo "Runtime: rootless nerdctl. The container runs as root."
else
  echo "Runtime: rootful Docker. The container runs as uid 1000 and gid 1000."
fi
if [ "$litefs_enabled" -eq 1 ]; then
  echo "LiteFS: enabled. Peer git port: $peer_git_port"
  echo "hint: LiteFS elects a primary through a consul lease (key forgejo/litefs)."
  echo "hint: Start the peer port profile on a second node with --profile peer."
  echo "hint: the git hook launcher is installed in every repository by the entrypoint."
  echo "Next step: docker compose --profile peer up -d forgejo"
else
  echo "LiteFS: disabled. Forgejo uses local SQLite without peers."
  echo "Next step: docker compose up -d forgejo"
fi
echo "hint: consul-template renders app.ini and the post-receive hook inside the container."
if [ -f "$SECRETS_DIR/consul-token" ]; then
  echo "warning: $SECRETS_DIR/consul-token is obsolete. This configuration does not use it." >&2
  echo "warning: Delete the file. The container reads the Consul token from config/consul/secrets." >&2
fi
