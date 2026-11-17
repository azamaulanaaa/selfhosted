#!/usr/bin/env bash
# Ask which services to enable, ask for the shared PUBLIC_IP, and run the
# wizard of each enabled service.
# The per-service wizards live in state/<service>/setup.sh.
# The stack assembles compose services with include. compose requires .env; this script creates it when it is missing.
# Safe to run again: the per-service wizards are idempotent. This script
# rewrites the PUBLIC_IP line in the root .env and keeps the other lines.
# It never prints secret values. It prints paths only.
#
# Usage:
#   setup.sh                        Ask which services to enable and for the shared PUBLIC_IP,
#                                   then run the wizard of each enabled service.
#   setup.sh <service> [args...]    Pass the arguments through to the service wizard.
#                                   For example: setup.sh <service> clean
#   setup.sh <service> clean [--data] [--yes]   Remove the service configuration
#                                   (and the service data with --data).
#                                   Not every service supports clean.
#                                   Services may support extra flags.
#
# Non-interactive environment variables:
#   SETUP_SERVICES  Comma-separated list of the services to enable. "all" enables every
#                   service. "none" enables no service. An empty or absent value enables
#                   every service. Surrounding whitespace is ignored. Unknown names are
#                   an error.
#   PUBLIC_IP       Public or LAN IPv4 of this node. The enabled services read it from .env.
#                   compose substitutes ${PUBLIC_IP}.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly KEBAB_CASE='^[a-z0-9]+(-[a-z0-9]+)*$'

