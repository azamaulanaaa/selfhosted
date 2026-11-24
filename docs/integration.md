# Combined stack

This document describes how to run the seven services together. The services
are caddy, consul, forgejo, garage, lldap, tinyauth, and vaultwarden. See
[`docs/layout.md`](layout.md) for the file contract,
[`docs/scaling.md`](scaling.md) for the shared and node-local files, and
[`docs/caddy.md`](caddy.md) for the caddy keys.

## Consul is mandatory

The stack requires Consul. Consul runs in this stack (local) or outside it
(remote). The root `setup.sh` asks about Consul first. A service wizard never
asks about Consul.

Most services use Consul for service discovery. Vaultwarden is the one
exception: its container does not use Consul directly. The stack still
requires Consul for the other services.

`CONSUL_ADDR` selects the location:

- `http://consul:8500` selects local Consul. The setup deploys the `consul`
  service.
- Any other valid `http://` or `https://` value selects remote Consul. The
  setup does not deploy the `consul` service.

A valid address starts with `http://` or `https://`, has a host, and has no
whitespace.

### Local mode

The root wizard asks for the peer list and for `bootstrap_expect`. It stores
both values in `.env` as `CONSUL_JOIN_IPS` and `CONSUL_BOOTSTRAP_EXPECT`. It
then deploys Consul with the other enabled services.

The root wizard forces the `consul` service into the enabled list. This
applies when the user answers no and when `SETUP_SERVICES=none`.

### Remote mode

The root wizard asks for the remote ACL token with a hidden prompt. It writes
the token to `config/consul/secrets/remote-token` with mode 600. It gives the
directory mode 700. It does not deploy Consul. The non-interactive token
input is `CONSUL_HTTP_TOKEN`.

The root wizard never writes the token to `.env`. It removes `consul` from
the enabled services.

## Services

- **caddy** is the reverse proxy. It serves the lldap, tinyauth, forgejo and
  vaultwarden web UIs over HTTPS. It also proxies the Consul web UI in local
  mode.
- **consul** is the service registry and the KV store. It runs only in local
  mode.
- **forgejo** is the Git forge.
- **garage** is the S3-compatible object store.
- **lldap** is the LDAP server.
- **tinyauth** is the authentication proxy.
- **vaultwarden** is the password manager. It uses SSO through Tinyauth.

### Garage

Garage is infrastructure only. The operator uses the Garage CLI for the
layout, the buckets, and the access keys. The wizard does not manage these
steps. It writes the secrets and the config file only.

Garage always uses Consul service discovery. It has no Consul-free mode.
`CONSUL_ADDR` selects local or remote Consul.

Garage publishes four ports on `PUBLIC_IP`:

| Port | Use                     |
| ---- | ----------------------- |
| 3900 | S3 API                  |
| 3901 | Garage RPC              |
| 3902 | Static website endpoint |
| 3903 | Admin and metrics API   |

`PUBLIC_IP` defaults to `127.0.0.1`. Set it to a trusted LAN address to
reach these ports from another host. Trusted LAN only.

A node that runs only Garage can use remote Consul. Set `CONSUL_ADDR` to
the remote address. The node keeps the same `rpc_secret` as the other
Garage nodes. See [`docs/garage.md`](garage.md) and
[`docs/scaling.md`](scaling.md).

### Vaultwarden

Caddy serves `vaultwarden.<STACK_DOMAIN>` and proxies to `vaultwarden:80`.
The vhost sets the `X-Real-IP` header. The container listens on port 80.

Vaultwarden uses SSO through Tinyauth only. The master password is still
required. SSO replaces the account login. It does not unlock the vault.

Add one Tinyauth client before the first login:

- Name: `vaultwarden`
- Redirect URI:
  `https://vaultwarden.<STACK_DOMAIN>/identity/connect/oidc-signin`

The Vaultwarden wizard reads `config/tinyauth/secrets/oidc/vaultwarden`
when the file exists. Create the client with the Tinyauth wizard or the
Tinyauth admin UI.

Attachments and Sends are disabled. The stack has no S3 backend, and the
official image has no S3 support. SMTP is off by default.

