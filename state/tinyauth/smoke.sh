#!/usr/bin/env bash
# Check the tinyauth wizard and the entrypoint in both configuration modes.
# Consul is always present. CONSUL_ADDR selects the Consul location.
# The checks use a scratch tree. They need no Docker and no peer.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# The PKCS#1 PEM header. The file holds one copy only, so the secret scanner
# does not pair it with another PEM marker.
readonly PKCS1_HEADER='-----BEGIN RSA PRIVATE KEY-----'

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

# Build the scratch tree with copies of the two service scripts and a scratch
# Consul secrets tree. The token values are test values. The checks never print
# them.
setup_tree() {
  mkdir -p "$scratch/state/tinyauth" "$scratch/config/consul/secrets"
  cp "$REPO_ROOT/state/tinyauth/setup.sh" "$scratch/state/tinyauth/setup.sh"
  cp "$REPO_ROOT/state/tinyauth/entrypoint.sh" "$scratch/state/tinyauth/entrypoint.sh"
  cat >"$scratch/config/consul/secrets/agent.hcl" <<'EOF'
acl {
  tokens {
    initial_management = "local-test-token"
  }
}
EOF
  printf 'remote-test-token\n' >"$scratch/config/consul/secrets/remote-token"
  chmod 0600 "$scratch/config/consul/secrets/agent.hcl" "$scratch/config/consul/secrets/remote-token"
}

# Run the wizard with the given Consul address and capability flags.
# Write the root .env first.
run_wizard() {
  local consul_addr="$1" litefs="$2" oidc="$3" tls="$4"
  local observer_pass
  observer_pass="$(openssl rand -hex 8)"
  (
    cd "$scratch"
    {
      printf 'STACK_DOMAIN=sh.lan\n'
      printf 'PUBLIC_IP=127.0.0.1\n'
      printf 'CONSUL_ADDR=%s\n' "$consul_addr"
      printf 'LITEFS_ENABLED=%s\n' "$litefs"
      printf 'OIDC_ENABLED=%s\n' "$oidc"
      printf 'TLS_ENABLED=%s\n' "$tls"
    } >.env
    CONSUL_ADDR="$consul_addr" \
      TINYAUTH_LDAP_LOCAL=yes \
      TINYAUTH_LDAP_BASEDN='dc=sh,dc=lan' \
      TINYAUTH_CLIENTS='demo:https://demo.sh.lan/callback' \
      TINYAUTH_OBSERVER_AUTO=no \
      TINYAUTH_LDAP_BINDPASSWORD="$observer_pass" \
      bash "$scratch/state/tinyauth/setup.sh"
  ) >"$scratch/wizard.log" 2>&1
}

