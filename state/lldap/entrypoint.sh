#!/bin/sh
# Boot the LLDAP server in standalone mode or integrated mode.
# Standalone mode starts LLDAP directly. It needs no LiteFS, no Consul, and no FUSE mount.
# Integrated mode runs LLDAP behind LiteFS. LiteFS mounts the database at /data.
# LiteFS elects a single primary through a Consul lease. Only the primary writes the database.
# Consul ACLs protect the lease. This script reads the management token at start.
# The script never prints secret values. It prints paths only.
set -eu

# These variables point at the image paths. The defaults match the base image.
# Override a variable to use a different path.
LLDAP_CONFIG_FILE="${LLDAP_CONFIG_FILE:-/etc/lldap/lldap_config.toml}"
LLDAP_DATA_DIR="${LLDAP_DATA_DIR:-/data}"
CONSUL_AGENT_HCL_FILE="${CONSUL_AGENT_HCL_FILE:-/etc/consul/secrets/agent.hcl}"
LITEFS_YML="${LITEFS_YML:-/run/litefs.yml}"
LITEFS_MOUNT_DIR="${LITEFS_MOUNT_DIR:-/data}"
LITEFS_DATA_DIR="${LITEFS_DATA_DIR:-/var/lib/litefs}"

# The runtime token stays outside the read-only config mount.
RUNTIME_TOKEN_FILE="${RUNTIME_TOKEN_FILE:-/run/lldap/litefs-token}"
RUNTIME_TOKEN_DIR="$(dirname -- "$RUNTIME_TOKEN_FILE")"

# Environment that the operator sets.
PUBLIC_IP="${PUBLIC_IP:-}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://consul:8500}"
STACK_DOMAIN="${STACK_DOMAIN:-sh.lan}"
CONSUL_ENABLED="${CONSUL_ENABLED:-0}"
LITEFS_ENABLED="${LITEFS_ENABLED:-0}"

readonly LLDAP_CONFIG_FILE LLDAP_DATA_DIR CONSUL_AGENT_HCL_FILE LITEFS_YML
readonly LITEFS_MOUNT_DIR LITEFS_DATA_DIR PUBLIC_IP CONSUL_HTTP_ADDR STACK_DOMAIN
readonly RUNTIME_TOKEN_FILE RUNTIME_TOKEN_DIR CONSUL_ENABLED LITEFS_ENABLED

# Use integrated mode only when both peers are enabled.
# Any other flag combination selects standalone mode.
integrated_mode=0
if [ "$CONSUL_ENABLED" = "1" ] && [ "$LITEFS_ENABLED" = "1" ]; then
  integrated_mode=1
fi

readonly POLICY_NAME="lldap-litefs"
# The rules grant write access to the lease key and to the session.
readonly POLICY_RULES_JSON='key \"lldap/litefs\" { policy = \"write\" } session \"litefs\" { policy = \"write\" }'

# The base image exports UID and GID as the lldap runtime ids.
# POSIX sh does not define these names, therefore allow them here.
# shellcheck disable=SC3028
EXEC_UID="${UID:-1000}"
# shellcheck disable=SC3028
EXEC_GID="${GID:-1000}"
readonly EXEC_UID EXEC_GID

log() { echo "lldap-litefs: $1" >&2; }
err() { echo "lldap-litefs: error: $1" >&2; }

