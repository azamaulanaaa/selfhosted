#!/usr/bin/env bash
# Check the Garage wizard and entrypoint in standalone and integrated modes.
# The checks use a scratch tree. They need no Docker and no Consul.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

scratch=""
passed=0
failed=0
declare -a secret_values=()

cleanup() {
  if [ -n "$scratch" ] && [ -d "$scratch" ]; then
    rm -rf -- "$scratch"
  fi
}
trap cleanup EXIT

pass() {
  printf 'PASS %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  if [ "$#" -ge 2 ]; then
    printf 'detail: %s\n' "$2" >&2
  fi
  failed=$((failed + 1))
}

# Make a scratch tree with the two service scripts.
new_tree() {
  local name="$1"
  local tree="$scratch/$name"
  mkdir -p "$tree/state/garage"
  cp -- "$REPO_ROOT/state/garage/setup.sh" "$tree/state/garage/setup.sh"
  cp -- "$REPO_ROOT/state/garage/entrypoint.sh" "$tree/state/garage/entrypoint.sh"
  printf '%s\n' "$tree"
}

# Write the shared root .env file for one scratch tree.
write_root_env() {
  local tree="$1"
  local consul_enabled="$2"
  {
    printf 'STACK_DOMAIN=example.test\n'
    printf 'PUBLIC_IP=192.0.2.10\n'
    printf 'CONSUL_ENABLED=%s\n' "$consul_enabled"
  } >"$tree/.env"
}

# Run the wizard in a scratch tree without an interactive terminal.
run_wizard() {
  local tree="$1"
  local consul_enabled="$2"
  local consul_addr="$3"
  local consul_token="$4"
  local replication_factor="${5:-1}"
  (
    cd "$tree"
    env \
      STACK_DOMAIN=example.test \
      PUBLIC_IP=192.0.2.10 \
      CONSUL_ENABLED="$consul_enabled" \
      CONSUL_HTTP_ADDR="$consul_addr" \
      CONSUL_HTTP_TOKEN="$consul_token" \
      GARAGE_REPLICATION_FACTOR="$replication_factor" \
      bash "$tree/state/garage/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1
}

# Run the entrypoint in render-only mode. No process starts.
render_entrypoint() {
  local tree="$1"
  local consul_enabled="$2"
  mkdir -p "$tree/run"
  (
    cd "$tree"
    env \
      GARAGE_CONFIG_TEMPLATE="$tree/config/garage/garage.toml" \
      GARAGE_RUNTIME_CONFIG="$tree/run/garage.toml" \
      GARAGE_RUNTIME_DIR="$tree/run" \
      GARAGE_SECRETS_DIR="$tree/config/garage/secrets" \
      CONSUL_SECRETS_DIR="$tree/config/consul/secrets" \
      CONSUL_AGENT_HCL_FILE="$tree/config/consul/secrets/agent.hcl" \
      CONSUL_ENABLED="$consul_enabled" \
      GARAGE_RENDER_ONLY=1 \
      sh "$tree/state/garage/entrypoint.sh"
  ) >>"$tree/entrypoint.log" 2>&1
}

# Print the mode of one file. Support GNU and BSD stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

# Check that a file holds one expected line.
assert_line() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [ ! -f "$file" ]; then
    fail "$description" "the file does not exist: $file"
    return 0
  fi
  if grep -Fq -- "$pattern" "$file"; then
    pass "$description"
  else
    fail "$description" "expected: $pattern"
  fi
}

# Check that a file does not hold a line.
assert_no_line() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if [ ! -f "$file" ]; then
    fail "$description" "the file does not exist: $file"
    return 0
  fi
  if grep -Fq -- "$pattern" "$file"; then
    fail "$description" "unexpected: $pattern"
  else
    pass "$description"
  fi
}

# Check that a file is absent.
assert_file_absent() {
  local path="$1"
  local description="$2"
  if [ -e "$path" ]; then
    fail "$description" "the file exists: $path"
  else
    pass "$description"
  fi
}

