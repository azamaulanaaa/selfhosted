#!/usr/bin/env bash
# Check the Vaultwarden wizard in standalone and integrated modes.
# Standalone means remote Consul, an external OIDC issuer, and an external
# HTTPS reverse proxy. Integrated means local Tinyauth and local Caddy.
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

skip() {
  printf 'SKIP %s\n' "$1"
}

# Build a scratch tree with the service wizard. Add a fake local Tinyauth when
# the first argument is "tinyauth".
new_tree() {
  local name="$1" with_tinyauth="${2:-no}"
  local tree="$scratch/$name"
  mkdir -p "$tree/state/vaultwarden"
  cp -- "$REPO_ROOT/state/vaultwarden/setup.sh" "$tree/state/vaultwarden/setup.sh"
  if [ "$with_tinyauth" = "yes" ]; then
    mkdir -p "$tree/state/tinyauth" "$tree/config/tinyauth/secrets/oidc"
    : >"$tree/state/tinyauth/setup.sh"
  fi
  printf '%s\n' "$tree"
}

# Write the shared root .env file for one scratch tree.
# CONSUL_ADDR is present because the root setup requires Consul. This wizard
# must ignore it.
write_root_env() {
  local tree="$1"
  local consul_addr="$2"
  {
    printf 'STACK_DOMAIN=example.test\n'
    printf 'PUBLIC_IP=192.0.2.10\n'
    printf 'CONSUL_ADDR=%s\n' "$consul_addr"
  } >"$tree/.env"
}

# Run the wizard in a scratch tree without an interactive terminal.
# Drop inherited wizard variables so one test cannot affect the next.
run_wizard() {
  local tree="$1"
  shift
  (
    cd "$tree"
    env -u STACK_DOMAIN -u VAULTWARDEN_DOMAIN -u VAULTWARDEN_OIDC_ISSUER \
      -u VAULTWARDEN_OIDC_CLIENT_ID -u VAULTWARDEN_OIDC_CLIENT_SECRET \
      -u VAULTWARDEN_SSO_SIGNUPS -u VAULTWARDEN_ROTATE_OIDC_SECRET \
      -u VAULTWARDEN_ADMIN_TOKEN -u VAULTWARDEN_SMTP_HOST \
      -u VAULTWARDEN_SMTP_FROM -u VAULTWARDEN_SMTP_PORT \
      -u VAULTWARDEN_SMTP_SECURITY -u VAULTWARDEN_SMTP_USERNAME \
      -u VAULTWARDEN_SMTP_PASSWORD \
      "$@" bash "$tree/state/vaultwarden/setup.sh" </dev/null
  ) >>"$tree/wizard.log" 2>&1
}

# Run the clean subcommand in a scratch tree.
run_clean() {
  local tree="$1"
  shift
  (
    cd "$tree"
    bash "$tree/state/vaultwarden/setup.sh" clean "$@"
  ) >>"$tree/clean.log" 2>&1
}

# Print the mode of one path. Support GNU and BSD stat.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

# Print the owner uid of one path.
file_owner() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null || printf 'unknown'
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

# Check that a file holds one expected line.
assert_line() {
  local file="$1" pattern="$2" description="$3"
  if [ ! -f "$file" ]; then
    fail "$description" "the file does not exist: $file"
    return 0
  fi
  if grep -Fqx -- "$pattern" "$file"; then
    pass "$description"
  else
    fail "$description" "expected line: $pattern"
  fi
}

# Check that a file does not hold a line that contains one pattern.
assert_no_line() {
  local file="$1" pattern="$2" description="$3"
  if [ ! -f "$file" ]; then
    fail "$description" "the file does not exist: $file"
    return 0
  fi
  if grep -Fq -- "$pattern" "$file"; then
    fail "$description" "unexpected text: $pattern"
  else
    pass "$description"
  fi
}

