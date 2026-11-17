#!/usr/bin/env bash
# Generate the caddy wizard files for this stack.
# Safe to run again: it rewrites consul-template.hcl. It never prints secret
# values. It prints paths only.
#
# One container serves the stack vhosts over HTTPS. The caddy image is
# built locally from state/caddy/Dockerfile. It embeds consul-template.
#
# Two modes exist. With CONSUL_ENABLED=0 the entrypoint renders a static
# Caddyfile from state/caddy/Caddyfile.static.tpl. No peer is required.
# With CONSUL_ENABLED=1 consul-template renders /etc/caddy/Caddyfile from
# state/caddy/Caddyfile.tpl and caddy reloads on change (caddy run --watch).
# There is no sidecar service.
#
# The wizard never writes a consul token. The entrypoint reads
# initial_management from config/consul/secrets/agent.hcl at container start.
# In integrated mode the TLS mode is asked on every run. There is no default.
# Standalone mode uses the internal CA.
#
# The root dispatcher (setup.sh) calls this script. It can also run standalone.
#
# Usage:
#   setup.sh caddy                          Run the caddy wizard.
#   setup.sh caddy clean [--data] [--yes]   Remove the caddy configuration.
#                                           With --data also remove the caddy data.
#                                           Asks for confirmation unless --yes is given.
#
# Non-interactive environment variables:
#   STACK_DOMAIN            Base domain for the stack. Default: the STACK_DOMAIN line
#                           in the root .env, else sh.lan. Example: sh.lan.
#   CADDY_USE_LOCAL_CONSUL  1 to use this repo's consul service, 0 to use a remote one.
#                           Default 1.
#   CADDY_CONSUL_HOST       Consul IP or hostname (remote only). Required when
#                           CADDY_USE_LOCAL_CONSUL=0.
#   CADDY_CONSUL_PORT       Consul HTTP port (remote only). Default 8500.
#   CONSUL_ENABLED          Capability flag. Default 0. Read from the root .env
#                           when not set in the process environment.
#   LITEFS_ENABLED          Capability flag. Default 0.
#   OIDC_ENABLED            Capability flag. Default 0.
#   TLS_ENABLED             Capability flag. Default 0.
#   CADDY_TLS_MODE          TLS mode: internal, letsencrypt, or existing.
#                           There is no default. Non-interactive runs must set it.
#   CADDY_TLS_EMAIL         ACME contact email. Required when CADDY_TLS_MODE=letsencrypt.
#   CADDY_TLS_CERTS         For CADDY_TLS_MODE=existing. One of:
#                             wildcard                          keep the existing
#                                                              wildcard pair in
#                                                              config/caddy/certs/wildcard
#                             wildcard:<fullchain>:<key>          copy that pair into
#                                                              config/caddy/certs/wildcard
#                             consul:<fullchain>:<key>,lldap:<fullchain>:<key>,tinyauth:<fullchain>:<key>
#                                                              copy per-vhost pairs into
#                                                              config/caddy/certs/<vhost>
#                           When unset, the existing certs under config/caddy/certs are
#                           kept; when nothing is present, the run fails.
#
# The rendered vhost label is computed at render time by consul-template.
# STACK_DOMAIN is not a secret; compose passes it to the caddy container as an
# environment variable. Caddy never decides the label.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

# Parse the STACK_DOMAIN value from the root .env file.
# Print the trimmed value. Print nothing when the file or the line is missing.
read_env_stack_domain() {
  if [ ! -f .env ]; then
    return 0
  fi
  { grep -E '^STACK_DOMAIN=' .env || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/" -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# Print a capability flag. The process environment wins over the root .env
# file. Print 0 when the value is absent or is not 0 or 1.
read_capability_flag() {
  local key="$1"
  local value
  value="$(printenv "$key" 2>/dev/null || true)"
  if [ -z "$value" ] && [ -f .env ]; then
    value="$({ grep -E "^${key}=" .env || true; } | tail -n1 | cut -d= -f2-)"
  fi
  case "$value" in
  0 | 1)
    printf '%s\n' "$value"
    ;;
  *)
    printf '0\n'
    ;;
  esac
}

