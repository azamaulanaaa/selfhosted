#!/usr/bin/env bash
# Run standalone smoke checks for the Consul wizard.
# The checks use a scratch tree so the live config stays untouched.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

# Print an STE error and exit 1.
fail() {
  echo "error: $1" >&2
  exit 1
}

scratch_tree=""

# Remove the scratch tree. This function runs when the script exits.
cleanup_scratch_tree() {
  if [ -n "$scratch_tree" ]; then
    rm -rf -- "$scratch_tree"
  fi
}
trap cleanup_scratch_tree EXIT

# Make a scratch tree with the wizard and its base template.
new_scratch_tree() {
  local tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/state/consul"
  cp -- state/consul/setup.sh "$tree/state/consul/setup.sh"
  cp -- state/consul/consul.hcl "$tree/state/consul/consul.hcl"
  printf '%s\n' "$tree"
}

# Run the wizard in a scratch tree.
run_wizard() {
  local tree="$1"
  if ! CONSUL_UI_ENABLED=0 bash "$tree/state/consul/setup.sh" >"$tree/wizard.log" 2>&1; then
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

# Check that the wizard creates a management token.
check_management_token() {
  local tree="$1"
  grep -q '^[[:space:]]*initial_management[[:space:]]*=' "$tree/config/consul/secrets/agent.hcl" ||
    fail "The secret file does not hold a management token."
}

# Check that a second wizard run leaves the files unchanged.
check_idempotent_run() {
  local tree="$1"
  local file before after
  local -a files=(
    config/consul/consul.hcl
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
  scratch_tree="$(new_scratch_tree)"

  run_wizard "$scratch_tree"
  check_rendered_config "$scratch_tree"
  check_strict_modes "$scratch_tree"
  check_management_token "$scratch_tree"
  check_idempotent_run "$scratch_tree"
  check_acl_commands "$scratch_tree"

  echo "Consul standalone smoke checks passed."
}

main "$@"
