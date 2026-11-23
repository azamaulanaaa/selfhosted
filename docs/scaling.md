# Scaling

This document answers one question: which file do I copy when I add a
node? It describes the shared and node-local files, the service manifests,
and the offline checker.

The manifests live in `state/<service>/scaling.tsv`. The checker reads
them. The manifests are the source of truth for this document.

## Shared and node-local files

A file has one of two scopes:

- **Shared**: the file must have the same content on every node. Copy it
  from an existing node. The SHA-256 must match. Shared secrets are copied
  in the same way.
- **Node-local**: the file has content for one node. Do not copy it. The
  wizard creates it on each node. Content may differ.

A directory has a mode and no hash. A shared directory must exist with an
allowed mode on every node. Its content may differ.

The mode is the permission bits of the path. A manifest can list more than
one allowed mode. For example, `600,640` permits mode 600 and mode 640.

## Manifest format

Each manifest has one row for each path. The columns are:

<!-- markdownlint-disable MD013 -->
| Column     | Value                          | Meaning                                                     |
| ---------- | ------------------------------ | --------------------------------------------------------    |
| `path`     | Relative path                  | The path under the node root. No absolute path and no `..`. |
| `mode`     | `600` or `600,640`             | The allowed permission bits. Use three octal digits.        |
| `scope`    | `shared` or `node-local`       | Copy a shared path. Do not copy a node-local path.          |
| `when`     | `both`, `local`, or `remote`   | The Consul location that selects this row.                  |
| `presence` | `required` or `optional`       | An optional row may be absent on every node.                |
| `purpose`  | Text                           | The reason for the row.                                     |
<!-- markdownlint-enable MD013 -->

Use one tab between two columns. A line that starts with `#` is a comment.
A duplicate path is an error.

An optional row is skipped when it is absent on every applicable node.
When the path is present on one applicable node, it must be present on all
of them. This rule covers optional files such as the Caddy wildcard
certificate pair.

## Copy commands

Use `install` to set the mode while you copy. Create a directory first.

```bash
install -d -m 700 /srv/node-b/config/consul/secrets
install -m 600 /srv/node-a/config/consul/secrets/gossip.key \
  /srv/node-b/config/consul/secrets/gossip.key
install -m 640 /srv/node-a/config/consul/peers.txt \
  /srv/node-b/config/consul/peers.txt
```

Do not print a secret value. Do not run `cat` on a secret file. The
checker prints a hash prefix, a path, and a mode only.

## Local Consul cluster

Local Consul means `CONSUL_ADDR=http://consul:8500`. Every server uses the
same peer list and the same `bootstrap_expect` value.

### Peer list

The peer list is in the root `.env` as `CONSUL_JOIN_IPS`. The Consul
wizard writes it to `config/consul/peers.txt`. The wizard renders
`config/consul/join.hcl` from that file.

Copy `peers.txt` and `join.hcl` from an existing server to each new
server. The list must name every server in the cluster. Add the new
server to the list on every server. Then run the Consul wizard again on
each server.

### `bootstrap_expect`

The root `.env` holds `CONSUL_BOOTSTRAP_EXPECT`. The Consul wizard writes
it to `config/consul/bootstrap.hcl`.

Use the same value on every server. Set it to the number of Consul
servers. A value of 3 is correct for a three-server cluster. Copy
`bootstrap.hcl` to each new server.

### Reboot order when every Consul server is down

Use this order:

1. Start one server. Prefer the server with the newest
    `data/consul/store` tree.
2. Wait until the process is up. Do not expect a leader yet.
    `bootstrap_expect` holds the election until the other servers join.
3. Start the other servers one at a time.
4. Wait for a leader. Run `consul operator raft list-peers` or read the
    `/v1/status/leader` endpoint.

Do not start every server at the same moment on an unreliable network.

### Gossip key

The gossip key is `config/consul/secrets/gossip.key`. It is a shared
secret. Copy it to every server before you start Consul. A server with a
different key cannot join the gossip pool.

### ACL management token

The management token is the `initial_management` key in
`config/consul/secrets/agent.hcl`. The file also holds the gossip key and
the initial agent token. The file is a shared secret.

Copy `agent.hcl` to every server. The mode is 600 or 640. Do not print the
token. Read it into a command when the Consul CLI needs it.

## Remote Consul

Remote Consul means any valid `http://` or `https://` address other than
`http://consul:8500`.

- Set `CONSUL_ADDR` in the root `.env` to the same value on every node.
- The remote ACL token is `config/consul/secrets/remote-token`. The file
  must match on every node. Copy it with mode 600.
- Do not deploy the `consul` service.
- The root wizard removes `consul` from the enabled services.

`remote-token` is a shared secret. It applies to remote Consul only.

## Garage-only node

Garage is infrastructure only. The operator uses the Garage CLI for the
layout, the buckets, and the access keys. The wizard does not manage these
steps.

