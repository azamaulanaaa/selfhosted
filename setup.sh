#!/usr/bin/env bash
# Make Consul the mandatory control plane, ask which services to enable, ask
# for the shared PUBLIC_IP, and run the wizard of each enabled service.
# Consul runs in this stack (local) or outside it (remote). The CONSUL_ADDR
# value selects the location. A service never asks about Consul.
# The per-service wizards live in state/<service>/setup.sh.
# When caddy is enabled, the script assembles the enabled service vhost
# descriptors into config/caddy/vhosts.json and config/caddy/vhosts.txt.
# The stack assembles compose services with include. compose requires .env; this script creates it when it is missing.
# Safe to run again: the per-service wizards are idempotent. This script
# rewrites the managed lines in the root .env and keeps the other lines.
# It never prints secret values. It prints paths only.
#
# Order: create .env, assemble compose.yaml, resolve Consul, enable services,
# assemble the Caddy vhost registry, resolve PUBLIC_IP, write .env, run the
# service wizards.
#
# Usage:
#   setup.sh                        Ask which services to enable and for the shared PUBLIC_IP,
#                                   then run the wizard of each enabled service.
#   setup.sh <service> [args...]    Pass the arguments through to the service wizard.
#                                   For example: setup.sh <service> clean
#   setup.sh <service> clean [--data] [--yes]   Remove the service configuration
#                                   (and the service data with --data).
#                                   Not every service supports clean.
#                                   Services may support extra flags.
#
# Non-interactive environment variables:
#   CONSUL_ADDR              Consul address. Read from the environment, then from the
#                            root .env file. http://consul:8500 runs Consul in this
#                            stack. Any other value runs Consul outside it.
#   CONSUL_JOIN_IPS          Comma-separated IPv4 list of local Consul peers. Local mode only.
#   CONSUL_BOOTSTRAP_EXPECT  Local Consul bootstrap_expect. A number from 1 to 99. Local mode only.
#   CONSUL_HTTP_TOKEN        Remote Consul ACL token. Remote mode only. The script writes
#                            it to config/consul/secrets/remote-token. It never writes
#                            the token to .env.
#   SETUP_SERVICES  Comma-separated list of the services to enable. "all" enables every
#                   service. "none" enables no service. An empty or absent value enables
#                   every service. Surrounding whitespace is ignored. Unknown names are
#                   an error. Local Consul always stays enabled.
#   PUBLIC_IP       Public or LAN IPv4 of this node. The enabled services read it from .env.
#                   compose substitutes ${PUBLIC_IP}.
#   STACK_ROOTLESS  1 runs the services as container root for rootless nerdctl.
#                   0 runs them as uid STACK_UID and gid STACK_GID.
#   STACK_UID       Container user id. Use 0 when STACK_ROOTLESS is 1.
#   STACK_GID       Container group id. Use 0 when STACK_ROOTLESS is 1.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly KEBAB_CASE='^[a-z0-9]+(-[a-z0-9]+)*$'

