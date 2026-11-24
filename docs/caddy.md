# Caddy

Caddy is the reverse proxy for the stack. It serves the web UIs over HTTPS.
Each UI has one virtual host. The base domain comes from `STACK_DOMAIN`.

## Environment keys

The wizard reads these keys from the process environment, then from the
root `.env` file:

- `STACK_DOMAIN`: base domain for every virtual host. Default `sh.lan`.
- `CONSUL_ADDR`: Consul address. Consul is mandatory. `http://consul:8500`
  is local Consul. Any other valid `http://` or `https://` value is remote
  Consul. Default `http://consul:8500`.
- `LITEFS_ENABLED`: set to `1` when services use LiteFS. Default `0`.
- `OIDC_ENABLED`: set to `1` when services use OIDC. Default `0`.
- `TLS_ENABLED`: set to `1` for managed TLS. Default `0`.
- `CADDY_TLS_MODE`: `internal`, `letsencrypt`, or `existing`.
  `TLS_ENABLED=1` asks for this key. `TLS_ENABLED=0` uses `internal`.
- `CADDY_TLS_EMAIL`: ACME contact for the `letsencrypt` mode.
- `CADDY_TLS_CERT_LAYOUT`: `wildcard` or `per-vhost` for the `existing` mode.
- `CADDY_TLS_CERTS`: certificate input for the `existing` mode. Use
  `wildcard` to keep the existing wildcard pair, `wildcard:<fullchain>:<key>`
  to copy one pair, or a comma-separated `vhost:<fullchain>:<key>` list to
  copy one pair per vhost.

The wizard does not ask about Consul. The root `setup.sh` asks for the
Consul address. See [layout](layout.md).

## Consul

Consul is always required. The wizard writes
`config/caddy/consul-template.hcl` with `address = "<CONSUL_ADDR>"`.

The entrypoint reads the management token from `config/consul/secrets` at
container start:

- Local Consul (`http://consul:8500`): `initial_management` in `agent.hcl`.
- Remote Consul: the token in `remote-token`.

The container mounts `config/consul/secrets` read-only. The wizard never
copies a token into `config/caddy/`.

When the `consul` CLI and the token are both available, the entrypoint
creates the `caddy-read` ACL policy and token. The policy grants read access
to services and KV keys. The token stays in the runtime store under
`/data/caddy`. When the CLI or the token is absent, the entrypoint prints the
commands to create the policy by hand.

consul-template renders `state/caddy/Caddyfile.tpl` once at start. A
supervisor restarts consul-template after a crash. Caddy reloads the file on
change with `caddy run --watch`.

## TLS

`TLS_ENABLED=0` uses `tls internal` on every virtual host. Caddy issues
certificates from its internal CA. Import
`data/caddy/store/caddy/pki/authorities/local/root.crt` on each client.

`TLS_ENABLED=1` asks for `CADDY_TLS_MODE`:

- `internal`: the internal CA.
- `letsencrypt`: ACME with `CADDY_TLS_EMAIL` as the contact.
- `existing`: certificates from `config/caddy/certs`. The layout comes from
  `CADDY_TLS_CERT_LAYOUT` (`wildcard` or `per-vhost`).

TLS does not depend on the Consul location.

## Virtual hosts

Caddy renders one virtual host per descriptor in the vhost registry. The
root `setup.sh` assembles `config/caddy/vhosts.json` from the enabled
`state/<service>/vhost.json` descriptors. The caddy container mounts that
file read-only at `/etc/consul-template/vhosts.json`. The template reads
`CADDY_VHOSTS_FILE` when it is set and uses
`/etc/consul-template/vhosts.json` otherwise.

The root wizard also writes `config/caddy/vhosts.txt` with one vhost name
per line. The caddy wizard reads this file for the TLS certificate list and
for the per-vhost certificate validation.

A descriptor has one of three modes:

- `catalog`: `range service <service>` and append `:<port>`.
- `litefs`: the `smart_proxy` template with the upstream and the redirect
  paths.
- `static`: `reverse_proxy <upstream>` with the `Host` header. When
  `x_real_ip` is true, it also sets the `X-Real-IP` header.

The descriptor schema is in [layout](layout.md#vhost-registry).

This branch has no service descriptors. When the registry is empty, Caddy
renders the fallback vhosts:

- `consul.<STACK_DOMAIN>` proxies to the `consul` service on port 8500.
- `lldap.<STACK_DOMAIN>` proxies to `lldap:17170`.
- `tinyauth.<STACK_DOMAIN>` proxies to `tinyauth:3000`.
- `forgejo.<STACK_DOMAIN>` proxies to `forgejo:3000`.
- `vaultwarden.<STACK_DOMAIN>` proxies to `vaultwarden:80`. It sets the
  `X-Real-IP` header for rate limiting.

When the registry is not empty, Caddy renders only the descriptors in it.
Garage has no descriptor and gets no vhost. After the enabled service set
changes, rerun `setup.sh` and restart caddy.

## Checks

Run `bash state/caddy/smoke.sh` to check the template, the vhost registry, the
fallback vhosts, the TLS vhost list, the token selection, and the
consul-template address.
