#!/usr/bin/env bash
# Generate the Traceloop Hub YAML Mode configuration for this stack.
# The wizard copies the committed template into config/traceloop-hub/.
# The wizard keeps an existing config.yaml unchanged on a second run.
# The wizard never asks about Consul. The root wizard resolves Consul first.
# The wizard never prints a secret value. It prints paths only.
#
# Usage:
#   setup.sh traceloop-hub                          Create the YAML config.
#   setup.sh traceloop-hub clean [--data] [--yes]   Remove the configuration.
#                                                   With --data also remove the
#                                                   service data.
#                                                   Ask for confirmation unless
#                                                   --yes is set.
#
# Non-interactive environment variables:
#   STACK_ROOTLESS  1 selects rootless nerdctl. 0 selects rootful Docker.
#   STACK_UID       Container user id. Default 1000.
#   STACK_GID       Container group id. Default 1000.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
readonly REPO_ROOT

readonly CONFIG_DIR="config/traceloop-hub"
readonly CONFIG_FILE="config/traceloop-hub/config.yaml"
readonly TEMPLATE_FILE="state/traceloop-hub/config.example.yaml"
readonly DATA_DIR="data/traceloop-hub"

# Print the value of one key from an environment file.
# Print nothing when the file or the line is missing.
read_env_value() {
  local key="$1"
  local file="$2"
  if [ ! -f "$file" ]; then
    return 0
  fi
  { grep -E "^${key}=" "$file" || true; } | tail -n1 | cut -d= -f2- |
    sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\\1/"
}

# Return 0 when the argument is 0 or 1.
is_valid_rootless() {
  [ "$1" = "0" ] || [ "$1" = "1" ]
}

# Return 0 when the argument is 0 or a positive integer.
is_valid_identity_id() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Print an STE error for an invalid stack identity value and exit 1.
# The message tells the user which source holds the bad value.
stack_identity_invalid() {
  local key="$1"
  local value="$2"
  local source="$3"
  local rule="$4"
  case "$source" in
  env)
    echo "error: $key '$value' is not valid. $rule" >&2
    ;;
  envfile)
    echo "error: The root .env holds the invalid $key '$value'. Fix .env by hand or set $key." >&2
    ;;
  *)
    echo "error: '$value' is not valid. $rule" >&2
    ;;
  esac
  exit 1
}

# Resolve the container runtime identity. Set stack_rootless, stack_uid, and stack_gid.
# Read each value from the process environment, then the root .env file.
# The default is rootful Docker: 0, 1000, 1000.
resolve_stack_identity() {
  local value=""
  local source="none"

  if [ -n "${STACK_ROOTLESS+x}" ]; then
    value="$STACK_ROOTLESS"
    source="env"
  elif [ -f .env ] && grep -qE '^STACK_ROOTLESS=' .env; then
    value="$(read_env_value STACK_ROOTLESS .env)"
    source="envfile"
  else
    value="0"
    source="default"
  fi
  if ! is_valid_rootless "$value"; then
    stack_identity_invalid STACK_ROOTLESS "$value" "$source" "Use 0 or 1."
  fi
  stack_rootless="$value"

  if [ -n "${STACK_UID+x}" ]; then
    value="$STACK_UID"
    source="env"
  elif [ -f .env ] && grep -qE '^STACK_UID=' .env; then
    value="$(read_env_value STACK_UID .env)"
    source="envfile"
  else
    value="1000"
    source="default"
  fi
  if ! is_valid_identity_id "$value"; then
    stack_identity_invalid STACK_UID "$value" "$source" "Use 0 or a positive integer."
  fi
  stack_uid="$value"

  if [ -n "${STACK_GID+x}" ]; then
    value="$STACK_GID"
    source="env"
  elif [ -f .env ] && grep -qE '^STACK_GID=' .env; then
    value="$(read_env_value STACK_GID .env)"
    source="envfile"
  else
    value="1000"
    source="default"
  fi
  if ! is_valid_identity_id "$value"; then
    stack_identity_invalid STACK_GID "$value" "$source" "Use 0 or a positive integer."
  fi
  stack_gid="$value"
}

usage_clean() {
  echo "usage: setup.sh traceloop-hub clean [--data] [--yes]" >&2
}

