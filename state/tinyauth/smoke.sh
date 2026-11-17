#!/usr/bin/env bash
# Check the tinyauth wizard and the entrypoint in both configuration modes.
# The checks use a scratch tree. They need no Docker and no peer.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

scratch=""
passed=0
failed=0

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

skip() {
  printf 'SKIP %s\n' "$1"
}

# Return 0 when this environment can change a file owner to uid 1000.
can_chown_to_app_uid() {
  local probe
  probe="$(mktemp "${scratch}/chown-probe.XXXXXX")"
  if chown 1000:1000 "$probe" 2>/dev/null; then
    rm -f -- "$probe"
    return 0
  fi
  rm -f -- "$probe"
  return 1
}

# Build the scratch tree with copies of the two service scripts.
setup_tree() {
  mkdir -p "$scratch/state/tinyauth"
  cp "$REPO_ROOT/state/tinyauth/setup.sh" "$scratch/state/tinyauth/setup.sh"
  cp "$REPO_ROOT/state/tinyauth/entrypoint.sh" "$scratch/state/tinyauth/entrypoint.sh"
}

# Run the wizard with the given capability flags. Write the root .env first.
run_wizard() {
  local consul="$1" litefs="$2" oidc="$3" tls="$4"
  local observer_pass
  observer_pass="$(openssl rand -hex 8)"
  (
    cd "$scratch"
    {
      printf 'STACK_DOMAIN=sh.lan\n'
      printf 'PUBLIC_IP=127.0.0.1\n'
      printf 'CONSUL_ENABLED=%s\n' "$consul"
      printf 'LITEFS_ENABLED=%s\n' "$litefs"
      printf 'OIDC_ENABLED=%s\n' "$oidc"
      printf 'TLS_ENABLED=%s\n' "$tls"
    } >.env
    TINYAUTH_LDAP_LOCAL=yes \
      TINYAUTH_LDAP_BASEDN='dc=sh,dc=lan' \
      TINYAUTH_CLIENTS='demo:https://demo.sh.lan/callback' \
      TINYAUTH_OBSERVER_AUTO=no \
      TINYAUTH_LDAP_BINDPASSWORD="$observer_pass" \
      bash "$scratch/state/tinyauth/setup.sh"
  ) >"$scratch/wizard.log" 2>&1
}

# Render the entrypoint config with the given flags. No process starts.
render_entrypoint() {
  local consul="$1" litefs="$2" oidc="$3" tls="$4"
  mkdir -p "$scratch/run" "$scratch/data/mount" "$scratch/data/store"
  (
    cd "$scratch"
    TINYAUTH_SECRETS_DIR="$scratch/secrets" \
      CONSUL_SECRETS_DIR="$scratch/consul-secrets" \
      LITEFS_YML="$scratch/run/litefs.yml" \
      LITEFS_MOUNT_DIR="$scratch/data/mount" \
      LITEFS_DATA_DIR="$scratch/data/store" \
      STANDALONE_RENDER_FILE="$scratch/run/standalone.env" \
      TINYAUTH_RENDER_ONLY=1 \
      CONSUL_ENABLED="$consul" \
      LITEFS_ENABLED="$litefs" \
      OIDC_ENABLED="$oidc" \
      TLS_ENABLED="$tls" \
      PUBLIC_IP=127.0.0.1 \
      STACK_DOMAIN=sh.lan \
      sh "$scratch/state/tinyauth/entrypoint.sh"
  ) >"$scratch/entrypoint.log" 2>&1
}

# Print the mode of one file. Support GNU and BSD stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

# Check that a second wizard run keeps the generated files.
check_wizard_idempotence() {
  local env_file="$scratch/config/tinyauth/tinyauth.env"
  local secrets="$scratch/config/tinyauth/secrets"
  local snapshot="$scratch/snapshot"
  mkdir -p "$snapshot"

  run_wizard 0 0 0 0
  cp "$env_file" "$snapshot/env.first"
  cp "$secrets/ldap-observer" "$snapshot/observer.first"
  cp "$secrets/oidc/private.pem" "$snapshot/private.first"
  cp "$secrets/oidc/public.pem" "$snapshot/public.first"

  run_wizard 0 0 0 0
  if cmp -s "$snapshot/env.first" "$env_file" &&
    cmp -s "$snapshot/observer.first" "$secrets/ldap-observer" &&
    cmp -s "$snapshot/private.first" "$secrets/oidc/private.pem" &&
    cmp -s "$snapshot/public.first" "$secrets/oidc/public.pem"; then
    pass 'wizard keeps the generated files on a second run'
  else
    fail 'wizard keeps the generated files on a second run' 'a file changed between the two runs'
  fi
}