# Check that a file is absent.
assert_file_absent() {
  local path="$1" description="$2"
  if [ -e "$path" ]; then
    fail "$description" "the path exists: $path"
  else
    pass "$description"
  fi
}

# Check the mode of one path.
assert_mode() {
  local path="$1" expected="$2" description="$3"
  if [ ! -e "$path" ]; then
    fail "$description" "the path does not exist: $path"
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

# Check that a file holds exactly one value. Never print the value.
assert_content() {
  local path="$1" expected="$2" description="$3"
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
    sha256sum config/vaultwarden/vaultwarden.env \
      config/vaultwarden/secrets/oidc-client-secret
  )
}

# Check the common environment keys and the disabled features.
check_env_shape() {
  local env="$1"
  assert_line "$env" 'SSO_ENABLED=true' 'config enables SSO'
  assert_line "$env" 'SSO_ONLY=true' 'config uses SSO only'
  assert_line "$env" 'SSO_CLIENT_SECRET_FILE=/run/secrets/vaultwarden/oidc-client-secret' 'config reads the OIDC secret from a file'
  assert_line "$env" 'SSO_SCOPES=email profile' 'config uses the email and profile scopes'
  assert_line "$env" 'SSO_PKCE=true' 'config enables PKCE'
  assert_line "$env" 'SSO_SIGNUPS_MATCH_EMAIL=true' 'config matches signups by email'
  assert_line "$env" 'SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION=false' 'config requires a verified email'
  assert_line "$env" 'SIGNUPS_ALLOWED=false' 'config disables password signups'
  assert_line "$env" 'SENDS_ALLOWED=false' 'config disables secure Sends'
  assert_line "$env" 'USER_ATTACHMENT_LIMIT=0' 'config disables user attachments'
  assert_line "$env" 'ORG_ATTACHMENT_LIMIT=0' 'config disables organization attachments'
  assert_line "$env" 'USER_SEND_LIMIT=0' 'config disables user Sends'
  assert_line "$env" 'SIGNUPS_VERIFY=false' 'config disables email verification'
  assert_line "$env" 'REQUIRE_DEVICE_EMAIL=false' 'config does not require device email'
  assert_line "$env" 'ENABLE_WEBSOCKET=true' 'config enables WebSocket support'
  assert_line "$env" 'IP_HEADER=X-Real-IP' 'config reads the Caddy real IP header'
  assert_no_line "$env" 'SENDS_ALLOWED=true' 'config never enables Sends'
  assert_no_line "$env" 'ADMIN_TOKEN=' 'config holds no admin token value'
  assert_no_line "$env" 'SMTP_PASSWORD=' 'config holds no SMTP password value'
  assert_no_line "$env" 'ADMIN_TOKEN_FILE' 'config holds no admin token path without a file'
  assert_no_line "$env" 'SMTP_PASSWORD_FILE' 'config holds no SMTP password path without a file'
  assert_no_line "$env" 'SMTP_' 'config does not set SMTP'
  assert_no_line "$env" 'S3_' 'config sets no S3 option'
  assert_no_line "$env" 'CONSUL_ADDR' 'config holds no Consul address'
  assert_no_line "$env" 'CONSUL_ENABLED' 'config holds no removed Consul flag'
}

# Check the generated files and modes.
check_file_modes() {
  local tree="$1" secret="$2"
  assert_mode "$tree/config/vaultwarden/vaultwarden.env" 600 'environment file has mode 600'
  assert_mode "$tree/config/vaultwarden/secrets" 700 'secret directory has mode 700'
  assert_mode "$secret" 600 'OIDC secret file has mode 600'
  assert_mode "$tree/data/vaultwarden/store" 700 'data store directory has mode 700'
}