# Print one vhost name per discovered service. Each service with a web UI
# ships a compose fragment. The caddy fragment is the proxy, not a vhost.
discover_vhosts() {
  local fragment service
  for fragment in compose/*.yaml; do
    [ -f "$fragment" ] || continue
    service="$(basename -- "$fragment" .yaml)"
    if [ "$service" != "caddy" ]; then
      printf '%s\n' "$service"
    fi
  done
}

# Resolve the default stack domain. Set stack_domain and stack_domain_source.
# The order is: STACK_DOMAIN from the environment, then the STACK_DOMAIN line in
# the root .env, then sh.lan.
resolve_stack_domain_default() {
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
  stack_domain="sh.lan"
  stack_domain_source="default"
}

# Print an STE error for an invalid resolved stack domain and exit 1.
# The message tells the user which source holds the bad value.
stack_domain_default_invalid() {
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
  exit 1
}

# Print an STE error for an invalid stack domain answer and exit 1.
stack_domain_answer_invalid() {
  echo "error: '$1' is not a valid base domain." >&2
  echo "error: Use lowercase labels separated by dots. Each label must start and end with a letter or a digit, and must not contain other characters than letters, digits, or hyphens. Use at least two labels, for example sh.lan." >&2
  exit 1
}

# Return 0 when the argument is a valid base domain.
# Lowercase, 2 or more labels; each label starts and ends with a lowercase letter
# or a digit. The other characters can be lowercase letters, digits, or hyphens.
is_valid_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Write the root .env with the shared STACK_DOMAIN and the TLS answers. Keep the other lines.
# Preserve every line except the managed keys (STACK_DOMAIN, CADDY_TLS_MODE,
# CADDY_TLS_EMAIL, CADDY_TLS_CERT_LAYOUT). Stale keys from a previous run are
# removed when they do not apply to the new mode.
# chmod 0640 the file. Never print the contents beyond paths.
write_env_file() {
  local stack_domain="$1"
  local tls_mode="$2"
  local tls_email="$3"
  local tls_cert_layout="$4"
  local tmp_env
  tmp_env="$(mktemp ./.env.tmp.XXXXXX)"
  if [ -f .env ]; then
    { grep -E -v '^(STACK_DOMAIN|CADDY_TLS_MODE|CADDY_TLS_EMAIL|CADDY_TLS_CERT_LAYOUT)=' .env || true; } >"$tmp_env"
  fi
  printf 'STACK_DOMAIN=%s\n' "$stack_domain" >>"$tmp_env"
  printf 'CADDY_TLS_MODE=%s\n' "$tls_mode" >>"$tmp_env"
  if [ "$tls_mode" = "letsencrypt" ]; then
    printf 'CADDY_TLS_EMAIL=%s\n' "$tls_email" >>"$tmp_env"
  fi
  if [ "$tls_mode" = "existing" ]; then
    printf 'CADDY_TLS_CERT_LAYOUT=%s\n' "$tls_cert_layout" >>"$tmp_env"
  fi
  chmod 0640 "$tmp_env"
  mv "$tmp_env" .env
}

# Return 0 when the argument is a plausible consul host.
# Allow letters, digits, dots, dashes, and colons. It must not be empty.
is_valid_consul_host() {
  [[ "$1" =~ ^[a-zA-Z0-9.:-]+$ ]]
}

# Return 0 when the argument is a valid TCP port. 1 to 65535.
is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# Return 0 when the argument is a valid email address. user@host.tld shape.
is_valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Copy one certificate file into the destination with the given mode.
# A source that is already in place keeps its contents and only gets the mode.
# Never prints the contents. Prints paths only.
install_cert_copy() {
  local src="$1" dst="$2" mode="$3"
  mkdir -p "$(dirname -- "$dst")"
  if command -v realpath >/dev/null 2>&1; then
    local src_real dst_real
    src_real="$(realpath -e -- "$src")" || {
      echo "error: Cannot resolve '$src'." >&2
      exit 1
    }
    if [ -f "$dst" ]; then
      dst_real="$(realpath -e -- "$dst")" || dst_real="$dst"
      if [ "$src_real" = "$dst_real" ]; then
        chmod "$mode" "$dst"
        echo "kept: $dst"
        return 0
      fi
    fi
  fi
  cp -- "$src" "$dst"
  chmod "$mode" "$dst"
  echo "wrote: $dst"
}

# Print a migration hint for vhosts that lack a per-vhost certificate pair.
# The first argument lists the missing vhosts, separated by spaces.
tls_migration_hint() {
  local missing="$1"
  echo "hint: Add a certificate pair for each missing vhost: $missing." >&2
  echo "hint: Copy fullchain.pem and privkey.pem into config/caddy/certs/<vhost>/ for each vhost." >&2
  echo "hint: Or set CADDY_TLS_CERTS=wildcard to use one wildcard pair for all vhosts." >&2
}

usage_clean() {
  echo "usage: setup.sh caddy clean [--data] [--yes]" >&2
}

# Resolve a removal target and make sure it stays inside the base directory.
# Print the resolved absolute path. Exit 1 when the target escapes the base.
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

# Remove the caddy configuration, and with --data also the caddy data.
# Never touches state/, .env, other services, or anything outside the
# resolved config/caddy and data/caddy directories.
clean_service() {
  local with_data=0
  local assume_yes=0
  local certs_removed=""
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

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/caddy" "$REPO_ROOT/config/caddy")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/caddy" "$REPO_ROOT/data/caddy")" || exit 1
  fi

  # Collect the paths to remove. Print each path under config/caddy.
  # For data/caddy print the tree root only; a store can be very large.
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
        prompt="Remove the configuration AND DATA for caddy? This deletes data/caddy (the store). [y/N] "
      else
        prompt="Remove the configuration for caddy? [y/N] "
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
    case "$removed_path" in
    */certs/*)
      certs_removed=1
      ;;
    esac
  done

  echo "Removed the caddy configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the caddy data."
  fi
  if [ -n "$certs_removed" ]; then
    echo "hint: TLS certificate files under config/caddy/certs were removed with it."
  fi
  echo "Run 'bash setup.sh caddy' (or setup.sh) to generate the caddy files again."
  echo "hint: .env is never removed. STACK_DOMAIN and PUBLIC_IP stay."
  return 0
}

# The clean subcommand removes the caddy configuration and data.
# Without --data only config/caddy is removed. The data is never removed without --data.
if [ "${1:-}" = "clean" ]; then
  shift
  clean_service "$@"
  exit 0
fi

# Step 1: collect the answers. Use the environment when stdin is not a TTY.
resolve_stack_domain_default
if [ -t 0 ]; then
  if ! read -r -p "Base domain for the stack? [$stack_domain] " domain_answer; then
    domain_answer=""
  fi
  if [ -z "$domain_answer" ]; then
    if ! is_valid_domain "$stack_domain"; then
      stack_domain_default_invalid
    fi
  else
    stack_domain="$domain_answer"
    if ! is_valid_domain "$stack_domain"; then
      stack_domain_answer_invalid "$stack_domain"
    fi
  fi
else
  if ! is_valid_domain "$stack_domain"; then
    stack_domain_default_invalid
  fi
fi

# Step 1b: resolve the capability flags. The process environment wins over
# the root .env file. Each flag defaults to 0.
consul_enabled="$(read_capability_flag CONSUL_ENABLED)"
litefs_enabled="$(read_capability_flag LITEFS_ENABLED)"
oidc_enabled="$(read_capability_flag OIDC_ENABLED)"
tls_enabled="$(read_capability_flag TLS_ENABLED)"

use_local_consul=1
consul_host="127.0.0.1"
consul_port="8500"
if [ "$consul_enabled" -eq 0 ]; then
  echo "info: Standalone mode. Caddy does not use consul." >&2
elif [ -t 0 ]; then
  if ! read -r -p "Use this repo's consul service for consul-template? [Y/n] " local_answer; then
    local_answer=""
  fi
  case "${local_answer:-Y}" in
  [Yy] | [Yy][Ee][Ss])
    use_local_consul=1
    ;;
  [Nn] | [Nn][Oo])
    use_local_consul=0
    ;;
  *)
    echo "error: Answer Y or N." >&2
    exit 1
    ;;
  esac
  if [ "$use_local_consul" -eq 0 ]; then
    if ! read -r -p "Consul IP or hostname? " host_answer; then
      host_answer=""
    fi
    if [ -z "$host_answer" ] || ! is_valid_consul_host "$host_answer"; then
      echo "error: '$host_answer' is not a valid Consul IP or hostname. Allow letters, digits, dots, dashes, and colons." >&2
      exit 1
    fi
    consul_host="$host_answer"
    if ! read -r -p "Consul HTTP port? [8500] " port_answer; then
      port_answer=""
    fi
    consul_port="${port_answer:-8500}"
    if ! is_valid_port "$consul_port"; then
      echo "error: '$consul_port' is not a valid port. Use 1 to 65535." >&2
      exit 1
    fi
  fi
else
  case "${CADDY_USE_LOCAL_CONSUL:-1}" in
  0 | 1)
    ;;
  *)
    echo "error: CADDY_USE_LOCAL_CONSUL must be 0 or 1." >&2
    exit 1
    ;;
  esac
  case "${CADDY_USE_LOCAL_CONSUL:-1}" in
  1)
    use_local_consul=1
    ;;
  0)
    use_local_consul=0
    consul_host="${CADDY_CONSUL_HOST:-}"
    consul_port="${CADDY_CONSUL_PORT:-8500}"
    if [ -z "$consul_host" ]; then
      echo "error: CADDY_CONSUL_HOST is required when CADDY_USE_LOCAL_CONSUL=0." >&2
      exit 1
    fi
    if ! is_valid_consul_host "$consul_host"; then
      echo "error: CADDY_CONSUL_HOST '$consul_host' is not a valid Consul IP or hostname. Allow letters, digits, dots, dashes, and colons." >&2
      exit 1
    fi
    if ! is_valid_port "$consul_port"; then
      echo "error: CADDY_CONSUL_PORT '$consul_port' is not a valid port. Use 1 to 65535." >&2
      exit 1
    fi
    ;;
  esac
fi

# Step 1b: collect the TLS answers. Standalone mode uses the internal CA.
# Integrated mode always asks the mode. There is no default.
# Collect everything, then create the files. Invalid answers exit before any writes.
tls_mode=""
if [ "$consul_enabled" -eq 0 ]; then
  tls_mode="internal"
elif [ -t 0 ]; then
  if ! read -r -p "TLS mode (internal, letsencrypt, existing)? " tls_answer; then
    tls_answer=""
  fi
  tls_mode="$(printf '%s' "$tls_answer" | tr '[:upper:]' '[:lower:]')"
  case "$tls_mode" in
  internal | letsencrypt | existing) ;;
  *)
    echo "error: '$tls_answer' is not a valid TLS mode. Use internal, letsencrypt, or existing." >&2
    exit 1
    ;;
  esac
else
  tls_mode="$(printf '%s' "${CADDY_TLS_MODE:-}" | tr '[:upper:]' '[:lower:]')"
  case "$tls_mode" in
  internal | letsencrypt | existing) ;;
  *)
    echo "error: CADDY_TLS_MODE must be internal, letsencrypt, or existing. Non-interactive runs must set CADDY_TLS_MODE." >&2
    exit 1
    ;;
  esac
fi

# Build the vhost list from the compose fragments. Keep a safe fallback for
# standalone checkouts that hold only the caddy fragment.
discovered_vhosts="$(discover_vhosts | tr '\n' ' ')"
TLS_VHOSTS="${discovered_vhosts% }"
if [ -z "$TLS_VHOSTS" ]; then
  TLS_VHOSTS="consul lldap tinyauth"
fi
readonly TLS_VHOSTS

# Build the printable vhost list and the certificate example from TLS_VHOSTS.
TLS_VHOSTS_LIST=""
TLS_CERTS_EXAMPLE=""
for vhost in $TLS_VHOSTS; do
  if [ -n "$TLS_VHOSTS_LIST" ]; then
    TLS_VHOSTS_LIST+=", "
    TLS_CERTS_EXAMPLE+=","
  fi
  TLS_VHOSTS_LIST+="$vhost"
  TLS_CERTS_EXAMPLE+="$vhost:<fullchain>:<key>"
done
readonly TLS_VHOSTS_LIST
readonly TLS_CERTS_EXAMPLE

tls_email=""
if [ "$tls_mode" = "letsencrypt" ]; then
  if [ -t 0 ]; then
    if ! read -r -p "ACME contact email? " email_answer; then
      email_answer=""
    fi
    tls_email="$email_answer"
  else
    tls_email="${CADDY_TLS_EMAIL:-}"
  fi
  if ! is_valid_email "$tls_email"; then
    echo "error: '$tls_email' is not a valid email address. Use the form user@host.tld." >&2
    exit 1
  fi
fi

tls_cert_layout="per-vhost"
# Pending certificate copies: entries of the form "vhost|src_fullchain|src_key".
# The wildcard target uses the pseudo-vhost name "wildcard".
declare -a cert_copies=()
if [ "$tls_mode" = "existing" ]; then
  if [ -t 0 ]; then
    if ! read -r -p "Use one wildcard certificate for all vhosts? [y/N] " wildcard_answer; then
      wildcard_answer=""
    fi
    case "${wildcard_answer:-N}" in
    [Yy] | [Yy][Ee][Ss])
      tls_cert_layout="wildcard"
      ;;
    [Nn] | [Nn][Oo] | "")
      tls_cert_layout="per-vhost"
      ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
    if [ "$tls_cert_layout" = "wildcard" ]; then
      if ! read -r -p "Wildcard fullchain path? " wildcard_fc; then
        wildcard_fc=""
      fi
      if ! read -r -p "Wildcard private key path? " wildcard_key; then
        wildcard_key=""
      fi
      if [ -z "$wildcard_fc" ] || [ -z "$wildcard_key" ] || [ ! -r "$wildcard_fc" ] || [ ! -r "$wildcard_key" ]; then
        echo "error: Both wildcard paths must exist and be readable." >&2
        exit 1
      fi
      cert_copies+=("wildcard|$wildcard_fc|$wildcard_key")
    else
      for vhost in $TLS_VHOSTS; do
        if ! read -r -p "Fullchain path for the $vhost vhost? " fc_path; then
          fc_path=""
        fi
        if ! read -r -p "Private key path for the $vhost vhost? " key_path; then
          key_path=""
        fi
        if [ -z "$fc_path" ] || [ -z "$key_path" ] || [ ! -r "$fc_path" ] || [ ! -r "$key_path" ]; then
          echo "error: Both paths for the $vhost vhost must exist and be readable." >&2
          exit 1
        fi
        cert_copies+=("$vhost|$fc_path|$key_path")
      done
    fi
  else
    certs_spec="${CADDY_TLS_CERTS:-}"
    if [ -z "$certs_spec" ]; then
      keep_ok=1
      missing_vhosts=""
      for vhost in $TLS_VHOSTS; do
        if ! [ -r "config/caddy/certs/$vhost/fullchain.pem" ] || ! [ -r "config/caddy/certs/$vhost/privkey.pem" ]; then
          keep_ok=0
          missing_vhosts="$missing_vhosts$vhost "
        fi
      done
      if [ -r config/caddy/certs/wildcard/fullchain.pem ] && [ -r config/caddy/certs/wildcard/privkey.pem ]; then
        tls_cert_layout="wildcard"
      elif [ "$keep_ok" -eq 1 ]; then
        tls_cert_layout="per-vhost"
      else
        echo "error: CADDY_TLS_CERTS is required when CADDY_TLS_MODE=existing and no certs are present." >&2
        echo "error: Use 'wildcard', 'wildcard:<fullchain>:<key>', or '$TLS_CERTS_EXAMPLE'." >&2
        echo "error: Missing per-vhost certificates: ${missing_vhosts% }." >&2
        tls_migration_hint "${missing_vhosts% }"
        exit 1
      fi
    else
      case "$certs_spec" in
      wildcard)
        if [ ! -r config/caddy/certs/wildcard/fullchain.pem ] || [ ! -r config/caddy/certs/wildcard/privkey.pem ]; then
          echo "error: CADDY_TLS_CERTS=wildcard requires config/caddy/certs/wildcard/fullchain.pem and privkey.pem to exist." >&2
          exit 1
        fi
        tls_cert_layout="wildcard"
        ;;
      wildcard:*)
        wildcard_rest="${certs_spec#wildcard:}"
        wildcard_fc="${wildcard_rest%%:*}"
        wildcard_key="${wildcard_rest##*:}"
        if [ -z "$wildcard_fc" ] || [ -z "$wildcard_key" ] || [ "$wildcard_fc" = "$wildcard_rest" ] || [ ! -r "$wildcard_fc" ] || [ ! -r "$wildcard_key" ]; then
          echo "error: CADDY_TLS_CERTS=wildcard:<fullchain>:<key> needs two readable paths." >&2
          exit 1
        fi
        tls_cert_layout="wildcard"
        cert_copies+=("wildcard|$wildcard_fc|$wildcard_key")
        ;;
      *:*)
        tls_cert_layout="per-vhost"
        old_ifs="$IFS"
        IFS=','
        # Split the pairs on commas.
        read -r -a spec_pairs <<<"$certs_spec"
        IFS="$old_ifs"
        for pair in "${spec_pairs[@]}"; do
          vhost="${pair%%:*}"
          pair_rest="${pair#*:}"
          fc_path="${pair_rest%%:*}"
          key_path="${pair_rest##*:}"
          vhost_ok=0
          for allowed in $TLS_VHOSTS; do
            if [ "$vhost" = "$allowed" ]; then
              vhost_ok=1
            fi
          done
          if [ "$vhost_ok" -eq 0 ]; then
            echo "error: CADDY_TLS_CERTS contains the unknown vhost '$vhost'. Use $TLS_VHOSTS_LIST." >&2
            exit 1
          fi
          if [ -z "$fc_path" ] || [ -z "$key_path" ] || [ "$fc_path" = "$pair_rest" ] || [ ! -r "$fc_path" ] || [ ! -r "$key_path" ]; then
            echo "error: CADDY_TLS_CERTS entry '$pair' needs two readable paths." >&2
            exit 1
          fi
          cert_copies+=("$vhost|$fc_path|$key_path")
        done
        for vhost in $TLS_VHOSTS; do
          found=0
          for entry in "${cert_copies[@]}"; do
            if [ "${entry%%|*}" = "$vhost" ]; then
              found=1
              break
            fi
          done
          if [ "$found" -eq 0 ]; then
            echo "error: CADDY_TLS_CERTS per-vhost needs a pair for every vhost: $TLS_CERTS_EXAMPLE." >&2
            tls_migration_hint "$vhost"
            exit 1
          fi
        done
        ;;
      *)
        echo "error: CADDY_TLS_CERTS must be 'wildcard', 'wildcard:<fullchain>:<key>', or '$TLS_CERTS_EXAMPLE'." >&2
        exit 1
        ;;
      esac
    fi
  fi
fi

# Step 2: create the config directories with strict modes.
# The wizard never writes data/. The caddy entrypoint creates the store at run time.
mkdir -p config/caddy
mkdir -p config/caddy/secrets
mkdir -p config/caddy/certs
chmod 0750 config/caddy
chmod 0700 config/caddy/secrets
chmod 0750 config/caddy/certs

# Step 3: write the root .env with the shared STACK_DOMAIN and the TLS answers.
# Keep the other lines.
write_env_file "$stack_domain" "$tls_mode" "$tls_email" "$tls_cert_layout"

# Step 3b: copy the TLS certificates into config/caddy/certs, if any were asked for.
# The files are copied, not printed. Prints paths only.
if [ "${#cert_copies[@]}" -gt 0 ]; then
  for entry in "${cert_copies[@]}"; do
    vhost="${entry%%|*}"
    rest="${entry#*|}"
    src_fc="${rest%%|*}"
    src_key="${rest##*|}"
    install_cert_copy "$src_fc" "config/caddy/certs/$vhost/fullchain.pem" 0640
    install_cert_copy "$src_key" "config/caddy/certs/$vhost/privkey.pem" 0600
  done
fi

# Step 4: write the consul-template configuration.
# The entrypoint reads the management token from
# config/consul/secrets/agent.hcl at container start. The wizard never writes
# a consul token. The entrypoint creates a scoped caddy token at run time.
if [ "$use_local_consul" -eq 1 ]; then
  consul_address="http://consul:8500"
else
  consul_address="http://$consul_host:$consul_port"
fi
{
  printf '# Rendered by setup.sh caddy. Do not edit. Run the wizard again to regenerate.\n'
  printf '# consul-template runs inside the caddy container.\n'
  printf 'consul {\n'
  printf '  # This is the address of the Consul agent or server.\n'
  printf '  address = "%s"\n' "$consul_address"
  printf '}\n'
  printf '\n'
  printf 'template {\n'
  printf '  source      = "/etc/consul-template/templates/Caddyfile.tpl"\n'
  printf '  destination = "/etc/caddy/Caddyfile"\n'
  printf '  backup      = false\n'
  printf '  perms       = "0640"\n'
  printf '}\n'
} >config/caddy/consul-template.hcl
chmod 0640 config/caddy/consul-template.hcl

# Step 5: never print secret values. Print paths only.

# Step 6: print the summary.
echo "Configured the caddy wizard files:"
echo "  config/caddy/consul-template.hcl"
echo "note: capability flags: consul=$consul_enabled litefs=$litefs_enabled oidc=$oidc_enabled tls=$tls_enabled"
if [ "$consul_enabled" -eq 0 ]; then
  echo "mode: standalone. The container uses a static Caddyfile and tls internal."
else
  echo "mode: integrated. The container uses consul-template."
  echo "note: the entrypoint reads initial_management from config/consul/secrets/agent.hcl."
  echo "note: mount that file into the caddy container before you start it."
fi
echo "caddy vhosts: https://consul.$stack_domain (all consul nodes, :8500), https://lldap.$stack_domain, https://tinyauth.$stack_domain"
case "$tls_mode" in
internal)
  echo "TLS mode: internal. caddy issues certificates from its internal CA."
  echo "note: import the root CA on each client: data/caddy/store/caddy/pki/authorities/local/root.crt"
  echo "note: trust this root on each client."
  ;;
letsencrypt)
  echo "TLS mode: letsencrypt. ACME contact: $tls_email."
  echo "note: requires a public DNS name and ports 80 and 443 reachable. Not usable for .lan."
  ;;
existing)
  if [ "$tls_cert_layout" = "wildcard" ]; then
    echo "TLS mode: existing (wildcard). Certificates are in config/caddy/certs/wildcard (fullchain.pem, privkey.pem)."
  else
    echo "TLS mode: existing (per-vhost). Certificates are in config/caddy/certs/<vhost> (fullchain.pem, privkey.pem)."
  fi
  ;;
esac
echo "note: .env written with STACK_DOMAIN=$stack_domain and CADDY_TLS_MODE=$tls_mode"
if [ "$consul_enabled" -eq 1 ]; then
  echo "note: consul-template renders state/caddy/Caddyfile.tpl into /etc/caddy/Caddyfile"
  echo "note: caddy reloads the file itself when it changes (caddy run --watch)"
else
  echo "note: the entrypoint renders state/caddy/Caddyfile.static.tpl into /etc/caddy/Caddyfile"
fi
echo "note: the caddy service publishes ports 80 and 443."
if [ "$consul_enabled" -eq 1 ] && [ "$use_local_consul" -eq 1 ]; then
  echo "hint: consul must run too (docker compose up -d consul)."
  echo "hint: the entrypoint creates the caddy read ACL when the consul CLI is in the image."
fi
echo "Next step: docker compose up -d caddy"
echo "hint: the caddy image is built locally from state/caddy/Dockerfile (build context ./state/caddy)."
