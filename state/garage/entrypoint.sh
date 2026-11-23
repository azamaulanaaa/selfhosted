#!/bin/sh
# Render the Garage runtime config and start the Garage server.
# Garage always uses Consul service discovery. The wizard writes the
# [consul_discovery] section and a token marker line.
# This script resolves the Consul token at container start and replaces the
# marker. It reads the token from the Garage secrets tree first. In integrated
# mode it reads initial_management from the stack Consul agent secrets.
# The script never prints secret values. It prints paths only.
set -eu

# These variables point at the runtime paths. The defaults match the image.
# The tests override them with a scratch tree.
GARAGE_CONFIG_TEMPLATE="${GARAGE_CONFIG_TEMPLATE:-/etc/garage/garage.toml}"
GARAGE_RUNTIME_CONFIG="${GARAGE_RUNTIME_CONFIG:-/run/garage/garage.toml}"
GARAGE_RUNTIME_DIR="${GARAGE_RUNTIME_DIR:-/run/garage}"
GARAGE_SECRETS_DIR="${GARAGE_SECRETS_DIR:-/etc/garage/secrets}"
CONSUL_SECRETS_DIR="${CONSUL_SECRETS_DIR:-/etc/garage/consul-secrets}"
CONSUL_AGENT_HCL_FILE="${CONSUL_AGENT_HCL_FILE:-${CONSUL_SECRETS_DIR}/agent.hcl}"
GARAGE_RENDER_ONLY="${GARAGE_RENDER_ONLY:-0}"

# Environment that the operator sets.
CONSUL_ENABLED="${CONSUL_ENABLED:-0}"

readonly GARAGE_CONFIG_TEMPLATE GARAGE_RUNTIME_CONFIG GARAGE_RUNTIME_DIR
readonly GARAGE_SECRETS_DIR CONSUL_SECRETS_DIR CONSUL_AGENT_HCL_FILE
readonly GARAGE_RENDER_ONLY CONSUL_ENABLED

readonly CONSUL_TOKEN_FILE="${GARAGE_SECRETS_DIR}/consul_token"
readonly TOKEN_MARKER='# __CONSUL_TOKEN__'

log() { echo "garage: $1" >&2; }
err() { echo "garage: error: $1" >&2; }

# Print the contents of one secret file. Print nothing when the file is empty.
read_secret_file() {
  path="$1"
  [ -s "$path" ] || return 0
  cat "$path"
}

# Read initial_management from the Consul agent secret file.
# Print the token on stdout. Print nothing when the key is absent.
read_initial_management() {
  if [ ! -r "$CONSUL_AGENT_HCL_FILE" ]; then
    return 0
  fi
  { grep -E '^[[:space:]]*initial_management[[:space:]]*=' "$CONSUL_AGENT_HCL_FILE" || true; } |
    head -n1 | cut -d'"' -f2
}

# Return 0 when the value can sit in a quoted TOML string.
# Reject a double quote, a backslash, and control characters.
is_safe_toml_string() {
  case "$1" in
  *'"'* | *\\*) return 1 ;;
  esac
  if printf '%s' "$1" | grep -q '[[:cntrl:]]'; then
    return 1
  fi
  return 0
}

# Render the runtime config from the wizard config.
# Replace the marker line with the token line. Remove the marker when the
# token is empty. Never print the token.
render_config() {
  token="$1"

  mkdir -p "$GARAGE_RUNTIME_DIR"
  chmod 0700 "$GARAGE_RUNTIME_DIR"
  tmp_config="${GARAGE_RUNTIME_CONFIG}.tmp"
  : >"$tmp_config"

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    *"$TOKEN_MARKER"*)
      if [ -n "$token" ]; then
        printf 'token = "%s"\n' "$token" >>"$tmp_config"
      fi
      ;;
    *)
      printf '%s\n' "$line" >>"$tmp_config"
      ;;
    esac
  done <"$GARAGE_CONFIG_TEMPLATE"

  chmod 0600 "$tmp_config"
  mv "$tmp_config" "$GARAGE_RUNTIME_CONFIG"
  log "rendered the runtime config at $GARAGE_RUNTIME_CONFIG"
}

# ---------------------------------------------------------------------------
# Boot sequence
# ---------------------------------------------------------------------------

if [ ! -r "$GARAGE_CONFIG_TEMPLATE" ]; then
  err "Garage configuration not readable at $GARAGE_CONFIG_TEMPLATE."
  err "Generate it first: bash setup.sh garage"
  exit 1
fi

if ! grep -Fq -- "$TOKEN_MARKER" "$GARAGE_CONFIG_TEMPLATE"; then
  err "The Garage configuration lacks the token marker '$TOKEN_MARKER'."
  err "Generate it again: bash setup.sh garage"
  exit 1
fi

# Resolve the token. The Garage token file wins. In integrated mode, read the
# stack Consul management token when the file is absent.
consul_token=""
token_source="none"
if [ -s "$CONSUL_TOKEN_FILE" ]; then
  consul_token="$(read_secret_file "$CONSUL_TOKEN_FILE")"
  if [ -n "$consul_token" ]; then
    token_source="file"
  fi
elif [ "$CONSUL_ENABLED" = "1" ]; then
  consul_token="$(read_initial_management)"
  if [ -n "$consul_token" ]; then
    token_source="agent"
  fi
fi

if [ -n "$consul_token" ] && ! is_safe_toml_string "$consul_token"; then
  err "The Consul token has a double quote, a backslash, or a control character."
  exit 1
fi

if [ "$CONSUL_ENABLED" = "1" ] && [ -z "$consul_token" ]; then
  log "warning: no Consul token found at $CONSUL_AGENT_HCL_FILE."
  log "warning: Garage cannot register with the stack Consul without a token."
fi

render_config "$consul_token"

case "$token_source" in
file)
  log "using the Consul token from $CONSUL_TOKEN_FILE"
  ;;
agent)
  log "using the Consul management token from $CONSUL_AGENT_HCL_FILE"
  ;;
*)
  log "no Consul token is configured"
  ;;
esac

if [ "$GARAGE_RENDER_ONLY" = "1" ]; then
  log "render-only mode. No process was started."
  exit 0
fi

log "starting the Garage server with Consul service discovery"
exec /garage -c "$GARAGE_RUNTIME_CONFIG" server