# Read initial_management from the Consul agent secret file.
# Print the token on stdout. Return 1 when the file is missing.
read_management_token() {
  if [ ! -r "$CONSUL_AGENT_HCL_FILE" ]; then
    return 1
  fi
  {
    grep -E '^[[:space:]]*initial_management' "$CONSUL_AGENT_HCL_FILE" 2>/dev/null || true
  } | head -n1 | sed -E 's/.*"([^"]+)".*/\1/'
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
  mgmt_token="$(read_management_token)" || {
    err "Cannot read the Consul agent secret file."
    err "Create the file $CONSUL_AGENT_HCL_FILE."
    err "The file must hold initial_management."
    return 1
  }
  if [ -z "$mgmt_token" ]; then
    err "The Consul agent secret file has no management token."
    err "Add initial_management to $CONSUL_AGENT_HCL_FILE."
    return 1
  fi
  if ! is_token_chars "$mgmt_token"; then
    err "The Consul management token has unexpected characters."
    return 1
  fi

  resp_file="${LITEFS_YML}.policy-response.json"

  # Reuse the policy when it exists. Create it when it does not.
  policy_code="$(curl -fsS -o "$resp_file" -w '%{http_code}' \
    -H "X-Consul-Token: $mgmt_token" \
    "$CONSUL_HTTP_ADDR/v1/acl/policy/name/$POLICY_NAME" 2>/dev/null || true)"
  if [ "$policy_code" = "404" ]; then
    policy_body="$(printf '{"Name":"%s","Description":"LiteFS lease for the lldap cluster","Rules":"%s"}' \
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

# Write the runtime token to a file that only root can read.
# Create the runtime directory first. Write to a temporary file before the move.
write_token_file() {
  mkdir -p "$RUNTIME_TOKEN_DIR"
  chmod 0700 "$RUNTIME_TOKEN_DIR"
  umask 077
  printf '%s' "$1" >"${RUNTIME_TOKEN_FILE}.tmp"
  mv "${RUNTIME_TOKEN_FILE}.tmp" "$RUNTIME_TOKEN_FILE"
  chmod 0600 "$RUNTIME_TOKEN_FILE"
}

# Check that consul accepts the token for the lease key.
# An authorized token sees the key or an empty key space (404).
check_litefs_token() {
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "X-Consul-Token: $1" \
    "$CONSUL_HTTP_ADDR/v1/kv/lldap/litefs" 2>/dev/null || true)"
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

if [ ! -r "$LLDAP_CONFIG_FILE" ]; then
  err "LLDAP configuration not readable at $LLDAP_CONFIG_FILE."
  err "Generate it first: bash setup.sh lldap"
  exit 1
fi

# Standalone mode needs no peer. Prepare the database directory and start LLDAP.
if [ "$integrated_mode" -eq 0 ]; then
  mkdir -p "$LLDAP_DATA_DIR"
  if [ "$(id -u)" -eq 0 ] && ! chown "${EXEC_UID}:${EXEC_GID}" "$LLDAP_DATA_DIR" 2>/dev/null; then
    log "cannot change the owner of $LLDAP_DATA_DIR. Check the directory permissions."
  fi
  chmod 0700 "$LLDAP_DATA_DIR"
  log "starting lldap in standalone mode"
  exec gosu "${EXEC_UID}:${EXEC_GID}" /app/lldap run --config-file "$LLDAP_CONFIG_FILE"
fi

log "starting lldap in integrated mode with litefs and consul"

if [ -z "$PUBLIC_IP" ]; then
  err "PUBLIC_IP is not set. Set it in the root .env or export it before starting the container."
  exit 1
fi

if ! curl -fsS -o /dev/null "$CONSUL_HTTP_ADDR/v1/status/leader" 2>/dev/null; then
  err "consul is not reachable at $CONSUL_HTTP_ADDR."
  err "Start consul first: docker compose up -d consul"
  exit 1
fi

# Resolve the LiteFS token. Reuse a token from the runtime path when it is valid.
if [ -s "$RUNTIME_TOKEN_FILE" ]; then
  token="$(cat "$RUNTIME_TOKEN_FILE")"
  if ! is_token_chars "$token"; then
    err "The stored LiteFS token has unexpected characters."
    err "Remove the file $RUNTIME_TOKEN_FILE."
    err "Restart the container to create a new token."
    exit 1
  fi
  if check_litefs_token "$token"; then
    log "reusing the LiteFS token from $RUNTIME_TOKEN_FILE"
  else
    err "Consul rejected the stored LiteFS token."
    err "Remove the file $RUNTIME_TOKEN_FILE."
    err "Restart the container to create a new token."
    exit 1
  fi
else
  log "creating the Consul policy and token for the LiteFS lease"
  token="$(create_litefs_token)"
  if [ -z "$token" ]; then
    err "No LiteFS token was created."
    exit 1
  fi
  if ! check_litefs_token "$token"; then
    err "The new LiteFS token does not work."
    err "Check the Consul ACLs."
    exit 1
  fi
  write_token_file "$token"
  log "stored the LiteFS token at $RUNTIME_TOKEN_FILE"
fi

# The store directory holds the LiteFS data. Create it at runtime with mode 700.
# The wizard never writes the data tree.
mkdir -p "$LITEFS_DATA_DIR"
chmod 0700 "$LITEFS_DATA_DIR"
mkdir -p "$LITEFS_MOUNT_DIR"

# Generate the LiteFS configuration. Values come from the container
# environment. The file must not contain secrets. The token travels through
# the CONSUL_HTTP_TOKEN_FILE environment variable instead.
umask 077
cat >"$LITEFS_YML" <<EOF
# Generated by state/lldap/entrypoint.sh at container start.
# Do not edit. The file is recreated on every start.
fuse:
  dir: "$LITEFS_MOUNT_DIR"
  allow-other: true
data:
  dir: "$LITEFS_DATA_DIR"
exec: "gosu ${EXEC_UID}:${EXEC_GID} /app/lldap run --config-file $LLDAP_CONFIG_FILE"
skip-sync: false
exit-on-error: true
http:
  addr: ":20202"
lease:
  type: "consul"
  advertise-url: "http://$PUBLIC_IP:20202"
  hostname: "lldap"
  candidate: true
  consul:
    url: "$CONSUL_HTTP_ADDR"
    key: "lldap/litefs"
    ttl: "10s"
    lock-delay: "1s"
tracing:
  enabled: false
EOF
chmod 0600 "$LITEFS_YML"

log "starting litefs on $LITEFS_MOUNT_DIR (advertise-url http://$PUBLIC_IP:20202)"
log "litefs internal data lives at $LITEFS_DATA_DIR (back this up)"
log "the database lldap.sqlite is created on the elected primary at first boot"

CONSUL_HTTP_TOKEN_FILE="$RUNTIME_TOKEN_FILE" litefs mount -config "$LITEFS_YML" &
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
log "waiting for the litefs-managed LLDAP process to exit"

wait "$litefs_pid"
status=$?
log "litefs exited with code $status"
exit "$status"
