#!/usr/bin/env bash
# Render the caddy template into a scratch tree and check the output.
# Check the local and remote token selection and the consul-template address.
# Run this script from any directory. It finds the repository root on its own.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

test_domain="example.test"
test_local_addr="http://consul:8500"
test_remote_addr="https://consul.example.test:8501"

# Exit with the given STE message when a check fails.
fail() {
  echo "error: $1" >&2
  exit 1
}

# Render the template with the substitution from the entrypoint.
render_template() {
  sed "s|{{ env \"STACK_DOMAIN\" }}|$test_domain|g" \
    state/caddy/Caddyfile.tpl >"$scratch/Caddyfile"
}

# Check that a file contains the given text.
check_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "The file $file misses this text: $text."
}

# Check that a file lacks the given text.
check_lacks() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "The file $file contains this text: $text."
  fi
}

# Load the entrypoint functions without starting the container.
# shellcheck source=state/caddy/entrypoint.sh
CADDY_ENTRYPOINT_LIB=1 . state/caddy/entrypoint.sh

# Check the local and remote token file selection.
[ "$(token_file_for_addr "$test_local_addr")" = "/etc/consul/secrets/agent.hcl" ] ||
  fail "The local Consul address does not select agent.hcl."
[ "$(token_file_for_addr "$test_local_addr/")" = "/etc/consul/secrets/agent.hcl" ] ||
  fail "One trailing slash on the local address does not select agent.hcl."
[ "$(token_file_for_addr "$test_remote_addr")" = "/etc/consul/secrets/remote-token" ] ||
  fail "The remote Consul address does not select remote-token."

# Check that the token reader selects the file for the address.
printf '%s\n' 'agent {' '  initial_management = "local-test-token"' '}' >"$scratch/agent.hcl"
printf '%s\n' 'remote-test-token' >"$scratch/remote-token"
MANAGEMENT_FILE="$scratch/agent.hcl"
REMOTE_TOKEN_FILE="$scratch/remote-token"
consul_addr="$test_local_addr"
[ "$(read_management_token)" = "local-test-token" ] ||
  fail "The token reader does not read agent.hcl in local mode."
consul_addr="$test_remote_addr"
[ "$(read_management_token)" = "remote-test-token" ] ||
  fail "The token reader does not read remote-token in remote mode."

# Render the wizard into a scratch tree and check the consul-template address.
wizard_root="$scratch/repo"
mkdir -p "$wizard_root/state/caddy"
cp state/caddy/setup.sh "$wizard_root/state/caddy/setup.sh"

# Run one wizard pass with the given Consul address.
run_wizard() {
  local consul_addr="$1"
  CONSUL_ADDR="$consul_addr" STACK_DOMAIN="$test_domain" TLS_ENABLED=0 \
    bash "$wizard_root/state/caddy/setup.sh" </dev/null >/dev/null
}

run_wizard "$test_local_addr"
check_contains "$wizard_root/config/caddy/consul-template.hcl" \
  "address = \"$test_local_addr\""

run_wizard "$test_remote_addr"
check_contains "$wizard_root/config/caddy/consul-template.hcl" \
  "address = \"$test_remote_addr\""

# The root .env is the second source for CONSUL_ADDR.
printf 'CONSUL_ADDR=%s\n' "$test_remote_addr" >>"$wizard_root/.env"
env -u CONSUL_ADDR STACK_DOMAIN="$test_domain" TLS_ENABLED=0 \
  bash "$wizard_root/state/caddy/setup.sh" </dev/null >/dev/null
check_contains "$wizard_root/config/caddy/consul-template.hcl" \
  "address = \"$test_remote_addr\""

render_template
check_contains "$scratch/Caddyfile" "https://forgejo.$test_domain {"
check_contains "$scratch/Caddyfile" "reverse_proxy http://forgejo:3000"
check_contains "$scratch/Caddyfile" 'template "tls_for" "forgejo"'
check_contains "$scratch/Caddyfile" 'service "consul"'
check_lacks "$scratch/Caddyfile" "https://lan."

echo "Checked the caddy template, token selection, and consul-template address."
