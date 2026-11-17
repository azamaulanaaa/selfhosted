#!/usr/bin/env bash
# The expected patterns use single quotes on purpose.
# shellcheck disable=SC2016
# Smoke check for the lldap standalone mode and integrated mode.
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

# Check the compose settings for both modes.
check_compose_fragment() {
  echo "smoke: checking the compose fragment"
  assert_line "$COMPOSE_FRAGMENT" 'CONSUL_ENABLED=${CONSUL_ENABLED:-0}' 'The compose fragment lacks the Consul flag.'
  assert_line "$COMPOSE_FRAGMENT" 'LITEFS_ENABLED=${LITEFS_ENABLED:-0}' 'The compose fragment lacks the LiteFS flag.'
  assert_line "$COMPOSE_FRAGMENT" 'target: 3890' 'The compose fragment lacks the LDAP target port.'
  assert_line "$COMPOSE_FRAGMENT" 'published: 3890' 'The compose fragment lacks the LDAP published port.'
  assert_line "$COMPOSE_FRAGMENT" 'host_ip: ${PUBLIC_IP:-127.0.0.1}' 'The compose fragment lacks the explicit LDAP interface.'
  assert_line "$COMPOSE_FRAGMENT" './data/lldap/store/db:/data:rw' 'The compose fragment lacks the standalone database mount.'
  assert_line "$COMPOSE_FRAGMENT" './data/lldap/store/litefs:/var/lib/litefs:rw' 'The compose fragment lacks the LiteFS data mount.'
  assert_line "$COMPOSE_FRAGMENT" './config/consul/secrets:/etc/consul/secrets:ro' 'The compose fragment lacks the Consul secrets mount.'
}

# Check that the entrypoint selects a mode and starts the right process.
check_entrypoint_modes() {
  echo "smoke: checking the entrypoint modes"
  assert_line "$ENTRYPOINT" 'CONSUL_ENABLED="${CONSUL_ENABLED:-0}"' 'The entrypoint lacks the Consul flag.'
  assert_line "$ENTRYPOINT" 'LITEFS_ENABLED="${LITEFS_ENABLED:-0}"' 'The entrypoint lacks the LiteFS flag.'
  assert_line "$ENTRYPOINT" 'if [ "$integrated_mode" -eq 0 ]; then' 'The entrypoint lacks the standalone branch.'
  assert_line "$ENTRYPOINT" 'exec gosu' 'The standalone branch lacks the direct LLDAP start.'
  assert_line "$ENTRYPOINT" 'initial_management' 'The entrypoint does not read the Consul management token.'
  assert_line "$ENTRYPOINT" 'litefs mount -config' 'The integrated branch lacks the LiteFS start.'
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

check_compose_fragment
check_entrypoint_modes
check_assembled_compose
check_wizard_idempotence

echo "smoke: all checks passed"
