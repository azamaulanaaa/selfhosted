#!/usr/bin/env bash
# The expected patterns use single quotes on purpose.
# shellcheck disable=SC2016
# Smoke check for lldap with and without LiteFS.
# The check verifies the compose fragment, the entrypoint, and the wizard.
# Names and messages use short active sentences.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly COMPOSE_FRAGMENT="compose/lldap.yaml"
readonly ENTRYPOINT="state/lldap/entrypoint.sh"
readonly WIZARD="state/lldap/setup.sh"
readonly ASSEMBLED_COMPOSE="compose.yaml"

SANDBOX="$(mktemp -d)"
readonly SANDBOX
trap 'rm -rf -- "$SANDBOX"' EXIT

smoke_error() {
  echo "smoke: error: $1" >&2
  exit 1
}

# Check that a file holds one expected line.
assert_line() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if ! grep -Fq -- "$pattern" "$file"; then
    smoke_error "$description Expected: $pattern"
  fi
}

# Check that a file holds none of an unexpected line.
assert_no_line() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if grep -Fq -- "$pattern" "$file"; then
    smoke_error "$description Unexpected: $pattern"
  fi
}

# Check the compose settings for both modes.
check_compose_fragment() {
  echo "smoke: checking the compose fragment"
  assert_line "$COMPOSE_FRAGMENT" 'CONSUL_ADDR=${CONSUL_ADDR:-http://consul:8500}' 'The compose fragment lacks the Consul address.'
  assert_line "$COMPOSE_FRAGMENT" 'LITEFS_ENABLED=${LITEFS_ENABLED:-0}' 'The compose fragment lacks the LiteFS flag.'
  assert_line "$COMPOSE_FRAGMENT" 'target: 3890' 'The compose fragment lacks the LDAP target port.'
  assert_line "$COMPOSE_FRAGMENT" 'published: 3890' 'The compose fragment lacks the LDAP published port.'
  assert_line "$COMPOSE_FRAGMENT" 'host_ip: ${PUBLIC_IP:-127.0.0.1}' 'The compose fragment lacks the explicit LDAP interface.'
  assert_line "$COMPOSE_FRAGMENT" './data/lldap/store/db:/data:rw' 'The compose fragment lacks the database mount.'
  assert_line "$COMPOSE_FRAGMENT" './data/lldap/store/litefs:/var/lib/litefs:rw' 'The compose fragment lacks the LiteFS data mount.'
  assert_line "$COMPOSE_FRAGMENT" './config/consul/secrets:/etc/consul/secrets:ro' 'The compose fragment lacks the Consul secrets mount.'
  assert_no_line "$COMPOSE_FRAGMENT" 'CONSUL_HTTP_ADDR' 'The compose fragment still holds the old Consul address key.'
}

# Check that the entrypoint selects a mode and starts the right process.
check_entrypoint_modes() {
  echo "smoke: checking the entrypoint modes"
  assert_line "$ENTRYPOINT" 'LITEFS_ENABLED="${LITEFS_ENABLED:-0}"' 'The entrypoint lacks the LiteFS flag.'
  assert_line "$ENTRYPOINT" 'CONSUL_ADDR="${CONSUL_ADDR:-http://consul:8500}"' 'The entrypoint lacks the Consul address.'
  assert_line "$ENTRYPOINT" 'LOCAL_CONSUL_ADDR="http://consul:8500"' 'The entrypoint lacks the local Consul comparison.'
  assert_line "$ENTRYPOINT" 'CONSUL_REMOTE_TOKEN_FILE="${CONSUL_REMOTE_TOKEN_FILE:-/etc/consul/secrets/remote-token}"' 'The entrypoint lacks the remote token file.'
  assert_line "$ENTRYPOINT" 'if [ "$litefs_mode" -eq 0 ]; then' 'The entrypoint lacks the branch without LiteFS.'
  assert_line "$ENTRYPOINT" 'exec gosu' 'The branch without LiteFS lacks the direct LLDAP start.'
  assert_line "$ENTRYPOINT" 'initial_management' 'The entrypoint does not read the local Consul token.'
  assert_line "$ENTRYPOINT" 'litefs mount -config' 'The LiteFS branch lacks the LiteFS start.'
  assert_no_line "$ENTRYPOINT" 'CONSUL_HTTP_ADDR' 'The entrypoint still holds the old Consul address key.'
}