# Check the mode of one file.
assert_mode() {
  local path="$1"
  local expected="$2"
  local description="$3"
  if [ ! -f "$path" ]; then
    fail "$description" "the file does not exist: $path"
    return 0
  fi
  local mode
  mode="$(file_mode "$path")"
  if [ "$mode" = "$expected" ]; then
    pass "$description"
  else
    fail "$description" "observed mode $mode"
  fi
}

# Check that a file holds exactly one value.
assert_content() {
  local path="$1"
  local expected="$2"
  local description="$3"
  if [ ! -f "$path" ]; then
    fail "$description" "the file does not exist: $path"
    return 0
  fi
  if [ "$(cat "$path")" = "$expected" ]; then
    pass "$description"
  else
    fail "$description" "the file content differs"
  fi
}

# Print a stable checksum of the generated files.
file_checksums() {
  local tree="$1"
  (
    cd "$tree"
    sha256sum \
      config/garage/garage.toml \
      config/garage/secrets/rpc_secret \
      config/garage/secrets/admin_token \
      config/garage/secrets/metrics_token
  )
}

# Check the config sections and the fixed values.
check_config_shape() {
  local config="$1"
  assert_line "$config" '[consul_discovery]' 'config has the Consul discovery section'
  assert_line "$config" 'api = "catalog"' 'config uses the Consul catalog API'
  assert_line "$config" 'service_name = "garage"' 'config uses the garage service name'
  assert_line "$config" 'tls_skip_verify = false' 'config verifies the Consul TLS certificate'
  assert_line "$config" '[s3_api]' 'config has the S3 API section'
  assert_line "$config" 'api_bind_addr = "[::]:3900"' 'config binds the S3 API on port 3900'
  assert_line "$config" 's3_region = "garage"' 'config uses the garage S3 region'
  assert_line "$config" 'public_endpoint = "http://192.0.2.10:3900"' 'config advertises the S3 endpoint'
  assert_line "$config" '[s3_web]' 'config has the S3 web section'
  assert_line "$config" 'bind_addr = "[::]:3902"' 'config binds the S3 web endpoint on port 3902'
  assert_line "$config" '[admin]' 'config has the admin section'
  assert_line "$config" 'api_bind_addr = "[::]:3903"' 'config binds the admin API on port 3903'
  assert_line "$config" 'admin_token_file = "/etc/garage/secrets/admin_token"' 'config reads the admin token from a file'
  assert_line "$config" 'metrics_token_file = "/etc/garage/secrets/metrics_token"' 'config reads the metrics token from a file'
  assert_line "$config" 'metadata_dir = "/var/lib/garage/meta"' 'config uses the metadata directory'
  assert_line "$config" 'data_dir = "/var/lib/garage/data"' 'config uses the data directory'
  assert_line "$config" 'db_engine = "lmdb"' 'config uses the LMDB engine'
  assert_line "$config" 'metadata_auto_snapshot_interval = "6h"' 'config takes metadata snapshots'
  assert_line "$config" 'replication_factor = 1' 'config uses replication factor 1'
  assert_line "$config" 'rpc_bind_addr = "[::]:3901"' 'config binds RPC on port 3901'
  assert_line "$config" 'rpc_public_addr = "192.0.2.10:3901"' 'config advertises the RPC address'
  assert_line "$config" 'rpc_secret_file = "/etc/garage/secrets/rpc_secret"' 'config reads the RPC secret from a file'
}

# Check the mode of the generated secret files.
check_secret_modes() {
  local tree="$1"
  local secret
  for secret in rpc_secret admin_token metrics_token; do
    assert_mode "$tree/config/garage/secrets/$secret" 600 "secret $secret has mode 600"
  done
  assert_mode "$tree/config/garage/garage.toml" 600 'garage.toml has mode 600'
}

