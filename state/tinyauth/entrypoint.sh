#!/bin/sh
# Boot the Tinyauth server.
# Consul is always present. CONSUL_ADDR selects the Consul location.
# In integrated mode, LiteFS wraps the app and replicates the SQLite database.
# Integrated mode needs a Consul lease and a FUSE mount.
# In standalone mode, the app runs directly on a local SQLite database.
# Standalone mode needs no peer, no FUSE, and no LiteFS. Consul is still required.
# The script never prints secret values. It prints paths only.
set -eu

# These variables point at the runtime paths. The defaults match the image.
# The tests override them with a scratch tree.
TINYAUTH_SECRETS_DIR="${TINYAUTH_SECRETS_DIR:-/etc/tinyauth/secrets}"
CONSUL_SECRETS_DIR="${CONSUL_SECRETS_DIR:-/etc/tinyauth/consul-secrets}"
LITEFS_YML="${LITEFS_YML:-/run/litefs.yml}"
LITEFS_MOUNT_DIR="${LITEFS_MOUNT_DIR:-/data}"
LITEFS_DATA_DIR="${LITEFS_DATA_DIR:-/var/lib/litefs}"
STANDALONE_RENDER_FILE="${STANDALONE_RENDER_FILE:-/run/tinyauth-standalone.env}"
TINYAUTH_RENDER_ONLY="${TINYAUTH_RENDER_ONLY:-0}"

# Environment that the operator sets.
PUBLIC_IP="${PUBLIC_IP:-}"
CONSUL_ADDR="${CONSUL_ADDR:-http://consul:8500}"
STACK_DOMAIN="${STACK_DOMAIN:-sh.lan}"

# Capability flags. A value of 1 enables the matching feature.
LITEFS_ENABLED="${LITEFS_ENABLED:-0}"
OIDC_ENABLED="${OIDC_ENABLED:-0}"
TLS_ENABLED="${TLS_ENABLED:-0}"

# Select the Consul token file by the Consul location.
# Local Consul writes the initial_management key to agent.hcl.
# Remote Consul writes the token to remote-token.
# One trailing slash does not change the comparison with the local address.
readonly CONSUL_LOCAL_ADDR="http://consul:8500"
consul_local=0
CONSUL_TOKEN_FILE="${CONSUL_SECRETS_DIR}/remote-token"
if [ "${CONSUL_ADDR%/}" = "$CONSUL_LOCAL_ADDR" ]; then
  consul_local=1
  CONSUL_TOKEN_FILE="${CONSUL_SECRETS_DIR}/agent.hcl"
fi

readonly TINYAUTH_SECRETS_DIR CONSUL_SECRETS_DIR LITEFS_YML
readonly LITEFS_MOUNT_DIR LITEFS_DATA_DIR STANDALONE_RENDER_FILE TINYAUTH_RENDER_ONLY
readonly PUBLIC_IP CONSUL_ADDR STACK_DOMAIN
readonly LITEFS_ENABLED OIDC_ENABLED TLS_ENABLED
readonly consul_local CONSUL_TOKEN_FILE

# Integrated mode needs LiteFS. Consul is always present.
integrated=0
if [ "$LITEFS_ENABLED" = "1" ]; then
  integrated=1
fi
readonly integrated

readonly TOKEN_FILE="${TINYAUTH_SECRETS_DIR}/litefs-token"
readonly POLICY_NAME="tinyauth-litefs"
# The rules grant write access to the lease key and to the session.
readonly POLICY_RULES_JSON='key \"tinyauth/litefs\" { policy = \"write\" } session \"litefs\" { policy = \"write\" }'

# The base image creates the tinyauth user with uid 1000 and gid 1000.
# The base image keeps the binary in /tinyauth. It does not set USER, so the
# container starts as root. gosu drops root before the app starts.
# Rootless operation sets EXEC_UID and EXEC_GID to 0. Container root then maps
# to the host user, which owns the mounted files.
EXEC_UID="${EXEC_UID:-1000}"
EXEC_GID="${EXEC_GID:-1000}"
EXEC_BINARY=/tinyauth/tinyauth
readonly EXEC_UID EXEC_GID EXEC_BINARY