# List the known services, one per line, in sorted order.
# A service is a directory directly under state/ that holds a readable setup.sh.
list_known_services() {
  local service_dir service
  for service_dir in state/*/; do
    [ -d "$service_dir" ] || continue
    service="$(basename "$service_dir")"
    if [ -f "${service_dir}setup.sh" ] && [ -r "${service_dir}setup.sh" ]; then
      printf '%s\n' "$service"
    fi
  done | LC_ALL=C sort
}

# Print the known services as a comma-separated list on one line.
known_services_list() {
  local -a known=()
  mapfile -t known < <(list_known_services)
  if [ "${#known[@]}" -eq 0 ]; then
    printf 'none\n'
    return 0
  fi
  local out="${known[0]}"
  local service
  for service in "${known[@]:1}"; do
    out="$out, $service"
  done
  printf '%s\n' "$out"
}

# Return 0 when the argument is a valid IPv4 address. Each octet must be 0 to 255.
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
    if [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

# Parse the value of a key from the root .env file.
# Print the trimmed value. Print nothing when the file or the line is missing.
read_env_value() {
  local key="$1"
  if [ ! -f .env ]; then
    return 0
  fi
  { grep -E "^${key}=" .env || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/" -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# Return 0 when the root .env file holds the key.
env_file_has_key() {
  local key="$1"
  [ -f .env ] && grep -qE "^${key}=" .env
}

# Parse the PUBLIC_IP value from the root .env file.
# Print the trimmed value. Print nothing when the file or the line is missing.
read_env_public_ip() {
  read_env_value PUBLIC_IP
}

# Resolve the default public or LAN IPv4 of this node.
# Set public_ip_default and public_ip_source.
# The order is: PUBLIC_IP, then the PUBLIC_IP line in the root .env, then autodetection.
# Autodetection uses the first IPv4 from hostname -I on Linux.
# On macOS it uses ipconfig getifaddr en0, then en1.
# The autodetected value is accepted only when is_valid_ipv4 accepts it.
resolve_public_ip_default() {
  local candidate
  if [ -n "${PUBLIC_IP:-}" ]; then
    public_ip_default="$PUBLIC_IP"
    public_ip_source="env"
    return 0
  fi
  candidate="$(read_env_public_ip)"
  if [ -n "$candidate" ]; then
    public_ip_default="$candidate"
    public_ip_source="envfile"
    return 0
  fi
  candidate=""
  if command -v hostname >/dev/null 2>&1; then
    candidate="$(hostname -I 2>/dev/null | awk '{print $1}')" || candidate=""
  fi
  if [ -n "$candidate" ] && is_valid_ipv4 "$candidate"; then
    public_ip_default="$candidate"
    public_ip_source="autodetect"
    return 0
  fi
  candidate=""
  if command -v ipconfig >/dev/null 2>&1; then
    candidate="$(ipconfig getifaddr en0 2>/dev/null)" || candidate=""
    if [ -z "$candidate" ] || ! is_valid_ipv4 "$candidate"; then
      candidate="$(ipconfig getifaddr en1 2>/dev/null)" || candidate=""
    fi
  fi
  if [ -n "$candidate" ] && is_valid_ipv4 "$candidate"; then
    public_ip_default="$candidate"
    public_ip_source="autodetect"
    return 0
  fi
  public_ip_default=""
  public_ip_source="none"
}

# Print an STE error for an invalid resolved public IP and exit 1.
# The message tells the user which source holds the bad value.
public_ip_default_invalid() {
  case "$public_ip_source" in
  env)
    echo "error: PUBLIC_IP '$public_ip_default' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid PUBLIC_IP '$public_ip_default'." >&2
    echo "error: Fix .env by hand or set PUBLIC_IP." >&2
    ;;
  *)
    echo "error: '$public_ip_default' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
    ;;
  esac
  exit 1
}

# Print an STE error for an invalid public IP answer and exit 1.
public_ip_answer_invalid() {
  echo "error: '$1' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
  exit 1
}

# Trim the surrounding whitespace from the argument and print it.
trim_whitespace() {
  printf '%s' "$1" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
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

# Return 0 when the argument is empty or a comma-separated list of IPv4 addresses.
# Surrounding whitespace around each entry is ignored.
is_valid_peer_list() {
  local list
  list="$(trim_whitespace "$1")"
  if [ -z "$list" ]; then
    return 0
  fi
  local IFS=','
  local -a entries
  read -r -a entries <<<"$list"
  local entry
  for entry in "${entries[@]}"; do
    entry="$(trim_whitespace "$entry")"
    if ! is_valid_ipv4 "$entry"; then
      return 1
    fi
  done
  return 0
}

# Print the peer list with trimmed entries. Print nothing for an empty list.
normalize_peer_list() {
  local list
  list="$(trim_whitespace "$1")"
  if [ -z "$list" ]; then
    return 0
  fi
  local IFS=','
  local -a entries
  read -r -a entries <<<"$list"
  local out=""
  local entry
  for entry in "${entries[@]}"; do
    entry="$(trim_whitespace "$entry")"
    if [ -n "$out" ]; then
      out="$out,"
    fi
    out="$out$entry"
  done
  printf '%s\n' "$out"
}

# Return 0 when the argument is a positive integer from 1 to 99.
is_valid_bootstrap_expect() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local number=$((10#$value))
  [ "$number" -ge 1 ] && [ "$number" -le 99 ]
}

# Print an STE error for an invalid Consul value and exit 1.
# The message tells the user which source holds the bad value.
consul_value_invalid() {
  local key="$1"
  local value="$2"
  local source="$3"
  local rule="$4"
  case "$source" in
  env)
    echo "error: $key '$value' is not valid. $rule" >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid $key '$value'. Fix .env by hand or set $key." >&2
    ;;
  *)
    echo "error: '$value' is not valid. $rule" >&2
    ;;
  esac
  exit 1
}

# Resolve CONSUL_ADDR. Set consul_addr and consul_mode.
# The order is: the process environment, then the root .env file, then a prompt.
# The default is local Consul when stdin is not a TTY.
# One trailing slash does not change the comparison with the local address.
resolve_consul_addr() {
  local candidate=""
  local source="none"
  if [ -n "${CONSUL_ADDR+x}" ]; then
    candidate="$CONSUL_ADDR"
    source="env"
  elif env_file_has_key CONSUL_ADDR; then
    candidate="$(read_env_value CONSUL_ADDR)"
    source="envfile"
  fi
  if [ "$source" = "none" ]; then
    if [ -t 0 ]; then
      local answer
      if ! read -r -p "Consul address? [http://consul:8500] " answer; then
        answer=""
      fi
      candidate="${answer:-http://consul:8500}"
      source="answer"
    else
      candidate="http://consul:8500"
      source="default"
    fi
  fi
  if ! is_valid_consul_addr "$candidate"; then
    consul_value_invalid CONSUL_ADDR "$candidate" "$source" "Use http:// or https://, a host, and no whitespace."
  fi
  consul_addr="$candidate"
  if [ "${consul_addr%/}" = "http://consul:8500" ]; then
    consul_mode="local"
  else
    consul_mode="remote"
  fi
}

# Resolve and write the remote Consul ACL token.
# Read CONSUL_HTTP_TOKEN first. Keep an existing token file by default.
# Write config/consul/secrets/remote-token with mode 600 and the directory with mode 700.
# Never print the token.
write_remote_consul_token() {
  local token_dir="config/consul/secrets"
  local token_file="$token_dir/remote-token"
  local token=""
  local token_source=""
  if [ -n "${CONSUL_HTTP_TOKEN+x}" ]; then
    token="$CONSUL_HTTP_TOKEN"
    token_source="env"
  elif [ -f "$token_file" ]; then
    token_source="file"
  elif [ -t 0 ]; then
    local answer
    if ! read -r -s -p "Remote Consul ACL token? " answer; then
      answer=""
    fi
    printf '\n' >&2
    token="$answer"
    token_source="answer"
  else
    echo "error: The remote Consul ACL token is required. Set CONSUL_HTTP_TOKEN." >&2
    exit 1
  fi

  if [ "$token_source" = "file" ]; then
    chmod 0700 "$token_dir"
    chmod 0600 "$token_file"
    echo "Kept the remote Consul token: $token_file"
    return 0
  fi
  if [ -z "$token" ]; then
    if [ "$token_source" = "env" ]; then
      echo "error: CONSUL_HTTP_TOKEN is empty." >&2
    else
      echo "error: The remote Consul ACL token is required." >&2
    fi
    exit 1
  fi
  mkdir -p "$token_dir"
  chmod 0700 "$token_dir"
  local tmp_token
  tmp_token="$(mktemp "$token_dir/.remote-token.XXXXXX")"
  chmod 0600 "$tmp_token"
  printf '%s\n' "$token" >"$tmp_token"
  mv "$tmp_token" "$token_file"
  chmod 0600 "$token_file"
  echo "Wrote the remote Consul token: $token_file"
}

# Resolve the local Consul peer list and bootstrap_expect.
# Read each value from the environment, then from the root .env file.
# Ask both questions when stdin is a TTY.
# A missing bootstrap_expect defaults to 1.
resolve_consul_local_settings() {
  local join_current=""
  local join_source="none"
  local bootstrap_current="1"
  local bootstrap_source="none"
  if [ -n "${CONSUL_JOIN_IPS+x}" ]; then
    join_current="$CONSUL_JOIN_IPS"
    join_source="env"
  elif env_file_has_key CONSUL_JOIN_IPS; then
    join_current="$(read_env_value CONSUL_JOIN_IPS)"
    join_source="envfile"
  fi
  if ! is_valid_peer_list "$join_current"; then
    consul_value_invalid CONSUL_JOIN_IPS "$join_current" "$join_source" "Use a comma-separated list of IPv4 addresses."
  fi
  join_current="$(normalize_peer_list "$join_current")"

  if [ -n "${CONSUL_BOOTSTRAP_EXPECT+x}" ]; then
    bootstrap_current="$CONSUL_BOOTSTRAP_EXPECT"
    bootstrap_source="env"
  elif env_file_has_key CONSUL_BOOTSTRAP_EXPECT; then
    bootstrap_current="$(read_env_value CONSUL_BOOTSTRAP_EXPECT)"
    bootstrap_source="envfile"
  fi
  if ! is_valid_bootstrap_expect "$bootstrap_current"; then
    consul_value_invalid CONSUL_BOOTSTRAP_EXPECT "$bootstrap_current" "$bootstrap_source" "Use a number from 1 to 99."
  fi

  consul_join_ips="$join_current"
  consul_bootstrap_expect="$((10#$bootstrap_current))"

  if [ -t 0 ]; then
    local join_answer
    if ! read -r -p "Peer IPs, comma-separated? [$consul_join_ips] " join_answer; then
      join_answer=""
    fi
    if [ -n "$join_answer" ]; then
      if ! is_valid_peer_list "$join_answer"; then
        consul_value_invalid CONSUL_JOIN_IPS "$join_answer" "answer" "Use a comma-separated list of IPv4 addresses."
      fi
      consul_join_ips="$(normalize_peer_list "$join_answer")"
    fi

    local bootstrap_answer
    if ! read -r -p "Consul bootstrap_expect? [$consul_bootstrap_expect] " bootstrap_answer; then
      bootstrap_answer=""
    fi
    if [ -n "$bootstrap_answer" ]; then
      if ! is_valid_bootstrap_expect "$bootstrap_answer"; then
        consul_value_invalid CONSUL_BOOTSTRAP_EXPECT "$bootstrap_answer" "answer" "Use a number from 1 to 99."
      fi
      consul_bootstrap_expect="$((10#$bootstrap_answer))"
    fi
  fi
}

# Return 0 when the argument is 0 or 1.
is_valid_rootless() {
  [ "$1" = "0" ] || [ "$1" = "1" ]
}

# Return 0 when the argument is 0 or a positive integer.
is_valid_identity_id() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Print an STE error for an invalid stack identity value and exit 1.
# The message tells the user which source holds the bad value.
stack_identity_invalid() {
  local key="$1"
  local value="$2"
  local source="$3"
  local rule="$4"
  case "$source" in
  env)
    echo "error: $key '$value' is not valid. $rule" >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid $key '$value'. Fix .env by hand or set $key." >&2
    ;;
  *)
    echo "error: '$value' is not valid. $rule" >&2
    ;;
  esac
  exit 1
}

# Resolve the container runtime identity. Set stack_rootless, stack_uid, and stack_gid.
# Read each value from the process environment, then from the root .env file.
# The default is rootful Docker: 0, 1000, 1000.
resolve_stack_identity() {
  local value=""
  local source="none"

  if [ -n "${STACK_ROOTLESS+x}" ]; then
    value="$STACK_ROOTLESS"
    source="env"
  elif env_file_has_key STACK_ROOTLESS; then
    value="$(read_env_value STACK_ROOTLESS)"
    source="envfile"
  else
    value="0"
    source="default"
  fi
  if ! is_valid_rootless "$value"; then
    stack_identity_invalid STACK_ROOTLESS "$value" "$source" "Use 0 or 1."
  fi
  stack_rootless="$value"

  if [ -n "${STACK_UID+x}" ]; then
    value="$STACK_UID"
    source="env"
  elif env_file_has_key STACK_UID; then
    value="$(read_env_value STACK_UID)"
    source="envfile"
  else
    value="1000"
    source="default"
  fi
  if ! is_valid_identity_id "$value"; then
    stack_identity_invalid STACK_UID "$value" "$source" "Use 0 or a positive integer."
  fi
  stack_uid="$value"

  if [ -n "${STACK_GID+x}" ]; then
    value="$STACK_GID"
    source="env"
  elif env_file_has_key STACK_GID; then
    value="$(read_env_value STACK_GID)"
    source="envfile"
  else
    value="1000"
    source="default"
  fi
  if ! is_valid_identity_id "$value"; then
    stack_identity_invalid STACK_GID "$value" "$source" "Use 0 or a positive integer."
  fi
  stack_gid="$value"
}

# Keep the discovered order. In local mode, force consul into the list.
# In remote mode, remove consul from the list.
normalize_enabled_services() {
  local service wanted
  local listed
  local -a normalized=()
  for service in "${services[@]}"; do
    listed=0
    for wanted in "${enabled[@]}"; do
      if [ "$service" = "$wanted" ]; then
        listed=1
        break
      fi
    done
    if [ "$service" = "consul" ]; then
      if [ "$consul_mode" = "remote" ]; then
        listed=0
      else
        listed=1
      fi
    fi
    if [ "$listed" -eq 1 ]; then
      normalized+=("$service")
    fi
  done
  enabled=("${normalized[@]}")
}

# Build the Caddy vhost registry from the enabled service descriptors.
# Read only state/<service>/vhost.json and keep the enabled order.
# A service without a descriptor gets no vhost.
# Write config/caddy/vhosts.json as a JSON array and config/caddy/vhosts.txt
# with one name per line. The directory is mode 750. Both files are mode 640.
assemble_caddy_vhosts() {
  local caddy_dir="config/caddy"
  local json_file="$caddy_dir/vhosts.json"
  local names_file="$caddy_dir/vhosts.txt"
  local service descriptor content name
  local json="["
  local first=1
  local -a names=()
  for service in "${enabled[@]}"; do
    descriptor="state/$service/vhost.json"
    if [ ! -f "$descriptor" ]; then
      continue
    fi
    content="$(<"$descriptor")"
    if [ "${content:0:1}" != "{" ] || [ "${content: -1}" != "}" ]; then
      echo "error: The vhost descriptor state/$service/vhost.json is not valid." >&2
      echo "error: The file must start with '{' and end with '}'." >&2
      exit 1
    fi
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$descriptor")"
    if [ -z "$name" ]; then
      echo "error: The vhost descriptor state/$service/vhost.json has no name." >&2
      exit 1
    fi
    if [ "$first" -eq 1 ]; then
      first=0
    else
      json="$json,"
    fi
    json="$json$content"
    names+=("$name")
  done
  json="$json]"

  mkdir -p "$caddy_dir"
  chmod 0750 "$caddy_dir"
  local tmp_json tmp_names
  tmp_json="$(mktemp "$caddy_dir/.vhosts.json.XXXXXX")"
  tmp_names="$(mktemp "$caddy_dir/.vhosts.txt.XXXXXX")"
  chmod 0640 "$tmp_json" "$tmp_names"
  printf '%s\n' "$json" >"$tmp_json"
  if [ "${#names[@]}" -gt 0 ]; then
    printf '%s\n' "${names[@]}" >"$tmp_names"
  fi
  mv "$tmp_json" "$json_file"
  mv "$tmp_names" "$names_file"
  chmod 0640 "$json_file" "$names_file"
  echo "Wrote the Caddy vhost registry: $json_file"
  echo "Wrote the Caddy vhost names: $names_file"
}

# Write the root .env with the shared Consul values and PUBLIC_IP. Keep the other lines.
# Preserve every line except the managed keys.
# In remote mode, do not write CONSUL_JOIN_IPS or CONSUL_BOOTSTRAP_EXPECT.
# When the resolved public IP is empty, keep the preserved lines without a PUBLIC_IP line.
# chmod 0640 the file. Never print the contents.
write_env_file() {
  local consul_addr="$1"
  local consul_join_ips="$2"
  local consul_bootstrap_expect="$3"
  local public_ip="$4"
  local tmp_env
  tmp_env="$(mktemp ./.env.tmp.XXXXXX)"
  if [ -f .env ]; then
    { grep -E -v '^(CONSUL_ADDR|CONSUL_JOIN_IPS|CONSUL_BOOTSTRAP_EXPECT|PUBLIC_IP)=' .env || true; } >"$tmp_env"
  fi
  printf 'CONSUL_ADDR=%s\n' "$consul_addr" >>"$tmp_env"
  if [ "$consul_mode" = "local" ]; then
    printf 'CONSUL_JOIN_IPS=%s\n' "$consul_join_ips" >>"$tmp_env"
    printf 'CONSUL_BOOTSTRAP_EXPECT=%s\n' "$consul_bootstrap_expect" >>"$tmp_env"
  fi
  if [ -n "$public_ip" ]; then
    printf 'PUBLIC_IP=%s\n' "$public_ip" >>"$tmp_env"
  fi
  chmod 0640 "$tmp_env"
  mv "$tmp_env" .env
}

# Dispatch mode: pass the arguments through to the service wizard.
if [ "$#" -ge 1 ]; then
  service="$1"
  if [[ ! "$service" =~ $KEBAB_CASE ]]; then
    echo "error: '$service' is not a valid service name. Use kebab-case, for example 'my-service'." >&2
    echo "usage: setup.sh [<service> [args...]]" >&2
    exit 2
  fi
  if [ -f "state/$service/setup.sh" ] && [ -r "state/$service/setup.sh" ]; then
    exec "$REPO_ROOT/state/$service/setup.sh" "${@:2}"
  fi
  echo "error: '$service' is not a known service. Known services: $(known_services_list)" >&2
  exit 2
fi

# Discover the services.
mapfile -t services < <(list_known_services)

# Step 1: create the root .env when it is missing. compose requires it.
if [ ! -e .env ]; then : >.env && chmod 0640 .env; fi

# Resolve the container runtime identity and export it to every service wizard.
resolve_stack_identity
export STACK_ROOTLESS="$stack_rootless"
export STACK_UID="$stack_uid"
export STACK_GID="$stack_gid"

# Step 2: regenerate the stack assembler from the current service fragments.
bash "$REPO_ROOT/scripts/compose-assemble.sh"

# Step 3: resolve the Consul address. Consul is mandatory.
resolve_consul_addr

# Step 4: resolve the Consul details for the selected mode.
consul_join_ips=""
consul_bootstrap_expect=""
if [ "$consul_mode" = "remote" ]; then
  write_remote_consul_token
  unset CONSUL_HTTP_TOKEN CONSUL_JOIN_IPS CONSUL_BOOTSTRAP_EXPECT
else
  if [ ! -f state/consul/setup.sh ] || [ ! -r state/consul/setup.sh ]; then
    echo "error: state/consul/setup.sh is missing. Local Consul needs this wizard." >&2
    echo "error: Set CONSUL_ADDR to a remote Consul or add the consul service." >&2
    exit 1
  fi
  resolve_consul_local_settings
  export CONSUL_JOIN_IPS="$consul_join_ips"
  export CONSUL_BOOTSTRAP_EXPECT="$consul_bootstrap_expect"
fi
export CONSUL_ADDR="$consul_addr"

# Step 5: select the services to enable.
# Consul is already decided by CONSUL_ADDR. The loop asks only the other services.
if [ "$consul_mode" = "local" ]; then
  echo "Consul is required in local mode. The setup enables the consul service."
else
  echo "Remote Consul is in use. The setup does not enable the local consul service."
fi
enabled=()
if [ -t 0 ]; then
  for service in "${services[@]}"; do
    if [ "$service" = "consul" ]; then
      continue
    fi
    if ! read -r -p "Enable the $service service? [Y/n] " answer; then
      answer=""
    fi
    case "${answer:-Y}" in
    [Yy] | [Yy][Ee][Ss])
      enabled+=("$service")
      ;;
    [Nn] | [Nn][Oo])
      ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
  done
else
  raw_services="${SETUP_SERVICES:-}"
  trimmed="$(printf '%s' "$raw_services" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//')"
  lowered="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$trimmed" ] || [ "$lowered" = "all" ]; then
    enabled=("${services[@]}")
  elif [ "$lowered" = "none" ]; then
    enabled=()
  else
    IFS=',' read -r -a tokens <<<"$trimmed"
    requested=()
    for token in "${tokens[@]}"; do
      service_name="$(printf '%s' "$token" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')"
      if [ -z "$service_name" ]; then
        continue
      fi
      if [ "$service_name" = "consul" ] && [ "$consul_mode" = "remote" ]; then
        echo "error: SETUP_SERVICES names consul, but CONSUL_ADDR '$consul_addr' is remote." >&2
        echo "error: Remove consul from SETUP_SERVICES." >&2
        exit 1
      fi
      duplicate=0
      for seen in "${requested[@]}"; do
        if [ "$seen" = "$service_name" ]; then
          duplicate=1
          break
        fi
      done
      if [ "$duplicate" -eq 1 ]; then
        continue
      fi
      requested+=("$service_name")
    done
    for service_name in "${requested[@]}"; do
      match=0
      for service in "${services[@]}"; do
        if [ "$service" = "$service_name" ]; then
          match=1
          break
        fi
      done
      if [ "$match" -eq 0 ]; then
        echo "error: '$service_name' is not a known service. Known services: $(known_services_list)" >&2
        exit 2
      fi
    done
    # Keep the sorted order of the discovered services.
    enabled=()
    for service in "${services[@]}"; do
      for service_name in "${requested[@]}"; do
        if [ "$service" = "$service_name" ]; then
          enabled+=("$service")
        fi
      done
    done
  fi
fi

# Consul is mandatory in local mode. It is absent in remote mode.
normalize_enabled_services

# Step 6: assemble the Caddy vhost registry when caddy is enabled.
for service in "${enabled[@]}"; do
  if [ "$service" = "caddy" ]; then
    assemble_caddy_vhosts
    break
  fi
done

# Step 7: resolve the public IP of this node. The enabled services advertise it.
resolve_public_ip_default
if [ -n "$public_ip_default" ] && ! is_valid_ipv4 "$public_ip_default"; then
  public_ip_default_invalid
fi
public_ip="$public_ip_default"
if [ -t 0 ]; then
  if ! read -r -p "Public IP of this node for other nodes to connect to? [$public_ip_default] " public_ip_answer; then
    public_ip_answer=""
  fi
  if [ -n "$public_ip_answer" ]; then
    if ! is_valid_ipv4 "$public_ip_answer"; then
      public_ip_answer_invalid "$public_ip_answer"
    fi
    public_ip="$public_ip_answer"
  fi
fi
if [ -z "$public_ip" ]; then
  echo "warning: No public IP was provided. .env is written without PUBLIC_IP." >&2
  echo "warning: The enabled services cannot read PUBLIC_IP from .env." >&2
fi
export PUBLIC_IP="$public_ip"

# Step 8: write the root .env with the shared Consul values and PUBLIC_IP. Keep the other lines.
write_env_file "$consul_addr" "$consul_join_ips" "$consul_bootstrap_expect" "$public_ip"

if [ "${#enabled[@]}" -eq 0 ]; then
  echo "No services enabled."
  exit 0
fi

# Step 9: run the wizard of each enabled service, in sorted order.
for service in "${enabled[@]}"; do
  if ! bash "$REPO_ROOT/state/$service/setup.sh"; then
    echo "error: the $service setup failed." >&2
    exit 1
  fi
done

# Step 10: print the summary.
echo "Configured the stack:"
for service in "${enabled[@]}"; do
  echo "  $service"
done
echo "CONSUL_ADDR: $consul_addr ($consul_mode)"
if [ -n "$public_ip" ]; then
  echo "PUBLIC_IP: $public_ip"
else
  echo "PUBLIC_IP: not set"
fi
echo "Next step: docker compose up -d ${enabled[*]}"