# Render the entrypoint config with the given Consul address and flags.
# No process starts. The optional exec uid and gid override EXEC_UID and
# EXEC_GID. An empty value keeps the entrypoint default.
render_entrypoint() {
  local consul_addr="$1" litefs="$2" oidc="$3" tls="$4"
  local exec_uid="${5:-}" exec_gid="${6:-}"
  mkdir -p "$scratch/run" "$scratch/data/mount" "$scratch/data/store"
  (
    cd "$scratch"
    if [ -n "$exec_uid" ]; then
      export EXEC_UID="$exec_uid"
      export EXEC_GID="$exec_gid"
    fi
    TINYAUTH_SECRETS_DIR="$scratch/secrets" \
      CONSUL_SECRETS_DIR="$scratch/config/consul/secrets" \
      LITEFS_YML="$scratch/run/litefs.yml" \
      LITEFS_MOUNT_DIR="$scratch/data/mount" \
      LITEFS_DATA_DIR="$scratch/data/store" \
      STANDALONE_RENDER_FILE="$scratch/run/standalone.env" \
      TINYAUTH_RENDER_ONLY=1 \
      CONSUL_ADDR="$consul_addr" \
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

# Check that the removed CONSUL_ENABLED flag is not in the runtime files.
# Consul is always present. CONSUL_ADDR selects the location.
check_consul_flag_removed() {
  local file
  local -a files=(
    "$REPO_ROOT/state/tinyauth/setup.sh"
    "$REPO_ROOT/state/tinyauth/entrypoint.sh"
    "$REPO_ROOT/compose/tinyauth.yaml"
  )
  for file in "${files[@]}"; do
    if grep -q 'CONSUL_ENABLED' "$file"; then
      fail "no CONSUL_ENABLED flag in $file" 'the file still holds the removed flag'
      return 0
    fi
  done
  pass 'no CONSUL_ENABLED flag in the wizard, the entrypoint, and the fragment'
}

# Check that a second wizard run keeps the generated files.
check_wizard_idempotence() {
  local env_file="$scratch/config/tinyauth/tinyauth.env"
  local secrets="$scratch/config/tinyauth/secrets"
  local snapshot="$scratch/snapshot"
  mkdir -p "$snapshot"

  run_wizard 'https://consul.remote.example:8500' 0 0 0
  cp "$env_file" "$snapshot/env.first"
  cp "$secrets/ldap-observer" "$snapshot/observer.first"
  cp "$secrets/oidc/private.pem" "$snapshot/private.first"
  cp "$secrets/oidc/public.pem" "$snapshot/public.first"

  run_wizard 'https://consul.remote.example:8500' 0 0 0
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

  if [ "$(head -n 1 "$key_dir/private.pem" 2>/dev/null)" = "$PKCS1_HEADER" ]; then
    pass 'OIDC private key is PKCS#1'
  else
    fail 'OIDC private key is PKCS#1' 'the private key header is not PKCS#1'
  fi

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

# Check that the wizard source generates a PKCS#1 key. The genpkey call alone
# writes PKCS#8, so the source must also hold the genrsa -traditional path and
# the openssl rsa -traditional conversion.
check_pkcs1_key_source() {
  local setup="$REPO_ROOT/state/tinyauth/setup.sh"
  if grep -q 'openssl genrsa -traditional 2048' "$setup"; then
    pass 'wizard uses genrsa -traditional for the private key'
  else
    fail 'wizard uses genrsa -traditional for the private key' 'the traditional genrsa call is missing'
  fi
  if grep -q 'openssl rsa -in .* -traditional' "$setup"; then
    pass 'wizard converts a PKCS#8 key with openssl rsa -traditional'
  else
    fail 'wizard converts a PKCS#8 key with openssl rsa -traditional' 'the conversion call is missing'
  fi
  # A genpkey call is allowed only as the fallback with a conversion.
  if grep -q 'openssl genpkey' "$setup" &&
    ! grep -q 'openssl rsa -in .* -traditional' "$setup"; then
    fail 'wizard does not only use genpkey for the private key' 'genpkey has no conversion'
  else
    pass 'wizard does not only use genpkey for the private key'
  fi
}

# Check that a re-run converts a PKCS#8 private key to PKCS#1 and keeps the
# public key. The PKCS#8 key holds the same key material, so the public key
# must not change.
check_pkcs8_key_conversion() {
  local key_dir="$scratch/config/tinyauth/secrets/oidc"
  local private_key="$key_dir/private.pem"
  local public_before public_after

  public_before="$(cat "$key_dir/public.pem")"
  (
    umask 077
    openssl pkcs8 -topk8 -nocrypt -in "$private_key" -out "${private_key}.pkcs8" 2>/dev/null
    mv -f -- "${private_key}.pkcs8" "$private_key"
  )
  if head -n 1 "$private_key" | grep -q 'RSA'; then
    skip 'wizard converts a PKCS#8 key to PKCS#1. This openssl wrote PKCS#1.'
    return 0
  fi
  if ! run_wizard 'https://consul.remote.example:8500' 0 0 0; then
    fail 'wizard converts a PKCS#8 key to PKCS#1' 'the wizard exited with an error'
    return 0
  fi
  public_after="$(cat "$key_dir/public.pem")"
  if [ "$(head -n 1 "$private_key")" = "$PKCS1_HEADER" ] &&
    [ "$public_before" = "$public_after" ]; then
    pass 'wizard converts a PKCS#8 key to PKCS#1'
  else
    fail 'wizard converts a PKCS#8 key to PKCS#1' 'the key header or the public key changed'
  fi
}

# Check the wizard in standalone mode with remote Consul.
check_standalone_wizard() {
  local env_file="$scratch/config/tinyauth/tinyauth.env"

  run_wizard 'https://consul.remote.example:8500' 0 0 0
  if grep -qx 'TINYAUTH_APPURL=http://127.0.0.1:3000' "$env_file"; then
    pass 'standalone wizard writes a local issuer'
  else
    fail 'standalone wizard writes a local issuer' 'the APPURL line is not local'
  fi
  if grep -qx 'Consul: remote' "$scratch/wizard.log"; then
    pass 'standalone wizard reports remote Consul'
  else
    fail 'standalone wizard reports remote Consul' 'the Consul line is wrong'
  fi
  if grep -qx 'LiteFS: off' "$scratch/wizard.log"; then
    pass 'standalone wizard reports LiteFS off'
  else
    fail 'standalone wizard reports LiteFS off' 'the LiteFS line is wrong'
  fi
  if grep -qx 'Consul address: https://consul.remote.example:8500' "$scratch/wizard.log"; then
    pass 'standalone wizard prints the Consul address'
  else
    fail 'standalone wizard prints the Consul address' 'the Consul address line is wrong'
  fi
  if grep -q '^Consul token file: config/consul/secrets/remote-token$' "$scratch/wizard.log"; then
    pass 'standalone wizard names the remote token file'
  else
    fail 'standalone wizard names the remote token file' 'the token file line is wrong'
  fi
  if [ -e "$scratch/config/tinyauth/secrets/consul-management-token" ] ||
    [ -e "$scratch/config/tinyauth/secrets/remote-token" ] ||
    [ -e "$scratch/config/tinyauth/secrets/agent.hcl" ]; then
    fail 'wizard does not copy the Consul token' 'a copied token exists'
  else
    pass 'wizard does not copy the Consul token'
  fi
  if grep -q 'CONSUL_ENABLED' "$scratch/wizard.log"; then
    fail 'standalone wizard log names no removed flag' 'the log holds CONSUL_ENABLED'
  else
    pass 'standalone wizard log names no removed flag'
  fi
}

# Check the wizard in integrated mode with local Consul and a trailing slash.
check_integrated_wizard() {
  local env_file="$scratch/config/tinyauth/tinyauth.env"

  run_wizard 'http://consul:8500/' 1 1 1
  if grep -qx 'TINYAUTH_APPURL=https://tinyauth.sh.lan' "$env_file"; then
    pass 'integrated wizard writes the stack domain issuer'
  else
    fail 'integrated wizard writes the stack domain issuer' 'the APPURL line is wrong'
  fi
  if grep -qx 'Consul: local' "$scratch/wizard.log"; then
    pass 'integrated wizard reports local Consul'
  else
    fail 'integrated wizard reports local Consul' 'the Consul line is wrong'
  fi
  if grep -qx 'LiteFS: on' "$scratch/wizard.log"; then
    pass 'integrated wizard reports LiteFS on'
  else
    fail 'integrated wizard reports LiteFS on' 'the LiteFS line is wrong'
  fi
  if grep -qx 'Consul address: http://consul:8500/' "$scratch/wizard.log"; then
    pass 'integrated wizard ignores one trailing slash'
  else
    fail 'integrated wizard ignores one trailing slash' 'the Consul line is wrong'
  fi
  if grep -qx 'Consul token file: config/consul/secrets/agent.hcl' "$scratch/wizard.log"; then
    pass 'integrated wizard names the local token file'
  else
    fail 'integrated wizard names the local token file' 'the token file line is wrong'
  fi
}

# Check local Consul with LiteFS off.
# The summary must not use the stack word standalone for this case.
check_local_consul_litefs_off() {
  run_wizard 'http://consul:8500' 0 0 0
  if grep -qx 'Consul: local' "$scratch/wizard.log"; then
    pass 'local Consul wizard reports local Consul'
  else
    fail 'local Consul wizard reports local Consul' 'the Consul line is wrong'
  fi
  if grep -qx 'LiteFS: off' "$scratch/wizard.log"; then
    pass 'local Consul wizard reports LiteFS off'
  else
    fail 'local Consul wizard reports LiteFS off' 'the LiteFS line is wrong'
  fi
  if grep -qi 'standalone' "$scratch/wizard.log"; then
    fail 'local Consul with LiteFS off never says standalone' 'the summary says standalone'
  else
    pass 'local Consul with LiteFS off never says standalone'
  fi
  if grep -q '^Mode:' "$scratch/wizard.log"; then
    fail 'summary has no mode line' 'a Mode line is present'
  else
    pass 'summary has no mode line'
  fi
}

# Check the entrypoint in standalone mode with remote Consul.
check_standalone_entrypoint() {
  local rendered="$scratch/run/standalone.env"
  local litefs="$scratch/run/litefs.yml"

  rm -f "$litefs"
  render_entrypoint 'https://consul.remote.example:8500' 0 0 0
  if grep -qx 'TINYAUTH_APPURL=http://127.0.0.1:3000' "$rendered"; then
    pass 'standalone entrypoint renders a local issuer'
  else
    fail 'standalone entrypoint renders a local issuer' 'the APPURL line is not local'
  fi
  if grep -qx 'CONSUL_ADDR=https://consul.remote.example:8500' "$rendered"; then
    pass 'standalone entrypoint records CONSUL_ADDR'
  else
    fail 'standalone entrypoint records CONSUL_ADDR' 'the CONSUL_ADDR line is wrong'
  fi
  if [ ! -e "$litefs" ]; then
    pass 'standalone entrypoint renders no litefs config'
  else
    fail 'standalone entrypoint renders no litefs config' 'a litefs config exists'
  fi
  if grep -q 'CONSUL_ENABLED' "$rendered" "$scratch/entrypoint.log"; then
    fail 'standalone entrypoint names no removed flag' 'CONSUL_ENABLED is present'
  else
    pass 'standalone entrypoint names no removed flag'
  fi
}

# Check the entrypoint in integrated mode with local Consul.
check_integrated_entrypoint() {
  local litefs="$scratch/run/litefs.yml"

  render_entrypoint 'http://consul:8500' 1 1 1
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
  if grep -q 'url: "http://consul:8500"' "$litefs"; then
    pass 'integrated entrypoint uses CONSUL_ADDR for the lease'
  else
    fail 'integrated entrypoint uses CONSUL_ADDR for the lease' 'the lease URL is wrong'
  fi
  if grep -q "consul token file: $scratch/config/consul/secrets/agent.hcl" "$scratch/entrypoint.log"; then
    pass 'integrated entrypoint selects the local token file'
  else
    fail 'integrated entrypoint selects the local token file' 'the token file line is wrong'
  fi
  if grep -q 'local-test-token' "$scratch/entrypoint.log"; then
    fail 'entrypoint does not print the local token' 'the token value is in the log'
  else
    pass 'entrypoint does not print the local token'
  fi
}

# Check that the entrypoint selects the remote token file for remote Consul.
check_remote_token_selection() {
  render_entrypoint 'https://consul.remote.example:8500' 1 0 0
  if grep -q "consul token file: $scratch/config/consul/secrets/remote-token" "$scratch/entrypoint.log"; then
    pass 'integrated entrypoint selects the remote token file'
  else
    fail 'integrated entrypoint selects the remote token file' 'the token file line is wrong'
  fi
  if grep -q 'remote-test-token' "$scratch/entrypoint.log"; then
    fail 'entrypoint does not print the remote token' 'the token value is in the log'
  else
    pass 'entrypoint does not print the remote token'
  fi
}

# Check that the entrypoint passes the Consul token value to LiteFS.
# LiteFS reads CONSUL_HTTP_TOKEN and ignores CONSUL_HTTP_TOKEN_FILE.
check_litefs_consul_token() {
  local entrypoint="$REPO_ROOT/state/tinyauth/entrypoint.sh"
  local start_line

  start_line="$(grep -F 'litefs mount -config' "$entrypoint" || true)"
  # The expected text is literal script text, not a shell variable.
  # shellcheck disable=SC2016
  if printf '%s\n' "$start_line" | grep -qF 'CONSUL_HTTP_TOKEN="$token"'; then
    pass 'entrypoint passes CONSUL_HTTP_TOKEN to litefs'
  else
    fail 'entrypoint passes CONSUL_HTTP_TOKEN to litefs' 'the litefs start line does not set CONSUL_HTTP_TOKEN'
  fi
  if printf '%s\n' "$start_line" | grep -qF 'CONSUL_HTTP_TOKEN_FILE'; then
    fail 'entrypoint does not pass CONSUL_HTTP_TOKEN_FILE to litefs' 'the litefs start line still sets CONSUL_HTTP_TOKEN_FILE'
  else
    pass 'entrypoint does not pass CONSUL_HTTP_TOKEN_FILE to litefs'
  fi
}

# Check that the LiteFS policy allows the hostname-based session name.
# LiteFS creates a Consul session named after the hostname, not "litefs".
check_litefs_policy_rules() {
  local entrypoint="$REPO_ROOT/state/tinyauth/entrypoint.sh"
  local rules

  rules="$(grep -F 'POLICY_RULES_JSON=' "$entrypoint" || true)"
  if printf '%s\n' "$rules" | grep -qF 'session_prefix \"\"'; then
    pass 'litefs policy uses session_prefix'
  else
    fail 'litefs policy uses session_prefix' 'the policy rules do not use session_prefix'
  fi
  if printf '%s\n' "$rules" | grep -qF 'session \"litefs\"'; then
    fail 'litefs policy no longer names the litefs session' 'the policy rules still name the litefs session'
  else
    pass 'litefs policy no longer names the litefs session'
  fi
}

# Check that the entrypoint updates an existing policy when its rules differ.
check_litefs_policy_update() {
  local entrypoint="$REPO_ROOT/state/tinyauth/entrypoint.sh"

  # The patterns are literal script text, not shell variables.
  # shellcheck disable=SC2016
  if grep -qF '"$CONSUL_ADDR/v1/acl/policy/$policy_id"' "$entrypoint"; then
    pass 'entrypoint has a litefs policy update path'
  else
    fail 'entrypoint has a litefs policy update path' 'the entrypoint has no policy update URL'
  fi
  # shellcheck disable=SC2016
  if grep -qF 'if [ "$existing_rules" = "$POLICY_RULES_JSON" ]' "$entrypoint"; then
    pass 'entrypoint compares the existing litefs policy rules'
  else
    fail 'entrypoint compares the existing litefs policy rules' 'the entrypoint does not compare the existing rules'
  fi
}

# Check the Caddy vhost descriptor. The descriptor sends writes to the LiteFS
# primary. The file holds no secret values.
check_vhost_descriptor() {
  local descriptor="$REPO_ROOT/state/tinyauth/vhost.json"
  local content keys name mode upstream redirects

  if [ ! -f "$descriptor" ]; then
    fail 'vhost descriptor exists' 'the file is missing'
    return 0
  fi
  pass 'vhost descriptor exists'

  content="$(<"$descriptor")"

  name="$(printf '%s\n' "$content" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ "$name" = 'tinyauth' ]; then
    pass 'vhost descriptor names tinyauth'
  else
    fail 'vhost descriptor names tinyauth' 'the name field is wrong'
  fi

  mode="$(printf '%s\n' "$content" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ "$mode" = 'litefs' ]; then
    pass 'vhost descriptor uses the litefs mode'
  else
    fail 'vhost descriptor uses the litefs mode' 'the mode field is wrong'
  fi

  upstream="$(printf '%s\n' "$content" | sed -n 's/.*"upstream"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ "$upstream" = 'http://tinyauth:3000' ]; then
    pass 'vhost descriptor uses the tinyauth upstream'
  else
    fail 'vhost descriptor uses the tinyauth upstream' 'the upstream field is wrong'
  fi

  redirects="$(printf '%s\n' "$content" | sed -n 's/.*"redirect_paths"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [ "$redirects" = '[]' ]; then
    pass 'vhost descriptor has an empty redirect list'
  else
    fail 'vhost descriptor has an empty redirect list' 'the redirect_paths field is wrong'
  fi

  keys="$(grep -o '"[a-z_]*"[[:space:]]*:' "$descriptor" | sed 's/[[:space:]]*:$//' | tr -d '"' | sort | tr '\n' ' ')"
  if [ "$keys" = 'mode name redirect_paths upstream ' ]; then
    pass 'vhost descriptor holds no secret values'
  else
    fail 'vhost descriptor holds no secret values' 'the file holds an unexpected field'
  fi
}

# Check that the entrypoint takes the run identity from the environment.
# Rootless nerdctl sets both values to 0.
check_entrypoint_exec_identity() {
  local litefs="$scratch/run/litefs.yml"

  render_entrypoint 'http://consul:8500' 1 0 0 0 0
  if grep -qx 'exec: "gosu 0:0 /tinyauth/tinyauth"' "$litefs"; then
    pass 'entrypoint takes EXEC_UID and EXEC_GID from the environment'
  else
    fail 'entrypoint takes EXEC_UID and EXEC_GID from the environment' 'the exec line is not gosu 0:0'
  fi
}

# Check that the compose fragment passes the stack identity to the app.
check_compose_exec_identity() {
  local fragment="$REPO_ROOT/compose/tinyauth.yaml"

  # The grep pattern is literal script text, not a shell variable.
  # shellcheck disable=SC2016
  if grep -qF 'EXEC_UID=${STACK_UID:-1000}' "$fragment"; then
    pass 'compose fragment passes STACK_UID to EXEC_UID'
  else
    fail 'compose fragment passes STACK_UID to EXEC_UID' 'the EXEC_UID line is missing'
  fi
  # shellcheck disable=SC2016
  if grep -qF 'EXEC_GID=${STACK_GID:-1000}' "$fragment"; then
    pass 'compose fragment passes STACK_GID to EXEC_GID'
  else
    fail 'compose fragment passes STACK_GID to EXEC_GID' 'the EXEC_GID line is missing'
  fi
}

# Run the wizard with a fake chown that records each call.
# The fake chown returns success and changes no real file owner.
run_wizard_with_identity() {
  local rootless="$1" uid="$2" gid="$3" log="$4"
  local observer_pass
  observer_pass="$(openssl rand -hex 8)"
  : >"$scratch/chown.calls"
  (
    cd "$scratch"
    CHOWN_LOG="$scratch/chown.calls" \
      PATH="$scratch/fake-chown-bin:$PATH" \
      STACK_ROOTLESS="$rootless" \
      STACK_UID="$uid" \
      STACK_GID="$gid" \
      CONSUL_ADDR='https://consul.remote.example:8500' \
      TINYAUTH_LDAP_LOCAL=yes \
      TINYAUTH_LDAP_BASEDN='dc=sh,dc=lan' \
      TINYAUTH_CLIENTS='demo:https://demo.sh.lan/callback' \
      TINYAUTH_OBSERVER_AUTO=no \
      TINYAUTH_LDAP_BINDPASSWORD="$observer_pass" \
      bash "$scratch/state/tinyauth/setup.sh"
  ) >"$log" 2>&1
}

# Check that the wizard skips the OIDC key chown in rootless mode and uses the
# stack identity in rootful mode.
check_rootless_wizard_ownership() {
  local fake_bin="$scratch/fake-chown-bin"
  local calls="$scratch/chown.calls"

  mkdir -p "$fake_bin"
  cat >"$fake_bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CHOWN_LOG:?}"
EOF
  chmod +x "$fake_bin/chown"

  if ! run_wizard_with_identity 1 0 0 "$scratch/wizard-rootless.log"; then
    fail 'rootless wizard runs' 'the wizard exited with an error'
    return 0
  fi
  if [ -s "$calls" ]; then
    fail 'rootless wizard skips the OIDC key chown' 'the wizard called chown'
  else
    pass 'rootless wizard skips the OIDC key chown'
  fi

  if ! run_wizard_with_identity 0 1234 1235 "$scratch/wizard-rootful.log"; then
    fail 'rootful wizard runs' 'the wizard exited with an error'
    return 0
  fi
  if grep -qF '1234:1235' "$calls"; then
    pass 'rootful wizard chowns the OIDC keys to STACK_UID:STACK_GID'
  else
    fail 'rootful wizard chowns the OIDC keys to STACK_UID:STACK_GID' 'the chown target is wrong'
  fi
}

# Check the engine diagnostic and the engine selection in the wizard.
check_engine_selection() {
  local fake_bin="$scratch/fake-bin"
  local setup="$REPO_ROOT/state/tinyauth/setup.sh"
  local engine custom

  mkdir -p "$fake_bin"
  cat >"$fake_bin/nerdctl" <<'EOF'
#!/usr/bin/env bash
printf 'fake nerdctl\n'
EOF
  chmod +x "$fake_bin/nerdctl"

  if engine="$(env -u CONTAINER_ENGINE PATH="$fake_bin:$PATH" \
    bash "$REPO_ROOT/setup.sh" tinyauth engine 2>"$scratch/engine.err")" &&
    [ "$engine" = 'nerdctl' ]; then
    pass 'engine subcommand selects nerdctl from PATH'
  else
    fail 'engine subcommand selects nerdctl from PATH' "observed '$engine'"
  fi

  custom="$scratch/custom-engine"
  if engine="$(CONTAINER_ENGINE="$custom" PATH="$fake_bin:$PATH" \
    bash "$REPO_ROOT/setup.sh" tinyauth engine 2>>"$scratch/engine.err")" &&
    [ "$engine" = "$custom" ]; then
    pass 'engine subcommand prefers CONTAINER_ENGINE'
  else
    fail 'engine subcommand prefers CONTAINER_ENGINE' "observed '$engine'"
  fi

  # The grep pattern is literal script text, not a shell variable.
  # shellcheck disable=SC2016
  if grep -qF '"$engine" compose exec' "$setup" &&
    ! grep -qF 'docker compose exec' "$setup"; then
    pass 'wizard uses the selected engine for compose exec'
  else
    fail 'wizard uses the selected engine for compose exec' 'the compose exec call is not engine-based'
  fi
}

scratch="$(mktemp -d /tmp/tinyauth-smoke.XXXXXX)"
setup_tree
check_vhost_descriptor
check_consul_flag_removed
check_engine_selection
check_entrypoint_exec_identity
check_compose_exec_identity
check_wizard_idempotence
check_oidc_key_modes
check_pkcs1_key_source
check_pkcs8_key_conversion
check_rootless_wizard_ownership
check_standalone_wizard
check_integrated_wizard
check_local_consul_litefs_off
check_standalone_entrypoint
check_integrated_entrypoint
check_remote_token_selection
check_litefs_consul_token
check_litefs_policy_rules
check_litefs_policy_update

printf 'smoke checks: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
