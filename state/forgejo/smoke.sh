#!/bin/sh
# Check that the Forgejo templates render in the standalone and integrated modes.
# Check that the wizard, the entrypoint, and the compose fragment follow the
# Consul-first contract. Check that the vhost descriptor names forgejo and holds
# no secret values. Each render writes into a scratch tree. No Consul agent is
# required.
set -eu

REPO_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
readonly REPO_ROOT

readonly STATE_DIR="$REPO_ROOT/state/forgejo"
readonly RENDER="$STATE_DIR/render.sh"
readonly APP_TPL="$STATE_DIR/app.ini.tpl"
readonly HOOK_TPL="$STATE_DIR/post-receive.tpl"
readonly WIZARD="$STATE_DIR/setup.sh"
readonly ENTRYPOINT="$STATE_DIR/entrypoint.sh"
readonly COMPOSE_FILE="$REPO_ROOT/compose/forgejo.yaml"
readonly VHOST="$STATE_DIR/vhost.json"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT

# Stop with one clear message.
fail() {
  echo "smoke: error: $1" >&2
  exit 1
}

# Check that a file holds one exact line.
expect_line() {
  file="$1"
  text="$2"
  label="$3"
  if ! grep -Fqx -- "$text" "$file"; then
    fail "$label does not hold this line: $text"
  fi
}

# Check that a file does not hold one string.
expect_no_text() {
  file="$1"
  text="$2"
  label="$3"
  if grep -Fq -- "$text" "$file"; then
    fail "$label holds this text: $text"
  fi
}

# Check that a file holds one string.
expect_contains() {
  file="$1"
  text="$2"
  label="$3"
  if ! grep -Fq -- "$text" "$file"; then
    fail "$label does not hold this text: $text"
  fi
}

# Check that a file holds one JSON field with one exact string value.
expect_json_field() {
  file="$1"
  field="$2"
  value="$3"
  label="$4"
  if ! grep -Eq "\"$field\"[[:space:]]*:[[:space:]]*\"$value\"" "$file"; then
    fail "$label does not hold the field $field with the value $value."
  fi
}

# Check that a file is a valid shell script.
expect_valid_shell() {
  file="$1"
  label="$2"
  if ! sh -n "$file"; then
    fail "$label is not a valid shell script."
  fi
}

# Check that a file starts with a shebang.
expect_shebang() {
  file="$1"
  label="$2"
  first_line="$(head -n 1 "$file")"
  if [ "$first_line" != "#!/bin/sh" ]; then
    fail "$label does not start with a shebang."
  fi
}

# Print the lines of one service from the compose fragment.
service_block() {
  service="$1"
  awk -v name="  $service:" '
    $0 == name { inside = 1; print; next }
    inside && /^  [^ ]/ { exit }
    inside { print }
  ' "$COMPOSE_FILE"
}

# Check that both ports bind to PUBLIC_IP with the long syntax.
check_compose_port_bindings() {
  forgejo_block="$scratch/forgejo-service.yaml"
  peer_block="$scratch/peer-service.yaml"
  service_block forgejo >"$forgejo_block"
  service_block forgejo-peer-port >"$peer_block"

  expect_line "$forgejo_block" "      - target: 3000" "forgejo service"
  expect_line "$forgejo_block" "        published: 3000" "forgejo service"
  expect_line "$forgejo_block" "        host_ip: \${PUBLIC_IP:-127.0.0.1}" "forgejo service"
  expect_line "$forgejo_block" "        protocol: tcp" "forgejo service"
  expect_no_text "$forgejo_block" "\${PUBLIC_IP:-127.0.0.1}:3000:3000" "forgejo service"

  expect_line "$peer_block" "      - target: 20202" "peer service"
  expect_line "$peer_block" "        published: 20202" "peer service"
  expect_line "$peer_block" "        host_ip: \${PUBLIC_IP:-127.0.0.1}" "peer service"
  expect_line "$peer_block" "        protocol: tcp" "peer service"
  expect_no_text "$peer_block" "\${PUBLIC_IP:-127.0.0.1}:20202:20202" "peer service"
  echo "smoke: compose port bindings passed."
}

# Check that the peer service has no build section.
check_peer_service_no_build() {
  peer_block="$scratch/peer-build-check.yaml"
  service_block forgejo-peer-port >"$peer_block"
  if grep -Eq -- '^    build:' "$peer_block"; then
    fail "the peer service must not declare a build section."
  fi
  echo "smoke: peer service build check passed."
}

