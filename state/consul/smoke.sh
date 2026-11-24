#!/usr/bin/env bash
# Run standalone smoke checks for the Consul wizard.
# The checks use scratch trees so the live config stays untouched.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

# Print an STE error and exit 1.
fail() {
  echo "error: $1" >&2
  exit 1
}

scratch_trees=()

# Remove the scratch trees. This function runs when the script exits.
cleanup_scratch_trees() {
  local tree
  for tree in "${scratch_trees[@]}"; do
    rm -rf -- "$tree"
  done
}
trap cleanup_scratch_trees EXIT

# Make a scratch tree with the wizard and its base template.
new_scratch_tree() {
  local tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/state/consul"
  cp -- state/consul/setup.sh "$tree/state/consul/setup.sh"
  cp -- state/consul/consul.hcl "$tree/state/consul/consul.hcl"
  scratch_trees+=("$tree")
  printf '%s\n' "$tree"
}

# Run the wizard in a scratch tree.
# Each remaining argument is a KEY=VALUE environment assignment.
run_wizard() {
  local tree="$1"
  shift
  if ! env CONSUL_UI_ENABLED=0 "$@" bash "$tree/state/consul/setup.sh" >"$tree/wizard.log" 2>&1; then
    fail "The wizard failed. Read $tree/wizard.log."
  fi
}

# Check that the rendered config uses the deny policy and the trusted-LAN binding.
check_rendered_config() {
  local tree="$1"
  local config="$tree/config/consul/consul.hcl"
  local policy_count addr_count
  [ -f "$config" ] || fail "The wizard did not render config/consul/consul.hcl."
  grep -q 'default_policy = "deny"' "$config" ||
    fail "The rendered config does not set the deny policy."
  policy_count="$(grep -c 'default_policy' "$config")"
  [ "$policy_count" -eq 1 ] ||
    fail "The rendered config holds more than one default policy."
  grep -q 'client_addr = "0.0.0.0"' "$config" ||
    fail "The rendered config does not use the trusted-LAN binding."
  addr_count="$(grep -c 'addr' "$config")"
  [ "$addr_count" -eq 1 ] ||
    fail "The rendered config holds an extra address binding."
}

# Check that the secret files use strict modes.
check_strict_modes() {
  local tree="$1"
  local file mode
  for file in config/consul/secrets/agent.hcl config/consul/secrets/gossip.key; do
    [ -f "$tree/$file" ] || fail "The wizard did not create $file."
    mode="$(stat -c '%a' "$tree/$file")"
    case "$mode" in
    600 | 640) ;;
    *) fail "$file has mode $mode. Use mode 600 or 640." ;;
    esac
  done
}

# Check that the wizard creates a management token and the agent token key.
# The old initial_agent key is not valid for the pinned image.
check_management_token() {
  local tree="$1"
  local file="$tree/config/consul/secrets/agent.hcl"
  grep -q '^[[:space:]]*initial_management[[:space:]]*=' "$file" ||
    fail "The secret file does not hold a management token."
  grep -q '^[[:space:]]*agent[[:space:]]*=' "$file" ||
    fail "The secret file does not hold the agent token key."
  if grep -q '^[[:space:]]*initial_agent[[:space:]]*=' "$file"; then
    fail "The secret file holds the old initial_agent key."
  fi
}

# Check that a rerun migrates the old initial_agent key and keeps its value.
check_agent_token_migration() {
  local tree="$1"
  local file="$tree/config/consul/secrets/agent.hcl"
  local old_value="test-agent-token-value"
  sed -i -E "s/^([[:space:]]*)agent([[:space:]]*)=.*/\1initial_agent\2= \"$old_value\"/" "$file"
  grep -q '^[[:space:]]*initial_agent[[:space:]]*=' "$file" ||
    fail "The migration check did not write the old initial_agent key."
  run_wizard "$tree"
  grep -q "^[[:space:]]*agent[[:space:]]*=[[:space:]]*\"$old_value\"" "$file" ||
    fail "The wizard did not migrate the old initial_agent value to the agent key."
  if grep -q '^[[:space:]]*initial_agent[[:space:]]*=' "$file"; then
    fail "The wizard kept the old initial_agent key."
  fi
}