# Check that the assembler output includes the lldap fragment.
check_assembled_compose() {
  echo "smoke: checking the assembled compose file"
  assert_line "$ASSEMBLED_COMPOSE" 'path: compose/lldap.yaml' 'The assembled compose file lacks the lldap fragment.'
}

# Print the checksum lines of the wizard secret files.
secret_checksums() {
  (
    cd "$SANDBOX"
    sha256sum \
      config/lldap/secrets/jwt_secret \
      config/lldap/secrets/key_seed \
      config/lldap/secrets/ldap_user_pass \
      config/ldap/secrets/user-pass
  )
}

# Run the wizard in the sandbox. Do not use an interactive terminal.
run_wizard() {
  (
    cd "$SANDBOX"
    LLDAP_BASE_DN='dc=sh,dc=lan' bash state/lldap/setup.sh </dev/null >/dev/null
  )
}

# Run the wizard in the sandbox with one CONSUL_ADDR value and print its output.
# Do not use an interactive terminal.
run_wizard_output() {
  (
    cd "$SANDBOX"
    CONSUL_ADDR="$1" LLDAP_BASE_DN='dc=sh,dc=lan' bash state/lldap/setup.sh </dev/null
  )
}

# Check that two wizard runs keep the secrets unchanged.
check_wizard_idempotence() {
  echo "smoke: checking wizard idempotence"
  mkdir -p "$SANDBOX/state/lldap"
  cp -- "$WIZARD" "$SANDBOX/state/lldap/setup.sh"

  run_wizard
  local first_checksums
  first_checksums="$(secret_checksums)"
  run_wizard
  local second_checksums
  second_checksums="$(secret_checksums)"
  if [ "$first_checksums" != "$second_checksums" ]; then
    smoke_error "The wizard changed a secret on the second run."
  fi

  local canonical_dir="$SANDBOX/config/ldap/secrets"
  local canonical_file="$canonical_dir/user-pass"
  local legacy_file="$SANDBOX/config/lldap/secrets/ldap_user_pass"
  local file_mode
  file_mode="$(stat -c '%a' "$canonical_file")"
  if [ "$file_mode" != "600" ]; then
    smoke_error "The canonical password file has mode $file_mode. Expected 600."
  fi
  if ! cmp -s -- "$canonical_file" "$legacy_file"; then
    smoke_error "The canonical password differs from the legacy password."
  fi

  # The canonical file is the source of truth. A new value must update the legacy file.
  printf '%s' 'smoke-test-canonical-value' >"$canonical_file"
  run_wizard
  if ! cmp -s -- "$canonical_file" "$legacy_file"; then
    smoke_error "The wizard did not copy the canonical password to the legacy file."
  fi
}

# Check that the wizard hint names the token path of the selected Consul.
check_wizard_token_hint() {
  echo "smoke: checking the wizard token hint"
  local local_output remote_output
  local_output="$(run_wizard_output 'http://consul:8500')"
  if ! printf '%s\n' "$local_output" | grep -Fq 'config/consul/secrets/agent.hcl'; then
    smoke_error "The wizard hint lacks the local Consul token path."
  fi
  remote_output="$(run_wizard_output 'https://consul.example:8500')"
  if ! printf '%s\n' "$remote_output" | grep -Fq 'config/consul/secrets/remote-token'; then
    smoke_error "The wizard hint lacks the remote Consul token path."
  fi
}

check_compose_fragment
check_entrypoint_modes
check_assembled_compose
check_wizard_idempotence
check_wizard_token_hint

echo "smoke: all checks passed"
