#!/bin/sh
# Boot the Tinyauth server behind LiteFS.
# LiteFS mounts the data directory at /data. Tinyauth stores its SQLite
# database and its OIDC keys in that directory.
# LiteFS elects a single primary through a Consul lease.
# Only the primary can write the database.
# Consul ACLs protect the lease, therefore this script also creates
# the Consul policy and token that LiteFS uses for the lease.
# The script never prints secret values. It prints paths only.
set -eu

# These variables point at the runtime paths. The defaults match the image.
# The tests override them with a scratch tree.
TINYAUTH_SECRETS_DIR="${TINYAUTH_SECRETS_DIR:-/etc/tinyauth/secrets}"
CONSUL_AGENT_HCL="${CONSUL_AGENT_HCL:-/config/consul/agent.hcl}"
LITEFS_YML="${LITEFS_YML:-/run/litefs.yml}"
LITEFS_MOUNT_DIR="${LITEFS_MOUNT_DIR:-/data}"
LITEFS_DATA_DIR="${LITEFS_DATA_DIR:-/var/lib/litefs}"

# Environment that the operator sets.
PUBLIC_IP="${PUBLIC_IP:-}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://consul:8500}"
STACK_DOMAIN="${STACK_DOMAIN:-sh.lan}"

readonly TINYAUTH_SECRETS_DIR CONSUL_AGENT_HCL LITEFS_YML
readonly LITEFS_MOUNT_DIR LITEFS_DATA_DIR PUBLIC_IP CONSUL_HTTP_ADDR STACK_DOMAIN

readonly TOKEN_FILE="${TINYAUTH_SECRETS_DIR}/litefs-token"
readonly POLICY_NAME="tinyauth-litefs"
# The rules grant write access to the lease key and to the session.
readonly POLICY_RULES_JSON='key \"tinyauth/litefs\" { policy = \"write\" } session \"litefs\" { policy = \"write\" }'

# The base image creates the tinyauth user with uid 1000 and gid 1000.
# The base image keeps the binary in /tinyauth. It does not set USER, so the
# container starts as root. gosu drops root before the app starts.
# The app writes to /data, which the base image chowns to uid 1000.
EXEC_UID=1000
EXEC_GID=1000
EXEC_BINARY=/tinyauth/tinyauth
readonly EXEC_UID EXEC_GID EXEC_BINARY

log() { echo "tinyauth-litefs: $1" >&2; }
err() { echo "tinyauth-litefs: error: $1" >&2; }

# Apply the persisted defaults that Tinyauth needs when the wizard did not
# set them. The wizard writes these keys to config/tinyauth/tinyauth.env.
# compose loads that file before this script starts.
: "${TINYAUTH_APPURL=https://tinyauth.${STACK_DOMAIN}}"
: "${TINYAUTH_DATABASE_PATH=/data/tinyauth.db}"
: "${TINYAUTH_OIDC_PRIVATEKEYPATH=/data/oidc/private.pem}"
: "${TINYAUTH_OIDC_PUBLICKEYPATH=/data/oidc/public.pem}"
export TINYAUTH_APPURL TINYAUTH_DATABASE_PATH
export TINYAUTH_OIDC_PRIVATEKEYPATH TINYAUTH_OIDC_PUBLICKEYPATH

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

# Create or reuse the Consul policy and token for the LiteFS lease.
# The policy grants write access to the lease key and to the session.
# The function prints the token on stdout.
# Return 1 with a message on stderr when any step fails.
create_litefs_token() {
  mgmt_token="$(read_initial_management)" || {
    err "consul secrets not found at $CONSUL_AGENT_HCL."
    err "Run the consul wizard first: bash setup.sh consul"
    err "Then start consul: docker compose up -d consul"
    err "For a remote consul, create a token with write access to the key"
    err "\"tinyauth/litefs\" and to the session \"litefs\", then place it at"
    err "config/tinyauth/secrets/litefs-token."
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
    policy_body="$(printf '{"Name":"%s","Description":"LiteFS lease for the tinyauth cluster","Rules":"%s"}' \
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
# Print the path on stdout.
write_token_file() {
  mkdir -p "$TINYAUTH_SECRETS_DIR"
  chmod 0700 "$TINYAUTH_SECRETS_DIR"
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
    "$CONSUL_HTTP_ADDR/v1/kv/tinyauth/litefs" 2>/dev/null || true)"
  case "$code" in
  200 | 404)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# ---------------------------------------------------------------------------
# Boot sequence
# ---------------------------------------------------------------------------

if [ -z "$PUBLIC_IP" ]; then
  err "PUBLIC_IP is not set. Set it in the root .env or export it before starting the container."
  exit 1
fi

case "$TINYAUTH_APPURL" in
https://*) ;;
*)
  err "TINYAUTH_APPURL must start with https://. The OIDC issuer requires HTTPS."
  exit 1
  ;;
esac

if ! curl -fsS -o /dev/null "$CONSUL_HTTP_ADDR/v1/status/leader" 2>/dev/null; then
  err "consul is not reachable at $CONSUL_HTTP_ADDR."
  err "Start consul first: docker compose up -d consul"
  exit 1
fi

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

# Create the backed-up store and set its mode here at runtime.
# The wizard never writes data/. Root owns the directory because litefs writes
# its LTX files as root before gosu drops privileges for the app.
mkdir -p "$LITEFS_DATA_DIR"
chmod 0700 "$LITEFS_DATA_DIR"
mkdir -p "$LITEFS_MOUNT_DIR"

# Generate the LiteFS configuration. Values come from the container
# environment. The file must not contain secrets. The token travels through
# the CONSUL_HTTP_TOKEN_FILE environment variable instead.
umask 077
cat >"$LITEFS_YML" <<EOF
# Generated by state/tinyauth/entrypoint.sh at container start.
# Do not edit. The file is recreated on every start.
fuse:
  dir: "$LITEFS_MOUNT_DIR"
  allow-other: true
data:
  dir: "$LITEFS_DATA_DIR"
exec: "gosu ${EXEC_UID}:${EXEC_GID} ${EXEC_BINARY}"
skip-sync: false
exit-on-error: true
http:
  addr: ":20202"
lease:
  type: "consul"
  advertise-url: "http://$PUBLIC_IP:20202"
  hostname: "tinyauth"
  candidate: true
  consul:
    url: "$CONSUL_HTTP_ADDR"
    key: "tinyauth/litefs"
    ttl: "10s"
    lock-delay: "1s"
tracing:
  enabled: false
EOF
chmod 0600 "$LITEFS_YML"

log "starting litefs on $LITEFS_MOUNT_DIR (advertise-url http://$PUBLIC_IP:20202)"
log "litefs internal data lives at $LITEFS_DATA_DIR (back this up)"
log "the app data is created on the elected primary at first boot"

CONSUL_HTTP_TOKEN_FILE="$TOKEN_FILE" litefs mount -config "$LITEFS_YML" &
litefs_pid=$!

# Forward signals to litefs. Docker stops the container with SIGTERM.
# After litefs exits, exit with its status code.
trap 'kill -TERM "$litefs_pid" 2>/dev/null || true; wait "$litefs_pid"; exit $?' TERM INT

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
log "waiting for the litefs-managed Tinyauth process to exit"

wait "$litefs_pid"
status=$?
log "litefs exited with code $status"
exit "$status"
