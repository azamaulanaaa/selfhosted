#!/usr/bin/env bash
# Check the scaling files on one or more node checkouts.
# The check is offline. It reads state/<service>/scaling.tsv and the node files.
# It does not contact a node, start a container, or use the network.
set -euo pipefail

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
readonly SELF

# The self-test sets this value to run against a fixture repository.
REPO_ROOT="$(cd -- "$(dirname -- "$SELF")/.." && pwd)"
if [[ -n "${SCALING_REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd -- "$SCALING_REPO_ROOT" && pwd)"
fi
readonly REPO_ROOT

readonly HASH_PREFIX_LENGTH=12
readonly LOCAL_CONSUL_ADDR="http://consul:8500"

# Print the usage text.
usage() {
  cat <<'EOF'
Usage:
  scripts/check-scaling.sh [--services <list>] <node-dir> [<node-dir>...]
  scripts/check-scaling.sh --selftest
  scripts/check-scaling.sh --help

Check the scaling files on each node checkout. A node checkout has a
config/ directory and a .env file. The .env file holds CONSUL_ADDR. The
value selects the local or remote Consul rows.

Options:
  --services <list>  Check only the comma-separated services. The default
                     is every state/<service>/scaling.tsv manifest.
  --selftest         Run the fixture self-test. This is the default when
                     the command has no arguments.
  --help, -h         Show this text.

The check reads the manifests in the repository. It prints paths, modes,
status, and a short SHA-256 prefix. It never prints a file value.

Exit codes:
  0  Every selected row passes.
  1  A row or a manifest fails.
  2  The command line is invalid.
EOF
}

# Print an error and exit 1. A failed check uses this path.
check_error() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# Print an error and the usage text. A bad command line uses this path.
usage_error() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# Split one manifest line into exactly six tab-separated columns.
# Keep empty columns so a malformed row fails instead of shifting.
# Store the result in COLUMNS.
split_columns() {
  local rest="$1"
  local index
  COLUMNS=()
  for index in 1 2 3 4 5; do
    if [[ "$rest" != *$'\t'* ]]; then
      return 1
    fi
    COLUMNS+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
  if [[ "$rest" == *$'\t'* ]]; then
    return 1
  fi
  COLUMNS+=("$rest")
  return 0
}

# Return 0 when the path is relative and stays inside the node directory.
is_valid_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    return 1
  fi
  if [[ "$path" == /* || "$path" == */ ]]; then
    return 1
  fi
  if [[ ! "$path" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    return 1
  fi
  case "/$path/" in
  *"/../"* | *"/./"* | *"//"*)
    return 1
    ;;
  esac
  return 0
}

# Return 0 when the value is a comma-separated list of three-digit octal modes.
is_valid_mode_list() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-7]{3}(,[0-7]{3})*$ ]]; then
    return 1
  fi
  return 0
}