A node that runs only Garage can use remote Consul. Set `CONSUL_ADDR` to
the remote address. Then do these steps:

1. Copy `config/garage/secrets/rpc_secret` from an existing Garage node.
    It is a shared secret. Every Garage node must use the same value.
2. Copy `config/consul/secrets/remote-token` from an existing node. It is
    a shared secret.
3. Run the Garage wizard on the new node. It writes `garage.toml` for the
    node address. Do not copy `garage.toml` from another node.
4. Start the service. Read the node ID with the Garage CLI. The
    [Garage documentation](garage.md) gives the commands.
5. Run the checker with `--services garage` and the node directory.

```bash
scripts/check-scaling.sh --services garage /srv/node-c
```

The `--services garage` run checks the Garage files. Run the full check
to include `remote-token`, because the Consul manifest owns that row.

## Caddy

Caddy has three paths that need attention.

- `config/caddy/consul-template.hcl` is shared. Copy it.
- `config/caddy/certs/` is shared when you supply the certificates by
  hand. Use the `existing` TLS mode. Copy `fullchain.pem` with mode 640
  and `privkey.pem` with mode 600.
- `data/caddy/store/` is node-local. It holds the ACME account state and
  the internal CA state. Do not copy it.

The Caddy container creates `data/caddy/store/` at the first start with
mode 700. A client trusts the internal CA from that store. A copied store
gives a second node the same CA state, but you do not need that behavior.
Keep the store on the node that made it.

A wildcard certificate pair is `config/caddy/certs/wildcard/fullchain.pem`
and `config/caddy/certs/wildcard/privkey.pem`. A per-vhost pair is
`config/caddy/certs/<vhost>/fullchain.pem` and
`config/caddy/certs/<vhost>/privkey.pem`. The wildcard pair is optional.

## Service tables

The tables below repeat the manifest rows. The mode column shows the
allowed values.

### Caddy paths

<!-- markdownlint-disable MD013 -->
| Path                                              | Mode      | Scope      | When | Purpose                                   |
| ------------------------------------------------- | --------- | ---------- | ---- | ----------------------------------------- |
| `config/caddy`                                    | 750       | shared     | both | Configuration directory.                  |
| `config/caddy/secrets`                            | 700       | shared     | both | Secret directory. The wizard creates it.  |
| `config/caddy/consul-template.hcl`                | 640       | shared     | both | Consul address and template settings.     |
| `config/caddy/certs`                              | 750       | shared     | both | Manual certificate directory.             |
| `config/caddy/certs/wildcard/fullchain.pem`       | 640       | shared     | both | Optional wildcard certificate chain.      |
| `config/caddy/certs/wildcard/privkey.pem`         | 600       | shared     | both | Optional wildcard private key.            |
| `data/caddy/store`                                | 700       | node-local | both | ACME and internal CA state. Do not copy.  |
<!-- markdownlint-enable MD013 -->

### Consul paths

<!-- markdownlint-disable MD013 -->
| Path                                    | Mode      | Scope      | When   | Purpose                                      |
| --------------------------------------- | --------- | ---------- | ------ | -------------------------------------------- |
| `.env`                                  | 640       | node-local | both   | Root environment file. `PUBLIC_IP` differs.  |
| `config/consul`                         | 750       | shared     | local  | Configuration directory.                     |
| `config/consul/secrets`                 | 700       | shared     | both   | Secret directory.                            |
| `config/consul/consul.hcl`              | 640       | shared     | local  | Rendered server base configuration.          |
| `config/consul/local.hcl`               | 640       | node-local | local  | Node name and advertise address.             |
| `config/consul/bootstrap.hcl`           | 640       | shared     | local  | Cluster `bootstrap_expect` value.            |
| `config/consul/join.hcl`                | 640       | shared     | local  | Rendered `retry_join` peer list.             |
| `config/consul/peers.txt`               | 640       | shared     | local  | Peer list.                                   |
| `config/consul/secrets/agent.hcl`       | 600,640   | shared     | local  | Gossip key and initial ACL tokens.           |
| `config/consul/secrets/gossip.key`      | 600       | shared     | local  | Shared Serf gossip key.                      |
| `config/consul/secrets/remote-token`    | 600       | shared     | remote | Remote Consul ACL token.                     |
<!-- markdownlint-enable MD013 -->

### Forgejo paths