# Check the standalone wizard, its config, and a second run.
check_standalone_mode() {
  local tree
  tree="$(new_tree standalone)"
  write_root_env "$tree" 0

  if ! run_wizard "$tree" 0 'http://10.20.30.40:8500' ''; then
    fail 'standalone wizard runs' "read $tree/wizard.log"
    return 0
  fi
  pass 'standalone wizard runs'

  local config="$tree/config/garage/garage.toml"
  assert_line "$config" 'consul_http_addr = "http://10.20.30.40:8500"' 'standalone wizard uses the supplied Consul address'
  assert_line "$config" '# __CONSUL_TOKEN__' 'standalone config keeps the token marker'
  assert_file_absent "$tree/config/garage/secrets/consul_token" 'standalone wizard writes no token file by default'
  check_config_shape "$config"
  check_secret_modes "$tree"

  local before after
  before="$(file_checksums "$tree")"
  if ! run_wizard "$tree" 0 'http://10.20.30.40:8500' ''; then
    fail 'second standalone wizard run succeeds' "read $tree/wizard.log"
    return 0
  fi
  after="$(file_checksums "$tree")"
  if [ "$before" = "$after" ]; then
    pass 'second standalone wizard run is idempotent'
  else
    fail 'second standalone wizard run is idempotent' 'a generated file changed'
  fi

  if ! run_wizard "$tree" 0 'http://10.20.30.40:8500' '' 3; then
    fail 'wizard accepts GARAGE_REPLICATION_FACTOR' "read $tree/wizard.log"
    return 0
  fi
  assert_line "$config" 'replication_factor = 3' 'wizard applies GARAGE_REPLICATION_FACTOR'

  # Render without a token. The entrypoint removes the marker.
  if ! render_entrypoint "$tree" 0; then
    fail 'standalone entrypoint renders without a token' "read $tree/entrypoint.log"
    return 0
  fi
  local runtime="$tree/run/garage.toml"
  assert_no_line "$runtime" '# __CONSUL_TOKEN__' 'entrypoint removes the marker when no token exists'
  assert_no_line "$runtime" 'token = ' 'entrypoint writes no token line when no token exists'

  # Record the secret values for the log leak check.
  local secret
  for secret in rpc_secret admin_token metrics_token; do
    secret_values+=("$(cat "$tree/config/garage/secrets/$secret")")
  done
}

# Check the standalone token path from the wizard to the entrypoint.
check_standalone_token() {
  local tree
  tree="$(new_tree standalone-token)"
  write_root_env "$tree" 0
  local token
  token="smoke-standalone-token-$(openssl rand -hex 8)"

  if ! run_wizard "$tree" 0 'https://consul.example.test:8501' "$token"; then
    fail 'standalone wizard accepts a Consul token' "read $tree/wizard.log"
    return 0
  fi
  pass 'standalone wizard accepts a Consul token'

  local token_file="$tree/config/garage/secrets/consul_token"
  assert_content "$token_file" "$token" 'standalone wizard stores the supplied token'
  assert_mode "$token_file" 600 'standalone Consul token has mode 600'
  assert_line "$tree/config/garage/garage.toml" 'consul_http_addr = "https://consul.example.test:8501"' 'standalone wizard accepts an HTTPS Consul address'

  if ! render_entrypoint "$tree" 0; then
    fail 'standalone entrypoint renders a token' "read $tree/entrypoint.log"
    return 0
  fi
  local runtime="$tree/run/garage.toml"
  assert_line "$runtime" "token = \"$token\"" 'entrypoint injects the standalone token file'
  assert_no_line "$runtime" '# __CONSUL_TOKEN__' 'entrypoint replaces the marker with the standalone token'

  secret_values+=("$token")
  secret_values+=("$(cat "$tree/config/garage/secrets/rpc_secret")")
  secret_values+=("$(cat "$tree/config/garage/secrets/admin_token")")
  secret_values+=("$(cat "$tree/config/garage/secrets/metrics_token")")
}

