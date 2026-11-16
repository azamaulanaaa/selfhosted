#!/bin/sh
# Boot the Forgejo server behind LiteFS.
# LiteFS mounts the data directory at /data. Forgejo stores its SQLite
# database and its git repositories in that directory.
# LiteFS elects a single primary through a Consul lease.
# Only the primary can write the database.
# Consul ACLs protect the lease, therefore this script also creates
# the Consul policy and token that LiteFS uses for the lease.
# consul-template renders app.ini and the git post-receive hook. A launcher in
# each repository reads the rendered hook, so a re-render reaches all repos.
# The script never prints secret values. It prints paths only.
set -eu

# These variables point at the runtime paths. The defaults match the image.
# The tests override them with a scratch tree.
FORGEJO_SECRETS_DIR="${FORGEJO_SECRETS_DIR:-/etc/forgejo/secrets}"
CONSUL_AGENT_HCL="${CONSUL_AGENT_HCL:-/config/consul/agent.hcl}"
CONSUL_TEMPLATE_CONFIG="${CONSUL_TEMPLATE_CONFIG:-/etc/consul-template/config.hcl}"
RENDER_DIR="${RENDER_DIR:-/run/forgejo}"
APP_INI="${APP_INI:-/run/forgejo/app.ini}"
RENDERED_HOOK="${RENDERED_HOOK:-/run/forgejo/post-receive}"
LITEFS_YML="${LITEFS_YML:-/run/litefs.yml}"
LITEFS_MOUNT_DIR="${LITEFS_MOUNT_DIR:-/data}"
LITEFS_DATA_DIR="${LITEFS_DATA_DIR:-/var/lib/litefs}"
REPO_ROOT="${REPO_ROOT:-/data/gitea/forgejo-repositories}"

# Environment that the operator sets.
PUBLIC_IP="${PUBLIC_IP:-}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://consul:8500}"
STACK_DOMAIN="${STACK_DOMAIN:-sh.lan}"

readonly FORGEJO_SECRETS_DIR CONSUL_AGENT_HCL CONSUL_TEMPLATE_CONFIG
readonly RENDER_DIR APP_INI RENDERED_HOOK LITEFS_YML
readonly LITEFS_MOUNT_DIR LITEFS_DATA_DIR REPO_ROOT
readonly PUBLIC_IP CONSUL_HTTP_ADDR STACK_DOMAIN

readonly TOKEN_FILE="${FORGEJO_SECRETS_DIR}/litefs-token"
readonly POLICY_NAME="forgejo-litefs"
# The rules grant write access to the lease key, the peer keys, and the
# sessions. The peer keys hold the advertise URLs that the hook reads.
readonly POLICY_RULES_JSON='key \"forgejo/litefs\" { policy = \"write\" } key \"forgejo/peers/\" { policy = \"write\" } session \"litefs\" { policy = \"write\" } session \"forgejo-peers\" { policy = \"write\" }'

# Forgejo runs as uid 1000 and gid 1000 in the pinned base image.
EXEC_UID=1000
EXEC_GID=1000
EXEC_BINARY=/app/gitea/gitea
readonly EXEC_UID EXEC_GID EXEC_BINARY

log() { echo "forgejo-litefs: $1" >&2; }
err() { echo "forgejo-litefs: error: $1" >&2; }

# Read the initial management token from the Consul agent configuration.
# Print the token on stdout. Return 1 when the file or the key is missing.
read_initial_management() {
  if [ ! -r "$CONSUL_AGENT_HCL" ]; then
    return 1
  fi
  { grep -E '^[[:space:]]*initial_management[[:space:]]*=' "$CONSUL_AGENT_HCL" || true; } |
    head -n1 | cut -d'"' -f2
}

# Print the value of one string field from a flat JSON response.
# Print nothing when the field is absent. The responses this script parses
# are flat objects written by consul, so a strict pattern is enough.
# Allow whitespace around the colon.
json_field() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n1 | cut -d'"' -f4
}

# Return 0 when the value contains only letters, digits, and hyphens.
is_token_chars() {
  case "$1" in
  '' | *[!a-zA-Z0-9-]*)
    return 1
    ;;
  *)
    return 0
    ;;
  esac
}