# Return 0 when the mode is in the allowed list.
is_allowed_mode() {
  local mode="$1"
  local value="$2"
  local allowed
  local -a allowed_modes=()
  IFS=',' read -r -a allowed_modes <<<"$value"
  for allowed in "${allowed_modes[@]}"; do
    if [[ "$mode" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

# Print the mode of a path. Support GNU and BSD stat.
path_mode() {
  local path="$1"
  local mode=""
  if mode="$(stat -c '%a' -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return 0
  fi
  if mode="$(stat -f '%Lp' -- "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return 0
  fi
  return 1
}

# Print the SHA-256 of one file. Never print the file content.
path_hash() {
  local path="$1"
  local hash=""
  if ! hash="$(sha256sum -- "$path" 2>/dev/null | awk '{ print $1 }')"; then
    return 1
  fi
  if [[ -z "$hash" ]]; then
    return 1
  fi
  printf '%s\n' "$hash"
}

# Print the value of one key from an environment file.
# Print nothing when the key is absent. Strip whitespace and matching quotes.
env_value() {
  local key="$1"
  local file="$2"
  local line=""
  local value=""
  if [[ ! -f "$file" ]]; then
    return 0
  fi
  line="$(grep -E "^${key}=" -- "$file" | tail -n1 || true)"
  if [[ -z "$line" ]]; then
    return 0
  fi
  value="${line#*=}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$value" in
  \"*\")
    value="${value#\"}"
    value="${value%\"}"
    ;;
  \'*\')
    value="${value#\'}"
    value="${value%\'}"
    ;;
  esac
  printf '%s\n' "$value"
}

# Read the manifests for the selected services.
# Store the rows in parallel arrays. Reject a duplicate path and a bad column.
declare -a manifest_paths=()
declare -a manifest_modes=()
declare -a manifest_scopes=()
declare -a manifest_whens=()
declare -a manifest_presence=()
declare -a manifest_services=()
declare -a manifest_purposes=()
declare -A seen_paths=()

append_manifest() {
  local service="$1"
  local file="$2"
  local line=""
  local line_number=0
  local path=""
  local mode_list=""
  local scope=""
  local when=""
  local presence=""
  local purpose=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi
    if ! split_columns "$line"; then
      check_error "$file:$line_number: expected six tab-separated columns."
    fi
    path="${COLUMNS[0]}"
    mode_list="${COLUMNS[1]}"
    scope="${COLUMNS[2]}"
    when="${COLUMNS[3]}"
    presence="${COLUMNS[4]}"
    purpose="${COLUMNS[5]}"
    if ! is_valid_path "$path"; then
      check_error "$file:$line_number: '$path' is not a safe relative path."
    fi
    if ! is_valid_mode_list "$mode_list"; then
      check_error "$file:$line_number: '$mode_list' is not a mode list such as 600,640."
    fi
    case "$scope" in
    shared | node-local) ;;
    *)
      check_error "$file:$line_number: '$scope' is not shared or node-local."
      ;;
    esac
    case "$when" in
    both | local | remote) ;;
    *)
      check_error "$file:$line_number: '$when' is not both, local, or remote."
      ;;
    esac
    case "$presence" in
    required | optional) ;;
    *)
      check_error "$file:$line_number: '$presence' is not required or optional."
      ;;
    esac
    if [[ -z "$purpose" ]]; then
      check_error "$file:$line_number: the purpose is empty."
    fi
    if [[ -n "${seen_paths[$path]+set}" ]]; then
      check_error "$file:$line_number: the path '$path' appears more than one time."
    fi
    seen_paths["$path"]=1
    manifest_paths+=("$path")
    manifest_modes+=("$mode_list")
    manifest_scopes+=("$scope")
    manifest_whens+=("$when")
    manifest_presence+=("$presence")
    manifest_services+=("$service")
    manifest_purposes+=("$purpose")
  done <"$file"
}

# Load every selected manifest. The --services value limits the set.
load_manifests() {
  local services_value="$1"
  local service=""
  local file=""
  local directory=""
  local -a requested=()
  local -a files=()
  local -A seen_services=()

  if [[ -n "$services_value" ]]; then
    IFS=',' read -r -a requested <<<"$services_value"
    for service in "${requested[@]}"; do
      if [[ -z "$service" ]]; then
        check_error "The --services value holds an empty service."
      fi
      if [[ ! "$service" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        check_error "'$service' is not a valid service name."
      fi
      if [[ -n "${seen_services[$service]+set}" ]]; then
        check_error "The --services value names '$service' more than one time."
      fi
      seen_services["$service"]=1
      file="$REPO_ROOT/state/$service/scaling.tsv"
      if [[ ! -f "$file" ]]; then
        check_error "The manifest for '$service' is absent: $file"
      fi
      append_manifest "$service" "$file"
    done
    return 0
  fi

  shopt -s nullglob
  files=("$REPO_ROOT"/state/*/scaling.tsv)
  shopt -u nullglob
  if ((${#files[@]} == 0)); then
    check_error "No state/<service>/scaling.tsv manifest exists in $REPO_ROOT."
  fi
  for file in "${files[@]}"; do
    directory="${file%/scaling.tsv}"
    service="${directory##*/}"
    append_manifest "$service" "$file"
  done
}

# Return 0 when a row applies to the given Consul mode.
row_applies() {
  local when="$1"
  local node_mode="$2"
  case "$when" in
  both) return 0 ;;
  local) [[ "$node_mode" == "local" ]] ;;
  remote) [[ "$node_mode" == "remote" ]] ;;
  *) return 1 ;;
  esac
}

