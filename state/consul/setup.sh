#!/usr/bin/env bash
# Generate the Consul wizard files for this stack.
# Safe to run again: it rewrites local.hcl and keeps the secret file unless you rotate.
# It never prints secret values. It prints paths only.
#
# The root dispatcher (setup.sh) calls this script. It can also run standalone.
#
# Usage:
#   setup.sh consul                            Run the Consul wizard.
#   setup.sh consul nodes add <ip> [<ip>...]    Add peer IPs to config/consul/peers.txt.
#   setup.sh consul nodes remove <ip> [<ip>...] Remove peer IPs from config/consul/peers.txt.
#   setup.sh consul nodes list                  Print the peer IPs.
#   setup.sh consul clean [--data] [--yes]      Remove the consul configuration.
#                                               With --data also remove the consul data.
#                                               Asks for confirmation unless --yes is given.
#
# Non-interactive environment variables:
#   CONSUL_UI_ENABLED      1 to enable the web UI, 0 to disable it. Default 1.
#   CONSUL_ROTATE_SECRETS  1 to create a new gossip key and new ACL tokens, 0 to keep them. Default 0.
#                          A new gossip key must be copied to every node in the cluster.
#   CONSUL_JOIN_IPS        Comma-separated IPv4 list of cluster peers. This script reads it
#                          from the environment, then from the CONSUL_JOIN_IPS line in the
#                          root .env. It merges the list into peers.txt. It does not prompt.
#   CONSUL_BOOTSTRAP_EXPECT  Local Consul bootstrap_expect. A number from 1 to 99. This script
#                          reads it from the environment, then from the CONSUL_BOOTSTRAP_EXPECT
#                          line in the root .env. It does not prompt. Default: 1.
#   CONSUL_NODE_NAME       Node name for this Consul server. Default: the machine hostname.
#   PUBLIC_IP              Public or LAN IPv4 of this node. The root dispatcher asks for it and
#                          stores it in the root .env. This script reads PUBLIC_IP from the
#                          environment, then from the PUBLIC_IP line in the root .env.
#                          When neither source has a value, advertise_addr is omitted from local.hcl.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

# The consul container starts as root. The entrypoint then drops to uid 100 and gid 1000.
readonly CONTAINER_GID=1000

# Give the consul container user read access to a file.
# On success the group becomes 1000 and the mode becomes 0640.
# On failure the file gets the fallback mode and a warning is printed.
grant_read_access() {
  local file="$1"
  local fallback_mode="$2"
  if chgrp "$CONTAINER_GID" "$file" 2>/dev/null; then
    chmod 0640 "$file"
    return 0
  fi
  chmod "$fallback_mode" "$file"
  echo "warning: Group 1000 is not available for $file." >&2
  echo "warning: The consul container cannot read this file. Add your user to group 1000 or run this script as root." >&2
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

# Resolve the advertise address for this node. Set public_ip and public_ip_source.
# The order is: PUBLIC_IP from the environment, then the PUBLIC_IP line in the root .env.
# When neither source holds a value, advertise_addr is omitted from local.hcl.
# The root dispatcher asks for PUBLIC_IP and writes .env. This script does not autodetect it.
resolve_public_ip() {
  if [ -n "${PUBLIC_IP:-}" ]; then
    public_ip="$PUBLIC_IP"
    public_ip_source="env"
    return 0
  fi
  local candidate
  candidate="$(read_env_value PUBLIC_IP)"
  if [ -n "$candidate" ]; then
    public_ip="$candidate"
    public_ip_source="envfile"
    return 0
  fi
  public_ip=""
  public_ip_source="none"
}

# Print an STE error for an invalid resolved public IP and exit 1.
# The message tells the user which source holds the bad value.
public_ip_invalid() {
  case "$public_ip_source" in
  env)
    echo "error: PUBLIC_IP '$public_ip' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid PUBLIC_IP '$public_ip'." >&2
    echo "error: Fix .env by hand or set PUBLIC_IP." >&2
    ;;
  *)
    echo "error: '$public_ip' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
    ;;
  esac
  exit 1
}