# Check that peers.txt and join.hcl hold the peer list from CONSUL_JOIN_IPS.
check_peer_list() {
  local tree="$1"
  shift
  local -a peers=("$@")
  local expected actual peer
  [ -f "$tree/config/consul/peers.txt" ] ||
    fail "The wizard did not write config/consul/peers.txt."
  expected="$(printf '%s\n' "${peers[@]}" | LC_ALL=C sort -u)"
  actual="$(LC_ALL=C sort -u "$tree/config/consul/peers.txt")"
  [ "$actual" = "$expected" ] ||
    fail "config/consul/peers.txt does not hold the CONSUL_JOIN_IPS peer list."
  for peer in "${peers[@]}"; do
    grep -q "\"$peer\"" "$tree/config/consul/join.hcl" ||
      fail "config/consul/join.hcl does not hold the CONSUL_JOIN_IPS peer $peer."
  done
}

# Check that bootstrap.hcl holds the value from CONSUL_BOOTSTRAP_EXPECT.
check_bootstrap_expect() {
  local tree="$1"
  local expected="$2"
  local file="$tree/config/consul/bootstrap.hcl"
  local value
  [ -f "$file" ] || fail "The wizard did not write config/consul/bootstrap.hcl."
  value="$(sed -nE 's/^bootstrap_expect[[:space:]]*=[[:space:]]*([0-9]+)$/\1/p' "$file")"
  [ "$value" = "$expected" ] ||
    fail "config/consul/bootstrap.hcl does not hold bootstrap_expect $expected."
}

# Check that the config set holds one bootstrap_expect and the template holds none.
check_single_bootstrap_expect() {
  local tree="$1"
  local count
  if grep -qE '^[[:space:]]*bootstrap_expect[[:space:]]*=' "$tree/config/consul/consul.hcl"; then
    fail "The rendered server config holds bootstrap_expect. The wizard owns this key."
  fi
  if grep -qE '^[[:space:]]*bootstrap_expect[[:space:]]*=' "$REPO_ROOT/state/consul/consul.hcl"; then
    fail "The committed server template holds bootstrap_expect. The wizard owns this key."
  fi
  count="$({ grep -h -E '^[[:space:]]*bootstrap_expect[[:space:]]*=' "$tree"/config/consul/*.hcl || true; } | wc -l)"
  [ "$count" -eq 1 ] ||
    fail "The Consul config set holds $count bootstrap_expect keys. Use one key."
}

# Check that the compose fragment loads the wizard-owned bootstrap file.
check_bootstrap_mount() {
  grep -q 'config/consul/bootstrap.hcl:/consul/config/' "$REPO_ROOT/compose/consul.yaml" ||
    fail "compose/consul.yaml does not load config/consul/bootstrap.hcl."
}

# Check that the vhost descriptor uses the static upstream for the single node.
# The descriptor must not hold a secret.
check_vhost_descriptor() {
  local file="state/consul/vhost.json"
  [ -f "$file" ] || fail "state/consul/vhost.json is missing."
  grep -q '"name":"consul"' "$file" ||
    fail "state/consul/vhost.json does not name consul."
  grep -q '"mode":"static"' "$file" ||
    fail "state/consul/vhost.json does not use static mode."
  grep -q '"upstream":"http://consul:8500"' "$file" ||
    fail "state/consul/vhost.json does not use the consul upstream."
  if grep -qiE '"(token|password|secret|credential|api[_-]?key|private[_-]?key)"' "$file"; then
    fail "state/consul/vhost.json holds a secret field."
  fi
  if grep -qE '://[^/"]*:[^/"]*@' "$file"; then
    fail "state/consul/vhost.json holds credentials in a URL."
  fi
}

