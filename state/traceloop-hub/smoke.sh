#!/usr/bin/env bash
# Check the Traceloop Hub wizard and files in standalone and integrated trees.
# Standalone means remote Consul. Integrated means local Consul.
# The checks use scratch trees. They need no Docker, no Consul, and no network.
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

# Make a scratch tree with the two wizard files.
new_tree() {
  local name="$1"
  local tree="$scratch/$name"
  mkdir -p "$tree/state/traceloop-hub"
  cp -- "$REPO_ROOT/state/traceloop-hub/setup.sh" "$tree/state/traceloop-hub/setup.sh"
  cp -- "$REPO_ROOT/state/traceloop-hub/config.example.yaml" "$tree/state/traceloop-hub/config.example.yaml"
  printf '%s\n' "$tree"
}

# Write the root .env file for one scratch tree.
write_root_env() {
  local tree="$1"
  local consul_addr="$2"
  {
    printf 'STACK_DOMAIN=example.test\n'
    printf 'PUBLIC_IP=192.0.2.10\n'
    printf 'STACK_ROOTLESS=0\n'
    printf 'STACK_UID=1000\n'
    printf 'STACK_GID=1000\n'
    printf 'CONSUL_ADDR=%s\n' "$consul_addr"
  } >"$tree/.env"
}

