#!/bin/sh
# Start caddy with consul-template embedded.
# 1. Render the Caddyfile one time, with retries, so that caddy starts only
#    after a successful render. Consul may still be starting.
# 2. Start consul-template in watch mode in the background. It rewrites
#    /etc/caddy/Caddyfile and caddy reloads the file itself on change.
# 3. Run caddy in the foreground. This process replaces the shell (PID 1).
set -eu

CFG=/etc/consul-template/config.hcl
max_tries=30
i=0

until consul-template -config="$CFG" -once; do
  i=$((i + 1))
  if [ "$i" -ge "$max_tries" ]; then
    echo "error: consul-template did not render after $max_tries tries." >&2
    echo "error: Check the consul address and the ACL token in $CFG." >&2
    exit 1
  fi
  echo "info: consul does not answer yet (try $i/$max_tries); wait 2 s and try again." >&2
  sleep 2
done

echo "info: consul-template rendered the caddyfile." >&2

consul-template -config="$CFG" &

echo "info: start caddy in watch mode." >&2
exec caddy run --watch --config /etc/caddy/Caddyfile --adapter caddyfile
