# Combined stack

This document describes how to run the five services together. The services
are caddy, consul, forgejo, lldap, and tinyauth. Garage is not part of this
stack. See [`docs/layout.md`](layout.md) for the file contract and
[`docs/caddy.md`](caddy.md) for the caddy keys.

## Consul is mandatory

Every service uses Consul. Consul runs in this stack (local) or outside it
(remote). The root `setup.sh` asks about Consul first. A service wizard never
asks about Consul.

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
directory mode 700. It does not deploy Consul. Non-interactive input is
`CONSUL_HTTP_TOKEN`.

The root wizard never writes the token to `.env`. It removes `consul` from
the enabled services.

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
2. Start lldap, tinyauth, and forgejo. The entrypoints read the LDAP
    password from `config/ldap/secrets/user-pass`. Each entrypoint selects the
    Consul token at container start.
3. Start caddy last. consul-template renders the vhosts from the Consul
    service list and KV keys.

In local mode, run `docker compose up -d consul`, then the other services,
then `docker compose up -d caddy`.

## Consul token files

A container selects the token file by comparing `CONSUL_ADDR` to
`http://consul:8500`. One trailing slash does not change the comparison.

- Local Consul: the container reads key `initial_management` from
  `config/consul/secrets/agent.hcl`.
- Remote Consul: the container reads the token from
  `config/consul/secrets/remote-token`.

A wizard does not copy the token into its own secret tree.

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
- Keep `STACK_DOMAIN=sh.lan` in `.env`. No service may use the `lan` domain.
- Copy the same OIDC key files to every node before you start a second
  tinyauth node. LiteFS does not replicate them.
- Forgejo peers replicate git over port 3000. Publish that port on each node
  when you run more than one Forgejo node.