# Return 0 when the argument is a valid Consul node name.
# The name must be 1 to 64 characters. It must start and end with a letter or a digit.
# The other characters can be letters, digits, dots, underscores, or hyphens.
is_valid_node_name() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,62}[a-zA-Z0-9])?$ ]]
}

# Resolve the default node name. Set node_name_default and node_name_source.
# The order is: CONSUL_NODE_NAME, then the node_name in config/consul/local.hcl, then the hostname.
resolve_node_name_default() {
  if [ -n "${CONSUL_NODE_NAME:-}" ]; then
    node_name_default="$CONSUL_NODE_NAME"
    node_name_source="env"
    return 0
  fi
  local_hcl_value="$(grep -E '^node_name' config/consul/local.hcl 2>/dev/null | head -n1 | cut -d '"' -f2 || true)"
  if [ -n "$local_hcl_value" ]; then
    node_name_default="$local_hcl_value"
    node_name_source="file"
    return 0
  fi
  host_value="$(hostname -s 2>/dev/null)" || host_value=""
  if [ -z "$host_value" ]; then
    host_value="$(hostname 2>/dev/null)" || host_value=""
  fi
  if [ -z "$host_value" ]; then
    host_value="consul-node"
  fi
  node_name_default="$host_value"
  node_name_source="hostname"
}

# Print an STE error for an invalid resolved node name and exit 1.
# The message tells the user which source holds the bad value.
node_name_default_invalid() {
  case "$node_name_source" in
  env)
    echo "error: CONSUL_NODE_NAME '$node_name_default' is not a valid node name." >&2
    ;;
  file)
    echo "error: config/consul/local.hcl holds the invalid node name '$node_name_default'." >&2
    echo "error: Fix the file by hand or set CONSUL_NODE_NAME." >&2
    ;;
  hostname)
    echo "error: The machine hostname '$node_name_default' is not a valid node name." >&2
    echo "error: Set CONSUL_NODE_NAME to a valid node name." >&2
    ;;
  esac
  echo "error: Use 1 to 64 characters. Start and end with a letter or a digit. Use letters, digits, dots, underscores, or hyphens." >&2
  exit 1
}

# Print an STE error for an invalid node name answer and exit 1.
node_name_answer_invalid() {
  echo "error: '$1' is not a valid node name." >&2
  echo "error: Use 1 to 64 characters. Start and end with a letter or a digit. Use letters, digits, dots, underscores, or hyphens." >&2
  exit 1
}

# Peers are the IPs of the other Consul servers in the cluster.
# config/consul/peers.txt is the source of truth. It holds one IPv4 per line.
# Blank lines and lines that start with # are ignored when the file is read.
readonly PEERS_FILE="config/consul/peers.txt"
readonly JOIN_FILE="config/consul/join.hcl"
# The wizard renders the server config to this file.
# The wizard reads the committed template and never writes to state/.
readonly BASE_CONFIG_FILE="state/consul/consul.hcl"
readonly RENDERED_CONFIG_FILE="config/consul/consul.hcl"
# The wizard owns bootstrap_expect. Consul loads this file with the other wizard files.
readonly BOOTSTRAP_CONFIG_FILE="config/consul/bootstrap.hcl"
# The shared gossip key lives in the backed-up secrets tree. Copy this file to every cluster node.
readonly GOSSIP_KEY_FILE="config/consul/secrets/gossip.key"

# Return 0 when the argument is a valid IPv4 address. Each octet must be 0 to 255.
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