# Check the mode of the OIDC secret when the environment can set uid 1000.
check_secret_owner() {
  local tree="$1" label="$2"
  if ! can_chown_to_app_uid; then
    skip "$label skips the secret owner check because this environment blocks chown"
    return 0
  fi
  local owner
  owner="$(file_owner "$tree/config/vaultwarden/secrets/oidc-client-secret")"
  if [ "$owner" = '1000' ]; then
    pass "$label gives the OIDC secret owner uid 1000"
  else
    fail "$label gives the OIDC secret owner uid 1000" "observed uid $owner"
  fi
  owner="$(file_owner "$tree/data/vaultwarden/store")"
  if [ "$owner" = '1000' ]; then
    pass "$label gives the data store owner uid 1000"
  else
    fail "$label gives the data store owner uid 1000" "observed uid $owner"
  fi
}

# Check standalone mode with remote Consul, an external issuer, and an
# external HTTPS reverse proxy.
check_standalone() {
  local tree secret env before after
  tree="$(new_tree standalone)"
  write_root_env "$tree" 'https://consul.remote.example:8500'
  secret="smoke-standalone-secret-$(openssl rand -hex 8)"
  secret_values+=("$secret")

  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_ID=vaultwarden \
    VAULTWARDEN_OIDC_CLIENT_SECRET="$secret"; then
    fail 'standalone wizard runs' "read $tree/wizard.log"
    return 0
  fi
  pass 'standalone wizard runs'

  env="$tree/config/vaultwarden/vaultwarden.env"
  assert_line "$env" 'DOMAIN=https://vaultwarden.example.test' 'standalone wizard derives the public URL'
  assert_line "$env" 'SSO_AUTHORITY=https://auth.example.test' 'standalone wizard uses the external issuer'
  assert_line "$env" 'SSO_CLIENT_ID=vaultwarden' 'standalone wizard writes the client ID'
  assert_line "$env" 'SSO_SIGNUPS_ALLOWED=true' 'standalone wizard allows SSO signups by default'
  check_env_shape "$env"
  check_file_modes "$tree" "$tree/config/vaultwarden/secrets/oidc-client-secret"
  assert_content "$tree/config/vaultwarden/secrets/oidc-client-secret" "$secret" 'standalone wizard writes the client secret'
  check_secret_owner "$tree" 'standalone wizard'

  if grep -q 'standalone' "$tree/wizard.log"; then
    fail 'standalone wizard log avoids the mode word' 'the log says standalone'
  else
    pass 'standalone wizard log avoids the mode word'
  fi

  before="$(file_checksums "$tree")"
  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_ID=vaultwarden \
    VAULTWARDEN_OIDC_CLIENT_SECRET="$secret"; then
    fail 'second standalone wizard run succeeds' "read $tree/wizard.log"
    return 0
  fi
  after="$(file_checksums "$tree")"
  if [ "$before" = "$after" ]; then
    pass 'second standalone wizard run is idempotent'
  else
    fail 'second standalone wizard run is idempotent' 'a generated file changed'
  fi

  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_ID=vaultwarden \
    VAULTWARDEN_OIDC_CLIENT_SECRET="$secret" \
    VAULTWARDEN_SSO_SIGNUPS=no; then
    fail 'standalone wizard accepts VAULTWARDEN_SSO_SIGNUPS=no' "read $tree/wizard.log"
    return 0
  fi
  assert_line "$env" 'SSO_SIGNUPS_ALLOWED=false' 'standalone wizard applies the no signup answer'
}

