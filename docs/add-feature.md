# Add a service

This guide describes how to add one service to the self-hosted stack. It
records the rules that the seven-service stack proved on a rootless arm64
host. Use it for each new service.

Domain terms:

- A **service** is one application in the stack.
- **Desired state** is the committed description of a service.
- **Runtime data** is the content that a container writes at run time.
- A **wizard** is a `setup.sh` script that asks the questions for one
  service.
- A **vhost** is one HTTPS name that Caddy serves for a service.
- A **rootless host** runs containers without host root.

## Delivery model

One feature gets one branch, one worktree, and one agent. Use
`/tmp/worktree/<key>` for the worktree. Use `feature/<service>` for the
branch. The worktree branch starts at the current default branch.

```bash
git worktree add -b feature/<service> /tmp/worktree/<key>
```

When the branch already exists, omit `-b`.

Write one commit for each scope. Use Conventional Commits:

```text
feat(<service>): add the service
docs(<service>): describe the service
test(<service>): cover the service
```

Do not merge without a user request. Keep `main` clean until the user asks
for a merge.

## Repository contract

| Path                | Content                              | In git |
| ------------------- | ------------------------------------ | ------ |
| `state/<service>/`  | Desired state for one service        | Yes    |
| `config/<service>/` | Wizard answers, secrets, and renders | No     |
| `data/<service>/`   | Runtime data                         | No     |

`config/` and `data/` are gitignored. The wizard owns `config/`. The
container owns `data/`. No commit writes either tree.

The root assembler `scripts/compose-assemble.sh` adds one include for each
`compose/<service>.yaml` to `compose.yaml`. The root wizard assembles the
descriptors of the enabled services into `config/caddy/vhosts.json` and
`config/caddy/vhosts.txt`.

## Files a service owns

A service owns these files:

- `state/<service>/setup.sh` asks the questions and writes
  `config/<service>/`.
- `state/<service>/entrypoint.sh` runs in the container. It reads
  environment values and mounted files.
- `compose/<service>.yaml` defines the service for the root assembler.
- `state/<service>/vhost.json` describes the Caddy vhost. A non-web
  service has no descriptor.
- `state/<service>/smoke.sh` runs a static check. It does not start a
  container.
- `state/<service>/scaling.tsv` lists the shared and node-local paths.
- `docs/<service>.md` documents the service.

Do not edit the root `compose.yaml`. The root assembler owns it. Do not add
service logic to the root `setup.sh`. The root dispatcher calls the service
wizard.

## Write the wizard

The service wizard is `state/<service>/setup.sh`. It asks the service
questions. It writes `config/<service>/`. It never writes `state/` or
`data/`.

The wizard is idempotent. A second run keeps the existing secrets and the
existing answers. It never prints a secret value. It prints paths only.

The root dispatcher finds a service by `state/*/setup.sh`. Run the wizard
alone with this command:

```bash
bash setup.sh <service>
```

