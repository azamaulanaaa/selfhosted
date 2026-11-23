#!/usr/bin/env bash
# Generate the Garage wizard files for this stack.
# Garage always uses Consul service discovery. The wizard writes the
# [consul_discovery] section on every run from CONSUL_ADDR.
# The root setup.sh resolves Consul first and writes CONSUL_ADDR to the root
# .env file. This wizard never asks about Consul. The container selects the
# Consul token file from CONSUL_ADDR at start time.
# Safe to run again: it rewrites garage.toml and keeps the secret files unless
# GARAGE_ROTATE_SECRETS=1 is set. It never prints secret values. It prints
# paths only.
#
# Usage:
#   setup.sh garage                          Run the Garage wizard.
#   setup.sh garage clean [--data] [--yes]   Remove the Garage configuration.
#                                            With --data also remove the Garage data.
#                                            Ask for confirmation unless --yes is set.
#
# Non-interactive environment variables:
#   STACK_DOMAIN              Stack domain. Read from the environment, then the
#                             root .env, then sh.lan.
#   PUBLIC_IP                 Public or LAN IPv4. Read from the environment,
#                             then the root .env, then 127.0.0.1.
#   CONSUL_ADDR               Consul address. Read from the environment, then
#                             the root .env. The value is required. It must
#                             start with http:// or https:// and must hold a
#                             host. http://consul:8500 means local Consul. Any
#                             other value means remote Consul.
#   GARAGE_REPLICATION_FACTOR Replication factor. Default 1.
#   GARAGE_ROTATE_SECRETS     Set to 1 to create new RPC, admin, and metrics
#                             secrets. Default 0.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly CONFIG_DIR="config/garage"
readonly SECRETS_DIR="config/garage/secrets"
readonly CONFIG_FILE="config/garage/garage.toml"

readonly RPC_SECRET_FILE="${SECRETS_DIR}/rpc_secret"
readonly ADMIN_TOKEN_FILE="${SECRETS_DIR}/admin_token"
readonly METRICS_TOKEN_FILE="${SECRETS_DIR}/metrics_token"

readonly DEFAULT_STACK_DOMAIN="sh.lan"
readonly DEFAULT_PUBLIC_IP="127.0.0.1"
readonly LOCAL_CONSUL_ADDR="http://consul:8500"
readonly DEFAULT_REPLICATION_FACTOR="1"

# Container paths. The compose fragment mounts the matching host paths.
readonly RPC_SECRET_PATH="/etc/garage/secrets/rpc_secret"
readonly ADMIN_TOKEN_PATH="/etc/garage/secrets/admin_token"
readonly METRICS_TOKEN_PATH="/etc/garage/secrets/metrics_token"

# Return 0 when the argument is a valid IPv4 address. Each octet is 0 to 255.
# Reject an octet that starts with zero. Bash would read it as an octal number.
is_valid_ipv4() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local octet
  local IFS='.'
  local -a octets
  read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    if [ "${#octet}" -gt 1 ] && [[ "$octet" == 0* ]]; then
      return 1
    fi
    if [ "$((10#$octet))" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

# Return 0 when the argument is a valid stack domain.
# Letters, digits, dots, and hyphens. At least one character.
is_valid_stack_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,252})$ ]]
}

# Return 0 when the argument is a Consul HTTP address.
# The value starts with http:// or https:// and holds a host.
is_valid_consul_http_addr() {
  local addr="$1"
  case "$addr" in
  http://* | https://*) ;;
  *) return 1 ;;
  esac
  case "$addr" in
  *[[:space:]]*) return 1 ;;
  esac
  local host="${addr#*://}"
  host="${host%%/*}"
  host="${host%%\?*}"
  host="${host%%#*}"
  if [ -z "$host" ]; then
    return 1
  fi
  case "$host" in
  *@*) return 1 ;;
  esac
  return 0
}

# Return 0 when the argument is a valid replication factor. A positive integer.
is_valid_replication_factor() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# Print the value of one key from an environment file.
# Print nothing when the file or the line is missing.
read_env_value() {
  local key="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  { grep -E "^${key}=" "$file" || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/"
}

# Resolve the stack domain. Set stack_domain and stack_domain_source.
# The order is: STACK_DOMAIN from the environment, then the root .env, then
# the built-in default.
resolve_stack_domain() {
  if [ -n "${STACK_DOMAIN:-}" ]; then
    stack_domain="$STACK_DOMAIN"
    stack_domain_source="env"
    return 0
  fi
  local candidate
  candidate="$(read_env_value STACK_DOMAIN .env)"
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

# Resolve the public IP. Set public_ip and public_ip_source.
# The order is: PUBLIC_IP from the environment, then the root .env, then the
# built-in default.
resolve_public_ip() {
  if [ -n "${PUBLIC_IP:-}" ]; then
    public_ip="$PUBLIC_IP"
    public_ip_source="env"
    return 0
  fi
  local candidate
  candidate="$(read_env_value PUBLIC_IP .env)"
  if [ -n "$candidate" ]; then
    public_ip="$candidate"
    public_ip_source="envfile"
    return 0
  fi
  public_ip="$DEFAULT_PUBLIC_IP"
  public_ip_source="default"
}

# Print an STE error for an invalid public IP and exit 1.
public_ip_invalid() {
  echo "error: '$public_ip' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
  case "$public_ip_source" in
  env)
    echo "error: PUBLIC_IP came from the environment." >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid PUBLIC_IP." >&2
    echo "error: Fix .env by hand or set PUBLIC_IP." >&2
    ;;
  esac
  exit 1
}