# Check integrated mode with a local Tinyauth setup script and secret file.
check_integrated() {
  local tree first_secret second_secret env
  tree="$(new_tree integrated yes)"
  write_root_env "$tree" 'http://consul:8500'
  first_secret="smoke-tinyauth-first-$(openssl rand -hex 8)"
  second_secret="smoke-tinyauth-second-$(openssl rand -hex 8)"
  secret_values+=("$first_secret" "$second_secret")
  printf '%s' "$first_secret" >"$tree/config/tinyauth/secrets/oidc/vaultwarden"
  chmod 0600 "$tree/config/tinyauth/secrets/oidc/vaultwarden"

  if ! run_wizard "$tree" STACK_DOMAIN=example.test; then
    fail 'integrated wizard runs' "read $tree/wizard.log"
    return 0
  fi
  pass 'integrated wizard runs'

  env="$tree/config/vaultwarden/vaultwarden.env"
  assert_line "$env" 'DOMAIN=https://vaultwarden.example.test' 'integrated wizard derives the public URL'
  assert_line "$env" 'SSO_AUTHORITY=https://tinyauth.example.test' 'integrated wizard defaults to the local Tinyauth issuer'
  assert_line "$env" 'SSO_CLIENT_ID=vaultwarden' 'integrated wizard defaults to the vaultwarden client'
  assert_line "$env" 'SSO_SIGNUPS_ALLOWED=true' 'integrated wizard allows SSO signups by default'
  check_env_shape "$env"
  check_file_modes "$tree" "$tree/config/vaultwarden/secrets/oidc-client-secret"
  assert_content "$tree/config/vaultwarden/secrets/oidc-client-secret" "$first_secret" 'integrated wizard reads the Tinyauth client secret'
  check_secret_owner "$tree" 'integrated wizard'
  if grep -q "Using the Tinyauth client secret at" "$tree/wizard.log"; then
    fail 'non-interactive integrated wizard prints no secret path note' 'the log holds the interactive note'
  else
    pass 'non-interactive integrated wizard prints no secret path note'
  fi
  if grep -q '^Tinyauth: local at https://tinyauth.example.test$' "$tree/wizard.log"; then
    pass 'integrated wizard reports the local Tinyauth issuer'
  else
    fail 'integrated wizard reports the local Tinyauth issuer' 'the Tinyauth line is wrong'
  fi

  # A new Tinyauth secret must reach the Vaultwarden secret file on the next run.
  printf '%s' "$second_secret" >"$tree/config/tinyauth/secrets/oidc/vaultwarden"
  chmod 0600 "$tree/config/tinyauth/secrets/oidc/vaultwarden"
  if ! run_wizard "$tree" STACK_DOMAIN=example.test; then
    fail 'integrated wizard runs after a Tinyauth secret change' "read $tree/wizard.log"
    return 0
  fi
  assert_content "$tree/config/vaultwarden/secrets/oidc-client-secret" "$second_secret" 'integrated wizard syncs a changed Tinyauth secret'

  # An explicit issuer overrides the local default.
  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test; then
    fail 'integrated wizard accepts an issuer override' "read $tree/wizard.log"
    return 0
  fi
  assert_line "$env" 'SSO_AUTHORITY=https://auth.example.test' 'integrated wizard applies the issuer override'
}