# Check every selected row against every applicable node.
check_rows() {
  local -a node_dirs=("$@")
  local -a node_modes=()
  local dir=""
  local addr=""
  local mode=""
  local index
  local row
  local path=""
  local mode_list=""
  local scope=""
  local when=""
  local presence=""
  local service=""
  local applicable=()
  local present=0
  local failures=()
  local first_mode=""
  local first_hash=""
  local first_node=""
  local first_kind=""
  local current_mode=""
  local current_hash=""
  local passed=0
  local failed=0

  for dir in "${node_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      check_error "The node directory is absent: $dir"
    fi
    if [[ ! -d "$dir/config" ]]; then
      check_error "The node directory has no config directory: $dir"
    fi
    if [[ ! -f "$dir/.env" ]]; then
      check_error "The node directory has no .env file: $dir"
    fi
    addr="$(env_value CONSUL_ADDR "$dir/.env")"
    if [[ -z "$addr" ]]; then
      check_error "The node $dir has no CONSUL_ADDR in .env."
    fi
    if [[ "$addr" != http://* && "$addr" != https://* ]]; then
      check_error "The node $dir has an invalid CONSUL_ADDR."
    fi
    addr="${addr%/}"
    if [[ "$addr" == "$LOCAL_CONSUL_ADDR" ]]; then
      mode="local"
    else
      mode="remote"
    fi
    node_modes+=("$mode")
    printf 'node %s: %s Consul\n' "$dir" "$mode"
  done

  for row in "${!manifest_paths[@]}"; do
    path="${manifest_paths[$row]}"
    mode_list="${manifest_modes[$row]}"
    scope="${manifest_scopes[$row]}"
    when="${manifest_whens[$row]}"
    presence="${manifest_presence[$row]}"
    service="${manifest_services[$row]}"
    applicable=()
    present=0
    failures=()
    first_mode=""
    first_hash=""
    first_node=""
    first_kind=""
    for index in "${!node_dirs[@]}"; do
      if ! row_applies "$when" "${node_modes[$index]}"; then
        continue
      fi
      applicable+=("$index")
      if [[ -e "${node_dirs[$index]}/$path" ]]; then
        present=$((present + 1))
      fi
    done
    if ((${#applicable[@]} == 0)); then
      printf 'skip %s %s (no node uses %s Consul)\n' "$service" "$path" "$when"
      continue
    fi
    if [[ "$presence" == "optional" && "$present" -eq 0 ]]; then
      printf 'skip %s %s (optional and absent)\n' "$service" "$path"
      continue
    fi

    for index in "${applicable[@]}"; do
      dir="${node_dirs[$index]}"
      if [[ ! -e "$dir/$path" ]]; then
        failures+=("node $dir: missing")
        continue
      fi
      if [[ ! -f "$dir/$path" && ! -d "$dir/$path" ]]; then
        failures+=("node $dir: not a file or a directory")
        continue
      fi
      if ! current_mode="$(path_mode "$dir/$path")"; then
        failures+=("node $dir: mode is unreadable")
        continue
      fi
      if ! is_allowed_mode "$current_mode" "$mode_list"; then
        failures+=("node $dir: mode $current_mode is not in $mode_list")
        continue
      fi
      if [[ -z "$first_mode" ]]; then
        first_mode="$current_mode"
        first_node="$dir"
        if [[ -d "$dir/$path" ]]; then
          first_kind="dir"
        else
          first_kind="file"
        fi
      fi
      if [[ -d "$dir/$path" ]]; then
        continue
      fi
      if [[ "$scope" == "node-local" ]]; then
        continue
      fi
      if ! current_hash="$(path_hash "$dir/$path")"; then
        failures+=("node $dir: sha256 is unreadable")
        continue
      fi
      if [[ -z "$first_hash" ]]; then
        first_hash="$current_hash"
      elif [[ "$current_hash" != "$first_hash" ]]; then
        failures+=(
          "node $dir: sha256 ${current_hash:0:$HASH_PREFIX_LENGTH} differs from ${first_hash:0:$HASH_PREFIX_LENGTH} on $first_node"
        )
      fi
    done

    if ((${#failures[@]} > 0)); then
      failed=$((failed + 1))
      printf 'FAIL %s %s (%s, %s)\n' "$service" "$path" "$scope" "$when"
      for failure in "${failures[@]}"; do
        printf '  %s\n' "$failure"
      done
      continue
    fi

    passed=$((passed + 1))
    if [[ "$first_kind" == "dir" ]]; then
      printf 'ok   %s %s mode=%s %s %s dir\n' \
        "$service" "$path" "$first_mode" "$scope" "$when"
    elif [[ "$scope" == "shared" ]]; then
      printf 'ok   %s %s mode=%s %s %s sha256=%s\n' \
        "$service" "$path" "$first_mode" "$scope" "$when" \
        "${first_hash:0:$HASH_PREFIX_LENGTH}"
    else
      printf 'ok   %s %s mode=%s %s %s\n' \
        "$service" "$path" "$first_mode" "$scope" "$when"
    fi
  done

  printf 'scaling check: %d passed, %d failed\n' "$passed" "$failed"
  if [[ "$failed" -ne 0 ]]; then
    printf 'FAIL: the scaling files are not consistent.\n' >&2
    return 1
  fi
  printf 'PASS: the scaling files are consistent.\n'
  return 0
}

# Write one fixture manifest with real tabs.
write_fixture_manifest() {
  local file="$1"
  local body="$2"
  printf '%s\n' "$body" >"$file"
}

# Make one fixture node with the three fixture files.
make_fixture_node() {
  local node="$1"
  local node_value="$2"
  mkdir -p "$node/config/dir"
  chmod 0750 "$node/config/dir"
  printf 'CONSUL_ADDR=http://consul:8500\n' >"$node/.env"
  chmod 0640 "$node/.env"
  printf 'shared-value\n' >"$node/config/shared.txt"
  chmod 0600 "$node/config/shared.txt"
  printf '%s\n' "$node_value" >"$node/config/node.txt"
  chmod 0600 "$node/config/node.txt"
}

# Run the checker against one fixture repository.
# The first argument is the expected result: pass or fail.
run_fixture_check() {
  local expected="$1"
  local description="$2"
  local output=""
  local status=0
  shift 2
  set +e
  output="$(SCALING_REPO_ROOT="$fixture_root" "$SELF" "$@" 2>&1)"
  status=$?
  set -e
  if [[ "$expected" == "pass" && "$status" -ne 0 ]]; then
    printf 'FAIL %s\n' "$description" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [[ "$expected" == "fail" && "$status" -ne 1 ]]; then
    printf 'FAIL %s\n' "$description" >&2
    printf 'detail: exit status %d, expected 1\n' "$status" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
  if [[ "$output" == *"shared-value"* || "$output" == *"node-a-value"* ||
    "$output" == *"node-b-value"* ]]; then
    printf 'FAIL %s\n' "$description" >&2
    printf 'detail: the checker printed a file value\n' >&2
    return 1
  fi
  printf 'PASS %s\n' "$description"
  return 0
}

selftest_scratch=""

# Remove the self-test fixture tree.
cleanup_selftest() {
  if [[ -n "$selftest_scratch" ]]; then
    rm -rf -- "$selftest_scratch"
  fi
}

# Run the fixture self-test. It needs no Docker, network, or Consul.
selftest() {
  local fixture_root=""
  local status=0

  selftest_scratch="$(mktemp -d /tmp/scaling-selftest.XXXXXX)"
  trap cleanup_selftest EXIT
  fixture_root="$selftest_scratch/repo"
  mkdir -p "$fixture_root/state/demo" "$fixture_root/state/extra"
  mkdir -p "$fixture_root/state/bad" "$fixture_root/state/dup"

  write_fixture_manifest "$fixture_root/state/demo/scaling.tsv" \
    $'config/shared.txt\t600\tshared\tboth\trequired\tShared fixture file.\nconfig/node.txt\t600\tnode-local\tboth\trequired\tNode-local fixture file.\nconfig/dir\t750\tshared\tboth\trequired\tFixture directory.'
  write_fixture_manifest "$fixture_root/state/extra/scaling.tsv" \
    $'config/extra.txt\t600\tshared\tboth\trequired\tExtra fixture file.'
  write_fixture_manifest "$fixture_root/state/bad/scaling.tsv" \
    $'../escape.txt\t600\tshared\tboth\trequired\tUnsafe fixture path.'
  write_fixture_manifest "$fixture_root/state/dup/scaling.tsv" \
    $'config/shared.txt\t600\tshared\tboth\trequired\tFirst row.\nconfig/shared.txt\t600\tshared\tboth\trequired\tSecond row.'

  make_fixture_node "$fixture_root/node-a" "node-a-value"
  make_fixture_node "$fixture_root/node-b" "node-b-value"

  if ! run_fixture_check pass "all files present and consistent" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi

  printf 'different-value\n' >"$fixture_root/node-b/config/shared.txt"
  if ! run_fixture_check fail "shared hash mismatch" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi
  printf 'shared-value\n' >"$fixture_root/node-b/config/shared.txt"

  chmod 0644 "$fixture_root/node-a/config/node.txt"
  if ! run_fixture_check fail "wrong file mode" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi
  chmod 0600 "$fixture_root/node-a/config/node.txt"

  mv -- "$fixture_root/node-b/config/shared.txt" "$fixture_root/shared.txt"
  if ! run_fixture_check fail "missing required file" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi
  mv -- "$fixture_root/shared.txt" "$fixture_root/node-b/config/shared.txt"

  printf 'node-a-value\n' >"$fixture_root/node-a/config/node.txt"
  if ! run_fixture_check pass "node-local content differs" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi

  chmod 0700 "$fixture_root/node-b/config/dir"
  if ! run_fixture_check fail "wrong directory mode" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi
  chmod 0750 "$fixture_root/node-b/config/dir"

  if ! run_fixture_check fail "a .. manifest path is rejected" \
    --services bad "$fixture_root/node-a"; then
    status=1
  fi

  if ! run_fixture_check fail "a duplicate manifest row is rejected" \
    --services dup "$fixture_root/node-a"; then
    status=1
  fi

  if ! run_fixture_check pass "--services selects a subset" \
    --services demo "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi
  if ! run_fixture_check fail "a full run sees the extra manifest" \
    "$fixture_root/node-a" "$fixture_root/node-b"; then
    status=1
  fi

  trap - EXIT
  rm -rf -- "$selftest_scratch"
  selftest_scratch=""
  if [[ "$status" -ne 0 ]]; then
    printf 'FAIL: scaling self-test\n' >&2
    return 1
  fi
  printf 'PASS: scaling self-test\n'
  return 0
}

main() {
  local services_value=""
  local selftest_mode=0
  local -a node_dirs=()

  while (($# > 0)); do
    case "$1" in
    --help | -h)
      usage
      return 0
      ;;
    --selftest)
      selftest_mode=1
      shift
      ;;
    --services)
      if (($# < 2)); then
        usage_error "--services needs a service list."
      fi
      services_value="$2"
      shift 2
      ;;
    --services=*)
      services_value="${1#*=}"
      shift
      ;;
    --)
      shift
      while (($# > 0)); do
        node_dirs+=("$1")
        shift
      done
      ;;
    -*)
      usage_error "Unknown option '$1'."
      ;;
    *)
      node_dirs+=("$1")
      shift
      ;;
    esac
  done

  if [[ "$selftest_mode" -eq 1 ]]; then
    selftest
    return
  fi
  if ((${#node_dirs[@]} == 0)); then
    if [[ -n "$services_value" ]]; then
      usage_error "--services needs at least one node directory."
    fi
    selftest
    return
  fi

  load_manifests "$services_value"
  check_rows "${node_dirs[@]}"
}

main "$@"