<!-- markdownlint-disable MD013 -->
| Path                                            | Mode | Scope      | When | Purpose                                    |
| ----------------------------------------------- | ---- | ---------- | ---- | ------------------------------------------ |
| `config/forgejo`                                | 750  | shared     | both | Configuration directory.                   |
| `config/forgejo/secrets`                        | 700  | shared     | both | Secret directory.                          |
| `config/forgejo/forgejo.env`                    | 640  | shared     | both | Wizard answers and secret file paths.      |
| `config/forgejo/consul-template.hcl`            | 640  | shared     | both | Consul-template settings.                  |
| `config/forgejo/secrets/secret-key`             | 600  | shared     | both | Forgejo secret key.                        |
| `config/forgejo/secrets/oidc-client-secret`     | 600  | shared     | both | Optional OIDC client secret.               |
| `config/forgejo/secrets/litefs-token`           | 600  | node-local | both | Optional LiteFS Consul token.              |
<!-- markdownlint-enable MD013 -->

### Garage paths

<!-- markdownlint-disable MD013 -->
| Path                                    | Mode | Scope      | When | Purpose                                     |
| --------------------------------------- | ---- | ---------- | ---- | ------------------------------------------- |
| `config/garage`                         | 700  | shared     | both | Configuration directory.                    |
| `config/garage/secrets`                 | 700  | shared     | both | Secret directory.                           |
| `config/garage/garage.toml`             | 600  | node-local | both | Config. The public RPC address differs.     |
| `config/garage/secrets/rpc_secret`      | 600  | shared     | both | RPC secret. It must match on every node.    |
| `config/garage/secrets/admin_token`     | 600  | node-local | both | Admin API token.                            |
| `config/garage/secrets/metrics_token`   | 600  | node-local | both | Metrics token.                              |
<!-- markdownlint-enable MD013 -->

### LLDAP paths

<!-- markdownlint-disable MD013 -->
| Path                                       | Mode | Scope  | When | Purpose                                    |
| ------------------------------------------ | ---- | ------ | ---- | ------------------------------------------ |
| `config/lldap`                             | 700  | shared | both | Configuration directory.                   |
| `config/lldap/secrets`                     | 700  | shared | both | Secret directory.                          |
| `config/lldap/lldap_config.toml`           | 600  | shared | both | Base DN, admin user, and database URL.     |
| `config/lldap/secrets/jwt_secret`          | 600  | shared | both | JWT signing secret.                        |
| `config/lldap/secrets/key_seed`            | 600  | shared | both | Key seed for stored values.                |
| `config/lldap/secrets/ldap_user_pass`      | 600  | shared | both | Admin password copy.                       |
| `config/ldap/secrets`                      | 700  | shared | both | Shared LDAP secret directory.              |
| `config/ldap/secrets/user-pass`            | 600  | shared | both | Canonical LDAP admin password.             |
<!-- markdownlint-enable MD013 -->

### Tinyauth paths

<!-- markdownlint-disable MD013 -->
| Path                                             | Mode | Scope      | When | Purpose                               |
| ------------------------------------------------ | ---- | ---------- | ---- | ----------------------------------    |
| `config/tinyauth`                                | 700  | shared     | both | Configuration directory.              |
| `config/tinyauth/secrets`                        | 700  | shared     | both | Secret directory.                     |
| `config/tinyauth/tinyauth.env`                   | 640  | shared     | both | Wizard answers and file paths.        |
| `config/tinyauth/secrets/oidc`                   | 700  | shared     | both | OIDC key and client secret directory. |
| `config/tinyauth/secrets/oidc/private.pem`       | 600  | shared     | both | OIDC private signing key.             |
| `config/tinyauth/secrets/oidc/public.pem`        | 600  | shared     | both | OIDC public signing key.              |
| `config/tinyauth/secrets/ldap-observer`          | 600  | shared     | both | Observer bind password.               |
| `config/tinyauth/secrets/litefs-token`           | 600  | node-local | both | Optional LiteFS Consul token.         |
<!-- markdownlint-enable MD013 -->

The OIDC client secret files have the client name as the file name. They
live in `config/tinyauth/secrets/oidc/`. Each file is a shared secret with
mode 600.

## How to run the checker

The checker needs the repository and the node directories. It reads
`CONSUL_ADDR` from each node `.env`.

```bash
scripts/check-scaling.sh /srv/node-a /srv/node-b
scripts/check-scaling.sh --services consul /srv/node-a /srv/node-b
scripts/check-scaling.sh --services caddy,garage /srv/node-a /srv/node-b
```

Run the Make target when you use the Makefile:

```bash
make check-scaling SCALING_NODES="/srv/node-a /srv/node-b"
```

Run the fixture self-test with this command:

```bash
scripts/check-scaling.sh --selftest
```

A run with no arguments also runs the self-test. The script
`scripts/ci.sh` calls it that way.

The checker exits 0 when every selected row passes. It exits 1 when a row
or a manifest fails. It exits 2 when the command line is invalid.

## What the checker does not do

The checker is offline. It does these actions:

- It does not contact a node.
- It does not start a container.
- It does not verify a running cluster.
- It does not check Consul quorum, ACLs, the Garage layout, or data
  content.

Use the service smoke checks and the running services for these checks.