# Check that the compose fragment passes CONSUL_DISABLE_PERM_MGMT to the consul service.
check_rootless_entrypoint() {
  local fragment="$REPO_ROOT/compose/consul.yaml"
  grep -qE '^[[:space:]]*- CONSUL_DISABLE_PERM_MGMT$' "$fragment" ||
    fail "compose/consul.yaml does not pass CONSUL_DISABLE_PERM_MGMT."
  if grep -qE '^[[:space:]]*- CONSUL_DISABLE_PERM_MGMT=' "$fragment"; then
    fail "compose/consul.yaml sets a value for CONSUL_DISABLE_PERM_MGMT."
  fi
}

# Check that the data init script exists, is executable, and keeps the rootless branch.
check_data_init_script() {
  local script="state/consul/data-init.sh"
  [ -f "$script" ] || fail "$script is missing."
  [ -x "$script" ] || fail "$script is not executable."
  grep -q 'mkdir -p /consul/data' "$script" ||
    fail "$script does not create /consul/data."
  grep -q 'STACK_ROOTLESS' "$script" ||
    fail "$script does not read STACK_ROOTLESS."
  if ! awk '
    /STACK_ROOTLESS/ { rootless = 1 }
    /^[[:space:]]*if / { in_if = 1 }
    /^[[:space:]]*else/ { in_else = 1 }
    in_if && !in_else && /chmod 0700 \/consul\/data/ { chmod_rootless = 1 }
    in_else && /chown 100:1000 \/consul\/data/ { chown_rootful = 1 }
    in_else && /chmod 0700 \/consul\/data/ { chmod_rootful = 1 }
    END { exit !(rootless && chmod_rootless && chown_rootful && chmod_rootful) }
  ' "$script"; then
    fail "$script does not keep the rootless branch."
  fi
}

# Check that compose runs the data init from the mounted script.
check_data_init_mount() {
  local fragment="$REPO_ROOT/compose/consul.yaml"
  grep -q 'state/consul/data-init.sh:/data-init.sh:ro' "$fragment" ||
    fail "compose/consul.yaml does not mount the data init script."
  grep -qE '^[[:space:]]*entrypoint:[[:space:]]*\["/bin/sh"\]' "$fragment" ||
    fail "compose/consul.yaml does not use /bin/sh as the init entrypoint."
  grep -qE '^[[:space:]]*command:[[:space:]]*\["/data-init.sh"\]' "$fragment" ||
    fail "compose/consul.yaml does not run /data-init.sh."
  grep -qF -- "- STACK_ROOTLESS=\${STACK_ROOTLESS:-0}" "$fragment" ||
    fail "compose/consul.yaml does not pass STACK_ROOTLESS."
  grep -qE '^[[:space:]]*user:[[:space:]]*"0:0"' "$fragment" ||
    fail "compose/consul.yaml does not run the init as root."
  if grep -q 'mkdir -p /consul/data' "$fragment"; then
    fail "compose/consul.yaml holds an inline init command."
  fi
}

# Check that grant_read_access has the rootless branch.
check_grant_read_access_rootless() {
  local wizard="$REPO_ROOT/state/consul/setup.sh"
  local body
  body="$(sed -n '/^grant_read_access()/,/^}/p' "$wizard")"
  if ! printf '%s\n' "$body" | awk '
    /stack_rootless/ { rootless = 1 }
    !rootless && /chgrp/ { bad = 1 }
    rootless && /chmod/ && /fallback_mode/ { fallback = 1 }
    END { exit !(rootless && fallback && !bad) }
  '; then
    fail "grant_read_access has no rootless branch before chgrp."
  fi
}

