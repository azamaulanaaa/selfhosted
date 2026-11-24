# Garage

Garage is an S3-compatible object store. This stack runs the official
`dxflrs/garage` image. Garage always uses Consul service discovery.
Garage has no Consul-free mode. The wizard writes the
`[consul_discovery]` section on every run.

The root setup resolves Consul. The Garage wizard never asks for a Consul
address and never asks for a Consul token. The root setup reads
`CONSUL_ADDR` from the process environment, then from the root `.env`
file. It writes the value to the root `.env` file before it runs the
service wizards.

## Modes

`CONSUL_ADDR` selects the mode. No flag selects the mode. Run
`bash setup.sh` once to resolve Consul and to run this wizard.

- `standalone` means remote Consul plus one service container.
- `integrated` means local Consul in this stack.

Remove one trailing slash from `CONSUL_ADDR` before the comparison with
`http://consul:8500`.

### Standalone mode

Standalone mode uses remote Consul. Set `CONSUL_ADDR` to the remote
address. For example:

```bash
CONSUL_ADDR=https://consul.example.test:8501 bash setup.sh
```

The address must start with `http://` or `https://` and must have a host.
The root setup writes the remote ACL token to
`config/consul/secrets/remote-token` with mode 600. It never writes the
token to the `.env` file.

### Integrated mode

Integrated mode uses local Consul. Set `CONSUL_ADDR` to
`http://consul:8500`, or accept the default:

```bash
CONSUL_ADDR=http://consul:8500 bash setup.sh
```

The root setup enables the local `consul` service. The wizard does not
copy the Consul management token.

## Consul token

At container start the entrypoint selects one token file. It compares
`CONSUL_ADDR` to `http://consul:8500`.

- Local Consul: the entrypoint reads `initial_management` from
  `config/consul/secrets/agent.hcl`.
- Remote Consul: the entrypoint reads `config/consul/secrets/remote-token`.

The compose fragment mounts the whole `config/consul/secrets/` directory
read-only at `/etc/garage/consul-secrets`. The entrypoint renders the
token into `/run/garage/garage.toml`. It never prints the token.

## Ports

The compose fragment binds every port to `${PUBLIC_IP:-127.0.0.1}`.

| Port | Use                     |
| ---- | ----------------------- |
| 3900 | S3 API                  |
| 3901 | Garage RPC              |
| 3902 | Static website endpoint |
| 3903 | Admin and metrics API   |

Garage has no Caddy virtual host. Clients use the S3 API on port 3900. The
static website endpoint on port 3902 is separate from the Caddy vhost
registry. Garage is not a web UI.

## Data and secrets

The wizard writes `config/garage/garage.toml` with mode 600. The file
holds no secrets. The secret files are in `config/garage/secrets/`:

- `rpc_secret`: 32 random bytes as hex.
- `admin_token`: a random base64 token.
- `metrics_token`: a random base64 token.

The wizard keeps existing secrets on a second run. Set
`GARAGE_ROTATE_SECRETS=1` to create new RPC, admin, and metrics secrets.

The container stores metadata in `data/garage/meta` and object data in
`data/garage/data`. Back up both directories. Back up the secrets
directory too.

The S3 endpoint is `http://<PUBLIC_IP>:3900`. The S3 region is `garage`.
The replication factor is 1 by default. Set `GARAGE_REPLICATION_FACTOR` to
change it.

## Garage CLI

The wizard does not manage the cluster layout, the buckets, or the access
keys. The operator uses the Garage CLI for these steps. Garage global
flags come before the subcommand. The order `/garage -c <file> status` is
correct. The order `/garage status -c <file>` does not work.

Start the service first.

### Layout

Garage needs a cluster layout before it can store objects. Read the node
ID from the status output:

```bash
docker compose exec garage /garage -c /run/garage/garage.toml status
```

Assign a role to the node, then apply the layout:

```bash
docker compose exec garage /garage -c /run/garage/garage.toml \
  layout assign -z dc1 -c 1G <node-id>
docker compose exec garage /garage -c /run/garage/garage.toml \
  layout apply --version 1
```

Use a capacity that matches the disk. The `-z dc1` value sets the zone.
The `layout apply` command fails when another layout version exists. In
that case, increment `--version`.

### Buckets and access keys

Create a bucket:

```bash
docker compose exec garage /garage -c /run/garage/garage.toml \
  bucket create <bucket>
```

Create an access key and allow it on the bucket:

```bash
docker compose exec garage /garage -c /run/garage/garage.toml \
  key create <key-name>
docker compose exec garage /garage -c /run/garage/garage.toml \
  bucket allow --read --write <bucket> --key <key-name>
```

The `key create` command prints the secret key. Store the secret in a safe
place. It is not in the wizard files.

## Health check

The compose fragment runs this command as a health check:

```text
/garage -c /run/garage/garage.toml status
```

The command reads the local metadata and prints the node status. It works
in the scratch image and needs no shell.

## Clean

Run this command to remove the Garage configuration:

```bash
bash setup.sh garage clean --yes
```

Add `--data` to remove `data/garage` too. Add `--yes` for a scripted run.

## Checks

Run the smoke check:

```bash
bash state/garage/smoke.sh
```

The check uses a scratch tree. It needs no Docker and no Consul.

## Image

The official Garage image is built `FROM scratch`. It has no shell. The
local `state/garage/Dockerfile` adds a static BusyBox and the CA
certificates. The final image keeps the Garage binary from the official
image.