# Check that the wizard accepts the optional admin and SMTP values without a
# prompt. The values are secret files and never appear in a log.
check_optional_settings() {
  local tree admin smtp_password env admin_file smtp_file
  tree="$(new_tree optional)"
  write_root_env "$tree" 'https://consul.remote.example:8500'
  admin="smoke-admin-$(openssl rand -hex 8)"
  smtp_password="smoke-smtp-$(openssl rand -hex 8)"
  secret_values+=("$admin" "$smtp_password")
  admin_file="$tree/config/vaultwarden/secrets/admin_token"
  smtp_file="$tree/config/vaultwarden/secrets/smtp_password"
  mkdir -p "$tree/config/vaultwarden"
  {
    printf 'ADMIN_TOKEN=old-direct-value\n'
    printf 'SMTP_PASSWORD=old-direct-value\n'
    printf 'KEEP_ME=yes\n'
  } >"$tree/config/vaultwarden/vaultwarden.env"

  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET=smoke-oidc-optional \
    VAULTWARDEN_ADMIN_TOKEN="$admin" \
    VAULTWARDEN_SMTP_HOST=mail.example.test \
    VAULTWARDEN_SMTP_FROM=vaultwarden@example.test \
    VAULTWARDEN_SMTP_PORT=587 \
    VAULTWARDEN_SMTP_SECURITY=starttls \
    VAULTWARDEN_SMTP_USERNAME=vaultwarden \
    VAULTWARDEN_SMTP_PASSWORD="$smtp_password"; then
    fail 'wizard accepts the optional admin and SMTP variables' "read $tree/wizard.log"
    return 0
  fi
  pass 'wizard accepts the optional admin and SMTP variables'

  env="$tree/config/vaultwarden/vaultwarden.env"
  assert_line "$env" 'ADMIN_TOKEN_FILE=/run/secrets/vaultwarden/admin_token' 'wizard writes the admin token file path'
  assert_line "$env" 'SMTP_PASSWORD_FILE=/run/secrets/vaultwarden/smtp_password' 'wizard writes the SMTP password file path'
  assert_no_line "$env" 'ADMIN_TOKEN=' 'wizard writes no admin token value'
  assert_no_line "$env" 'SMTP_PASSWORD=' 'wizard writes no SMTP password value'
  assert_line "$env" 'KEEP_ME=yes' 'wizard keeps unmanaged lines'
  assert_line "$env" 'SMTP_HOST=mail.example.test' 'wizard writes the optional SMTP host'
  assert_line "$env" 'SMTP_FROM=vaultwarden@example.test' 'wizard writes the optional SMTP sender'
  assert_line "$env" 'SMTP_PORT=587' 'wizard writes the optional SMTP port'
  assert_line "$env" 'SMTP_SECURITY=starttls' 'wizard writes the optional SMTP security mode'
  assert_line "$env" 'SMTP_USERNAME=vaultwarden' 'wizard writes the optional SMTP username'
  assert_mode "$env" 600 'optional settings keep the environment file mode 600'
  assert_mode "$admin_file" 600 'admin token file has mode 600'
  assert_mode "$smtp_file" 600 'SMTP password file has mode 600'
  assert_content "$admin_file" "$admin" 'wizard writes the admin token file'
  assert_content "$smtp_file" "$smtp_password" 'wizard writes the SMTP password file'

  if can_chown_to_app_uid; then
    local owner
    owner="$(file_owner "$admin_file")"
    if [ "$owner" = '1000' ]; then
      pass 'admin token file has owner uid 1000'
    else
      fail 'admin token file has owner uid 1000' "observed uid $owner"
    fi
    owner="$(file_owner "$smtp_file")"
    if [ "$owner" = '1000' ]; then
      pass 'SMTP password file has owner uid 1000'
    else
      fail 'SMTP password file has owner uid 1000' "observed uid $owner"
    fi
  else
    skip 'optional secret owner check skipped because this environment blocks chown'
  fi

  # A run without the secret variables keeps the existing files and the paths.
  if ! run_wizard "$tree" STACK_DOMAIN=example.test; then
    fail 'wizard runs again without the optional secret variables' "read $tree/wizard.log"
    return 0
  fi
  assert_line "$env" 'ADMIN_TOKEN_FILE=/run/secrets/vaultwarden/admin_token' 'rerun keeps the admin token path when the file exists'
  assert_line "$env" 'SMTP_PASSWORD_FILE=/run/secrets/vaultwarden/smtp_password' 'rerun keeps the SMTP password path when the file exists'
  assert_content "$admin_file" "$admin" 'rerun keeps the admin token file'
  assert_content "$smtp_file" "$smtp_password" 'rerun keeps the SMTP password file'

  # Remove the files. The next run must not write the _FILE paths.
  rm -f "$admin_file" "$smtp_file"
  if ! run_wizard "$tree" STACK_DOMAIN=example.test; then
    fail 'wizard runs again after the optional secret files are removed' "read $tree/wizard.log"
    return 0
  fi
  assert_no_line "$env" 'ADMIN_TOKEN_FILE' 'no admin token path without the file'
  assert_no_line "$env" 'SMTP_PASSWORD_FILE' 'no SMTP password path without the file'
  assert_file_absent "$admin_file" 'no admin token file is created without the variable'
  assert_file_absent "$smtp_file" 'no SMTP password file is created without the variable'
}

