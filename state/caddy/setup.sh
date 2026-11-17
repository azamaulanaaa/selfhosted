#!/usr/bin/env bash
# Generate the caddy wizard files for this stack.
# Safe to run again: it rewrites consul-template.hcl. It never prints secret
# values. It prints paths only.
#
# One container serves consul.<STACK_DOMAIN>: the caddy image (built locally
# from state/caddy/Dockerfile) embeds consul-template. consul-template renders
# /etc/caddy/Caddyfile from state/caddy/Caddyfile.tpl, and caddy reloads itself
# on change (caddy run --watch). There is no sidecar service.
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
#   CADDY_CONSUL_TOKEN      Consul ACL token (remote only). When non-empty it is
#                           written to config/caddy/secrets/consul-token.
#                           When empty, an existing token file is kept; when the file
#                           does not exist, an anonymous token is used.
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

# Write the root .env with the shared STACK_DOMAIN. Keep the other lines.
# Preserve every line except the STACK_DOMAIN=... lines.
# chmod 0640 the file. Never print the contents beyond paths.
write_env_file() {
  local stack_domain="$1"
  local tmp_env
  tmp_env="$(mktemp ./.env.tmp.XXXXXX)"
  if [ -f .env ]; then
    { grep -E -v '^STACK_DOMAIN=' .env || true; } >"$tmp_env"
  fi
  printf 'STACK_DOMAIN=%s\n' "$stack_domain" >>"$tmp_env"
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
  done

  echo "Removed the caddy configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the caddy data."
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
  case "${CADDY_USE_LOCAL_CONSUL:-1}" in
  0 | 1)
    ;;
  *)
    echo "error: CADDY_USE_LOCAL_CONSUL must be 0 or 1." >&2
    exit 1
    ;;
  esac
  if ! is_valid_domain "$stack_domain"; then
    stack_domain_default_invalid
  fi
fi

use_local_consul=1
consul_host="127.0.0.1"
consul_port="8500"
consul_token=""
if [ -t 0 ]; then
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
    if ! read -r -p "Consul ACL token? (empty for anonymous) " token_answer; then
      token_answer=""
    fi
    consul_token="$token_answer"
  fi
else
  case "${CADDY_USE_LOCAL_CONSUL:-1}" in
  1)
    use_local_consul=1
    ;;
  0)
    use_local_consul=0
    consul_host="${CADDY_CONSUL_HOST:-}"
    consul_port="${CADDY_CONSUL_PORT:-8500}"
    consul_token="${CADDY_CONSUL_TOKEN:-}"
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

# Step 2: create the directory layout with strict modes.
mkdir -p config/caddy
mkdir -p config/caddy/secrets
mkdir -p data/caddy/store
chmod 0750 config/caddy
chmod 0700 config/caddy/secrets
chmod 0750 data/caddy
chmod 0750 data/caddy/store

# Step 3: write the root .env with the shared STACK_DOMAIN. Keep the other lines.
write_env_file "$stack_domain"

# Step 4: write the consul-template configuration.
# The token flows as a file, never inline: consul-template supports token_file.
# The caddy container runs as root, so root-owned 0600 is readable inside it.
# When anonymous is chosen the token_file line is omitted; the container then
# talks to consul without a token.
token_state="anonymous"
if [ "$use_local_consul" -eq 1 ]; then
  consul_address="http://consul:8500"
else
  consul_address="http://$consul_host:$consul_port"
  if [ -n "$consul_token" ]; then
    (
      umask 077
      printf '%s\n' "$consul_token" >config/caddy/secrets/consul-token
    )
    chmod 0600 config/caddy/secrets/consul-token
    token_state="written"
  elif [ -f config/caddy/secrets/consul-token ]; then
    chmod 0600 config/caddy/secrets/consul-token
    token_state="kept"
  fi
fi
{
  printf '# Rendered by setup.sh caddy. Do not edit. Run the wizard again to regenerate.\n'
  printf '# consul-template runs inside the caddy container.\n'
  printf 'consul {\n'
  printf '  # This is the address of the Consul agent or server.\n'
  printf '  address = "%s"\n' "$consul_address"
  if [ "$token_state" = "written" ] || [ "$token_state" = "kept" ]; then
    printf '  # The ACL token is read from a file. It never appears inline.\n'
    printf '  token_file = "/etc/consul-template/secrets/consul-token"\n'
  fi
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
case "$token_state" in
written)
  echo "  config/caddy/secrets/consul-token (written)"
  ;;
kept)
  echo "  config/caddy/secrets/consul-token (kept)"
  ;;
esac
echo "caddy vhost: http://consul.$stack_domain -> all consul nodes (:8500)"
echo "note: HTTP only for now. TLS is intentionally absent for this issue."
echo "note: .env written with STACK_DOMAIN=$stack_domain"
echo "note: consul-template renders state/caddy/Caddyfile.tpl into /etc/caddy/Caddyfile (inside the caddy container)"
echo "note: caddy reloads the file itself when it changes (caddy run --watch)"
if [ "$use_local_consul" -eq 1 ]; then
  echo "note: this repo's consul uses default_policy=deny. To render, create an anonymous read policy, or re-run and answer N with 127.0.0.1 and a token."
  if [ -f config/caddy/secrets/consul-token ]; then
    echo "warning: config/caddy/secrets/consul-token exists but is not referenced by the new configuration." >&2
  fi
fi
echo "Next step: docker compose up -d caddy"
echo "hint: the caddy image is built locally from state/caddy/Dockerfile (build context ./state/caddy)."
echo "hint: the container waits for consul on boot and renders once consul answers."
echo "hint: for the local case, consul must run too (docker compose up -d consul)."