# Trim the surrounding whitespace from the argument and print it.
trim_whitespace() {
  printf '%s' "$1" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
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
    if ! is_valid_ipv4 "$(trim_whitespace "$entry")"; then
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

# Return 0 when the argument is a number from 1 to 99.
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

# Resolve the peer list. Set consul_join_ips.
# The order is: the process environment, then the root .env file.
# A missing value is an empty list.
resolve_join_ips() {
  local candidate=""
  local source="none"
  if [ -n "${CONSUL_JOIN_IPS+x}" ]; then
    candidate="$CONSUL_JOIN_IPS"
    source="env"
  elif [ -f .env ] && grep -qE '^CONSUL_JOIN_IPS=' .env; then
    candidate="$(read_env_value CONSUL_JOIN_IPS)"
    source="envfile"
  fi
  if ! is_valid_peer_list "$candidate"; then
    consul_value_invalid CONSUL_JOIN_IPS "$candidate" "$source" "Use a comma-separated list of IPv4 addresses."
  fi
  consul_join_ips="$(normalize_peer_list "$candidate")"
}

# Resolve bootstrap_expect. Set consul_bootstrap_expect.
# The order is: the process environment, then the root .env file, then 1.
resolve_bootstrap_expect() {
  local candidate="1"
  local source="default"
  if [ -n "${CONSUL_BOOTSTRAP_EXPECT+x}" ]; then
    candidate="$CONSUL_BOOTSTRAP_EXPECT"
    source="env"
  elif [ -f .env ] && grep -qE '^CONSUL_BOOTSTRAP_EXPECT=' .env; then
    candidate="$(read_env_value CONSUL_BOOTSTRAP_EXPECT)"
    source="envfile"
  fi
  if ! is_valid_bootstrap_expect "$candidate"; then
    consul_value_invalid CONSUL_BOOTSTRAP_EXPECT "$candidate" "$source" "Use a number from 1 to 99."
  fi
  consul_bootstrap_expect="$((10#$candidate))"
}

# Print the configured peers, one IPv4 per line. Sort and deduplicate the output.
read_peers() {
  if [ ! -f "$PEERS_FILE" ]; then
    return 0
  fi
  awk '{ sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if (length($0)) print }' "$PEERS_FILE" | sort -u
}

# Write the given peers to peers.txt. Sort and deduplicate them.
write_peers() {
  local -a peers=("$@")
  if [ "${#peers[@]}" -eq 0 ]; then
    : >"$PEERS_FILE"
  else
    printf '%s\n' "${peers[@]}" | sort -u >"$PEERS_FILE"
  fi
  chmod 0640 "$PEERS_FILE"
}

# Render config/consul/join.hcl from peers.txt. Always write the file so the
# mount in compose.yaml never fails. Write retry_join = [] when there are no peers.
render_join() {
  local -a peers=()
  local peer
  while IFS= read -r peer; do
    peers+=("$peer")
  done < <(read_peers)
  {
    printf '# Rendered by setup.sh from config/consul/peers.txt. Do not edit.\n'
    if [ "${#peers[@]}" -eq 0 ]; then
      printf 'retry_join = []\n'
    else
      printf 'retry_join = ['
      local first=1
      for peer in "${peers[@]}"; do
        if [ "$first" -eq 1 ]; then
          first=0
        else
          printf ', '
        fi
        printf '"%s"' "$peer"
      done
      printf ']\n'
    fi
  } >"$JOIN_FILE"
  chmod 0640 "$JOIN_FILE"
  grant_read_access "$JOIN_FILE" 0640
}

# Render the Consul server config from the committed template.
# The template holds the production form. The wizard never writes to state/.
render_consul_hcl() {
  {
    printf '# Rendered by setup.sh from %s. Do not edit.\n' "$BASE_CONFIG_FILE"
    cat -- "$BASE_CONFIG_FILE"
  } >"$RENDERED_CONFIG_FILE"
  chmod 0640 "$RENDERED_CONFIG_FILE"
  grant_read_access "$RENDERED_CONFIG_FILE" 0640
}

# Render the wizard-owned bootstrap_expect file.
# The committed template does not hold this key, so Consul reads it once.
render_bootstrap_hcl() {
  {
    printf '# Rendered by setup.sh from CONSUL_BOOTSTRAP_EXPECT. Do not edit.\n'
    printf 'bootstrap_expect = %s\n' "$consul_bootstrap_expect"
  } >"$BOOTSTRAP_CONFIG_FILE"
  chmod 0640 "$BOOTSTRAP_CONFIG_FILE"
  grant_read_access "$BOOTSTRAP_CONFIG_FILE" 0640
}

# Print the exact commands that create a read-only policy and token for caddy.
# The wizard does not run the Consul CLI and does not invent a token.
# The operator runs these commands when the Consul CLI is available and the stack is up.
print_acl_commands() {
  echo "Consul denies requests without a token."
  echo "The caddy service requires a read-only token."
  echo "The wizard does not create this token."
  echo "Run these commands when the Consul CLI is available:"
  cat <<'EOF'
  export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
  export CONSUL_HTTP_TOKEN="$(grep -E '^[[:space:]]*initial_management' config/consul/secrets/agent.hcl | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
  consul acl policy create -name 'caddy-read' -description 'Read-only access for caddy' -rules 'key "" { policy = "read" }'
  consul acl token create -description 'caddy read-only token' -policy-name 'caddy-read'
EOF
  echo "Store the printed token in caddy's own secret tree with the caddy wizard."
}

# Validate a list of IPs. Print one error per invalid IP. Return 1 when at least one IP is invalid.
validate_ips() {
  local ip
  local invalid=0
  for ip in "$@"; do
    if ! is_valid_ipv4 "$ip"; then
      echo "error: '$ip' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
      invalid=1
    fi
  done
  return "$invalid"
}

# Merge the resolved peer list into peers.txt (union, deduplicated).
# resolve_join_ips validates the list before this function runs.
seed_peers() {
  if [ -z "$consul_join_ips" ]; then
    return 0
  fi
  local ip
  local -a extra=()
  local IFS=','
  read -r -a extra <<<"$consul_join_ips"
  unset IFS
  local -a merged=()
  while IFS= read -r ip; do
    merged+=("$ip")
  done < <(read_peers)
  merged+=("${extra[@]}")
  write_peers "${merged[@]}"
}

# Print the number of configured peers.
peer_count() {
  read_peers | wc -l | tr -d '[:space:]'
}

usage_nodes() {
  echo "usage: setup.sh consul nodes add <ip> [<ip>...]" >&2
  echo "       setup.sh consul nodes remove <ip> [<ip>...]" >&2
  echo "       setup.sh consul nodes list" >&2
}

# The nodes subcommands manage the peer IPs of this Consul server.
# They never prompt and never need openssl. They run before the wizard path.
if [ "${1:-}" = "nodes" ]; then
  mkdir -p config/consul
  resolve_join_ips
  shift
  nodes_sub="${1:-}"
  if [ $# -gt 0 ]; then
    shift
  fi
  case "$nodes_sub" in
  add)
    if [ $# -eq 0 ]; then
      usage_nodes
      exit 2
    fi
    if ! validate_ips "$@"; then
      exit 1
    fi
    seed_peers
    merged=()
    while IFS= read -r peer; do
      merged+=("$peer")
    done < <(read_peers)
    merged+=("$@")
    write_peers "${merged[@]}"
    render_join
    echo "$(peer_count) peers configured."
    ;;
  remove)
    if [ $# -eq 0 ]; then
      usage_nodes
      exit 2
    fi
    if ! validate_ips "$@"; then
      exit 1
    fi
    seed_peers
    local_peers=()
    while IFS= read -r peer; do
      local_peers+=("$peer")
    done < <(read_peers)
    remaining=()
    for peer in "${local_peers[@]}"; do
      present=0
      for remove_ip in "$@"; do
        if [ "$peer" = "$remove_ip" ]; then
          present=1
          break
        fi
      done
      if [ "$present" -eq 0 ]; then
        remaining+=("$peer")
      fi
    done
    for remove_ip in "$@"; do
      found=0
      for peer in "${local_peers[@]}"; do
        if [ "$peer" = "$remove_ip" ]; then
          found=1
          break
        fi
      done
      if [ "$found" -eq 0 ]; then
        echo "warning: '$remove_ip' is not in the peer list." >&2
      fi
    done
    if [ "${#remaining[@]}" -eq 0 ]; then
      write_peers
    else
      write_peers "${remaining[@]}"
    fi
    render_join
    echo "Remaining peers:"
    read_peers
    echo "$(peer_count) peers configured."
    ;;
  list)
    if [ $# -ne 0 ]; then
      usage_nodes
      exit 2
    fi
    count="$(peer_count)"
    if [ "$count" -eq 0 ]; then
      echo "0 peers configured."
    else
      read_peers
    fi
    ;;
  *)
    usage_nodes
    exit 2
    ;;
  esac
  exit 0
fi

usage_clean() {
  echo "usage: setup.sh consul clean [--data] [--yes]" >&2
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

# Remove the consul configuration, and with --data also the consul data.
# Never touches state/, .env, other services, or anything outside the
# resolved config/consul and data/consul directories.
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
  config_target="$(resolve_removal_target "$REPO_ROOT/config/consul" "$REPO_ROOT/config/consul")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/data/consul" "$REPO_ROOT/data/consul")" || exit 1
  fi

  # Collect the paths to remove. Print each path under config/consul.
  # For data/consul print the tree root only; a store can be very large.
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
        prompt="Remove the configuration AND DATA for consul? This deletes certs/buckets. [y/N] "
      else
        prompt="Remove the configuration for consul? [y/N] "
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

  echo "Removed the consul configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the consul data."
  fi
  echo "Run 'bash setup.sh consul' (or setup.sh) to generate fresh secrets for a future install."
  echo "hint: Rotation changes the bootstrap defaults. It does not revoke ACL tokens in the persisted store."
  echo "hint: if this node was in a multi-node cluster, remove it with: consul operator raft remove-peer."
  return 0
}