# Resolve CONSUL_ADDR. Set consul_addr and consul_mode.
# The order is: the process environment, then the root .env file.
# The value is required. This wizard never asks about Consul.
# One trailing slash does not change the comparison with the local address.
resolve_consul_addr() {
  local candidate=""
  local source="none"
  if [ -n "${CONSUL_ADDR+x}" ]; then
    candidate="$CONSUL_ADDR"
    source="env"
  elif [ -f .env ] && grep -qE '^CONSUL_ADDR=' .env; then
    candidate="$(read_env_value CONSUL_ADDR .env)"
    source="envfile"
  fi
  if [ "$source" = "none" ]; then
    echo "error: CONSUL_ADDR is not set. Consul is required." >&2
    echo "error: Run 'bash setup.sh' first, or set CONSUL_ADDR." >&2
    exit 1
  fi
  if ! is_valid_consul_http_addr "$candidate"; then
    case "$source" in
    env)
      echo "error: CONSUL_ADDR '$candidate' is not valid. Use http:// or https://, a host, and no whitespace." >&2
      ;;
    envfile)
      echo "error: The root .env holds the invalid CONSUL_ADDR '$candidate'." >&2
      echo "error: Fix .env by hand or set CONSUL_ADDR." >&2
      ;;
    esac
    exit 1
  fi
  candidate="${candidate%/}"
  consul_addr="$candidate"
  if [ "$consul_addr" = "$LOCAL_CONSUL_ADDR" ]; then
    consul_mode="local"
  else
    consul_mode="remote"
  fi
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
  echo "usage: setup.sh garage clean [--data] [--yes]" >&2
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

# Remove the Garage configuration, and with --data also the Garage data.
# Never touches state/, .env, other services, or anything outside the resolved
# config/garage and data/garage directories.
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
  if [ -L "$REPO_ROOT/config/garage" ]; then
    echo "error: '$REPO_ROOT/config/garage' is a symlink. Refusing to remove it." >&2
    exit 1
  fi
  if [ "$with_data" -eq 1 ] && [ -L "$REPO_ROOT/data/garage" ]; then
    echo "error: '$REPO_ROOT/data/garage' is a symlink. Refusing to remove it." >&2
    exit 1
  fi

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/garage" "$REPO_ROOT/config/garage")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/garage" "$REPO_ROOT/data/garage")" || exit 1
  fi

  # Collect the paths to remove. Print each path under config/garage.
  # For data/garage print the tree root only; a store can be very large.
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
        prompt="Remove the configuration AND DATA for garage? This deletes the metadata and the object data. [y/N] "
      else
        prompt="Remove the configuration for garage? [y/N] "
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

  echo "Removed the Garage configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the Garage data."
  fi
  echo "Run 'bash setup.sh garage' to generate fresh secrets for a future install."
  return 0
}

# The clean subcommand removes the Garage configuration and data.
# Without --data only config/garage is removed. The data is never removed
# without --data.
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

# Step 2: resolve and validate the stack values before anything is written.
resolve_stack_domain
if ! is_valid_stack_domain "$stack_domain"; then
  stack_domain_invalid
fi
resolve_public_ip
if ! is_valid_ipv4 "$public_ip"; then
  public_ip_invalid
fi
resolve_consul_addr

readonly STACK_DOMAIN_RESOLVED="$stack_domain"
readonly PUBLIC_IP_RESOLVED="$public_ip"
readonly CONSUL_ADDR_RESOLVED="$consul_addr"
case "$consul_mode" in
local)
  readonly MODE="integrated"
  readonly CONSUL_TOKEN_HINT="config/consul/secrets/agent.hcl"
  ;;
remote)
  readonly MODE="standalone"
  readonly CONSUL_TOKEN_HINT="config/consul/secrets/remote-token"
  ;;
esac

replication_factor="${GARAGE_REPLICATION_FACTOR:-$DEFAULT_REPLICATION_FACTOR}"
if ! is_valid_replication_factor "$replication_factor"; then
  echo "error: GARAGE_REPLICATION_FACTOR '$replication_factor' is not a positive integer." >&2
  exit 1
fi

rotate="${GARAGE_ROTATE_SECRETS:-0}"
case "$rotate" in
0 | 1) ;;
*)
  echo "error: GARAGE_ROTATE_SECRETS must be 0 or 1." >&2
  exit 1
  ;;