# Return 0 when the argument is a valid IPv4 address. Each octet is 0 to 255.
is_valid_ipv4() {
  local_ip="$1"
  case "$local_ip" in
  *[!0-9.]* | '' | .* | *.) return 1 ;;
  esac
  local_octet_count=0
  local_rest="$local_ip"
  while [ -n "$local_rest" ]; do
    local_octet="${local_rest%%.*}"
    case "$local_octet" in
    '' | *[!0-9]*) return 1 ;;
    esac
    if [ "$local_octet" -gt 255 ]; then
      return 1
    fi
    local_octet_count=$((local_octet_count + 1))
    if [ "$local_rest" = "$local_octet" ]; then
      local_rest=""
    else
      local_rest="${local_rest#*.}"
    fi
  done
  [ "$local_octet_count" -eq 4 ]
}

# Create or reuse the Consul policy and token for the LiteFS lease.
# The policy grants write access to the lease key, the peer keys, and the
# sessions. The function prints the token on stdout.
# Return 1 with a message on stderr when any step fails.
create_litefs_token() {
  mgmt_token="$(read_initial_management)" || {
    err "consul secrets not found at $CONSUL_AGENT_HCL."
    err "Run the consul wizard first: bash setup.sh consul"
    err "Then start consul: docker compose up -d consul"
    err "For a remote consul, create a token with write access to the key"
    err "\"forgejo/litefs\", the prefix \"forgejo/peers/\", and the sessions"
    err "\"litefs\" and \"forgejo-peers\". Place it at"
    err "config/forgejo/secrets/litefs-token."
    return 1
  }
  if [ -z "$mgmt_token" ]; then
    err "the initial_management key is missing or empty in $CONSUL_AGENT_HCL."
    return 1
  fi
  if ! is_token_chars "$mgmt_token"; then
    err "the initial_management value in $CONSUL_AGENT_HCL has unexpected characters."
    return 1
  fi

  resp_file="${LITEFS_YML}.policy-response.json"

  # Reuse the policy when it exists. Create it when it does not.
  policy_code="$(curl -fsS -o "$resp_file" -w '%{http_code}' \
    -H "X-Consul-Token: $mgmt_token" \
    "$CONSUL_HTTP_ADDR/v1/acl/policy/name/$POLICY_NAME" 2>/dev/null || true)"
  if [ "$policy_code" = "404" ]; then
    policy_body="$(printf '{"Name":"%s","Description":"LiteFS lease for the forgejo cluster","Rules":"%s"}' \
      "$POLICY_NAME" "$POLICY_RULES_JSON")"
    policy_code="$(curl -fsS -o "$resp_file" -w '%{http_code}' \
      -X PUT -H "X-Consul-Token: $mgmt_token" \
      -H "Content-Type: application/json" \
      -d "$policy_body" \
      "$CONSUL_HTTP_ADDR/v1/acl/policy" 2>/dev/null || true)"
    if [ "$policy_code" != "200" ] && [ "$policy_code" != "201" ]; then
      err "could not create the consul policy $POLICY_NAME (HTTP $policy_code)."
      return 1
    fi
    log "created the consul policy $POLICY_NAME"
  elif [ "$policy_code" = "200" ]; then
    log "reusing the existing consul policy $POLICY_NAME"
  else
    err "could not read the consul policy $POLICY_NAME (HTTP $policy_code)."
    return 1
  fi

  policy_id="$(json_field ID <"$resp_file")"
  if [ -z "$policy_id" ]; then
    err "the consul policy response has no ID."
    return 1
  fi
  if ! is_token_chars "$policy_id"; then
    err "the consul policy ID has unexpected characters."
    return 1
  fi

  token_body="$(printf '{"Name":"%s","Policies":[{"ID":"%s"}]}' "$POLICY_NAME" "$policy_id")"
  token_code="$(curl -fsS -o "$resp_file" -w '%{http_code}' \
    -X PUT -H "X-Consul-Token: $mgmt_token" \
    -H "Content-Type: application/json" \
    -d "$token_body" \
    "$CONSUL_HTTP_ADDR/v1/acl/token" 2>/dev/null || true)"
  if [ "$token_code" != "200" ] && [ "$token_code" != "201" ]; then
    err "could not create the consul token for litefs (HTTP $token_code)."
    return 1
  fi

  candidate_token="$(json_field SecretID <"$resp_file")"
  if [ -z "$candidate_token" ]; then
    err "the consul token response has no SecretID."
    return 1
  fi
  if ! is_token_chars "$candidate_token"; then
    err "the consul token SecretID has unexpected characters."
    return 1
  fi
  rm -f "$resp_file"
  printf '%s' "$candidate_token"
}