# Check that the wizard and the entrypoint follow the Consul-first contract.
check_consul_contract() {
  expect_contains "$WIZARD" 'CONSUL_ADDR' "wizard"
  expect_contains "$WIZARD" 'address = "%s"' "wizard consul-template output"
  expect_contains "$WIZARD" 'token_file = "/run/forgejo/consul-token"' "wizard consul-template output"
  expect_no_text "$WIZARD" 'CONSUL_ENABLED' "wizard"
  expect_no_text "$WIZARD" 'FORGEJO_USE_LOCAL_CONSUL' "wizard"
  expect_no_text "$WIZARD" 'FORGEJO_CONSUL_HOST' "wizard"
  expect_no_text "$WIZARD" 'FORGEJO_CONSUL_PORT' "wizard"
  expect_no_text "$WIZARD" 'FORGEJO_CONSUL_TOKEN' "wizard"

  expect_contains "$ENTRYPOINT" 'agent.hcl' "entrypoint"
  expect_contains "$ENTRYPOINT" 'remote-token' "entrypoint"
  expect_contains "$ENTRYPOINT" 'http://consul:8500' "entrypoint"
  expect_contains "$ENTRYPOINT" 'CONSUL_ADDR' "entrypoint"
  expect_contains "$ENTRYPOINT" 'LITEFS_ENABLED' "entrypoint"
  expect_no_text "$ENTRYPOINT" 'CONSUL_ENABLED' "entrypoint"
  expect_no_text "$ENTRYPOINT" 'render_local' "entrypoint"
  echo "smoke: Consul contract passed."
}

# Check that the templates gate their optional blocks on the right flags.
check_template_gates() {
  expect_contains "$APP_TPL" '{{ if eq (env "TLS_ENABLED") "1" }}' "app.ini template"
  expect_no_text "$APP_TPL" 'CONSUL_ENABLED' "app.ini template"
  expect_contains "$HOOK_TPL" '{{ if eq (env "LITEFS_ENABLED") "1" }}' "post-receive template"
  echo "smoke: template gates passed."
}

# Check that the compose fragment mounts the Consul secrets and passes CONSUL_ADDR.
check_compose_consul_contract() {
  block="$scratch/forgejo-consul-check.yaml"
  service_block forgejo >"$block"
  expect_contains "$block" "CONSUL_ADDR=\${CONSUL_ADDR:-http://consul:8500}" "forgejo service"
  expect_no_text "$block" "CONSUL_ENABLED" "forgejo service"
  expect_no_text "$block" "CONSUL_HTTP_ADDR" "forgejo service"
  expect_contains "$block" './config/consul/secrets:/config/consul/secrets:ro' "forgejo service"
  expect_no_text "$block" './config/consul/secrets/agent.hcl:/config/consul/agent.hcl:ro' "forgejo service"
  echo "smoke: compose Consul contract passed."
}

# Check that the vhost descriptor exists and names forgejo as a static vhost.
check_vhost_descriptor() {
  if [ ! -f "$VHOST" ]; then
    fail "the vhost descriptor is missing: $VHOST"
  fi
  expect_json_field "$VHOST" name forgejo "vhost descriptor"
  expect_json_field "$VHOST" mode static "vhost descriptor"
  expect_json_field "$VHOST" upstream 'http://forgejo:3000' "vhost descriptor"

  keys="$(grep -o '"[a-z_]*"[[:space:]]*:' "$VHOST" | sed -E 's/[":[:space:]]//g' | LC_ALL=C sort)"
  if [ "$keys" != "$(printf 'mode\nname\nupstream')" ]; then
    fail "the vhost descriptor holds fields other than name, mode, and upstream."
  fi
  echo "smoke: vhost descriptor passed."
}

# Check that the vhost descriptor holds no secret values.
check_vhost_no_secrets() {
  if grep -Eq '"(secret|token|password|passwd|key|credential)[a-z_-]*"[[:space:]]*:' "$VHOST"; then
    fail "the vhost descriptor holds a secret field. A secret value does not belong in state/."
  fi
  echo "smoke: vhost descriptor secret check passed."
}

# Render the standalone mode into the scratch tree.
render_standalone() {
  mode_dir="$scratch/standalone"
  mkdir -p "$mode_dir/out" "$mode_dir/secrets"
  printf 'test-secret-key' >"$mode_dir/secrets/secret-key"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    LITEFS_ENABLED=0 \
    OIDC_ENABLED=0 \
    TLS_ENABLED=0 \
    STACK_DOMAIN=sh.lan \
    PUBLIC_IP=127.0.0.1 \
    FORGEJO_APP_NAME=Forgejo \
    sh "$RENDER" "$APP_TPL" "$mode_dir/out/app.ini"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    LITEFS_ENABLED=0 \
    OIDC_ENABLED=0 \
    TLS_ENABLED=0 \
    STACK_DOMAIN=sh.lan \
    PUBLIC_IP=127.0.0.1 \
    FORGEJO_APP_NAME=Forgejo \
    sh "$RENDER" "$HOOK_TPL" "$mode_dir/out/post-receive"
}