esac

# Step 3: create the config directories with strict modes.
mkdir -p "$SECRETS_DIR"
chmod 0700 "$CONFIG_DIR"
chmod 0700 "$SECRETS_DIR"

# Step 4: reuse the generated secrets. Create or rotate them when needed.
rpc_state="kept"
if [ "$rotate" -eq 1 ] || [ ! -s "$RPC_SECRET_FILE" ]; then
  if [ -s "$RPC_SECRET_FILE" ]; then
    rpc_state="rotated"
  else
    rpc_state="created"
  fi
  write_secret_file "$RPC_SECRET_FILE" "$(openssl rand -hex 32)"
else
  chmod 0600 "$RPC_SECRET_FILE"
fi

admin_state="kept"
if [ "$rotate" -eq 1 ] || [ ! -s "$ADMIN_TOKEN_FILE" ]; then
  if [ -s "$ADMIN_TOKEN_FILE" ]; then
    admin_state="rotated"
  else
    admin_state="created"
  fi
  write_secret_file "$ADMIN_TOKEN_FILE" "$(openssl rand -base64 32)"
else
  chmod 0600 "$ADMIN_TOKEN_FILE"
fi

metrics_state="kept"
if [ "$rotate" -eq 1 ] || [ ! -s "$METRICS_TOKEN_FILE" ]; then
  if [ -s "$METRICS_TOKEN_FILE" ]; then
    metrics_state="rotated"
  else
    metrics_state="created"
  fi
  write_secret_file "$METRICS_TOKEN_FILE" "$(openssl rand -base64 32)"
else
  chmod 0600 "$METRICS_TOKEN_FILE"
fi

# Step 5: write the config file. It holds no secrets.
# The marker line tells the entrypoint where to add the Consul token.
tmp_config="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
{
  printf '# Garage configuration. Generated by state/garage/setup.sh.\n'
  printf '# Do not commit this file. Regenerate it with: bash setup.sh garage\n'
  printf '# Consul service discovery is always enabled.\n'
  printf '# Stack domain: %s\n' "$STACK_DOMAIN_RESOLVED"
  printf '\n'
  printf 'metadata_dir = "/var/lib/garage/meta"\n'
  printf 'data_dir = "/var/lib/garage/data"\n'
  printf 'db_engine = "lmdb"\n'
  printf 'metadata_auto_snapshot_interval = "6h"\n'
  printf 'replication_factor = %s\n' "$replication_factor"
  printf 'rpc_bind_addr = "[::]:3901"\n'
  printf 'rpc_public_addr = "%s:3901"\n' "$PUBLIC_IP_RESOLVED"
  printf 'rpc_secret_file = "%s"\n' "$RPC_SECRET_PATH"
  printf '\n'
  printf '[consul_discovery]\n'
  printf 'api = "catalog"\n'
  printf 'consul_http_addr = "%s"\n' "$CONSUL_ADDR_RESOLVED"
  printf 'service_name = "garage"\n'
  printf 'tls_skip_verify = false\n'
  printf '# __CONSUL_TOKEN__\n'
  printf '\n'
  printf '[s3_api]\n'
  printf 'api_bind_addr = "[::]:3900"\n'
  printf 's3_region = "garage"\n'
  printf 'public_endpoint = "http://%s:3900"\n' "$PUBLIC_IP_RESOLVED"
  printf '\n'
  printf '[s3_web]\n'
  printf 'bind_addr = "[::]:3902"\n'
  printf '\n'
  printf '[admin]\n'
  printf 'api_bind_addr = "[::]:3903"\n'
  printf 'admin_token_file = "%s"\n' "$ADMIN_TOKEN_PATH"
  printf 'metrics_token_file = "%s"\n' "$METRICS_TOKEN_PATH"
} >"$tmp_config"
chmod 0600 "$tmp_config"
mv "$tmp_config" "$CONFIG_FILE"

# Step 6: print the summary. Never print secret values.
echo "Configured the Garage configuration:"
echo "  $CONFIG_FILE"
echo "  $SECRETS_DIR"
echo "Mode: $MODE"
echo "Consul address: $CONSUL_ADDR_RESOLVED"
echo "Consul token: read at container start from $CONSUL_TOKEN_HINT"
echo "RPC secret: $RPC_SECRET_FILE ($rpc_state)"
echo "Admin token: $ADMIN_TOKEN_FILE ($admin_state)"
echo "Metrics token: $METRICS_TOKEN_FILE ($metrics_state)"
echo "Replication factor: $replication_factor"
echo "RPC public address: ${PUBLIC_IP_RESOLVED}:3901"
echo "S3 endpoint: http://${PUBLIC_IP_RESOLVED}:3900"
echo "hint: The metadata and data directories are data/garage/meta and data/garage/data."
echo "hint: Use the Garage CLI for the layout, the buckets, and the access keys. See docs/garage.md."
echo "Next step: docker compose up -d garage"
