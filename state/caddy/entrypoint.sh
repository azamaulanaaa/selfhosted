#!/bin/sh
# Create the caddy read ACL, render the Caddyfile with consul-template, and
# run caddy in watch mode.
# Consul is always required. The CONSUL_ADDR value selects local or remote
# Consul. The entrypoint never prints the token.
set -eu

CFG=/etc/consul-template/config.hcl
MANAGEMENT_FILE=/etc/consul/secrets/agent.hcl
REMOTE_TOKEN_FILE=/etc/consul/secrets/remote-token
CADDYFILE=/etc/caddy/Caddyfile
STORE=/data/caddy
LOCAL_CONSUL_ADDR=http://consul:8500

# Return 0 when the argument is the local Consul address.
# Remove one trailing slash before the comparison.
is_local_consul_addr() {
  [ "${1%/}" = "$LOCAL_CONSUL_ADDR" ]
}

# Print the token file for the given Consul address.
token_file_for_addr() {
  if is_local_consul_addr "$1"; then
    printf '%s\n' "$MANAGEMENT_FILE"
  else
    printf '%s\n' "$REMOTE_TOKEN_FILE"
  fi
}

# Print the Consul address from the consul-template configuration.
read_config_address() {
  sed -n 's/.*address[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$CFG" | head -n1
}

# Resolve CONSUL_ADDR. Set consul_addr.
# The environment wins. Fall back to the configuration file, then local.
resolve_consul_addr() {
  consul_addr="${CONSUL_ADDR:-}"
  if [ -z "$consul_addr" ]; then
    consul_addr="$(read_config_address)"
  fi
  if [ -z "$consul_addr" ]; then
    consul_addr="$LOCAL_CONSUL_ADDR"
  fi
}

# Print the management token. Print nothing when the file is absent.
# Local mode reads initial_management from agent.hcl.
# Remote mode reads the first line of remote-token.
read_management_token() {
  source_token_file="$(token_file_for_addr "$consul_addr")"
  [ -f "$source_token_file" ] || return 0
  if is_local_consul_addr "$consul_addr"; then
    sed -n 's/.*initial_management[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$source_token_file" | head -n1
  else
    head -n1 "$source_token_file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
  fi
}

# Print the commands that create the caddy read ACL by hand.
print_acl_commands() {
  echo "hint: Create the caddy read ACL policy with these commands." >&2
  if is_local_consul_addr "$consul_addr"; then
    echo "hint: 1. Read initial_management from config/consul/secrets/agent.hcl." >&2
  else
    echo "hint: 1. Read the ACL token from config/consul/secrets/remote-token." >&2
  fi
  echo "hint: 2. Run: export CONSUL_HTTP_ADDR=$consul_addr" >&2
  echo "hint: 3. Run: export CONSUL_HTTP_TOKEN=<management-token>" >&2
  printf '%s\n' "hint: 4. Run: printf 'service_prefix \"\" { policy = \"read\" }\\nkey_prefix \"\" { policy = \"read\" }\\n' > /tmp/caddy-read.hcl" >&2
  echo "hint: 5. Run: consul acl policy create -name caddy-read -rules @/tmp/caddy-read.hcl" >&2
  echo "hint: 6. Run: consul acl token create -description 'caddy read' -policy-name caddy-read" >&2
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
  management_token="$(read_management_token)"
  if [ -z "$management_token" ] || ! command -v consul >/dev/null 2>&1; then
    print_acl_commands
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
      print_acl_commands
      return 0
    fi
  fi

  token_json="$(consul acl token create -description 'caddy read' \
    -policy-name caddy-read -format json 2>/dev/null)" || {
    echo "warning: Could not create the caddy read ACL token." >&2
    print_acl_commands
    return 0
  }
  acl_token="$(printf '%s\n' "$token_json" |
    sed -n 's/.*"SecretID"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  if [ -z "$acl_token" ]; then
    echo "warning: Could not read the new caddy read ACL token." >&2
    print_acl_commands
    return 0
  fi

  runtime_token_file="$STORE/consul-template.token"
  (umask 077 && printf '%s\n' "$acl_token" >"$runtime_token_file")

  runtime_cfg="$STORE/consul-template.hcl"
  {
    printf 'consul {\n'
    printf '  address = "%s"\n' "$consul_addr"
    printf '  token_file = "%s"\n' "$runtime_token_file"
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

# Render once, supervise consul-template, and run caddy in watch mode.
start() {
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

# Create the store, resolve the Consul address, and start the services.
main() {
  # Docker creates a missing bind mount root as root-owned mode 0755. The
  # container runs as root, so it owns the store and the ACME files in it.
  # A backup must read the store with root privileges.
  mkdir -p "$STORE"
  chmod 0700 /data "$STORE"
  resolve_consul_addr
  start
}

# The smoke test sources this file as a function library.
if [ "${CADDY_ENTRYPOINT_LIB:-0}" != "1" ]; then
  main
fi
