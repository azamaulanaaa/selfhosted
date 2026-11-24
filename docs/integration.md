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
The combined stack has five descriptors: consul, forgejo, lldap, tinyauth,
and vaultwarden.

The root wizard assembles the descriptors of the enabled services into
`config/caddy/vhosts.json` and `config/caddy/vhosts.txt`. Caddy renders one
vhost per descriptor.

The Consul descriptor is `static`. It proxies to `http://consul:8500`.
Garage has no descriptor and no Caddy vhost.

A `litefs` descriptor uses the `<name>/litefs` KV key. When the key exists,
write methods go to the primary and reads go to the local upstream. When the
key is absent, as with `LITEFS_ENABLED=0`, `smart_proxy` falls back to the
local upstream. The vhost never renders an empty handler.

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

## Rootless nerdctl

You can run the stack on rootless nerdctl. Set these keys in the root `.env`:

- `STACK_ROOTLESS=1`
- `STACK_UID=0`
- `STACK_GID=0`
- `CONSUL_DISABLE_PERM_MGMT=1`

The root `setup.sh` exports `STACK_ROOTLESS`, `STACK_UID`, and `STACK_GID`
to the service wizards. It writes `config/compose.env.yaml` after the
wizards finish. That file is generated, not committed. `config/` is
gitignored.

nerdctl compose version 2.4.2 ignores `env_file`. The generated override
supplies the Forgejo, Tinyauth, and Vaultwarden environment files. The
other services read their values from `environment` in the fragments.

Start the stack with both files:

```text
nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d <services>
```

Container root maps to the unprivileged host user. The host user owns the
files under `config/` and `data/`, and container root reads them. The
services run as container root. The wizards do not change the file owner
in rootless mode.

Rootful Docker keeps the current behavior. It reads `env_file` from the
fragments. Do not set the rootless keys on a rootful Docker host.

## Host ports

Forgejo and Tinyauth both use container port 3000. In the combined stack,
Forgejo keeps host port 3000 and Tinyauth uses host port 3001. Caddy still
proxies `forgejo:3000` and `tinyauth:3000`. The container ports do not
change.

## Caddy network and vhost names

`scripts/compose-assemble.sh` writes the default network with subnet
`10.90.0.0/24`. The caddy fragment sets the static address `10.90.0.10`.

Rootless nerdctl resolves a dotted vhost name through the host or tailnet
DNS. It does not use the network alias. The Forgejo and Vaultwarden
fragments add `extra_hosts` for `consul`, `forgejo`, `lldap`, `tinyauth`,
and `vaultwarden`. Each name resolves to `10.90.0.10`. Without these entries,
an app can reach another Tailscale node that serves a different
`*.sh.lan` certificate.

The stack has no caddy network alias block. The `extra_hosts` entries
replace it.

## Caddy CA trust

The caddy internal CA has an intermediate certificate. The entrypoint writes
`data/caddy/store/caddy/ca-bundle.crt` from `intermediate.crt` and
`root.crt`. The bundle holds the intermediate first.

Forgejo and Vaultwarden mount the bundle at
`/etc/ssl/certs/caddy-ca.pem` and set `SSL_CERT_FILE` to that path. The root
certificate alone is not enough. Start these apps after caddy writes the
bundle.

## Startup order

Start the services in four stages. The caddy ACL token needs Consul. The CA
bundle needs Caddy. The apps trust the bundle. The Tinyauth OIDC provider
must run before the apps start their login flows.

1. Start local Consul, LLDAP, and Tinyauth. In remote mode, skip local
    Consul. Wait for the Consul leader and the web UI on port 8500. The
    Tinyauth OIDC provider is now up.
2. Start Caddy. Wait until `data/caddy/store/caddy/ca-bundle.crt` exists.
    Caddy creates the read ACL token through the Consul HTTP API. It renders
    the vhosts from the Consul service list.
3. Start Vaultwarden, Forgejo, and Garage. Vaultwarden and Forgejo read the
    CA bundle. The entrypoints read the LDAP password from
    `config/ldap/secrets/user-pass`. Each entrypoint selects the Consul token
    at container start. Wait for the Garage health check. Then use the Garage
    CLI for the layout. The wizard does not do this step. See
    [`docs/garage.md`](garage.md).
4. Verify the five vhosts and the Tinyauth OIDC discovery endpoint at
    `https://tinyauth.<STACK_DOMAIN>/.well-known/openid-configuration`. The
    vhosts are `consul`, `forgejo`, `lldap`, `tinyauth`, and `vaultwarden`.
    Garage has no vhost.

In local mode, run these commands in order:

```bash
docker compose up -d consul lldap tinyauth
docker compose up -d caddy
# Wait for data/caddy/store/caddy/ca-bundle.crt.
docker compose up -d vaultwarden forgejo garage
```

On rootless nerdctl, use `nerdctl compose -f compose.yaml -f
config/compose.env.yaml` in place of `docker compose` in each command.

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
`caddy-read` policy and token at start. It uses the `consul` CLI when the
image has it. It creates the policy and token through the Consul HTTP API
with `curl` when the CLI is absent. The management token goes in the
`X-Consul-Token` header. The token stays in the runtime store under
`/data/caddy`.

Run the commands below by hand only when the API creation fails.

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