Vaultwarden is single-node. It uses SQLite in `data/vaultwarden/store`. Do
not run two nodes on one SQLite file. See
[`docs/vaultwarden.md`](vaultwarden.md) and
[`docs/scaling.md`](scaling.md).

## Vhost registry

Each web service commits one descriptor at `state/<service>/vhost.json`.

The root wizard assembles the descriptors of the enabled services into
`config/caddy/vhosts.json` and `config/caddy/vhosts.txt`. Caddy renders one
vhost per descriptor.

Garage has no descriptor and no Caddy vhost.

After the enabled service set changes, rerun `setup.sh` and restart caddy.

The descriptor schema is in [`docs/layout.md`](layout.md#vhost-registry).

## Capability flags

The root `.env` file holds three capability flags:

- `LITEFS_ENABLED` gates LiteFS.
- `OIDC_ENABLED` gates OIDC.
- `TLS_ENABLED` gates the caddy TLS mode question.

Each flag defaults to `0`. A flag does not select the Consul location.

`STACK_DOMAIN` defaults to `sh.lan`. `PUBLIC_IP` holds the address that peers
use to reach this node.

## Startup order

Start the services in this order:

1. In local mode, start consul first. Wait for a leader and for the web UI
    on port 8500. In remote mode, skip this step.
2. Start lldap, tinyauth, forgejo, and garage. The entrypoints read the LDAP
    password from `config/ldap/secrets/user-pass`. Each entrypoint selects the
    Consul token at container start. Wait for the Garage health check. Then
    use the Garage CLI for the layout. The wizard does not do this step. See
    [`docs/garage.md`](garage.md).
3. Start vaultwarden. Start it after tinyauth, because it uses Tinyauth as
    its OIDC provider.
4. Start caddy last. consul-template renders the vhosts from the Consul
    service list and KV keys.

In local mode, run `docker compose up -d consul`, then
`docker compose up -d lldap tinyauth forgejo garage`, then
`docker compose up -d vaultwarden`, then `docker compose up -d caddy`.

## Consul token files

A container selects the token file by comparing `CONSUL_ADDR` to
`http://consul:8500`. One trailing slash does not change the comparison.

- Local Consul: the container reads key `initial_management` from
  `config/consul/secrets/agent.hcl`.
- Remote Consul: the container reads the token from
  `config/consul/secrets/remote-token`.

A wizard does not copy the token into its own secret tree. Caddy, forgejo,
garage, lldap and tinyauth mount `config/consul/secrets` read-only.

## Caddy read policy

Consul uses `default_policy = "deny"`. The caddy entrypoint creates the
`caddy-read` policy and token at start when the Consul CLI and the management
token are available. If the CLI is absent, the entrypoint prints these
commands. Run them by hand.

For local Consul, read `initial_management` from
`config/consul/secrets/agent.hcl`:

```bash
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
export CONSUL_HTTP_TOKEN=<initial_management>
printf 'service_prefix "" { policy = "read" }\n' > /tmp/caddy-read.hcl
printf 'key_prefix "" { policy = "read" }\n' >> /tmp/caddy-read.hcl
consul acl policy create -name caddy-read -rules @/tmp/caddy-read.hcl
consul acl token create -description 'caddy read' -policy-name caddy-read
```

For remote Consul, read the token from
`config/consul/secrets/remote-token`. Set `CONSUL_HTTP_ADDR` to the remote
address. Then run the same commands.

The policy grants read access to the service list and the KV keys.

## Operator steps

- Run `bash state/<service>/smoke.sh` for each service before you start it.
  The scripts use scratch trees and need no Docker.
- Run `scripts/check-scaling.sh` before you add a node. See
  [`docs/scaling.md`](scaling.md).
- Keep `STACK_DOMAIN=sh.lan` in `.env`. No service may use the `lan` domain.
- Copy the same OIDC key files to every node before you start a second
  tinyauth node. LiteFS does not replicate them.
- Forgejo peers replicate git over port 3000. Publish that port on each node
  when you run more than one Forgejo node.
- Use the Garage CLI for the layout, the buckets, and the access keys. Do
  not add a layout or key step to the wizard.