# Resolve a removal target and make sure it stays inside the base directory.
# Print the resolved absolute path. Return 1 when the target escapes the base.
resolve_removal_target() {
  local target="$1"
  local base="$2"
  local resolved
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath -m -- "$target")" || {
      echo "error: Cannot resolve '$target'." >&2
      return 1
    }
  else
    resolved="$target"
  fi
  case "$resolved" in
  "$base" | "$base"/*)
    printf '%s\n' "$resolved"
    return 0
    ;;
  *)
    echo "error: Refusing to remove '$resolved'. It is not inside '$base'." >&2
    return 1
    ;;
  esac
}

# Remove the Traceloop Hub configuration, and with --data also the data.
# Never touch state/, the root .env, other services, or paths outside the
# resolved config/traceloop-hub and data/traceloop-hub directories.
clean_service() {
  local with_data=0
  local assume_yes=0
  local flag
  for flag in "$@"; do
    case "$flag" in
    --data)
      with_data=1
      ;;
    --yes)
      assume_yes=1
      ;;
    *)
      echo "error: Unknown flag '$flag'." >&2
      usage_clean
      exit 2
      ;;
    esac
  done

  # Refuse to operate when a domain directory is a symlink.
  if [ -L "$REPO_ROOT/config/traceloop-hub" ]; then
    echo "error: '$REPO_ROOT/config/traceloop-hub' is a symlink. Refusing to remove it." >&2
    exit 1
  fi
  if [ "$with_data" -eq 1 ] && [ -L "$REPO_ROOT/$DATA_DIR" ]; then
    echo "error: '$REPO_ROOT/$DATA_DIR' is a symlink. Refusing to remove it." >&2
    exit 1
  fi

  local config_target data_target
  config_target="$(resolve_removal_target "$REPO_ROOT/config/traceloop-hub" "$REPO_ROOT/config/traceloop-hub")" || exit 1
  if [ "$with_data" -eq 1 ]; then
    data_target="$(resolve_removal_target "$REPO_ROOT/$DATA_DIR" "$REPO_ROOT/$DATA_DIR")" || exit 1
  fi

  # Collect the paths to remove. Print each path under config/traceloop-hub.
  # For data/traceloop-hub print the tree root only.
  local -a remove_paths=()
  local path
  if [ -d "$config_target" ]; then
    while IFS= read -r path; do
      remove_paths+=("$path")
    done < <(find "$config_target" -mindepth 1 | LC_ALL=C sort)
    remove_paths+=("$config_target")
  fi
  if [ "$with_data" -eq 1 ] && [ -d "$data_target" ]; then
    remove_paths+=("$data_target")
  fi

  if [ "${#remove_paths[@]}" -eq 0 ]; then
    echo "Nothing to remove."
    return 0
  fi

  echo "This will remove:"
  for path in "${remove_paths[@]}"; do
    echo "  $path"
  done

  if [ "$assume_yes" -eq 0 ]; then
    if [ -t 0 ]; then
      local prompt answer
      if [ "$with_data" -eq 1 ]; then
        prompt="Remove the configuration AND DATA for traceloop-hub? [y/N] "
      else
        prompt="Remove the configuration for traceloop-hub? [y/N] "
      fi
      if ! read -r -p "$prompt" answer; then
        answer=""
      fi
      case "${answer:-N}" in
      [Yy] | [Yy][Ee][Ss])
        ;;
      [Nn] | [Nn][Oo] | "")
        echo "Aborted. Nothing removed."
        return 0
        ;;
      *)
        echo "error: Answer Y or N." >&2
        return 1
        ;;
      esac
    else
      echo "Aborted. Nothing removed."
      echo "hint: Pass --yes to remove without a prompt."
      return 0
    fi
  fi

  rm -rf -- "$config_target"
  if [ "$with_data" -eq 1 ]; then
    rm -rf -- "$data_target"
  fi
  local removed_path
  for removed_path in "${remove_paths[@]}"; do
    echo "removed: $removed_path"
  done

  echo "Removed the Traceloop Hub configuration."
  if [ "$with_data" -eq 1 ]; then
    echo "Removed the Traceloop Hub data."
  fi
  echo "Run 'bash setup.sh traceloop-hub' to generate a fresh config."
  return 0
}

# The clean subcommand removes the configuration and, with --data, the data.
if [ "${1:-}" = "clean" ]; then
  shift
  clean_service "$@"
  exit 0
fi

# Step 1: reject unknown arguments before any write.
if [ "$#" -ne 0 ]; then
  echo "error: Unknown argument '$1'." >&2
  echo "usage: setup.sh traceloop-hub [clean [--data] [--yes]]" >&2
  exit 2
fi

# Step 2: fail early when the template is missing or unreadable.
if [ ! -f "$TEMPLATE_FILE" ] || [ ! -r "$TEMPLATE_FILE" ]; then
  echo "error: '$TEMPLATE_FILE' is missing or unreadable." >&2
  exit 1
fi

# Step 3: resolve and validate the stack identity before any write.
resolve_stack_identity

# Step 4: refuse an existing config that is not a regular file.
if [ -e "$CONFIG_FILE" ] && [ ! -f "$CONFIG_FILE" ]; then
  echo "error: '$CONFIG_FILE' is not a regular file." >&2
  exit 1
fi
if [ -L "$CONFIG_FILE" ]; then
  echo "error: '$CONFIG_FILE' is a symlink. Refusing to use it." >&2
  exit 1
fi

# Step 5: create the config directory with a strict mode.
mkdir -p "$CONFIG_DIR"
chmod 0700 "$CONFIG_DIR"

# Step 6: keep an existing config. Copy the template when no config exists.
config_state="kept"
if [ ! -e "$CONFIG_FILE" ]; then
  tmp_config="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  cp -- "$TEMPLATE_FILE" "$tmp_config"
  chmod 0600 "$tmp_config"
  if [ "$stack_rootless" -eq 0 ]; then
    if ! chown "$stack_uid:$stack_gid" "$tmp_config" 2>/dev/null; then
      if chgrp "$stack_gid" "$tmp_config" 2>/dev/null; then
        chmod 0640 "$tmp_config"
        echo "warning: chown failed for '$CONFIG_FILE'. The file uses mode 640." >&2
      else
        echo "warning: chown failed for '$CONFIG_FILE'. Set the owner by hand." >&2
      fi
    fi
  fi
  mv -- "$tmp_config" "$CONFIG_FILE"
  config_state="created"
fi

# Step 7: print the summary. Never print a config value.
echo "Configured the Traceloop Hub configuration:"
echo "  $CONFIG_FILE ($config_state)"
echo "  $CONFIG_DIR"
echo "Mode: YAML"
echo "hint: Add a provider, a model, and a pipeline to '$CONFIG_FILE' before the gateway routes requests."
if [ "$stack_rootless" -eq 1 ]; then
  echo "hint: Start with nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d traceloop-hub"
else
  echo "hint: Start with docker compose up -d traceloop-hub"
fi