The wizard never asks about Consul. The root `setup.sh` resolves Consul
first. See [Consul first](#consul-first).

## Consul first

Consul is always present. Only the location changes.

`CONSUL_ADDR` in the environment or the root `.env` is authoritative. When
the value is set, do not ask for it. One trailing slash does not change the
comparison with the local address.

- `http://consul:8500` means local Consul.
- Any other value means remote Consul.

Local Consul asks for the peer list and `bootstrap_expect` on every run. A
service never asks about Consul. A local service uses the local Consul.

The local management token is `initial_management` in
`config/consul/secrets/agent.hcl`. The remote token is
`config/consul/secrets/remote-token` with mode 600.

The stack must also work standalone: remote Consul plus one service
container. A service does not require the local Consul.

## Vhost registry

A web service commits one descriptor at `state/<service>/vhost.json`. A
service without a web UI commits no descriptor.

Every descriptor has `name` and `mode`. A `static` or `litefs` descriptor
adds `upstream`. A `catalog` descriptor adds `service` and `port`.

| Mode      | Behavior                                                       |
| --------- | -------------------------------------------------------------- |
| `static`  | Reverse-proxies one fixed upstream.                            |
| `litefs`  | Routes writes to the LiteFS primary from Consul KV.            |
| `catalog` | Reads the Consul service catalog.                              |

Examples:

```json
{"name":"forgejo","mode":"static","upstream":"http://forgejo:3000"}
{"name":"vaultwarden","mode":"static","upstream":"http://vaultwarden:80","x_real_ip":true}
{"name":"tinyauth","mode":"litefs","upstream":"http://tinyauth:3000","redirect_paths":"[]"}
{"name":"app","mode":"catalog","service":"app","port":8080}
```

Add `redirect_paths` and `x_real_ip` only when the service needs them. For
a `litefs` descriptor, `redirect_paths` is a JSON string such as `"[]"`.

Caddy renders one vhost per descriptor. After you change the enabled
service set, run `bash setup.sh` and restart Caddy.

## Write the entrypoint

The entrypoint is `state/<service>/entrypoint.sh`. It runs in the
container. It reads only environment values and mounted files.

The entrypoint selects the Consul token by `CONSUL_ADDR`:

- Local Consul: read `initial_management` from
  `config/consul/secrets/agent.hcl`.
- Remote Consul: read `config/consul/secrets/remote-token`.

Do not copy the token into the service secret tree. Mount
`config/consul/secrets` read-only.

## Rootless nerdctl

Set these keys in the root `.env`:

```text
STACK_ROOTLESS=1
STACK_UID=0
STACK_GID=0
```

Set `CONSUL_DISABLE_PERM_MGMT=1` for the local Consul in rootless mode.
Container root maps to the host user. Do not expect real root.

Rootless `nerdctl compose` ignores `env_file`. Run `scripts/compose-env.sh`
and pass `config/compose.env.yaml` with `-f`:

```bash
bash scripts/compose-env.sh
nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d <service>
```

`nerdctl compose` converts a healthcheck `CMD` exec form to `CMD-SHELL` and
prints a warning. Write the healthcheck in shell form:

```yaml
healthcheck:
  test: curl -fsS http://127.0.0.1:3000/api/healthz
```

A long inline compose command can be truncated by nerdctl. Put the script
in a file. Mount the file into the container.

Rootless ports below 1024 need
`net.ipv4.ip_unprivileged_port_start=0`.

A stale rootless port forwarder can survive
`systemctl --user restart containerd`. Recover the stack in this order:

```bash
nerdctl compose -f compose.yaml -f config/compose.env.yaml down
nerdctl ps -a
nerdctl rm -f <container>
systemctl --user restart containerd
nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d <service>
```

Run a full `nerdctl compose down` first. Remove the project containers.
Restart the runtime. Then start the stack.

Do not run Docker commands on the rootless host. Select the engine in the
scripts.

## Staged startup

Start Consul first. Wait until Consul answers before you run the data-init
job. Run the Consul data-init job next. The job must exit with code 0.
Start the applications. Start Caddy last, after Consul answers.

```bash
nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d consul
nerdctl compose -f compose.yaml -f config/compose.env.yaml up consul-data-init
nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d <services>
nerdctl compose -f compose.yaml -f config/compose.env.yaml up -d caddy
```

Caddy creates its read ACL token at start. If Consul is not ready, the
token creation fails and KV reads return 403.

## Caddy specifics

The fixed Caddy network is `10.90.0.0/24`. Caddy uses `10.90.0.10`.

Add each vhost name to `extra_hosts` for the application containers.
Tailnet DNS can return a different node with a different certificate.

```yaml
extra_hosts:
  - "forgejo.${STACK_DOMAIN}:10.90.0.10"
```

Mount the Caddy CA bundle into the application containers. Set
`SSL_CERT_FILE` to the mount path.

The CA bundle must contain the intermediate certificate and the root
certificate. The root certificate alone fails. Test each vhost with
`curl --cacert` and `--resolve`:

```bash
curl --cacert data/caddy/store/caddy/ca-bundle.crt \
  --resolve forgejo.sh.lan:443:10.90.0.10 \
  https://forgejo.sh.lan/
```

A `litefs` vhost must use a static proxy as the fallback when
`LITEFS_ENABLED=0`. Without the fallback, Caddy polls Consul KV that it
cannot read and every vhost fails.

## LiteFS specifics

LiteFS needs a FUSE mount and the `SYS_ADMIN` capability. Rootless FUSE
works.

```yaml
cap_add:
  - SYS_ADMIN
devices:
  - /dev/fuse
```

LiteFS reads `CONSUL_HTTP_TOKEN`. It does not read
`CONSUL_HTTP_TOKEN_FILE`.

LiteFS names its Consul session after the hostname, not `litefs`. Grant
`session_prefix ""` when the session name is not fixed.

LiteFS stores the cluster ID at `<key>/clusterid`. The Consul rule must
use `key_prefix "<service>/litefs"`. A `key` rule matches one exact key
only and causes a 403.

```text
key_prefix "<service>/litefs" { policy = "write" }
session_prefix "" { policy = "write" }
```

An existing policy is reused. The entrypoint must read the existing rules,
compare them, and update the policy when they differ.

LiteFS needs a stable `advertise-url`. Publish it in the lease value:

```yaml
lease:
  type: "consul"
  advertise-url: "http://<PUBLIC_IP>:20202"
```

## Ports

Do not use the same host port twice across the stack. Tinyauth uses host
port 3001. Forgejo uses host port 3000.

## Checks before a merge request

Run `bash -n` on every changed shell script:

```bash
bash -n state/<service>/setup.sh
bash -n state/<service>/entrypoint.sh
```

Run `shellcheck` on every changed shell script:

```bash
shellcheck state/<service>/setup.sh state/<service>/entrypoint.sh
```

Run `shfmt -i 2 -d` on every changed shell script:

```bash
shfmt -i 2 -d state/<service>/setup.sh state/<service>/entrypoint.sh
```

Run the service smoke check:

```bash
bash state/<service>/smoke.sh
```

Run the Compose environment check:

```bash
bash scripts/check-compose-env.sh
```

Run the editorconfig checker:

```bash
editorconfig-checker
```

Run the full check suite on the host:

```bash
SMOLVM_ENABLED=0 bash scripts/ci.sh
```

Run the container test on a real host when Docker or nerdctl is available.
Do not claim a container test passed when no container ran.

## Report to the user

Report the branch, the commits, the test commands, and the results. Report
a blocker with its cause and the decision you need.