# The clean subcommand removes the consul configuration and data.
# Without --data only config/consul is removed. The data is never removed without --data.
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

# Step 2: create the config directory layout with strict modes.
# The wizard never writes to data/. The container entrypoint creates and owns data/consul/store.
mkdir -p config/consul/secrets
chmod 0750 config/consul
chmod 0700 config/consul/secrets

# Step 3: read the cluster values and collect the answers.
# The root dispatcher writes CONSUL_JOIN_IPS and CONSUL_BOOTSTRAP_EXPECT to
# the root .env and exports them. This script reads them. It never asks for them.
resolve_join_ips
resolve_bootstrap_expect
# Use the environment when stdin is not a TTY.
ui_enabled=1
rotate=0
node_name=""
# Resolve and validate the default node name before anything is written.
resolve_node_name_default
if ! is_valid_node_name "$node_name_default"; then
  node_name_default_invalid
fi
node_name="$node_name_default"
# Resolve and validate the advertise address before anything is written.
resolve_public_ip
if [ -n "$public_ip" ] && ! is_valid_ipv4 "$public_ip"; then
  public_ip_invalid
fi
if [ -t 0 ]; then
  if ! read -r -p "Enable the Consul web UI? [Y/n] " ui_answer; then
    ui_answer=""
  fi
  case "${ui_answer:-Y}" in
  [Yy] | [Yy][Ee][Ss])
    ui_enabled=1
    ;;
  [Nn] | [Nn][Oo])
    ui_enabled=0
    ;;
  *)
    echo "error: Answer Y or N." >&2
    exit 1
    ;;
  esac
  if [ -f config/consul/secrets/agent.hcl ]; then
    if ! read -r -p "Secrets exist. Rotate the gossip key and the ACL bootstrap defaults? [y/N] " rotate_answer; then
      rotate_answer=""
    fi
    case "${rotate_answer:-N}" in
    [Yy] | [Yy][Ee][Ss])
      rotate=1
      ;;
    [Nn] | [Nn][Oo])
      rotate=0
      ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
  fi
  if ! read -r -p "Node name for this Consul server? [$node_name_default] " node_name_answer; then
    node_name_answer=""
  fi
  if [ -n "$node_name_answer" ]; then
    if ! is_valid_node_name "$node_name_answer"; then
      node_name_answer_invalid "$node_name_answer"
    fi
    node_name="$node_name_answer"
  fi
