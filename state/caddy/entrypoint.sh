#!/bin/sh
# Start caddy in standalone mode or integrated mode.
# Standalone (CONSUL_ENABLED=0): render a static Caddyfile. No consul calls.
# Integrated (CONSUL_ENABLED=1): create the read ACL, render once with
# consul-template, supervise it, then run caddy in watch mode.
set -eu

CFG=/etc/consul-template/config.hcl
STATIC_TEMPLATE=/etc/consul-template/templates/Caddyfile.static.tpl
MANAGEMENT_FILE=/etc/caddy/consul-agent.hcl
CADDYFILE=/etc/caddy/Caddyfile
STORE=/data/caddy
CONSUL_ENABLED="${CONSUL_ENABLED:-0}"
STACK_DOMAIN="${STACK_DOMAIN:-sh.lan}"

# Docker creates a missing bind mount root as root-owned mode 0755. The
# container runs as root, so it owns the store and the ACME files in it.
# A backup must read the store with root privileges.
mkdir -p "$STORE"
chmod 0700 /data "$STORE"

# Print the commands that create the caddy read ACL by hand.
print_acl_commands() {
  echo "hint: Create the caddy read ACL policy with these commands." >&2
  echo "hint: 1. Read initial_management from config/consul/secrets/agent.hcl." >&2
  echo "hint: 2. Run: export CONSUL_HTTP_ADDR=$1" >&2
  echo "hint: 3. Run: export CONSUL_HTTP_TOKEN=<initial_management>" >&2
  printf '%s\n' "hint: 4. Run: printf 'service_prefix \"\" { policy = \"read\" }\\nkey_prefix \"\" { policy = \"read\" }\\n' > /tmp/caddy-read.hcl" >&2
  echo "hint: 5. Run: consul acl policy create -name caddy-read -rules @/tmp/caddy-read.hcl" >&2
  echo "hint: 6. Run: consul acl token create -description 'caddy read' -policy-name caddy-read" >&2
}

# Print the management token. Print nothing when the file is absent.
read_management_token() {
  [ -f "$MANAGEMENT_FILE" ] || return 0
  sed -n 's/.*initial_management[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$MANAGEMENT_FILE" | head -n1
}

# Print the consul address from the consul-template configuration.
read_consul_address() {
  sed -n 's/.*address[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$CFG" | head -n1
}

# Restart consul-template after a crash. Caddy must keep receiving updates.
supervise_consul_template() {
  while true; do
    consul-template -config="$CFG" || true
    echo "warning: consul-template stopped. Restart in 2 s." >&2
    sleep 2
  done
}

# Create the caddy read ACL policy and token. Write a runtime consul-template
# config that uses the token. Print commands when automatic creation fails.
bootstrap_read_acl() {
  consul_addr="$(read_consul_address)"
  if [ -z "$consul_addr" ]; then
    consul_addr="http://consul:8500"
  fi
  management_token="$(read_management_token)"
  if [ -z "$management_token" ] || ! command -v consul >/dev/null 2>&1; then
    print_acl_commands "$consul_addr"
    return 0
  fi

  policy_file="$STORE/caddy-read-policy.hcl"
  printf '%s\n' \
    'service_prefix "" {' \
    '  policy = "read"' \
    '}' \
    'key_prefix "" {' \
    '  policy = "read"' \
    '}' >"$policy_file"

  export CONSUL_HTTP_ADDR="$consul_addr"
  export CONSUL_HTTP_TOKEN="$management_token"

  if ! consul acl policy read -name caddy-read >/dev/null 2>&1; then
    if ! consul acl policy create -name caddy-read -rules "@$policy_file" >/dev/null 2>&1; then
      echo "warning: Could not create the caddy read ACL policy." >&2
      print_acl_commands "$consul_addr"
      return 0
    fi
  fi

  token_json="$(consul acl token create -description 'caddy read' \
    -policy-name caddy-read -format json 2>/dev/null)" || {
    echo "warning: Could not create the caddy read ACL token." >&2
    print_acl_commands "$consul_addr"
    return 0
  }
  acl_token="$(printf '%s\n' "$token_json" |
    sed -n 's/.*"SecretID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "$acl_token" ]; then
    echo "warning: Could not read the new caddy read ACL token." >&2
    print_acl_commands "$consul_addr"
    return 0
  fi

  token_file="$STORE/consul-template.token"
  (umask 077 && printf '%s\n' "$acl_token" >"$token_file")

  runtime_cfg="$STORE/consul-template.hcl"
  {
    printf 'consul {\n'
    printf '  address = "%s"\n' "$consul_addr"
    printf '  token_file = "%s"\n' "$token_file"
    printf '}\n\n'
    printf 'template {\n'
    printf '  source = "/etc/consul-template/templates/Caddyfile.tpl"\n'
    printf '  destination = "%s"\n' "$CADDYFILE"
    printf '  backup = false\n'
    printf '  perms = "0640"\n'
    printf '}\n'
  } >"$runtime_cfg"
  CFG="$runtime_cfg"
  echo "info: Created the caddy read ACL policy and token." >&2
}

# Render the static Caddyfile for standalone mode.
render_standalone_caddyfile() {
  if [ ! -f "$STATIC_TEMPLATE" ]; then
    echo "error: The standalone caddy template is missing." >&2
    exit 1
  fi
  sed "s|__STACK_DOMAIN__|$STACK_DOMAIN|g" "$STATIC_TEMPLATE" >"$CADDYFILE"
  echo "info: Rendered the standalone caddyfile." >&2
}

# Start caddy with no peer. No consul-template calls.
start_standalone() {
  render_standalone_caddyfile
  echo "info: Start caddy in standalone mode." >&2
  exec caddy run --config "$CADDYFILE" --adapter caddyfile
}

# Render once, supervise consul-template, and run caddy in watch mode.
start_integrated() {
  bootstrap_read_acl
  max_tries=30
  i=0
  until consul-template -config="$CFG" -once; do
    i=$((i + 1))
    if [ "$i" -ge "$max_tries" ]; then
      echo "error: consul-template did not render after $max_tries tries." >&2
      echo "error: Check the consul address and the ACL token." >&2
      exit 1
    fi
    echo "info: consul does not answer yet (try $i/$max_tries)." >&2
    sleep 2
  done
  echo "info: consul-template rendered the caddyfile." >&2

  supervise_consul_template &

  echo "info: start caddy in watch mode." >&2
  exec caddy run --watch --config "$CADDYFILE" --adapter caddyfile
}

if [ "$CONSUL_ENABLED" = "1" ]; then
  start_integrated
else
  start_standalone
fi