# Write the token to a file atomically, readable only by root.
write_token_file() {
  mkdir -p "$FORGEJO_SECRETS_DIR"
  chmod 0700 "$FORGEJO_SECRETS_DIR"
  umask 077
  printf '%s' "$1" >"${TOKEN_FILE}.tmp"
  mv "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
}

# Check that consul accepts the token for the lease key.
# An authorized token sees the key or an empty key space (404).
check_litefs_token() {
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Consul-Token: $1" \
    "$CONSUL_HTTP_ADDR/v1/kv/forgejo/litefs" 2>/dev/null || true)"
  case "$code" in
  200 | 404)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# Register this node's advertise URL in Consul KV. The rendered hook reads all
# peer keys under forgejo/peers. A failed registration is not fatal.
register_peer() {
  node_name="$(hostname 2>/dev/null || printf 'forgejo')"
  peer_name="$(printf '%s' "$node_name" | tr -c 'a-zA-Z0-9._-' '-')"
  peer_json="$(printf '{"advertise-url":"http://%s:20202","hostname":"%s"}' \
    "$PUBLIC_IP" "$peer_name")"
  peer_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H "X-Consul-Token: $1" \
    --data-binary "$peer_json" \
    "$CONSUL_HTTP_ADDR/v1/kv/forgejo/peers/$peer_name" 2>/dev/null || true)"
  case "$peer_code" in
  200)
    log "registered the peer data at forgejo/peers/$peer_name"
    ;;
  *)
    err "could not register the peer data at forgejo/peers/$peer_name (HTTP $peer_code)."
    ;;
  esac
}

# Apply the file modes that consul-template cannot keep across a re-render.
# The app.ini file is group readable so that the git user can read the
# rendered OIDC client secret. The hook must be executable.
fix_rendered_files() {
  if [ -f "$APP_INI" ]; then
    chmod 0640 "$APP_INI" 2>/dev/null || true
    chgrp "$EXEC_GID" "$APP_INI" 2>/dev/null || true
  fi
  if [ -f "$RENDERED_HOOK" ]; then
    chmod 0755 "$RENDERED_HOOK" 2>/dev/null || true
  fi
}

# Render both templates once. Retry while consul starts.
render_once() {
  tries=0
  max_tries=30
  until consul-template -config="$CONSUL_TEMPLATE_CONFIG" -once; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$max_tries" ]; then
      err "consul-template did not render after $max_tries tries."
      err "Check the consul address and the token file in $CONSUL_TEMPLATE_CONFIG."
      return 1
    fi
    log "consul does not answer yet (try $tries/$max_tries). Wait 2 s."
    sleep 2
  done
  for rendered_file in "$APP_INI" "$RENDERED_HOOK"; do
    if [ ! -s "$rendered_file" ]; then
      err "consul-template did not write $rendered_file."
      return 1
    fi
  done
  fix_rendered_files
}

# Write the small launcher that Forgejo chains from every repository.
# Forgejo ignores the name "gitea" in hooks/post-receive.d, so this name is
# different. The launcher execs the consul-template output. A re-render reaches
# every repository without rewriting the launcher.
write_hook_launcher() {
  launcher="$1"
  (
    umask 022
    {
      printf '%s\n' '#!/bin/sh'
      printf '%s\n' '# Installed by state/forgejo/entrypoint.sh. Do not edit.'
      printf '%s\n' '# consul-template refreshes the rendered hook.'
      printf 'exec /bin/sh "%s"\n' "$RENDERED_HOOK"
    } >"${launcher}.tmp"
  )
  mv "${launcher}.tmp" "$launcher"
  chmod 0755 "$launcher"
}