else
  case "${CONSUL_UI_ENABLED:-1}" in
  0)
    ui_enabled=0
    ;;
  1)
    ui_enabled=1
    ;;
  *)
    echo "error: CONSUL_UI_ENABLED must be 0 or 1." >&2
    exit 1
    ;;
  esac
  case "${CONSUL_ROTATE_SECRETS:-0}" in
  0)
    rotate=0
    ;;
  1)
    rotate=1
    ;;
  *)
    echo "error: CONSUL_ROTATE_SECRETS must be 0 or 1." >&2
    exit 1
    ;;
  esac
fi
if [ -z "$public_ip" ]; then
  echo "warning: No PUBLIC_IP is set. advertise_addr is omitted from config/consul/local.hcl." >&2
  echo "warning: Consul advertises the OS interface address. Run setup.sh to set PUBLIC_IP." >&2
fi

# Return 0 when the argument is a base64 string that decodes to 32 bytes.
validate_gossip_key() {
  local decoded_size
  if ! decoded_size="$(printf '%s' "$1" | openssl base64 -d -A 2>/dev/null | wc -c)"; then
    return 1
  fi
  [ "$decoded_size" -eq 32 ]
}

# Print the encrypt value from the agent secret file. Print nothing when the file is missing.
current_gossip_key() {
  if [ ! -f config/consul/secrets/agent.hcl ]; then
    return 0
  fi
  grep -E '^[[:space:]]*encrypt' config/consul/secrets/agent.hcl | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'
}

