# Caddy

Caddy is the reverse proxy for the stack. It serves the web UIs over HTTPS.
Each UI has one virtual host. The base domain comes from `STACK_DOMAIN`.

## Environment keys

The wizard reads these keys from the root `.env` file:

- `STACK_DOMAIN`: base domain for every virtual host. Default `sh.lan`.
- `CONSUL_ENABLED`: set to `1` for integrated mode. Default `0`.
- `LITEFS_ENABLED`: set to `1` when services use LiteFS. Default `0`.
- `OIDC_ENABLED`: set to `1` when services use OIDC. Default `0`.
- `TLS_ENABLED`: set to `1` for managed TLS. Default `0`.
- `CADDY_TLS_MODE`: `internal`, `letsencrypt`, or `existing`. Integrated mode
  asks for this key. Standalone mode uses `internal`.
- `CADDY_TLS_EMAIL`: ACME contact for the `letsencrypt` mode.
- `CADDY_TLS_CERT_LAYOUT`: `wildcard` or `per-vhost` for the `existing` mode.
- `CADDY_USE_LOCAL_CONSUL`: set to `0` to use a remote Consul agent. Default
  `1`. Integrated mode only.
- `CADDY_CONSUL_HOST`: remote Consul address. Required when
  `CADDY_USE_LOCAL_CONSUL=0`.
- `CADDY_CONSUL_PORT`: remote Consul HTTP port. Default `8500`.

## Standalone mode

Set every capability flag to `0`. The container renders
`state/caddy/Caddyfile.static.tpl` into `/etc/caddy/Caddyfile`. The upstreams
are static. The file has no consul-template calls. The container uses
`tls internal` and self-signed certificates. It does not wait for Consul.
It serves a page on `https://<STACK_DOMAIN>`.

## Integrated mode

Set `CONSUL_ENABLED=1`. The wizard writes `config/caddy/consul-template.hcl`.
The container reads `initial_management` from
`config/consul/secrets/agent.hcl` when it starts. The wizard never copies
that token into `config/caddy/secrets/`.

When the `consul` CLI and the token are both available, the entrypoint
creates the `caddy-read` ACL policy and token. The policy grants read access
to services and KV keys. The token stays in the runtime store under
`/data/caddy`. When the CLI or the token is absent, the entrypoint prints the
exact commands to create the policy by hand.

consul-template renders `state/caddy/Caddyfile.tpl` once at start. A
supervisor restarts consul-template after a crash. Caddy reloads the file on
change with `caddy run --watch`.

## Virtual hosts

- `consul.<STACK_DOMAIN>` proxies to `consul:8500`.
- `lldap.<STACK_DOMAIN>` proxies to `lldap:17170`.
- `tinyauth.<STACK_DOMAIN>` proxies to `tinyauth:3000`.
- `forgejo.<STACK_DOMAIN>` proxies to `forgejo:3000`.

## Checks

Run `bash state/caddy/smoke.sh` to render both templates and check them.