# Install the launcher in every repository that exists now.
install_hooks_once() {
  [ -s "$RENDERED_HOOK" ] || return 0
  [ -d "$REPO_ROOT" ] || return 0
  find "$REPO_ROOT" -type d -name '*.git' -print 2>/dev/null |
    while IFS= read -r repo_dir; do
      hook_dir="${repo_dir}/hooks/post-receive.d"
      hook_file="${hook_dir}/forgejo-replicate"
      if [ -f "$hook_file" ] && grep -q 'Installed by state/forgejo' "$hook_file" 2>/dev/null; then
        continue
      fi
      mkdir -p "$hook_dir" 2>/dev/null || continue
      write_hook_launcher "$hook_file" || continue
    done
}

# Keep installing the launcher. New repositories appear after boot.
install_hooks_loop() {
  while :; do
    install_hooks_once || true
    sleep 30
  done
}

# Prepare the FUSE mount and run Forgejo as the git user. LiteFS calls this
# branch through its exec directive.
exec_forgejo() {
  for runtime_dir in \
    "${LITEFS_MOUNT_DIR}/gitea/conf" \
    "${LITEFS_MOUNT_DIR}/gitea/log" \
    "${LITEFS_MOUNT_DIR}/gitea/home" \
    "${LITEFS_MOUNT_DIR}/gitea/tmp" \
    "${LITEFS_MOUNT_DIR}/git"; do
    mkdir -p "$runtime_dir" 2>/dev/null || true
    chmod 0777 "$runtime_dir" 2>/dev/null || true
  done
  chmod 0777 "$LITEFS_MOUNT_DIR" 2>/dev/null || true
  exec gosu "${EXEC_UID}:${EXEC_GID}" "$EXEC_BINARY" web --config "$APP_INI"
}

# ---------------------------------------------------------------------------
# Entry points used by the image and by consul-template.
# ---------------------------------------------------------------------------

case "${1:-}" in
--exec)
  exec_forgejo
  ;;
--render-fixed)
  fix_rendered_files
  exit 0
  ;;
--install-hooks)
  install_hooks_once
  exit 0
  ;;
'')
  ;;
*)
  err "unknown argument '$1'."
  exit 2
  ;;
esac

# ---------------------------------------------------------------------------
# Boot sequence
# ---------------------------------------------------------------------------

if [ -z "$PUBLIC_IP" ]; then
  err "PUBLIC_IP is not set. Set it in the root .env or export it before starting the container."
  exit 1
fi
if ! is_valid_ipv4 "$PUBLIC_IP"; then
  err "PUBLIC_IP '$PUBLIC_IP' is not a valid IPv4 address."
  exit 1
fi
if [ ! -r "$CONSUL_TEMPLATE_CONFIG" ]; then
  err "consul-template configuration not readable at $CONSUL_TEMPLATE_CONFIG."
  err "Generate it first: bash setup.sh forgejo"
  exit 1
fi
if ! curl -fsS -o /dev/null "$CONSUL_HTTP_ADDR/v1/status/leader" 2>/dev/null; then
  err "consul is not reachable at $CONSUL_HTTP_ADDR."
  err "Start consul first: docker compose up -d consul"
  exit 1
fi
log "using the stack domain $STACK_DOMAIN"

# Resolve the LiteFS token. Reuse a stored token when it is still valid.
if [ -s "$TOKEN_FILE" ]; then
  token="$(cat "$TOKEN_FILE")"
  if ! is_token_chars "$token"; then
    err "the stored litefs token at $TOKEN_FILE has unexpected characters."
    err "Delete the file and restart the container to create a new token."
    exit 1
  fi
  if check_litefs_token "$token"; then
    log "reusing the litefs token from $TOKEN_FILE"
  else
    err "the stored litefs token at $TOKEN_FILE was rejected by consul."
    err "Delete the file and restart the container to create a new token."
    exit 1
  fi
