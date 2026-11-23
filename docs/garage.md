# Garage

Garage is an S3-compatible object store. This stack runs the official
`dxflrs/garage` image. Garage always uses Consul service discovery. The
wizard writes the `[consul_discovery]` section on every run.

The service has two modes. The `CONSUL_ENABLED` flag in the root `.env`
file selects the mode.

## Standalone mode

Set `CONSUL_ENABLED=0` in the root `.env` file. Run the wizard:

```bash
bash setup.sh garage
```

The wizard asks for the Consul HTTP address. The interactive default is
`http://127.0.0.1:8500`. A non-interactive run must set
`CONSUL_HTTP_ADDR`.

The wizard validates the address. The value must start with `http://` or
`https://` and must have a host. For example:

```bash
CONSUL_HTTP_ADDR=http://192.0.2.10:8500 bash setup.sh garage
```

The wizard also asks for an optional Consul token. The prompt hides the
value. A non-interactive run uses `CONSUL_HTTP_TOKEN`. The wizard writes a
provided token to `config/garage/secrets/consul_token` with mode 600. It
does not create the file when no token is given. The entrypoint never
prints the token.

## Integrated mode

Set `CONSUL_ENABLED=1` in the root `.env` file. Run the wizard:

```bash
bash setup.sh garage
```

The wizard uses `http://consul:8500`. It does not ask for an address. It
does not ask for a token. It does not copy the Consul management token.

At container start the entrypoint reads `initial_management` from
`config/consul/secrets/agent.hcl`. It renders the token into
`/run/garage/garage.toml`. The mount is read-only. The token stays out of
the Garage secret tree.

A `config/garage/secrets/consul_token` file wins over the management
token in both modes. Remove that file when you move a node from standalone
mode to integrated mode.

## Ports

The compose fragment binds every port to `${PUBLIC_IP:-127.0.0.1}`.

| Port | Use                     |
| ---- | ----------------------- |
| 3900 | S3 API                  |
| 3901 | Garage RPC              |
| 3902 | Static website endpoint |
| 3903 | Admin and metrics API   |

## Data and secrets

The wizard writes `config/garage/garage.toml` with mode 600. The file
holds no secrets. The secret files are in `config/garage/secrets/`:

- `rpc_secret`: 32 random bytes as hex.
- `admin_token`: a random base64 token.
- `metrics_token`: a random base64 token.
- `consul_token`: optional. Standalone mode only.

The wizard keeps existing secrets on a second run. Set
`GARAGE_ROTATE_SECRETS=1` to create new RPC, admin, and metrics secrets.
The wizard does not rotate the Consul token.

The container stores metadata in `data/garage/meta` and object data in
`data/garage/data`. Back up both directories. Back up the secrets
directory too.

The S3 endpoint is `http://<PUBLIC_IP>:3900`. The S3 region is `garage`.
The replication factor is 1 by default. Set `GARAGE_REPLICATION_FACTOR` to
change it.

## One-time layout assignment

Garage needs a cluster layout before it can store objects. Start the
service first. Then assign a role to the node. Read the node ID from the
status output:

```bash
docker compose exec garage /garage -c /run/garage/garage.toml status
docker compose exec garage /garage -c /run/garage/garage.toml \
  layout assign -z dc1 -c 1G <node-id>
docker compose exec garage /garage -c /run/garage/garage.toml \
  layout apply --version 1
```

Use a capacity that matches the disk. The `-z dc1` value sets the zone.
The `layout apply` command fails when another layout version exists. In
that case, increment `--version`.

Garage global flags come before the subcommand. The order
`/garage -c <file> status` is correct. The order
`/garage status -c <file>` does not work.

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
