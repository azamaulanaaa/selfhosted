#!/usr/bin/env bash
# Check scripts/compose-env.sh with a fixture tree.
# The fixture holds two service environment files and one unsafe value.
# The check also covers the empty case.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/check-compose-env.XXXXXX")"
trap 'rm -rf -- "$tmp_root"' EXIT

fail() {
  echo "error: $1" >&2
  exit 1
}

mkdir -p "$tmp_root/scripts" "$tmp_root/config/svc-one" "$tmp_root/config/svc-two"
cp "$REPO_ROOT/scripts/compose-env.sh" "$tmp_root/scripts/compose-env.sh"
chmod +x "$tmp_root/scripts/compose-env.sh"

env_one="$tmp_root/config/svc-one/svc-one.env"
env_two="$tmp_root/config/svc-two/svc-two.env"
output="$tmp_root/config/compose.env.yaml"

# The GREETING value holds a space, a single quote, a colon, and a dollar sign.
cat >"$env_one" <<'EOF'
# A comment line. The script must skip it.
DOMAIN=https://svc-one.sh.lan

GREETING=it's a $VALUE: next
SSO_ENABLED=true
EOF

# The TOKEN value holds a space, a hash, a colon, and an equal sign.
printf 'TOKEN=a b#c:d=e\n' >"$env_two"

bash "$tmp_root/scripts/compose-env.sh"

if [ ! -f "$output" ]; then
  fail "The override file is missing: config/compose.env.yaml"
fi
if ! grep -Fqx -- '  svc-one:' "$output"; then
  fail "The override has no svc-one service."
fi
if ! grep -Fqx -- '  svc-two:' "$output"; then
  fail "The override has no svc-two service."
fi
if ! grep -Fqx -- "      - 'DOMAIN=https://svc-one.sh.lan'" "$output"; then
  fail "The override has the wrong DOMAIN value."
fi
if ! grep -Fqx -- "      - 'GREETING=it''s a \$VALUE: next'" "$output"; then
  fail "The override has the wrong GREETING value."
fi
if ! grep -Fqx -- "      - 'TOKEN=a b#c:d=e'" "$output"; then
  fail "The override has the wrong TOKEN value."
fi
if grep -Fq -- 'A comment line' "$output"; then
  fail "The override holds a comment line from an environment file."
fi

rm -f -- "$env_one" "$env_two"
bash "$tmp_root/scripts/compose-env.sh"

if ! grep -Fqx -- 'services: {}' "$output"; then
  fail "The empty override does not hold 'services: {}'."
fi
if grep -Fq -- 'svc-one' "$output" || grep -Fq -- 'svc-two' "$output"; then
  fail "The empty override holds a service name."
fi

echo "checked the Compose environment override"