else
  log "creating the consul policy and token for the litefs lease"
  token="$(create_litefs_token)"
  if [ -z "$token" ]; then
    err "no litefs token was created."
    exit 1
  fi
  if ! check_litefs_token "$token"; then
    err "the new litefs token does not work. Check the consul ACLs."
    exit 1
  fi
  write_token_file "$token"
  log "stored the litefs token at $TOKEN_FILE"
fi

mkdir -p "$LITEFS_DATA_DIR" "$LITEFS_MOUNT_DIR" "$RENDER_DIR"

# Generate the LiteFS configuration. Values come from the container
# environment. The file must not contain secrets. The token travels through
# the CONSUL_HTTP_TOKEN_FILE environment variable instead.
umask 077
cat >"$LITEFS_YML" <<EOF
# Generated by state/forgejo/entrypoint.sh at container start.
# Do not edit. The file is recreated on every start.
fuse:
  dir: "$LITEFS_MOUNT_DIR"
  allow-other: true
data:
  dir: "$LITEFS_DATA_DIR"
exec: "/usr/local/bin/entrypoint.sh --exec"
skip-sync: false
exit-on-error: true
http:
  addr: ":20202"
lease:
  type: "consul"
  advertise-url: "http://$PUBLIC_IP:20202"
  hostname: "forgejo"
  candidate: true
  consul:
    url: "$CONSUL_HTTP_ADDR"
    key: "forgejo/litefs"
    ttl: "10s"
    lock-delay: "1s"
tracing:
  enabled: false
EOF
chmod 0600 "$LITEFS_YML"

log "starting litefs on $LITEFS_MOUNT_DIR (advertise-url http://$PUBLIC_IP:20202)"
log "litefs internal data lives at $LITEFS_DATA_DIR (back this up)"
log "the database and the git repositories are created on the elected primary"

# Publish this node's peer data for the rendered git hook.
register_peer "$token"

# Render app.ini and the post-receive hook before Forgejo starts.
render_once
log "rendered app.ini at $APP_INI and the hook at $RENDERED_HOOK"

# Keep both templates reactive. consul-template rewrites the files on change.
consul-template -config="$CONSUL_TEMPLATE_CONFIG" &
ct_pid=$!

# Install the hook launcher into new repositories as they appear.
install_hooks_loop &
hook_pid=$!

# Start LiteFS. It runs the --exec branch under gosu on the mounted data.
CONSUL_HTTP_TOKEN_FILE="$TOKEN_FILE" litefs mount -config "$LITEFS_YML" &
litefs_pid=$!

# Forward signals to litefs. Exit with the status of litefs.
# shellcheck disable=SC2329
on_signal() {
  kill -TERM "$litefs_pid" 2>/dev/null || true
  kill -TERM "$ct_pid" 2>/dev/null || true
  kill -TERM "$hook_pid" 2>/dev/null || true
  set +e
  wait "$litefs_pid"
  final_status=$?
  exit "$final_status"
}
trap on_signal TERM INT

# Wait for the FUSE mount to appear.
mount_found=0
i=0
while [ "$i" -lt 30 ]; do
  if ! kill -0 "$litefs_pid" 2>/dev/null; then
    err "litefs exited before the mount appeared."
    exit 1
  fi
  if grep -E "[[:space:]]${LITEFS_MOUNT_DIR}[[:space:]]fuse" /proc/mounts >/dev/null 2>&1; then
    mount_found=1
    break
  fi
  i=$((i + 1))
  sleep 1
done

if [ "$mount_found" -ne 1 ]; then
  err "the litefs mount did not appear at $LITEFS_MOUNT_DIR after 30 seconds."
  kill -TERM "$litefs_pid" 2>/dev/null || true
  exit 1
fi

log "litefs mounted at $LITEFS_MOUNT_DIR"
log "waiting for the litefs-managed Forgejo process to exit"

status=0
wait "$litefs_pid" || status=$?
kill -TERM "$ct_pid" 2>/dev/null || true
kill -TERM "$hook_pid" 2>/dev/null || true
log "litefs exited with code $status"
exit "$status"