log() { echo "tinyauth: $1" >&2; }
err() { echo "tinyauth: error: $1" >&2; }

# Apply the defaults that Tinyauth needs. The wizard writes these keys to
# config/tinyauth/tinyauth.env. Compose loads that file before this script.
# A standalone instance without OIDC uses a local issuer.
: "${TINYAUTH_APPURL=https://tinyauth.${STACK_DOMAIN}}"
if [ "$OIDC_ENABLED" = "0" ]; then
  TINYAUTH_APPURL="http://127.0.0.1:3000"
fi
: "${TINYAUTH_DATABASE_PATH=/data/tinyauth.db}"
: "${TINYAUTH_OIDC_PRIVATEKEYPATH=/etc/tinyauth/secrets/oidc/private.pem}"
: "${TINYAUTH_OIDC_PUBLICKEYPATH=/etc/tinyauth/secrets/oidc/public.pem}"
export TINYAUTH_APPURL TINYAUTH_DATABASE_PATH
export TINYAUTH_OIDC_PRIVATEKEYPATH TINYAUTH_OIDC_PUBLICKEYPATH

# Read the Consul ACL token from the selected token file at container start.
# Local Consul: the initial_management key in agent.hcl.
# Remote Consul: the raw value in remote-token.
# Print the token on stdout. Return 1 when the file is missing.
read_consul_token() {
  [ -r "$CONSUL_TOKEN_FILE" ] || return 1
  if [ "$consul_local" = "1" ]; then
    { grep -E '^[[:space:]]*initial_management[[:space:]]*=' "$CONSUL_TOKEN_FILE" || true; } |
      head -n1 | cut -d'"' -f2
    return 0
  fi
  tr -d '\r\n' <"$CONSUL_TOKEN_FILE"
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

# Create or reuse the consul policy and token for the LiteFS lease.
# The policy grants write access to the lease key and to the session.
# The function prints the token on stdout.
# Return 1 with a message on stderr when any step fails.
create_litefs_token() {
  mgmt_token="$(read_consul_token)" || {
    err "the Consul token is missing at $CONSUL_TOKEN_FILE."
    err "Run the root setup.sh to write the Consul secret."
    err "You may write a prepared litefs token to ${TINYAUTH_SECRETS_DIR}/litefs-token."
    return 1
  }
  if [ -z "$mgmt_token" ]; then
    err "the Consul token at $CONSUL_TOKEN_FILE is empty."
    return 1
  fi
  if ! is_token_chars "$mgmt_token"; then
    err "the Consul token at $CONSUL_TOKEN_FILE has unexpected characters."
    return 1
  fi

  resp_file="${LITEFS_YML}.policy-response.json"

  # Reuse the policy when it exists. Create it when it does not.
  policy_code="$(curl -fsS -o "$resp_file" -w '%{http_code}' \
    -H "X-Consul-Token: $mgmt_token" \
    "$CONSUL_ADDR/v1/acl/policy/name/$POLICY_NAME" 2>/dev/null || true)"
  if [ "$policy_code" = "404" ]; then
    policy_body="$(printf '{"Name":"%s","Description":"LiteFS lease for the tinyauth cluster","Rules":"%s"}' \
      "$POLICY_NAME" "$POLICY_RULES_JSON")"
    policy_code="$(curl -fsS -o "$resp_file" -w '%{http_code}' \
      -X PUT -H "X-Consul-Token: $mgmt_token" \
      -H "Content-Type: application/json" \
      -d "$policy_body" \
      "$CONSUL_ADDR/v1/acl/policy" 2>/dev/null || true)"
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
    "$CONSUL_ADDR/v1/acl/token" 2>/dev/null || true)"
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
    "$CONSUL_ADDR/v1/kv/tinyauth/litefs" 2>/dev/null || true)"
  case "$code" in
  200 | 404)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