# Run the wizard in a scratch tree without an interactive terminal.
run_wizard() {
  local tree="$1"
  (
    cd "$tree"
    bash "$tree/state/traceloop-hub/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1
}

# Print the mode of one file. Support GNU and BSD stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

# Check that a file exists.
assert_file_exists() {
  local path="$1"
  local description="$2"
  if [ -f "$path" ]; then
    pass "$description"
  else
    fail "$description" "the file does not exist: $path"
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

# Check that two files hold the same bytes.
assert_same_content() {
  local left="$1"
  local right="$2"
  local description="$3"
  if [ ! -f "$left" ] || [ ! -f "$right" ]; then
    fail "$description" 'one of the files does not exist'
    return 0
  fi
  if cmp -s -- "$left" "$right"; then
    pass "$description"
  else
    fail "$description" 'the file contents differ'
  fi
}

# Check that a file holds exactly the expected bytes.
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
    fail "$description" 'the file content differs'
  fi
}

# Check the config file shape, modes, and template copy for one tree.
check_tree_output() {
  local tree="$1"
  local config="$tree/config/traceloop-hub/config.yaml"
  local template="$tree/state/traceloop-hub/config.example.yaml"

  assert_file_exists "$config" 'wizard writes the YAML config'
  assert_same_content "$config" "$template" 'wizard copies the committed template'
  assert_mode "$config" 600 'config file has mode 600'
  local mode
  mode="$(stat -c '%a' "$tree/config/traceloop-hub" 2>/dev/null || stat -f '%Lp' "$tree/config/traceloop-hub" 2>/dev/null || printf 'unknown')"
  if [ "$mode" = "700" ]; then
    pass 'config directory has mode 700'
  else
    fail 'config directory has mode 700' "observed mode $mode"
  fi

  assert_line "$config" 'general:' 'config holds the general section'
  assert_line "$config" 'providers: []' 'config has no active provider'
  assert_line "$config" 'models: []' 'config has no active model'
  assert_line "$config" 'pipelines: []' 'config has no active pipeline'
  assert_line "$config" '# Supported types: openai, anthropic, azure, bedrock, vertexai.' 'config documents provider types'
  assert_line "$config" '# Supported types: chat, completion, embeddings.' 'config documents pipeline types'
  assert_no_line "$config" '# __SECRET__' 'config holds no secret marker'

  assert_file_absent "$tree/config/consul" 'wizard writes no Consul config'
  assert_file_absent "$tree/config/traceloop-hub/config.env" 'wizard writes no environment file'
  assert_file_absent "$tree/config/traceloop-hub/secrets" 'wizard writes no secret directory'
  assert_file_absent "$tree/data" 'wizard writes no runtime data'
}

# Check the wizard in a standalone-style tree with remote Consul.
check_standalone_tree() {
  local tree
  tree="$(new_tree standalone)"
  write_root_env "$tree" 'https://consul.example.test:8501'

  if ! run_wizard "$tree"; then
    fail 'standalone wizard runs' "read $tree/wizard.log"
    return 0
  fi
  pass 'standalone wizard runs'
  check_tree_output "$tree"
  assert_line "$tree/wizard.log" 'config/traceloop-hub/config.yaml' 'standalone wizard prints the config path'

  local before after
  before="$(cksum "$tree/config/traceloop-hub/config.yaml")"
  if ! run_wizard "$tree"; then
    fail 'second standalone wizard run succeeds' "read $tree/wizard.log"
    return 0
  fi
  after="$(cksum "$tree/config/traceloop-hub/config.yaml")"
  if [ "$before" = "$after" ]; then
    pass 'second standalone wizard run is idempotent'
  else
    fail 'second standalone wizard run is idempotent' 'the config file changed'
  fi
}

# Check the wizard in an integrated-style tree with local Consul.
check_integrated_tree() {
  local tree
  tree="$(new_tree integrated)"
  write_root_env "$tree" 'http://consul:8500/'

  if ! run_wizard "$tree"; then
    fail 'integrated wizard runs' "read $tree/wizard.log"
    return 0
  fi
  pass 'integrated wizard runs'
  check_tree_output "$tree"
  assert_line "$tree/wizard.log" 'config/traceloop-hub/config.yaml' 'integrated wizard prints the config path'
}

# Check that an edited config stays unchanged on a rerun.
check_preserved_config() {
  local tree
  tree="$(new_tree preserved)"
  write_root_env "$tree" 'http://consul:8500'
  if ! run_wizard "$tree"; then
    fail 'wizard creates a config for the preserve check' "read $tree/wizard.log"
    return 0
  fi

  local config="$tree/config/traceloop-hub/config.yaml"
  local fake_secret="smoke-key-$$"
  {
    cat "$config"
    printf '\n# smoke marker\ngeneral:\n  trace_content_enabled: false\n'
    printf '# api key placeholder: %s\n' "$fake_secret"
  } >"$tree/edited.yaml"
  mv -- "$tree/edited.yaml" "$config"
  secret_values+=("$fake_secret")

  if ! run_wizard "$tree"; then
    fail 'wizard rerun keeps an edited config' "read $tree/wizard.log"
    return 0
  fi
  assert_line "$config" '# smoke marker' 'wizard keeps an edited config'
  assert_line "$config" "$fake_secret" 'wizard keeps the edited config bytes'
  assert_no_line "$tree/wizard.log" 'trace_content_enabled' 'wizard logs no config content'
  assert_no_line "$tree/wizard.log" "$fake_secret" 'wizard logs no secret value'
}

# Check that the wizard rejects bad values and unknown arguments.
check_validation() {
  local tree
  tree="$(new_tree bad-rootless)"
  write_root_env "$tree" 'http://consul:8500'
  if (
    cd "$tree"
    env STACK_ROOTLESS=2 bash "$tree/state/traceloop-hub/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'wizard rejects a bad STACK_ROOTLESS' 'the wizard accepted 2'
  else
    pass 'wizard rejects a bad STACK_ROOTLESS'
  fi

  tree="$(new_tree bad-uid)"
  write_root_env "$tree" 'http://consul:8500'
  if (
    cd "$tree"
    env STACK_UID=abc bash "$tree/state/traceloop-hub/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'wizard rejects a bad STACK_UID' 'the wizard accepted abc'
  else
    pass 'wizard rejects a bad STACK_UID'
  fi

  tree="$(new_tree bad-gid)"
  write_root_env "$tree" 'http://consul:8500'
  if (
    cd "$tree"
    env STACK_GID=-1 bash "$tree/state/traceloop-hub/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'wizard rejects a bad STACK_GID' 'the wizard accepted -1'
  else
    pass 'wizard rejects a bad STACK_GID'
  fi

  tree="$(new_tree bad-argument)"
  write_root_env "$tree" 'http://consul:8500'
  if (
    cd "$tree"
    bash "$tree/state/traceloop-hub/setup.sh" wrong </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'wizard rejects an unknown argument' 'the wizard accepted wrong'
  else
    pass 'wizard rejects an unknown argument'
  fi
}

# Check that clean removes only the requested trees.
check_clean() {
  local tree
  tree="$(new_tree clean)"
  write_root_env "$tree" 'http://consul:8500'
  run_wizard "$tree"
  mkdir -p "$tree/data/traceloop-hub"
  printf 'runtime\n' >"$tree/data/traceloop-hub/marker"

  if ! (
    cd "$tree"
    bash "$tree/state/traceloop-hub/setup.sh" clean --yes </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'clean removes the config with --yes' "read $tree/wizard.log"
    return 0
  fi
  pass 'clean removes the config with --yes'
  assert_file_absent "$tree/config/traceloop-hub/config.yaml" 'clean removes the config file'
  assert_file_exists "$tree/data/traceloop-hub/marker" 'clean keeps data without --data'

  run_wizard "$tree"
  if ! (
    cd "$tree"
    bash "$tree/state/traceloop-hub/setup.sh" clean --data --yes </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'clean removes the data with --data' "read $tree/wizard.log"
    return 0
  fi
  pass 'clean removes the data with --data'
  assert_file_absent "$tree/config/traceloop-hub" 'clean removes the config directory'
  assert_file_absent "$tree/data/traceloop-hub" 'clean removes the data directory'

  tree="$(new_tree clean-declined)"
  write_root_env "$tree" 'http://consul:8500'
  run_wizard "$tree"
  (
    cd "$tree"
    bash "$tree/state/traceloop-hub/setup.sh" clean </dev/null
  ) >>"$tree/wizard.log" 2>&1 || true
  assert_file_exists "$tree/config/traceloop-hub/config.yaml" 'clean keeps the config when declined'

  tree="$(new_tree clean-flag)"
  write_root_env "$tree" 'http://consul:8500'
  if (
    cd "$tree"
    bash "$tree/state/traceloop-hub/setup.sh" clean --wrong </dev/null
  ) >>"$tree/wizard.log" 2>&1; then
    fail 'clean rejects an unknown flag' 'the wizard accepted --wrong'
  else
    pass 'clean rejects an unknown flag'
  fi
}

# Check the compose fragment contract.
check_compose_fragment() {
  local fragment="$REPO_ROOT/compose/traceloop-hub.yaml"
  if [ ! -f "$fragment" ]; then
    fail 'compose fragment exists' "the file is missing: $fragment"
    return 0
  fi
  pass 'compose fragment exists'

  assert_line "$fragment" '# dclint disable require-project-name-field' 'fragment disables the project name rule'
  assert_line "$fragment" 'image: traceloop/hub:0.10.1' 'fragment uses the official Hub image'
  assert_line "$fragment" 'container_name: traceloop-hub' 'fragment sets a unique container name'
  # The dollar signs in these patterns are literal Compose substitutions.
  # shellcheck disable=SC2016
  assert_line "$fragment" 'user: "${STACK_UID:-1000}:${STACK_GID:-1000}"' 'fragment sets the stack user'
  assert_line "$fragment" '      - target: 3000' 'fragment publishes container port 3000'
  assert_line "$fragment" '        published: 3002' 'fragment publishes host port 3002'
  # shellcheck disable=SC2016
  assert_line "$fragment" '        host_ip: ${PUBLIC_IP:-127.0.0.1}' 'fragment binds the port to PUBLIC_IP'
  assert_line "$fragment" './config/traceloop-hub/config.yaml:/app/config.yaml:ro' 'fragment mounts the config read-only'
  # shellcheck disable=SC2016
  assert_line "$fragment" 'traceloop-hub.${STACK_DOMAIN}:10.90.0.10' 'fragment maps the vhost to caddy'
  assert_line "$fragment" 'test: wget -q -O /dev/null http://127.0.0.1:3000/health' 'fragment checks GET /health in shell form'
  assert_line "$fragment" 'restart: unless-stopped' 'fragment restarts the service'
  assert_line "$fragment" 'HUB_MODE=yaml' 'fragment selects YAML Mode'
  assert_line "$fragment" 'CONFIG_FILE_PATH=/app/config.yaml' 'fragment sets the config path'

  assert_no_line "$fragment" 'CONSUL_ADDR' 'fragment has no Consul address'
  assert_no_line "$fragment" 'consul:8500' 'fragment has no local Consul address'
  assert_no_line "$fragment" 'config/consul' 'fragment mounts no Consul secrets'
  assert_no_line "$fragment" 'entrypoint:' 'fragment runs the upstream entrypoint'

  local port_count
  port_count="$(grep -cF -- 'published: 3002' "$fragment" || true)"
  if [ "$port_count" = "1" ]; then
    pass 'fragment publishes port 3002 once'
  else
    fail 'fragment publishes port 3002 once' "observed $port_count entries"
  fi

  local stack_port_count
  stack_port_count="$({ grep -h -F -- 'published: 3002' "$REPO_ROOT"/compose/*.yaml || true; } | wc -l)"
  stack_port_count="$(printf '%s' "$stack_port_count" | tr -d '[:space:]')"
  if [ "$stack_port_count" = "1" ]; then
    pass 'host port 3002 is unique in the stack'
  else
    fail 'host port 3002 is unique in the stack' "observed $stack_port_count fragments"
  fi
}

# Check the scaling manifest columns and rows.
check_scaling_manifest() {
  local manifest="$REPO_ROOT/state/traceloop-hub/scaling.tsv"
  if [ ! -f "$manifest" ]; then
    fail 'scaling manifest exists' "the file is missing: $manifest"
    return 0
  fi
  pass 'scaling manifest exists'

  assert_line "$manifest" '# Traceloop Hub scaling files. The columns are path, mode, scope, when, presence, purpose.' 'manifest declares six columns'

  local bad_rows row_count
  bad_rows="$(awk -F '\t' '!/^#/ && NF != 6 {print NR}' "$manifest")"
  if [ -z "$bad_rows" ]; then
    pass 'every manifest row has six columns'
  else
    fail 'every manifest row has six columns' "bad rows: $bad_rows"
  fi

  row_count="$(awk '!/^#/ && NF > 0 {n++} END {print n+0}' "$manifest")"
  if [ "$row_count" = "2" ]; then
    pass 'manifest holds two file rows'
  else
    fail 'manifest holds two file rows' "observed $row_count rows"
  fi

  assert_line "$manifest" $'config/traceloop-hub\t700\tnode-local\tboth\trequired' 'manifest lists the config directory'
  assert_line "$manifest" $'config/traceloop-hub/config.yaml\t600\tnode-local\tboth\trequired' 'manifest lists the config file'
}

# Check the static vhost descriptor.
check_vhost_descriptor() {
  local descriptor="$REPO_ROOT/state/traceloop-hub/vhost.json"
  if [ ! -f "$descriptor" ]; then
    fail 'vhost descriptor exists' "the file is missing: $descriptor"
    return 0
  fi
  pass 'vhost descriptor exists'

  assert_content "$descriptor" '{"name":"traceloop-hub","mode":"static","upstream":"http://traceloop-hub:3000"}' 'vhost descriptor has the expected content'
  assert_line "$descriptor" '"name":"traceloop-hub"' 'vhost descriptor names the service'
  assert_line "$descriptor" '"mode":"static"' 'vhost descriptor uses static mode'
  assert_line "$descriptor" '"upstream":"http://traceloop-hub:3000"' 'vhost descriptor proxies port 3000'
  assert_no_line "$descriptor" 'secret' 'vhost descriptor holds no secret'
  assert_no_line "$descriptor" 'token' 'vhost descriptor holds no token'
  assert_no_line "$descriptor" 'password' 'vhost descriptor holds no password'
}

# Check that no test value appears in any log file.
check_logs_for_secrets() {
  local leaked=0 log_file value
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

scratch="$(mktemp -d /tmp/traceloop-hub-smoke.XXXXXX)"
check_standalone_tree
check_integrated_tree
check_preserved_config
check_validation
check_clean
check_compose_fragment
check_scaling_manifest
check_vhost_descriptor
check_logs_for_secrets

printf 'smoke checks: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
