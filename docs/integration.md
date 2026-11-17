# Combined stack

This document describes how to run the five services together. The services
are consul, lldap, caddy, tinyauth, and forgejo. See
[`docs/layout.md`](layout.md) for the file contract and
[`docs/caddy.md`](caddy.md) for the caddy keys.

## Capability flags

The root `.env` file holds four capability flags. `STACK_DOMAIN` defaults to
`sh.lan`. `PUBLIC_IP` holds the address that peers use to reach this node.

- `CONSUL_ENABLED`
- `LITEFS_ENABLED`
- `OIDC_ENABLED`
- `TLS_ENABLED`

Each flag defaults to `0`. A service with every flag at `0` runs in standalone
mode. Set all four flags to `1` for the combined stack. Run `setup.sh` once
after you change the flags. The script regenerates `compose.yaml` from the
files in `compose/`. Do not edit `compose.yaml` by hand.

## Startup order

Start the services in this order:

1. Start consul. Wait for a leader and for the web UI on port 8500.
2. Start lldap, tinyauth, and forgejo. The entrypoints read the LDAP password
    from `config/ldap/secrets/user-pass`. They read the Consul management
    token from `config/consul/secrets/agent.hcl` at start. Wizards do not copy
    the token into their own secret trees.
3. Start caddy last. In integrated mode consul-template renders the vhosts
    from the Consul service list and KV keys.

Run `docker compose up -d consul`, then the other services, then
`docker compose up -d caddy`.

## Caddy read policy

Consul uses `default_policy = "deny"`. The caddy entrypoint creates the
`caddy-read` policy and token at start when the Consul CLI and the management
token are available. If the CLI is absent, the entrypoint prints these
commands. Run them by hand:

```bash
export CONSUL_HTTP_ADDR=http://127.0.0.1:8500
export CONSUL_HTTP_TOKEN=<initial_management>
printf 'service_prefix "" { policy = "read" }\n' > /tmp/caddy-read.hcl
printf 'key_prefix "" { policy = "read" }\n' >> /tmp/caddy-read.hcl
consul acl policy create -name caddy-read -rules @/tmp/caddy-read.hcl
consul acl token create -description 'caddy read' -policy-name caddy-read
```

The policy grants read access to the service list and the KV keys.

## Operator steps

- Run `bash state/<service>/smoke.sh` for each service before you start it.
  The scripts use scratch trees and need no Docker.
- Keep `STACK_DOMAIN=sh.lan` in `.env`. No service may use the `lan` domain.
- Copy the same OIDC key files to every node before you start a second
  tinyauth node. LiteFS does not replicate them.
- Forgejo peers replicate git over port 3000. Publish that port on each node
  when you run more than one Forgejo node.