# Check that the wizard rejects bad answers.
check_validation() {
  local tree
  tree="$(new_tree validation)"
  write_root_env "$tree" 'https://consul.remote.example:8500'

  if run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET=test-secret; then
    fail 'wizard requires an OIDC issuer' 'the wizard accepted a missing issuer'
  else
    pass 'wizard requires an OIDC issuer'
  fi

  if run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=http://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET=test-secret; then
    fail 'wizard requires an HTTPS OIDC issuer' 'the wizard accepted an HTTP issuer'
  else
    pass 'wizard requires an HTTPS OIDC issuer'
  fi

  if run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET=test-secret \
    VAULTWARDEN_SSO_SIGNUPS=maybe; then
    fail 'wizard requires a yes or no signup answer' 'the wizard accepted maybe'
  else
    pass 'wizard requires a yes or no signup answer'
  fi

  if run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_ID='bad client' \
    VAULTWARDEN_OIDC_CLIENT_SECRET=test-secret; then
    fail 'wizard rejects a client ID with whitespace' 'the wizard accepted a bad client ID'
  else
    pass 'wizard rejects a client ID with whitespace'
  fi

  if run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET=test-secret \
    VAULTWARDEN_ROTATE_OIDC_SECRET=2; then
    fail 'wizard rejects an invalid rotation flag' 'the wizard accepted 2'
  else
    pass 'wizard rejects an invalid rotation flag'
  fi
}

# Check that the clean subcommand keeps the data without --data.
check_clean() {
  local tree secret
  tree="$(new_tree clean)"
  write_root_env "$tree" 'http://consul:8500'
  secret="smoke-clean-secret-$(openssl rand -hex 8)"
  secret_values+=("$secret")
  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET="$secret"; then
    fail 'clean test wizard runs' "read $tree/wizard.log"
    return 0
  fi
  printf 'payload' >"$tree/data/vaultwarden/store/db.sqlite3"

  if ! run_clean "$tree" --yes; then
    fail 'clean removes the configuration' "read $tree/clean.log"
    return 0
  fi
  assert_file_absent "$tree/config/vaultwarden" 'clean removes config/vaultwarden'
  if [ -f "$tree/data/vaultwarden/store/db.sqlite3" ]; then
    pass 'clean keeps the data without --data'
  else
    fail 'clean keeps the data without --data' 'the data file is missing'
  fi

  if ! run_wizard "$tree" \
    STACK_DOMAIN=example.test \
    VAULTWARDEN_OIDC_ISSUER=https://auth.example.test \
    VAULTWARDEN_OIDC_CLIENT_SECRET="$secret"; then
    fail 'wizard runs again after clean' "read $tree/wizard.log"
    return 0
  fi
  if ! run_clean "$tree" --data --yes; then
    fail 'clean --data removes the data' "read $tree/clean.log"
    return 0
  fi
  assert_file_absent "$tree/data/vaultwarden" 'clean --data removes data/vaultwarden'
}