# Check integrated mode. The wizard uses the stack Consul and copies no token.
check_integrated_mode() {
  local tree
  tree="$(new_tree integrated)"
  write_root_env "$tree" 1
  local management
  management="smoke-management-token-$(openssl rand -hex 8)"
  mkdir -p "$tree/config/consul/secrets"
  (
    umask 077
    {
      printf 'acl {\n'
      printf '  tokens {\n'
      printf '    initial_management = "%s"\n' "$management"
      printf '  }\n'
      printf '}\n'
    } >"$tree/config/consul/secrets/agent.hcl"
  )
  chmod 0600 "$tree/config/consul/secrets/agent.hcl"

  if ! run_wizard "$tree" 1 'http://ignored.example.test:9999' ''; then
    fail 'integrated wizard runs' "read $tree/wizard.log"
    return 0
  fi
  pass 'integrated wizard runs'

  local config="$tree/config/garage/garage.toml"
  assert_line "$config" 'consul_http_addr = "http://consul:8500"' 'integrated wizard uses the stack Consul'
  assert_line "$config" '# __CONSUL_TOKEN__' 'integrated config keeps the token marker'
  assert_file_absent "$tree/config/garage/secrets/consul_token" 'integrated wizard writes no Consul token file'
  if grep -rFq -- "$management" "$tree/config/garage/secrets"; then
    fail 'integrated wizard copies no management token' 'the management token is in the Garage secrets'
  else
    pass 'integrated wizard copies no management token'
  fi

  if ! render_entrypoint "$tree" 1; then
    fail 'integrated entrypoint renders a token' "read $tree/entrypoint.log"
    return 0
  fi
  local runtime="$tree/run/garage.toml"
  assert_line "$runtime" "token = \"$management\"" 'entrypoint injects initial_management in integrated mode'
  assert_no_line "$runtime" '# __CONSUL_TOKEN__' 'entrypoint replaces the marker in integrated mode'

  secret_values+=("$management")
  secret_values+=("$(cat "$tree/config/garage/secrets/rpc_secret")")
  secret_values+=("$(cat "$tree/config/garage/secrets/admin_token")")
  secret_values+=("$(cat "$tree/config/garage/secrets/metrics_token")")
}

# Check that the wizard rejects a bad or missing Consul address in standalone mode.
check_consul_address_validation() {
  local tree
  tree="$(new_tree invalid-address)"
  write_root_env "$tree" 0
  if run_wizard "$tree" 0 'ftp://consul.example.test:8500' ''; then
    fail 'wizard rejects a Consul address with a bad scheme' 'the wizard accepted ftp://'
  else
    pass 'wizard rejects a Consul address with a bad scheme'
  fi

  tree="$(new_tree missing-address)"
  write_root_env "$tree" 0
  if (
    cd "$tree"
    env -u CONSUL_HTTP_ADDR \
      STACK_DOMAIN=example.test \
      PUBLIC_IP=192.0.2.10 \
      CONSUL_ENABLED=0 \
      bash "$tree/state/garage/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'wizard requires CONSUL_HTTP_ADDR in standalone mode' 'the wizard ran without an address'
  else
    pass 'wizard requires CONSUL_HTTP_ADDR in standalone mode'
  fi
}

# Check that no secret value appears in any log file.
check_logs_for_secrets() {
  local leaked=0
  local log_file value
  while IFS= read -r log_file; do
    for value in "${secret_values[@]}"; do
      [ -n "$value" ] || continue
      if grep -Fq -- "$value" "$log_file"; then
        fail 'no secret value appears in a log' "a secret value is in $log_file"
        leaked=1
      fi
    done
  done < <(find "$scratch" -type f -name '*.log' | sort)
  if [ "$leaked" -eq 0 ]; then
    pass 'no secret value appears in a log'
  fi
}

scratch="$(mktemp -d /tmp/garage-smoke.XXXXXX)"
check_standalone_mode
check_standalone_token
check_integrated_mode
check_consul_address_validation
check_logs_for_secrets

printf 'smoke checks: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
