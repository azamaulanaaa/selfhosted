#!/bin/sh
# Check that the Forgejo templates render in both stack modes.
# Each check writes output into a scratch tree. No Consul agent is required.
set -eu

REPO_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
readonly REPO_ROOT

readonly STATE_DIR="$REPO_ROOT/state/forgejo"
readonly RENDER="$STATE_DIR/render.sh"
readonly APP_TPL="$STATE_DIR/app.ini.tpl"
readonly HOOK_TPL="$STATE_DIR/post-receive.tpl"

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

# Render the standalone mode into the scratch tree.
render_standalone() {
  mode_dir="$scratch/standalone"
  mkdir -p "$mode_dir/out" "$mode_dir/secrets"
  printf 'test-secret-key' >"$mode_dir/secrets/secret-key"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    CONSUL_ENABLED=0 \
    LITEFS_ENABLED=0 \
    OIDC_ENABLED=0 \
    TLS_ENABLED=0 \
    STACK_DOMAIN=sh.lan \
    PUBLIC_IP=127.0.0.1 \
    FORGEJO_APP_NAME=Forgejo \
    sh "$RENDER" "$APP_TPL" "$mode_dir/out/app.ini"
  env \
    SECRET_FILE_ROOT="$mode_dir/secrets" \
    CONSUL_ENABLED=0 \
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
    CONSUL_ENABLED=1 \
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
    CONSUL_ENABLED=1 \
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
    CONSUL_ENABLED=0 \
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
echo "smoke: all render checks passed."
