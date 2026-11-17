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

dev_tree=""
prod_tree=""

# Remove the scratch trees. This function runs when the script exits.
cleanup_scratch_trees() {
  if [ -n "$dev_tree" ]; then
    rm -rf -- "$dev_tree"
  fi
  if [ -n "$prod_tree" ]; then
    rm -rf -- "$prod_tree"
  fi
}
trap cleanup_scratch_trees EXIT

# Make a scratch tree with the wizard and its base template.
new_scratch_tree() {
  local tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/state/consul"
  cp -- state/consul/setup.sh "$tree/state/consul/setup.sh"
  cp -- state/consul/consul.hcl "$tree/state/consul/consul.hcl"
  printf '%s\n' "$tree"
}

# Run the wizard in a scratch tree with the selected ACL mode.
run_wizard() {
  local tree="$1"
  local mode="$2"
  if ! CONSUL_ACL_MODE="$mode" CONSUL_UI_ENABLED=0 \
    bash "$tree/state/consul/setup.sh" >"$tree/wizard.log" 2>&1; then
    fail "The wizard failed in $mode mode. Read $tree/wizard.log."
  fi
}

# Check that the rendered config matches the selected ACL mode.
check_rendered_mode() {
  local tree="$1"
  local mode="$2"
  local config="$tree/config/consul/consul.hcl"
  [ -f "$config" ] || fail "The wizard did not render config/consul/consul.hcl."
  grep -q "ACL mode: $mode" "$config" ||
    fail "The rendered config does not report $mode mode."
  if [ "$mode" = "dev" ]; then
    grep -q 'default_policy = "allow"' "$config" ||
      fail "The dev config does not set the allow policy."
    grep -q 'client_addr = "127.0.0.1"' "$config" ||
      fail "The dev config does not bind the client interface to 127.0.0.1."
    grep -q 'bind_addr = "127.0.0.1"' "$config" ||
      fail "The dev config does not bind the server interface to 127.0.0.1."
  else
    grep -q 'default_policy = "deny"' "$config" ||
      fail "The prod config does not set the deny policy."
    grep -q 'client_addr = "0.0.0.0"' "$config" ||
      fail "The prod config does not use the trusted-LAN binding."
    if grep -q 'bind_addr = "127.0.0.1"' "$config"; then
      fail "The prod config binds the server interface to 127.0.0.1."
    fi
  fi
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

# Check that a second wizard run leaves the files unchanged.
check_idempotent_run() {
  local tree="$1"
  local mode="$2"
  local file before after
  local -a files=(
    config/consul/consul.hcl
    config/consul/secrets/agent.hcl
    config/consul/secrets/gossip.key
  )
  before="$(for file in "${files[@]}"; do sha256sum "$tree/$file"; done)"
  run_wizard "$tree" "$mode"
  after="$(for file in "${files[@]}"; do sha256sum "$tree/$file"; done)"
  [ "$before" = "$after" ] ||
    fail "The wizard changed files on the second run in $mode mode."
}

# Check that prod mode prints the exact caddy ACL commands.
check_caddy_commands() {
  local tree="$1"
  grep -q 'consul acl policy create' "$tree/wizard.log" ||
    fail "The prod output does not print the caddy policy command."
  grep -q 'consul acl token create' "$tree/wizard.log" ||
    fail "The prod output does not print the caddy token command."
}

main() {
  dev_tree="$(new_scratch_tree)"
  prod_tree="$(new_scratch_tree)"

  run_wizard "$dev_tree" dev
  check_rendered_mode "$dev_tree" dev
  check_strict_modes "$dev_tree"
  check_idempotent_run "$dev_tree" dev

  run_wizard "$prod_tree" prod
  check_rendered_mode "$prod_tree" prod
  check_strict_modes "$prod_tree"
  check_idempotent_run "$prod_tree" prod
  check_caddy_commands "$prod_tree"

  echo "Consul standalone smoke checks passed."
}

main "$@"