# Check that a rootless wizard run does not use group 1000.
check_rootless_run() {
  local tree="$1"
  local mode
  if grep -q 'Group 1000' "$tree/wizard.log"; then
    fail "The rootless wizard run uses group 1000."
  fi
  [ -f "$tree/config/consul/secrets/agent.hcl" ] ||
    fail "The rootless wizard did not write the secret file."
  mode="$(stat -c '%a' "$tree/config/consul/secrets/agent.hcl")"
  [ "$mode" = "600" ] ||
    fail "The rootless secret file has mode $mode. Use mode 600."
}

# Check that no production file uses CONSUL_ENABLED.
check_no_consul_enabled() {
  local file
  for file in setup.sh .env.example state/consul/setup.sh state/consul/consul.hcl compose/consul.yaml docs/layout.md; do
    if [ -f "$REPO_ROOT/$file" ] && grep -q 'CONSUL_ENABLED' "$REPO_ROOT/$file"; then
      fail "$file uses CONSUL_ENABLED. The stack uses CONSUL_ADDR."
    fi
  done
}

# Check that a second wizard run leaves the files unchanged.
check_idempotent_run() {
  local tree="$1"
  local file before after
  local -a files=(
    config/consul/bootstrap.hcl
    config/consul/consul.hcl
    config/consul/join.hcl
    config/consul/peers.txt
    config/consul/secrets/agent.hcl
    config/consul/secrets/gossip.key
  )
  before="$(for file in "${files[@]}"; do sha256sum "$tree/$file"; done)"
  run_wizard "$tree"
  after="$(for file in "${files[@]}"; do sha256sum "$tree/$file"; done)"
  [ "$before" = "$after" ] ||
    fail "The wizard changed files on the second run."
}

# Check that the wizard prints the exact caddy ACL commands.
check_acl_commands() {
  local tree="$1"
  grep -q 'consul acl policy create' "$tree/wizard.log" ||
    fail "The wizard output does not print the caddy policy command."
  grep -q 'consul acl token create' "$tree/wizard.log" ||
    fail "The wizard output does not print the caddy token command."
}

main() {
  local env_tree env_file_tree rootless_tree rootless_env_tree

  env_tree="$(new_scratch_tree)"
  run_wizard "$env_tree" "CONSUL_JOIN_IPS=10.0.0.12, 10.0.0.21" "CONSUL_BOOTSTRAP_EXPECT=3"
  check_peer_list "$env_tree" 10.0.0.12 10.0.0.21
  check_bootstrap_expect "$env_tree" 3
  check_single_bootstrap_expect "$env_tree"
  check_rendered_config "$env_tree"
  check_strict_modes "$env_tree"
  check_management_token "$env_tree"
  check_acl_commands "$env_tree"

  env_file_tree="$(new_scratch_tree)"
  printf 'CONSUL_JOIN_IPS=10.0.1.5,10.0.1.6\nCONSUL_BOOTSTRAP_EXPECT=2\n' >"$env_file_tree/.env"
  run_wizard "$env_file_tree"
  check_peer_list "$env_file_tree" 10.0.1.5 10.0.1.6
  check_bootstrap_expect "$env_file_tree" 2
  check_single_bootstrap_expect "$env_file_tree"
  check_idempotent_run "$env_file_tree"
  check_agent_token_migration "$env_file_tree"

  rootless_tree="$(new_scratch_tree)"
  run_wizard "$rootless_tree" "STACK_ROOTLESS=1"
  check_rootless_run "$rootless_tree"

  rootless_env_tree="$(new_scratch_tree)"
  printf 'STACK_ROOTLESS=1\n' >"$rootless_env_tree/.env"
  run_wizard "$rootless_env_tree"
  check_rootless_run "$rootless_env_tree"

  check_rootless_entrypoint
  check_data_init_script
  check_data_init_mount
  check_grant_read_access_rootless
  check_bootstrap_mount
  check_vhost_descriptor
  check_no_consul_enabled

  echo "Consul standalone smoke checks passed."
}

main "$@"