# Check the compose fragment and its contract.
check_compose_fragment() {
  local fragment="$REPO_ROOT/compose/vaultwarden.yaml"
  if [ ! -f "$fragment" ]; then
    fail 'compose fragment exists' "the file is missing: $fragment"
    return 0
  fi
  pass 'compose fragment exists'
  assert_line "$fragment" '    image: vaultwarden/server:1.37.4' 'fragment uses the official image tag'
  assert_line "$fragment" '    container_name: vaultwarden' 'fragment sets the container name'
  assert_line "$fragment" '    user: "1000:1000"' 'fragment runs as uid 1000'
  assert_line "$fragment" '      - SSO_CLIENT_SECRET_FILE=/run/secrets/vaultwarden/oidc-client-secret' 'fragment sets the OIDC secret file path'
  assert_line "$fragment" '      - ./config/vaultwarden/secrets:/run/secrets/vaultwarden:ro' 'fragment mounts the secret directory read-only'
  assert_no_line "$fragment" './config/vaultwarden/secrets/oidc-client-secret:/run/secrets/oidc-client-secret' 'fragment has no old single-file secret mount'
  assert_line "$fragment" '      - ./data/vaultwarden/store:/data:rw' 'fragment mounts the data store read-write'
  assert_line "$fragment" '      - target: 80' 'fragment targets container port 80'
  assert_line "$fragment" '        published: 8080' 'fragment publishes port 8080'
  # shellcheck disable=SC2016
  assert_line "$fragment" '        host_ip: ${PUBLIC_IP:-127.0.0.1}' 'fragment binds the published port to PUBLIC_IP'
  assert_line "$fragment" '    restart: unless-stopped' 'fragment sets the restart policy'
  assert_no_line "$fragment" 'CONSUL_ADDR' 'fragment holds no Consul address'
  assert_no_line "$fragment" 'CONSUL_ENABLED' 'fragment holds no removed Consul flag'
  assert_no_line "$fragment" 'S3_' 'fragment sets no S3 option'
  if grep -Fq 'Caddy proxies' "$fragment"; then
    pass 'fragment documents the Caddy proxy in the header'
  else
    fail 'fragment documents the Caddy proxy in the header' 'the header does not name Caddy'
  fi
}

# Check the scaling manifest.
check_scaling_manifest() {
  local manifest="$REPO_ROOT/state/vaultwarden/scaling.tsv"
  if [ ! -f "$manifest" ]; then
    fail 'scaling manifest exists' "the file is missing: $manifest"
    return 0
  fi
  pass 'scaling manifest exists'
  local bad
  bad="$(awk -F '\t' '!/^#/ && NF != 0 && NF != 6 { print NR }' "$manifest")"
  if [ -z "$bad" ]; then
    pass 'scaling manifest rows have six columns'
  else
    fail 'scaling manifest rows have six columns' "bad rows: $bad"
  fi
  assert_line "$manifest" $'config/vaultwarden/vaultwarden.env\t600\tnode-local\tboth\trequired\tWizard answers and secret file paths. The wizard creates it on each node.' 'manifest marks the env file node-local'
  assert_line "$manifest" $'config/vaultwarden/secrets/oidc-client-secret\t600\tshared\tboth\trequired\tOIDC client secret. It must match the Tinyauth client on every node.' 'manifest marks the OIDC secret shared'
  assert_line "$manifest" $'config/vaultwarden/secrets/admin_token\t600\tshared\tboth\toptional\tOptional admin token. The wizard writes it when VAULTWARDEN_ADMIN_TOKEN is set.' 'manifest marks the admin token optional and shared'
  assert_line "$manifest" $'config/vaultwarden/secrets/smtp_password\t600\tshared\tboth\toptional\tOptional SMTP password. The wizard writes it when VAULTWARDEN_SMTP_PASSWORD is set.' 'manifest marks the SMTP password optional and shared'
  assert_line "$manifest" $'config/vaultwarden/secrets\t700\tshared\tboth\trequired\tVaultwarden secret directory.' 'manifest marks the secret directory shared'
  assert_line "$manifest" $'data/vaultwarden/store\t700\tnode-local\tboth\trequired\tSQLite database and signing keys. Single-node only. Do not copy.' 'manifest marks the data store node-local'
}

# Check that no secret value appears in any log file.
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

scratch="$(mktemp -d /tmp/vaultwarden-smoke.XXXXXX)"
check_standalone
check_integrated
check_validation
check_optional_settings
check_clean
check_compose_fragment
check_scaling_manifest
check_logs_for_secrets

printf 'smoke checks: %d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