# Check that the wizard writes the OIDC keys with the expected mode and owner.
check_oidc_key_modes() {
  local key_dir="$scratch/config/tinyauth/secrets/oidc"
  local key mode owner

  for key in private.pem public.pem; do
    if [ ! -f "$key_dir/$key" ]; then
      fail "wizard creates $key" 'the key file is missing'
      continue
    fi
    mode="$(file_mode "$key_dir/$key")"
    if [ "$mode" = '600' ]; then
      pass "OIDC key $key has mode 600"
    else
      fail "OIDC key $key has mode 600" "observed mode $mode"
    fi
  done

  if grep -q 'PRIVATE KEY' "$key_dir/private.pem" &&
    grep -q 'PUBLIC KEY' "$key_dir/public.pem"; then
    pass 'OIDC keys are PEM files'
  else
    fail 'OIDC keys are PEM files' 'a key has no PEM header'
  fi

  if can_chown_to_app_uid; then
    owner="$(stat -c '%u' "$key_dir/private.pem" 2>/dev/null || printf 'unknown')"
    if [ "$owner" = '1000' ]; then
      pass 'OIDC keys are owned by uid 1000'
    else
      fail 'OIDC keys are owned by uid 1000' "observed uid $owner"
    fi
  else
    skip 'OIDC keys are owned by uid 1000. This environment blocks chown.'
  fi
}

# Check the wizard and the entrypoint in standalone and integrated mode.
check_rendered_configuration_modes() {
  local env_file="$scratch/config/tinyauth/tinyauth.env"
  local rendered="$scratch/run/standalone.env"
  local litefs="$scratch/run/litefs.yml"

  run_wizard 0 0 0 0
  if grep -q '^TINYAUTH_APPURL=http://127.0.0.1:3000$' "$env_file"; then
    pass 'standalone wizard writes a local issuer'
  else
    fail 'standalone wizard writes a local issuer' 'the APPURL line is not local'
  fi
  if grep -q '^Mode: standalone' "$scratch/wizard.log"; then
    pass 'standalone wizard reports standalone mode'
  else
    fail 'standalone wizard reports standalone mode' 'the mode line is missing'
  fi
  if [ -e "$scratch/config/tinyauth/secrets/consul-management-token" ]; then
    fail 'wizard does not copy the consul token' 'a copied token exists'
  else
    pass 'wizard does not copy the consul token'
  fi

  run_wizard 1 1 1 1
  if grep -q '^TINYAUTH_APPURL=https://tinyauth.sh.lan$' "$env_file"; then
    pass 'integrated wizard writes the stack domain issuer'
  else
    fail 'integrated wizard writes the stack domain issuer' 'the APPURL line is wrong'
  fi
  if grep -q '^Mode: integrated' "$scratch/wizard.log"; then
    pass 'integrated wizard reports integrated mode'
  else
    fail 'integrated wizard reports integrated mode' 'the mode line is missing'
  fi

  render_entrypoint 0 0 0 0
  if grep -q '^TINYAUTH_APPURL=http://127.0.0.1:3000$' "$rendered"; then
    pass 'standalone entrypoint renders a local issuer'
  else
    fail 'standalone entrypoint renders a local issuer' 'the APPURL line is not local'
  fi
  if [ ! -e "$litefs" ]; then
    pass 'standalone entrypoint renders no litefs config'
  else
    fail 'standalone entrypoint renders no litefs config' 'a litefs config exists'
  fi

  render_entrypoint 1 1 1 1
  if grep -q 'type: "consul"' "$litefs"; then
    pass 'integrated entrypoint renders a consul lease'
  else
    fail 'integrated entrypoint renders a consul lease' 'the lease type is not consul'
  fi
  if grep -q 'addr: ":20202"' "$litefs"; then
    pass 'integrated entrypoint renders the peer port'
  else
    fail 'integrated entrypoint renders the peer port' 'the peer port is missing'
  fi
}

scratch="$(mktemp -d /tmp/tinyauth-smoke.XXXXXX)"
setup_tree
check_wizard_idempotence
check_oidc_key_modes
check_rendered_configuration_modes

printf 'smoke checks: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