# Render the LiteFS configuration. Values come from the container environment.
# The file must not contain secrets. LiteFS reads the Consul token from the
# CONSUL_HTTP_TOKEN environment variable. LiteFS does not read
# CONSUL_HTTP_TOKEN_FILE. The start command passes the token value directly.
render_integrated_config() {
  mkdir -p "$LITEFS_DATA_DIR"
  chmod 0700 "$LITEFS_DATA_DIR"
  mkdir -p "$LITEFS_MOUNT_DIR"
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
    url: "$CONSUL_ADDR"
    key: "tinyauth/litefs"
    ttl: "10s"
    lock-delay: "1s"
tracing:
  enabled: false
EOF
  chmod 0600 "$LITEFS_YML"
  log "rendered the litefs config at $LITEFS_YML"
  log "consul token file: $CONSUL_TOKEN_FILE"
}

# Render the standalone app configuration. Tinyauth reads its settings from
# environment variables. This file records the values for verification.
render_standalone_config() {
  mkdir -p "$LITEFS_MOUNT_DIR"
  chown "${EXEC_UID}:${EXEC_GID}" "$LITEFS_MOUNT_DIR" 2>/dev/null || true
  umask 077
  cat >"$STANDALONE_RENDER_FILE" <<EOF
# Generated by state/tinyauth/entrypoint.sh at container start.
# Do not edit. The file is recreated on every start.
TINYAUTH_APPURL=$TINYAUTH_APPURL
TINYAUTH_DATABASE_PATH=$TINYAUTH_DATABASE_PATH
TINYAUTH_OIDC_PRIVATEKEYPATH=$TINYAUTH_OIDC_PRIVATEKEYPATH
TINYAUTH_OIDC_PUBLICKEYPATH=$TINYAUTH_OIDC_PUBLICKEYPATH
CONSUL_ADDR=$CONSUL_ADDR
LITEFS_ENABLED=$LITEFS_ENABLED
OIDC_ENABLED=$OIDC_ENABLED
TLS_ENABLED=$TLS_ENABLED
EOF
  chmod 0600 "$STANDALONE_RENDER_FILE"
  log "rendered the standalone config at $STANDALONE_RENDER_FILE"
}

# Start LiteFS and wait for its FUSE mount. LiteFS starts the app.
start_integrated() {
  if ! curl -fsS -o /dev/null "$CONSUL_ADDR/v1/status/leader" 2>/dev/null; then
    err "consul is not reachable at $CONSUL_ADDR."
    err "Start Consul at that address first."
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

  log "starting litefs on $LITEFS_MOUNT_DIR (advertise-url http://$PUBLIC_IP:20202)"
  log "litefs internal data lives at $LITEFS_DATA_DIR (back this up)"
  log "the app data is created on the elected primary at first boot"

  CONSUL_HTTP_TOKEN="$token" litefs mount -config "$LITEFS_YML" &
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

  status=0
  wait "$litefs_pid" || status=$?
  log "litefs exited with code $status"
  exit "$status"
}

# Start the app directly on local SQLite. No peer process is required.
start_standalone() {
  log "starting tinyauth on local SQLite at $TINYAUTH_DATABASE_PATH"
  log "standalone mode needs no LiteFS peer and no FUSE. Consul is still required."

  gosu "${EXEC_UID}:${EXEC_GID}" "${EXEC_BINARY}" &
  app_pid=$!
  trap 'kill -TERM "$app_pid" 2>/dev/null || true; wait "$app_pid"; exit $?' TERM INT

  status=0
  wait "$app_pid" || status=$?
  log "tinyauth exited with code $status"
  exit "$status"
}

# ---------------------------------------------------------------------------
# Boot sequence
# ---------------------------------------------------------------------------

if [ "$integrated" -eq 1 ] && [ -z "$PUBLIC_IP" ]; then
  err "PUBLIC_IP is not set. Set it in the root .env file."
  exit 1
fi

if [ "$OIDC_ENABLED" = "1" ]; then
  case "$TINYAUTH_APPURL" in
  https://*) ;;
  *)
    err "TINYAUTH_APPURL must start with https://. The OIDC issuer requires HTTPS."
    exit 1
    ;;
  esac
fi

if [ "$integrated" -eq 1 ]; then
  render_integrated_config
else
  render_standalone_config
fi

if [ "$TINYAUTH_RENDER_ONLY" = "1" ]; then
  log "render-only mode. No process was started."
  exit 0
fi

if [ "$integrated" -eq 1 ]; then
  start_integrated
else
  start_standalone
fi