# List the known services, one per line, in sorted order.
# A service is a directory directly under state/ that holds a readable setup.sh.
list_known_services() {
  local service_dir service
  for service_dir in state/*/; do
    [ -d "$service_dir" ] || continue
    service="$(basename "$service_dir")"
    if [ -f "${service_dir}setup.sh" ] && [ -r "${service_dir}setup.sh" ]; then
      printf '%s\n' "$service"
    fi
  done | LC_ALL=C sort
}

# Print the known services as a comma-separated list on one line.
known_services_list() {
  local -a known=()
  mapfile -t known < <(list_known_services)
  if [ "${#known[@]}" -eq 0 ]; then
    printf 'none\n'
    return 0
  fi
  local out="${known[0]}"
  local service
  for service in "${known[@]:1}"; do
    out="$out, $service"
  done
  printf '%s\n' "$out"
}

# Return 0 when the argument is a valid IPv4 address. Each octet must be 0 to 255.
is_valid_ipv4() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local octet
  local IFS='.'
  local -a octets
  read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    if [ "$octet" -gt 255 ]; then
      return 1
    fi
  done
  return 0
}

# Parse the PUBLIC_IP value from the root .env file.
# Print the trimmed value. Print nothing when the file or the line is missing.
read_env_public_ip() {
  if [ ! -f .env ]; then
    return 0
  fi
  { grep -E '^PUBLIC_IP=' .env || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/" -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# Resolve the default public or LAN IPv4 of this node.
# Set public_ip_default and public_ip_source.
# The order is: PUBLIC_IP, then the PUBLIC_IP line in the root .env, then autodetection.
# Autodetection uses the first IPv4 from hostname -I on Linux.
# On macOS it uses ipconfig getifaddr en0, then en1.
# The autodetected value is accepted only when is_valid_ipv4 accepts it.
resolve_public_ip_default() {
  local candidate
  if [ -n "${PUBLIC_IP:-}" ]; then
    public_ip_default="$PUBLIC_IP"
    public_ip_source="env"
    return 0
  fi
  candidate="$(read_env_public_ip)"
  if [ -n "$candidate" ]; then
    public_ip_default="$candidate"
    public_ip_source="envfile"
    return 0
  fi
  candidate=""
  if command -v hostname >/dev/null 2>&1; then
    candidate="$(hostname -I 2>/dev/null | awk '{print $1}')" || candidate=""
  fi
  if [ -n "$candidate" ] && is_valid_ipv4 "$candidate"; then
    public_ip_default="$candidate"
    public_ip_source="autodetect"
    return 0
  fi
  candidate=""
  if command -v ipconfig >/dev/null 2>&1; then
    candidate="$(ipconfig getifaddr en0 2>/dev/null)" || candidate=""
    if [ -z "$candidate" ] || ! is_valid_ipv4 "$candidate"; then
      candidate="$(ipconfig getifaddr en1 2>/dev/null)" || candidate=""
    fi
  fi
  if [ -n "$candidate" ] && is_valid_ipv4 "$candidate"; then
    public_ip_default="$candidate"
    public_ip_source="autodetect"
    return 0
  fi
  public_ip_default=""
  public_ip_source="none"
}

# Print an STE error for an invalid resolved public IP and exit 1.
# The message tells the user which source holds the bad value.
public_ip_default_invalid() {
  case "$public_ip_source" in
  env)
    echo "error: PUBLIC_IP '$public_ip_default' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid PUBLIC_IP '$public_ip_default'." >&2
    echo "error: Fix .env by hand or set PUBLIC_IP." >&2
    ;;
  *)
    echo "error: '$public_ip_default' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
    ;;
  esac
  exit 1
}

# Print an STE error for an invalid public IP answer and exit 1.
public_ip_answer_invalid() {
  echo "error: '$1' is not a valid IPv4 address. Each part must be a number from 0 to 255." >&2
  exit 1
}

# Write the root .env with the shared PUBLIC_IP. Keep the other lines.
# Preserve every line except the PUBLIC_IP=... lines.
# When the resolved public IP is empty, keep the preserved lines without a PUBLIC_IP line.
# chmod 0640 the file. Never print the contents beyond the PUBLIC_IP line itself.
write_env_file() {
  local public_ip="$1"
  local tmp_env
  tmp_env="$(mktemp ./.env.tmp.XXXXXX)"
  if [ -f .env ]; then
    { grep -E -v '^PUBLIC_IP=' .env || true; } >"$tmp_env"
  fi
  if [ -n "$public_ip" ]; then
    printf 'PUBLIC_IP=%s\n' "$public_ip" >>"$tmp_env"
  fi
  chmod 0640 "$tmp_env"
  mv "$tmp_env" .env
}

# Dispatch mode: pass the arguments through to the service wizard.
if [ "$#" -ge 1 ]; then
  service="$1"
  if [[ ! "$service" =~ $KEBAB_CASE ]]; then
    echo "error: '$service' is not a valid service name. Use kebab-case, for example 'my-service'." >&2
    echo "usage: setup.sh [<service> [args...]]" >&2
    exit 2
  fi
  if [ -f "state/$service/setup.sh" ] && [ -r "state/$service/setup.sh" ]; then
    exec "$REPO_ROOT/state/$service/setup.sh" "${@:2}"
  fi
  echo "error: '$service' is not a known service. Known services: $(known_services_list)" >&2
  exit 2
fi

# Step 1: discover the services.
mapfile -t services < <(list_known_services)
if [ "${#services[@]}" -eq 0 ]; then
  echo "No services found in state/."
  exit 1
fi

# Create the root .env when it is missing. compose requires it.
if [ ! -e .env ]; then : >.env && chmod 0640 .env; fi

# Regenerate the stack assembler from the current service fragments.
bash "$REPO_ROOT/scripts/compose-assemble.sh"

# Step 2: select the services to enable.
enabled=()
if [ -t 0 ]; then
  for service in "${services[@]}"; do
    if ! read -r -p "Enable the $service service? [Y/n] " answer; then
      answer=""
    fi
    case "${answer:-Y}" in
    [Yy] | [Yy][Ee][Ss])
      enabled+=("$service")
      ;;
    [Nn] | [Nn][Oo])
      ;;
    *)
      echo "error: Answer Y or N." >&2
      exit 1
      ;;
    esac
  done
else
  raw_services="${SETUP_SERVICES:-}"
  trimmed="$(printf '%s' "$raw_services" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//')"
  lowered="$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$trimmed" ] || [ "$lowered" = "all" ]; then
    enabled=("${services[@]}")
  elif [ "$lowered" = "none" ]; then
    enabled=()
  else
    IFS=',' read -r -a tokens <<<"$trimmed"
    requested=()
    for token in "${tokens[@]}"; do
      service_name="$(printf '%s' "$token" | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]')"
      if [ -z "$service_name" ]; then
        continue
      fi
      duplicate=0
      for seen in "${requested[@]}"; do
        if [ "$seen" = "$service_name" ]; then
          duplicate=1
          break
        fi
      done
      if [ "$duplicate" -eq 1 ]; then
        continue
      fi
      requested+=("$service_name")
    done
    for service_name in "${requested[@]}"; do
      match=0
      for service in "${services[@]}"; do
        if [ "$service" = "$service_name" ]; then
          match=1
          break
        fi
      done
      if [ "$match" -eq 0 ]; then
        echo "error: '$service_name' is not a known service. Known services: $(known_services_list)" >&2
        exit 2
      fi
    done
    # Keep the sorted order of the discovered services.
    enabled=()
    for service in "${services[@]}"; do
      for service_name in "${requested[@]}"; do
        if [ "$service" = "$service_name" ]; then
          enabled+=("$service")
        fi
      done
    done
  fi
fi

if [ "${#enabled[@]}" -eq 0 ]; then
  echo "No services enabled."
  exit 0
fi

# Step 3: resolve the public IP of this node. The enabled services advertise it.
resolve_public_ip_default
if [ -n "$public_ip_default" ] && ! is_valid_ipv4 "$public_ip_default"; then
  public_ip_default_invalid
fi
public_ip="$public_ip_default"
if [ -t 0 ]; then
  if ! read -r -p "Public IP of this node for other nodes to connect to? [$public_ip_default] " public_ip_answer; then
    public_ip_answer=""
  fi
  if [ -n "$public_ip_answer" ]; then
    if ! is_valid_ipv4 "$public_ip_answer"; then
      public_ip_answer_invalid "$public_ip_answer"
    fi
    public_ip="$public_ip_answer"
  fi
fi
if [ -z "$public_ip" ]; then
  echo "warning: No public IP was provided. .env is written without PUBLIC_IP." >&2
  echo "warning: The enabled services cannot read PUBLIC_IP from .env." >&2
fi
export PUBLIC_IP="$public_ip"

# Step 4: write the root .env with the shared PUBLIC_IP. Keep the other lines.
write_env_file "$public_ip"

# Step 5: run the wizard of each enabled service, in sorted order.
for service in "${enabled[@]}"; do
  if ! bash "$REPO_ROOT/state/$service/setup.sh"; then
    echo "error: the $service setup failed." >&2
    exit 1
  fi
done

# Step 6: print the summary.
echo "Configured the stack:"
for service in "${enabled[@]}"; do
  echo "  $service"
done
if [ -n "$public_ip" ]; then
  echo "PUBLIC_IP: $public_ip"
else
  echo "PUBLIC_IP: not set"
fi
echo "Next step: docker compose up -d ${enabled[*]}"