# Resolve the shared gossip key. Store the key in the backed-up secrets tree.
# Create a new key when the file is missing or when rotation was accepted.
# The operator copies the key file to every node in the cluster.
resolve_gossip_key() {
  if [ "$rotate" -eq 1 ] || [ ! -f "$GOSSIP_KEY_FILE" ]; then
    encrypt_key="$(openssl rand -base64 32)"
    if ! validate_gossip_key "$encrypt_key"; then
      echo "error: The gossip key does not decode to 32 bytes. Check openssl and run this script again." >&2
      exit 1
    fi
    (
      umask 077
      printf '%s\n' "$encrypt_key" >"$GOSSIP_KEY_FILE"
    )
    chmod 0600 "$GOSSIP_KEY_FILE"
    gossip_key_state="created"
    return 0
  fi
  encrypt_key="$(head -n1 "$GOSSIP_KEY_FILE" | tr -d '[:space:]')"
  if ! validate_gossip_key "$encrypt_key"; then
    echo "error: The file $GOSSIP_KEY_FILE holds an invalid gossip key." >&2
    echo "error: Use a base64 string that decodes to 32 bytes." >&2
    exit 1
  fi
  gossip_key_state="kept"
}

# Step 4: write the secret file.
# The gossip key comes from the shared key file, so every cluster node uses the same key.
# The ACL tokens stay the same unless the user rotates them.
secret_state="kept"
resolve_gossip_key
needs_write=0
if [ ! -f config/consul/secrets/agent.hcl ] || [ "$rotate" -eq 1 ]; then
  needs_write=1
  if [ -f config/consul/secrets/agent.hcl ]; then
    secret_state="rotated"
  else
    secret_state="created"
  fi
elif [ "$(current_gossip_key)" != "$encrypt_key" ]; then
  needs_write=1
  secret_state="updated"
