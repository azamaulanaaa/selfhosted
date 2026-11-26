# Traceloop Hub

Traceloop Hub is an open-source LLM gateway written in Rust. It accepts
OpenAI-compatible requests and forwards them to upstream model providers.
This stack runs the official `traceloop/hub` image.

The service runs Hub in YAML Mode. YAML Mode reads a static `config.yaml` at
startup. It needs no PostgreSQL and no management API. Database Mode is out
of scope for this stack.

## YAML Mode configuration

The committed template is `state/traceloop-hub/config.example.yaml`. The
wizard copies it to `config/traceloop-hub/config.yaml` when that file is
absent. The file has the top-level keys `general`, `providers`, `models`, and
`pipelines`.

No provider is active in the shipped template. The `providers`, `models`, and
`pipelines` lists are empty. The gateway does not route requests until you
edit the file. Add a provider, a model, and a pipeline before you send
traffic. Commented examples in the template show each step.

The config supports `${ENV_VAR}` substitution. Keep API keys in environment
variables. Do not write a key into a committed file. The wizard never asks
for API keys. The wizard never prints a secret value.

## Setup

Run the wizard from the repository root:

```bash
bash setup.sh traceloop-hub
```

The wizard writes only under `config/traceloop-hub/`. It never writes
`state/` or `data/`. A second run keeps an existing `config.yaml` unchanged.

The environment variables are:

- `STACK_ROOTLESS`: `1` for rootless nerdctl. `0` for rootful Docker.
- `STACK_UID`: container user id. Default `1000`.
- `STACK_GID`: container group id. Default `1000`.

The wizard reads each value from the process environment. It then reads the
root `.env` file. It uses the default when neither source holds a value.
Invalid values stop the wizard before it writes a file.

## Files and modes

<!-- markdownlint-disable MD013 -->
| Path                               | Mode | Scope      | Presence |
| ---------------------------------- | ---- | ---------- | -------- |
| `config/traceloop-hub`             | 700  | node-local | required |
| `config/traceloop-hub/config.yaml` | 600  | node-local | required |
<!-- markdownlint-enable MD013 -->

The scaling manifest is `state/traceloop-hub/scaling.tsv`. It lists the path,
the mode, the scope, the phase, the presence, and the purpose of each file.

## Rootless mode

Set `STACK_ROOTLESS=1`, `STACK_UID=0`, and `STACK_GID=0` in the root `.env`.
The runtime maps container user 0 to the host user. The host user owns the
config file. Container root reads the read-only mount. The wizard skips the
chown calls in this mode.

In rootful mode the wizard sets the config file owner to `STACK_UID:STACK_GID`.
When `chown` fails, the wizard tries `chgrp` and sets mode 640. It prints a
warning when both calls fail. Set the owner by hand in that case.

## Standalone and integrated modes

Consul is mandatory in both modes. The root `setup.sh` resolves it first.
This service does not read `CONSUL_ADDR`. The compose fragment has no Consul
address and no Consul flag.

Standalone means remote Consul and one service container. The published port
gives direct HTTP access. An external HTTPS proxy can forward to that port.

Integrated means local Consul and the stack Caddy. The root wizard assembles
the vhost descriptor into `config/caddy/vhosts.json`. Restart Caddy after the
enabled service set changes.

## Static vhost

`state/traceloop-hub/vhost.json` is a static descriptor. It proxies
`http://traceloop-hub:3000` at `traceloop-hub.<STACK_DOMAIN>`. Caddy
terminates HTTPS. The compose fragment adds `extra_hosts` for that name so
rootless nerdctl reaches the fixed Caddy address.

## Published port

The gateway listens on container port 3000. The compose fragment publishes
host port 3002 on `${PUBLIC_IP:-127.0.0.1}`. Port 3002 does not collide with
forgejo on 3000 or tinyauth on 3001.

## Data and secrets

The wizard writes no runtime data. YAML Mode needs no database.
`data/traceloop-hub/` stays absent unless you create it.

The config file may hold provider keys after you edit it. The file has mode
600. Save an encrypted copy of the file with the other `config/` secrets. A
restore of the config restores the gateway routes and the provider references.

Keep key values in environment variables outside the repository. The config
substitutes them at container start.

## Clean

Remove the configuration:

```bash
bash setup.sh traceloop-hub clean
```

Add `--data` to remove `data/traceloop-hub/` too. Add `--yes` for a scripted
run. A declined prompt removes nothing. The clean command never touches
`state/`, the root `.env`, or the other services.

## Checks

Run the static smoke check:

```bash
bash state/traceloop-hub/smoke.sh
```

The check uses scratch trees. It needs no Docker, no Consul, and no network.
It covers both tree styles, idempotency, file modes, the compose fragment,
the scaling manifest, the vhost descriptor, and secret log leaks.

The compose fragment is `compose/traceloop-hub.yaml`. Regenerate the root
`compose.yaml` after a fragment change:

```bash
scripts/compose-assemble.sh
```

## Image

The image is `traceloop/hub:0.10.1`. The runtime is distroless nonroot with a
debug shell. The container runs the upstream entrypoint. No custom
entrypoint is mounted. The tag is not a digest pin. Pin a digest before a
production deploy:

<!-- markdownlint-disable MD013 -->
```text
traceloop/hub:0.10.1@sha256:e9d8102db4cef307594e0a888782a8ed2a5a5e4034f5a808188bec9ae0258900
```
<!-- markdownlint-enable MD013 -->