# Check the standalone output.
check_standalone() {
  mode_dir="$scratch/standalone"
  app_ini="$mode_dir/out/app.ini"
  hook="$mode_dir/out/post-receive"
  expect_line "$app_ini" "APP_NAME = Forgejo" "standalone app.ini"
  expect_line "$app_ini" "DOMAIN = sh.lan" "standalone app.ini"
  expect_line "$app_ini" "ROOT_URL = http://127.0.0.1:3000/" "standalone app.ini"
  expect_line "$app_ini" "DB_TYPE = sqlite3" "standalone app.ini"
  expect_line "$app_ini" "ENABLED = false" "standalone app.ini"
  expect_line "$app_ini" "SECRET_KEY = test-secret-key" "standalone app.ini"
  expect_no_text "$app_ini" "CLIENT_ID" "standalone app.ini"
  expect_no_text "$app_ini" "OPENID_CONNECT_URL" "standalone app.ini"
  expect_no_text "$app_ini" "https://forgejo." "standalone app.ini"
  expect_shebang "$hook" "standalone post-receive hook"
  expect_line "$hook" "set -u" "standalone post-receive hook"
  expect_line "$hook" "exit 0" "standalone post-receive hook"
  expect_no_text "$hook" "git push" "standalone post-receive hook"
  expect_no_text "$hook" "{{" "standalone post-receive hook"
  expect_valid_shell "$hook" "standalone post-receive hook"
  echo "smoke: standalone mode passed."
}

# Render the integrated mode into the scratch tree.
render_integrated() {
  mode_dir="$scratch/integrated"
  mkdir -p "$mode_dir/out" "$mode_dir/secrets"
  printf 'test-secret-key' >"$mode_dir/secrets/secret-key"
  printf 'test-oidc-secret' >"$mode_dir/secrets/oidc-client-secret"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    LITEFS_ENABLED=1 \
    OIDC_ENABLED=1 \
    TLS_ENABLED=1 \
    STACK_DOMAIN=sh.lan \
    PUBLIC_IP=127.0.0.1 \
    FORGEJO_APP_NAME=Forgejo \
    FORGEJO_OIDC_PROVIDER_NAME=oidc \
    FORGEJO_OIDC_CLIENT_ID=forgejo-client \
    FORGEJO_OIDC_ISSUER_URL=https://auth.sh.lan \
    FORGEJO_OIDC_AUTO_REGISTER=true \
    FORGEJO_PEER_GIT_PORT=3000 \
    sh "$RENDER" "$APP_TPL" "$mode_dir/out/app.ini"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    LITEFS_ENABLED=1 \
    OIDC_ENABLED=1 \
    TLS_ENABLED=1 \
    STACK_DOMAIN=sh.lan \
    PUBLIC_IP=127.0.0.1 \
    FORGEJO_APP_NAME=Forgejo \
    FORGEJO_OIDC_PROVIDER_NAME=oidc \
    FORGEJO_OIDC_CLIENT_ID=forgejo-client \
    FORGEJO_OIDC_ISSUER_URL=https://auth.sh.lan \
    FORGEJO_OIDC_AUTO_REGISTER=true \
    FORGEJO_PEER_GIT_PORT=3000 \
    sh "$RENDER" "$HOOK_TPL" "$mode_dir/out/post-receive"
}

# Check the integrated output.
check_integrated() {
  mode_dir="$scratch/integrated"
  app_ini="$mode_dir/out/app.ini"
  hook="$mode_dir/out/post-receive"
  expect_line "$app_ini" "DOMAIN = sh.lan" "integrated app.ini"
  expect_line "$app_ini" "ROOT_URL = https://forgejo.sh.lan/" "integrated app.ini"
  expect_line "$app_ini" "ENABLED = true" "integrated app.ini"
  expect_line "$app_ini" "CLIENT_ID = forgejo-client" "integrated app.ini"
  expect_line "$app_ini" "CLIENT_SECRET = test-oidc-secret" "integrated app.ini"
  expect_line "$app_ini" "OPENID_CONNECT_URL = https://auth.sh.lan" "integrated app.ini"
  expect_line "$app_ini" "OPENID_CONNECT_SCOPES = openid,profile,email" "integrated app.ini"
  expect_no_text "$app_ini" "ENABLED = false" "integrated app.ini"
  expect_no_text "$app_ini" "http://127.0.0.1:3000/" "integrated app.ini"
  expect_shebang "$hook" "integrated post-receive hook"
  expect_line "$hook" "set -u" "integrated post-receive hook"
  expect_line "$hook" "exit 0" "integrated post-receive hook"
  expect_no_text "$hook" "{{" "integrated post-receive hook"
  expect_valid_shell "$hook" "integrated post-receive hook"
  echo "smoke: integrated mode passed."
}

# Check the sh.lan fallback when STACK_DOMAIN is not set.
check_domain_fallback() {
  mode_dir="$scratch/fallback"
  mkdir -p "$mode_dir/secrets"
  printf 'test-secret-key' >"$mode_dir/secrets/secret-key"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    LITEFS_ENABLED=0 \
    OIDC_ENABLED=0 \
    PUBLIC_IP=127.0.0.1 \
    sh "$RENDER" "$APP_TPL" "$mode_dir/app.ini"
  expect_line "$mode_dir/app.ini" "DOMAIN = sh.lan" "fallback app.ini"
  expect_line "$mode_dir/app.ini" "ROOT_URL = http://127.0.0.1:3000/" "fallback app.ini"
  echo "smoke: domain fallback passed."
}

render_standalone
check_standalone
render_integrated
check_integrated
check_domain_fallback
check_compose_port_bindings
check_peer_service_no_build
check_consul_contract
check_template_gates
check_compose_consul_contract
check_vhost_descriptor
check_vhost_no_secrets
echo "smoke: all checks passed."
