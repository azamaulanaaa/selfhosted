#!/usr/bin/env bash
# Check the caddy template and the caddy wizard.
# Check the vhost registry, the fallback vhosts, the TLS vhost list, the token
# selection, and the consul-template address.
# Run this script from any directory. It finds the repository root on its own.
# shellcheck disable=SC2016
# The checked strings hold Go template variables. Do not expand them.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

test_domain="example.test"
test_local_addr="http://consul:8500"
test_remote_addr="https://consul.example.test:8501"
template="state/caddy/Caddyfile.tpl"

# Exit with the given STE message when a check fails.
fail() {
  echo "error: $1" >&2
  exit 1
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

# Check the template definitions and the three descriptor modes.
check_contains "$template" '{{ define "smart_proxy" }}'
check_contains "$template" '{{ define "tls_for" }}'
check_contains "$template" '{{ define "render_vhost" }}'
check_contains "$template" 'eq (sprig_toString $mode) "catalog"'
check_contains "$template" 'range service (sprig_toString $service)'
check_contains "$template" ':{{ $port }}'
check_contains "$template" 'eq (sprig_toString $mode) "litefs"'
check_contains "$template" 'template "smart_proxy" (sprig_list'
check_contains "$template" 'eq (sprig_toString $mode) "static"'
check_contains "$template" 'reverse_proxy {{ sprig_toString $upstream }} {'
check_contains "$template" 'header_up Host {host}'
check_contains "$template" 'header_up X-Real-IP {remote_host}'

# Extract one named template definition. Stop at the closing end at column 1.
template_block() {
  sed -n "/{{ define \"$1\" }}/,/^{{ end }}$/p" "$template"
}

# The smart_proxy template falls back to the local upstream when the LiteFS
# KV key is absent. The fallback must hold the local reverse_proxy.
smart_proxy_block="$(template_block smart_proxy)"
printf '%s\n' "$smart_proxy_block" | grep -Fq '{{ else }}' ||
  fail "The smart_proxy template misses the else branch."
printf '%s\n' "$smart_proxy_block" | awk '
  index($0, "{{ else }}") { fallback = 1; next }
  fallback && index($0, "reverse_proxy {{ $local_addr }} {") { found = 1 }
  END { exit(found ? 0 : 1) }
' || fail "The smart_proxy template does not fall back to the local upstream."

# Check the entrypoint ACL and CA bundle paths.
entrypoint="state/caddy/entrypoint.sh"
check_contains "$entrypoint" 'create_read_acl_with_curl'
check_contains "$entrypoint" 'consul_api()'
check_contains "$entrypoint" 'X-Consul-Token'
check_contains "$entrypoint" '/v1/acl/policy'
check_contains "$entrypoint" '/v1/acl/token'
check_contains "$entrypoint" 'write_ca_bundle'
check_contains "$entrypoint" 'write_ca_bundle &'
check_contains "$entrypoint" 'ca-bundle.crt'
check_contains "$entrypoint" 'intermediate.crt'

# Check the CA bundle holds the intermediate first, then the root.
ca_store="$scratch/ca-store"
mkdir -p "$ca_store/pki/authorities/local"
printf 'test-intermediate\n' >"$ca_store/pki/authorities/local/intermediate.crt"
printf 'test-root\n' >"$ca_store/pki/authorities/local/root.crt"
saved_store="$STORE"
STORE="$ca_store"
write_ca_bundle >/dev/null 2>&1
STORE="$saved_store"
expected_ca_bundle="$(printf 'test-intermediate\ntest-root\n')"
[ "$(cat "$ca_store/ca-bundle.crt")" = "$expected_ca_bundle" ] ||
  fail "The CA bundle does not hold the intermediate first and the root second."
[ "$(stat -c '%a' "$ca_store/ca-bundle.crt")" = "644" ] ||
  fail "The CA bundle does not have mode 0644."

# Check the registry file selection and the vhost block header.
check_contains "$template" 'env "CADDY_VHOSTS_FILE"'
check_contains "$template" '/etc/consul-template/vhosts.json'
check_contains "$template" 'parseJSON (file $vhosts_file)'
check_contains "$template" 'https://{{ $name }}.{{ env "STACK_DOMAIN" }} {'

# Check the fallback descriptors. The empty registry renders these vhosts.
check_contains "$template" '"name":"consul","mode":"catalog","service":"consul","port":8500'
check_contains "$template" '"name":"lldap","mode":"litefs","upstream":"http://lldap:17170","redirect_paths":"[]"'
check_contains "$template" '"name":"tinyauth","mode":"litefs","upstream":"http://tinyauth:3000","redirect_paths":"[]"'
check_contains "$template" '"name":"forgejo","mode":"static","upstream":"http://forgejo:3000"'
check_contains "$template" '"name":"vaultwarden","mode":"static","upstream":"http://vaultwarden:80","x_real_ip":true'
check_lacks "$template" 'garage'

# Check that no vhost block is hard-coded outside the render definition.
check_lacks "$template" 'https://consul.{{ env "STACK_DOMAIN" }} {'
check_lacks "$template" 'https://lldap.{{ env "STACK_DOMAIN" }} {'
check_lacks "$template" 'https://tinyauth.{{ env "STACK_DOMAIN" }} {'
check_lacks "$template" 'https://forgejo.{{ env "STACK_DOMAIN" }} {'
check_lacks "$template" 'https://vaultwarden.{{ env "STACK_DOMAIN" }} {'

# Check that the caddy compose fragment mounts the registry.
check_contains compose/caddy.yaml \
  './config/caddy/vhosts.json:/etc/consul-template/vhosts.json:ro'

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

# The wizard creates an empty registry when the files are missing.
[ -f "$wizard_root/config/caddy/vhosts.json" ] ||
  fail "The caddy wizard did not create the registry JSON file."
[ "$(cat "$wizard_root/config/caddy/vhosts.json")" = "[]" ] ||
  fail "The caddy wizard did not write the empty registry array."
[ -f "$wizard_root/config/caddy/vhosts.txt" ] ||
  fail "The caddy wizard did not create the vhost names file."
if [ -s "$wizard_root/config/caddy/vhosts.txt" ]; then
  fail "The caddy wizard did not create an empty vhost names file."
fi

run_wizard "$test_remote_addr"
check_contains "$wizard_root/config/caddy/consul-template.hcl" \
  "address = \"$test_remote_addr\""

# The root .env is the second source for CONSUL_ADDR.
printf 'CONSUL_ADDR=%s\n' "$test_remote_addr" >>"$wizard_root/.env"
env -u CONSUL_ADDR STACK_DOMAIN="$test_domain" TLS_ENABLED=0 \
  bash "$wizard_root/state/caddy/setup.sh" </dev/null >/dev/null
check_contains "$wizard_root/config/caddy/consul-template.hcl" \
  "address = \"$test_remote_addr\""

# The wizard keeps an existing registry. Write catalog, litefs, and static
# descriptors, then run the wizard again.
vhosts_json='[{"name":"consul","mode":"catalog","service":"consul","port":8500},{"name":"forgejo","mode":"static","upstream":"http://forgejo:3000"},{"name":"vaultwarden","mode":"static","upstream":"http://vaultwarden:80","x_real_ip":true}]'
printf '%s\n' "$vhosts_json" >"$wizard_root/config/caddy/vhosts.json"
printf '%s\n' 'consul' 'forgejo' 'vaultwarden' >"$wizard_root/config/caddy/vhosts.txt"
run_wizard "$test_local_addr"
[ "$(cat "$wizard_root/config/caddy/vhosts.json")" = "$vhosts_json" ] ||
  fail "The caddy wizard overwrote the existing registry."

# The TLS vhost list comes from vhosts.txt. The fallback list must not appear.
cert_dir="$scratch/certs"
mkdir -p "$cert_dir"
printf 'test-fullchain\n' >"$cert_dir/fullchain.pem"
printf 'test-privkey\n' >"$cert_dir/privkey.pem"
tls_status=0
CADDY_TLS_MODE=existing TLS_ENABLED=1 \
  CADDY_TLS_CERTS="forgejo:$cert_dir/fullchain.pem:$cert_dir/privkey.pem" \
  CONSUL_ADDR="$test_local_addr" STACK_DOMAIN="$test_domain" \
  bash "$wizard_root/state/caddy/setup.sh" </dev/null >"$scratch/tls-error.txt" 2>&1 ||
  tls_status=$?
[ "$tls_status" -ne 0 ] ||
  fail "The wizard must reject a per-vhost certificate list with no consul pair."
check_contains "$scratch/tls-error.txt" "consul:<fullchain>:<key>,forgejo:<fullchain>:<key>,vaultwarden:<fullchain>:<key>"
check_lacks "$scratch/tls-error.txt" "lldap"
check_lacks "$scratch/tls-error.txt" "garage"

# The wizard rejects a vhost name that the registry does not name. The
# fallback list must not accept garage.
tls_status=0
CADDY_TLS_MODE=existing TLS_ENABLED=1 \
  CADDY_TLS_CERTS="garage:$cert_dir/fullchain.pem:$cert_dir/privkey.pem" \
  CONSUL_ADDR="$test_local_addr" STACK_DOMAIN="$test_domain" \
  bash "$wizard_root/state/caddy/setup.sh" </dev/null >"$scratch/garage-error.txt" 2>&1 ||
  tls_status=$?
[ "$tls_status" -ne 0 ] ||
  fail "The wizard must reject the garage vhost when the registry does not name it."
check_contains "$scratch/garage-error.txt" "The vhost 'garage' is not in the registry."
check_contains "$scratch/garage-error.txt" "Use one of these vhosts: consul, forgejo, vaultwarden."
check_lacks "$scratch/garage-error.txt" "lldap"

# An empty registry renders the fallback list. The wizard creates the registry
# files before the TLS validation and then fails on the missing certificates.
fresh_root="$scratch/fresh"
mkdir -p "$fresh_root/state/caddy"
cp state/caddy/setup.sh "$fresh_root/state/caddy/setup.sh"
tls_status=0
CADDY_TLS_MODE=existing TLS_ENABLED=1 \
  CONSUL_ADDR="$test_local_addr" STACK_DOMAIN="$test_domain" \
  bash "$fresh_root/state/caddy/setup.sh" </dev/null >"$scratch/fallback-error.txt" 2>&1 ||
  tls_status=$?
[ "$tls_status" -ne 0 ] ||
  fail "The wizard must fail when existing TLS has no certificates."
[ -f "$fresh_root/config/caddy/vhosts.json" ] ||
  fail "The wizard did not create the registry before the TLS validation."
[ "$(cat "$fresh_root/config/caddy/vhosts.json")" = "[]" ] ||
  fail "The wizard did not write the empty registry array before the TLS validation."
[ -f "$fresh_root/config/caddy/vhosts.txt" ] ||
  fail "The wizard did not create the vhost names file before the TLS validation."
if [ -s "$fresh_root/config/caddy/vhosts.txt" ]; then
  fail "The wizard did not create an empty vhost names file before the TLS validation."
fi
check_contains "$scratch/fallback-error.txt" \
  "Missing per-vhost certificates: consul lldap tinyauth forgejo vaultwarden."
check_contains "$scratch/fallback-error.txt" "vaultwarden:<fullchain>:<key>"
check_lacks "$scratch/fallback-error.txt" "garage"

echo "Checked the caddy template, local fallback, ACL paths, CA bundle, vhost registry, fallback vhosts, TLS list, token selection, and consul-template address."
