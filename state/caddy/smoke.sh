#!/usr/bin/env bash
# Render both caddy templates into a scratch tree and check the output.
# Run this script from any directory. It finds the repository root on its own.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

test_domain="example.test"

# Exit with the given STE message when a check fails.
fail() {
  echo "error: $1" >&2
  exit 1
}

# Render the standalone template with the substitution from the entrypoint.
render_standalone_template() {
  sed "s|__STACK_DOMAIN__|$test_domain|g" \
    state/caddy/Caddyfile.static.tpl >"$scratch/Caddyfile.standalone"
}

# Render the domain expressions of the integrated template for the check.
render_integrated_template() {
  sed "s|{{ env \"STACK_DOMAIN\" }}|$test_domain|g" \
    state/caddy/Caddyfile.tpl >"$scratch/Caddyfile.integrated"
}

# Check that a rendered file contains the given text.
check_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "The file $file misses this text: $text."
}

# Check that a rendered file lacks the given text.
check_lacks() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "The file $file contains this text: $text."
  fi
}

render_standalone_template
render_integrated_template

[ -s "$scratch/Caddyfile.standalone" ] || fail "The standalone render is empty."
[ -s "$scratch/Caddyfile.integrated" ] || fail "The integrated render is empty."

check_contains "$scratch/Caddyfile.standalone" "https://$test_domain {"
check_contains "$scratch/Caddyfile.standalone" "tls internal"
check_contains "$scratch/Caddyfile.standalone" "https://forgejo.$test_domain {"
check_contains "$scratch/Caddyfile.standalone" "reverse_proxy forgejo:3000"
check_lacks "$scratch/Caddyfile.standalone" "__STACK_DOMAIN__"
check_lacks "$scratch/Caddyfile.standalone" "{{"
check_lacks "$scratch/Caddyfile.standalone" "https://lan."

check_contains "$scratch/Caddyfile.integrated" \
  "https://forgejo.$test_domain {"
check_contains "$scratch/Caddyfile.integrated" \
  "reverse_proxy http://forgejo:3000"
check_contains "$scratch/Caddyfile.integrated" \
  "template \"tls_for\" \"forgejo\""
check_contains "$scratch/Caddyfile.integrated" "service \"consul\""
check_lacks "$scratch/Caddyfile.integrated" "https://lan."

echo "Checked both caddy templates."