fi
if [ "$needs_write" -eq 1 ]; then
  if [ "$secret_state" = "updated" ]; then
    initial_management="$(grep -E '^[[:space:]]*initial_management' config/consul/secrets/agent.hcl | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
    initial_agent="$(grep -E '^[[:space:]]*initial_agent' config/consul/secrets/agent.hcl | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
    if [ -z "$initial_management" ] || [ -z "$initial_agent" ]; then
      initial_management="$(openssl rand -hex 32)"
      initial_agent="$(openssl rand -hex 32)"
    fi
  else
    initial_management="$(openssl rand -hex 32)"
    initial_agent="$(openssl rand -hex 32)"
  fi
  (
    umask 077
    {
      printf 'encrypt = "%s"\n' "$encrypt_key"
      printf '\n'
      printf 'acl {\n'
      printf '  tokens {\n'
      printf '    initial_management = "%s"\n' "$initial_management"
      printf '    initial_agent = "%s"\n' "$initial_agent"
      printf '  }\n'
      printf '}\n'
    } >config/consul/secrets/agent.hcl
  )
  chmod 0600 config/consul/secrets/agent.hcl
fi
# The container reads this file as uid 100 and gid 1000. The mode becomes 0640 on success.
grant_read_access config/consul/secrets/agent.hcl 0600

# Step 5: write the local wizard answers on every run.
{
  printf 'ui_config {\n'
  if [ "$ui_enabled" -eq 1 ]; then
    printf '  enabled = true\n'
  else
    printf '  enabled = false\n'
  fi
  printf '}\n'
  if [ -n "$public_ip" ]; then
    printf 'advertise_addr = "%s"\n' "$public_ip"
  fi
  printf 'node_name = "%s"\n' "$node_name"
} >config/consul/local.hcl
chmod 0640 config/consul/local.hcl
# The container reads this file as uid 100 and gid 1000. The mode stays 0640 on success.
grant_read_access config/consul/local.hcl 0640

# Step 5b: render the server config from the committed template.
render_consul_hcl

# Step 5c: write bootstrap_expect to the wizard-owned config file.
render_bootstrap_hcl

# Step 6: enforce the directory modes on every run.
chmod 0700 config/consul/secrets
chmod 0750 config/consul

# Step 7: merge the resolved CONSUL_JOIN_IPS list and re-render the join config.
# peers.txt can be empty on the first run. Always write join.hcl so the mount never fails.
# peers.txt can also be missing, for example after a clean. Always write it.
if [ ! -f "$PEERS_FILE" ]; then
  write_peers
fi
seed_peers
render_join
peers_configured="$(peer_count)"

# Step 8: never print secret values. Print paths only.

# Step 9: print the summary.
echo "Configured the consul wizard files:"
echo "  config/consul/local.hcl"
echo "  config/consul/bootstrap.hcl"
echo "  config/consul/consul.hcl"
echo "  config/consul/secrets/gossip.key ($gossip_key_state)"
case "$secret_state" in
created)
  echo "  config/consul/secrets/agent.hcl (created)"
  ;;
rotated)
  echo "  config/consul/secrets/agent.hcl (rotated)"
  ;;
updated)
  echo "  config/consul/secrets/agent.hcl (key updated)"
  ;;
*)
  echo "  config/consul/secrets/agent.hcl (kept)"
  ;;
esac
echo "hint: Copy config/consul/secrets/gossip.key to every node in the cluster."
if [ -n "$public_ip" ]; then
  echo "PUBLIC_IP: $public_ip"
else
  echo "PUBLIC_IP: not set (advertise_addr omitted)"
fi
echo "Node name: $node_name"
echo "hint: Node names must be unique per server."
echo "  config/consul/join.hcl"
echo "Peers configured: $peers_configured"
echo "bootstrap_expect: $consul_bootstrap_expect"
echo "Next step: docker compose up -d consul"
echo "Back up config/consul/secrets and data/consul/store. These are the backup-critical paths. See docs/layout.md."
echo ""
print_acl_commands
