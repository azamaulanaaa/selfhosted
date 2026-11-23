# Layout contract

## Overview

This document defines where every file in this repository lives. Each
file has one owner. The path shows the owner and the lifecycle of the
file.

The repository has three domains and the repository tooling:

<!-- markdownlint-disable MD013 -->
| Domain    | Location            | Owner                                    | Change mechanism   | In git | In backup                    |
| --------- | ------------------- | ---------------------------------------- | ------------------ | ------ | ---------------------------- |
| `config/` | On disk, gitignored | `setup.sh` wizard                        | Re-run `setup.sh`  | No     | Secret files only, encrypted |
| `state/`  | Committed           | Humans, via commits                      | Commits, CI checks | Yes    | No (git is the record)       |
| `data/`   | On disk, gitignored | Renderer (`run/`) and the app (`store/`) | Runtime            | No     | `store/` only, encrypted     |
<!-- markdownlint-enable MD013 -->

The repository tooling at the root (`Makefile`, `scripts/`, `.github/`,
`.githook/`, `docs/`, `smol/`, `mise.toml`, `cog.toml`, `README.md`,
`LICENSE`) is committed. This contract does not change it.

## Tree

A per-application directory set has this form:

```text
./
├── compose.yaml    # Stack assembler (include of compose/<service>.yaml)
├── compose/
│   └── <service>.yaml  # service definition
├── setup.sh                # service dispatcher
├── config/
│   └── <app>/
│       ├── <app>.env       # wizard answers (domain, email, ...)
│       └── secrets/        # API keys as files, mode 600
├── state/
│   └── <app>/
│       ├── setup.sh          # per-service wizard
│       ├── <app>.env.example # committed example of config/<app>/<app>.env
│       └── Caddyfile         # hand-maintained advanced config, OR
│       └── Caddyfile.tpl     # rendered at runtime; output not committed
└── data/
    └── <app>/
        ├── run/            # renderer output; disposable; no backup
        └── store/     # app payload (certs, buckets); backed up; mode 700
```

## Rules

### `config/` — wizard-owned

- `setup.sh` owns `config/**`. It never writes `state/` or `data/`.
- `setup.sh` is idempotent. A re-run never overwrites a file under
  `config/*/secrets/` without an explicit yes from the user.
- Files under `config/` are mode 600 or 640. `secrets/` directories
  are mode 700.
- Nothing under `config/` is committed. Example files are committed
  under `state/<app>/`.
- `config/` is gitignored.

### `state/` — committed desired state

- `state/` is the committed tree for per-application state, examples,
  and wizards. A service branch commits its fragment to
  `compose/<service>.yaml`.
- No secrets in `state/`, ever.
- Changes to `state/` come only from commits. They are reviewed.
- Hand-maintained advanced configuration (for example `Caddyfile`)
  is edited in `state/<app>/`. It is mounted read-only.
- Template files (for example `Caddyfile.tpl`) are edited in
  `state/<app>/`. Rendered output is never committed.
- Example environment files (`<app>.env.example`) are the only
  committed form of `config/<app>/<app>.env`.
- Service wizards live in `state/<app>/setup.sh` and are committed.
  See [Wizards and cleanup](#wizards-and-cleanup).

### `data/` — runtime only

- `data/` is gitignored.
- `data/<app>/run/` holds renderer output. It is disposable.
  `setup.sh` or the renderer may remove and recreate it. It is never
  backed up.
- `data/<app>/store/` holds the application payload. No repository
  tooling writes it. It is always backed up. Directories are mode 700.
- Certificates and private keys (for example Caddy ACME storage)
  live under `data/<app>/store/`.
- `data/` is never mounted into the wizard or into repository tooling.

### Secrets

- Secrets flow as files: wizard prompt, then
  `config/<app>/secrets/<name>`, then a Docker secret or an `_FILE`
  environment variable (for example `POSTGRES_PASSWORD_FILE`).
- Secrets never appear inline in `compose.yaml`.
- Secrets never appear in `state/`.
- Backups of `store/` and `secrets/` are encrypted. They can contain
  private keys.

### Mounts

- `config/<app>/` is mounted read-only when the application tolerates
  it, or not mounted at all.
- `state/<app>/` files are always mounted read-only.
- `data/<app>/run/` is always mounted read-only.
- `data/<app>/store/` is mounted read-write. The `user:` directive or
  directory ownership matches the application uid.

### Naming

- Application directories use kebab-case.
- Each application has exactly one directory per domain:
  `config/<app>/`, `state/<app>/`, `data/<app>/`.

## Wizards and cleanup

The root `setup.sh` is a dispatcher. It holds no service-specific
logic. It finds the services by scanning `state/*/setup.sh`. It resolves
Consul first. Then it asks for `PUBLIC_IP`. It asks which services to
enable. Then it calls each selected service wizard in turn. Consul is
mandatory. A service wizard never asks about Consul.

The root wizard uses this order:

1. Create `.env` when it is missing.
2. Regenerate `compose.yaml` with `scripts/compose-assemble.sh`.
3. Resolve `CONSUL_ADDR`.
4. Remote: resolve and write the remote token. Local: ask for the peers,
    then ask for `bootstrap_expect`.
5. Run the service enable loop for the other services.
6. Resolve `PUBLIC_IP`.
7. Write `.env`.
8. Run each enabled service wizard in sorted order.

`CONSUL_ADDR` decides Consul. The service enable loop asks only the other
services.

Each service owns one wizard at `state/<app>/setup.sh`. The service
wizard asks the service-specific questions. It generates the service
secrets. It renders the service config files. The root dispatcher does
not know the service questions, the service secrets, or the service
config keys.

Stack-wide values are asked once by the root dispatcher. All services
read them from the root `.env` file. The `.env` file is gitignored.
Per-service values stay in `config/<app>/`.

### Dispatch

- `setup.sh` with no argument runs the dispatcher.
- `setup.sh <app> [args...]` passes the arguments to that service
  wizard. Example: `setup.sh <app> clean`.
- Non-interactive selection comes from `SETUP_SERVICES`. The value is
  a comma-separated list of service names. `all` selects every
  discovered service. `none` selects no service. The default is every
  discovered service.

### Cleanup

Each service wizard supports `clean`.

- `setup.sh <app> clean` removes only `config/<app>/`. It removes the
  wizard answers, the peer lists, the rendered files, and the secrets.
- `data/<app>/` is never removed without `--data`.
- `--data` also removes the whole `data/<app>/` tree. Use it with care.
- Destructive actions ask for confirmation. `--yes` skips the prompt
  for scripted runs. A declined prompt removes nothing and exits 0.
- `clean` never touches `state/`, the root `.env`, or the other
  services.
- After a cleanup, run the service wizard again to regenerate the
  files. A service that was part of a cluster may need its own admin
  commands to leave the cluster cleanly.

## Compose files

The root `compose.yaml` is an assembler. It contains no service
definitions. It includes one file per service from
`compose/<service>.yaml` with the long syntax for `include`. Every
include sets `project_directory: .` so service paths resolve against
the repository layout. Every include reads the root `.env` file. The
stack requires the `.env` file. `setup.sh` creates it when it is
missing.

Each service fragment owns its own service definition. A service branch
contains its fragment and its `state/<service>/` tree. Fragments do not
reference each other. All cross-service references work through the
shared Docker network.

The root wizard prints the `docker compose up -d` command for the enabled
services. In remote mode, that command does not include `consul`.

## Consul control plane

Consul is mandatory. Every service uses Consul. Consul runs in this stack
(local) or outside it (remote). A service never asks about Consul.

`CONSUL_ADDR` selects the location. The root wizard reads it from the
process environment first, then from the root `.env` file. When the value
is present, the root wizard does not ask for the address.

- `http://consul:8500` selects local Consul. The root wizard removes one
  trailing slash before the comparison.
- Any other value selects remote Consul.
- A valid value starts with `http://` or `https://`, has a host, and has
  no whitespace.

The root wizard rejects an empty value. It also rejects a malformed value
and a value with whitespace.

### Remote Consul

- The local `consul` service is not deployed.
- The root wizard asks for the remote ACL token with a hidden prompt.
- The token file is `config/consul/secrets/remote-token`. The file is
  mode 600. The directory is mode 700.
- Non-interactive input is `CONSUL_HTTP_TOKEN`. The root wizard keeps an
  existing token file by default.
- The root wizard removes `consul` from the enabled services. When
  `SETUP_SERVICES` explicitly names `consul`, the root wizard exits with
  an error.
- The root wizard never writes the remote token to `.env`.

### Local Consul

- The root wizard asks for the peer list on every run:
  `Peer IPs, comma-separated? [<current>]`.
- The root wizard asks for `bootstrap_expect` on every run:
  `Consul bootstrap_expect? [<current>]`.
- The answers are stored in the root `.env` as `CONSUL_JOIN_IPS` and
  `CONSUL_BOOTSTRAP_EXPECT`.
- The root wizard exports both values to the `consul` service wizard.
- The root wizard forces `consul` into the enabled services. This applies
  when the user answers no and when `SETUP_SERVICES=none`.
- A missing `state/consul/setup.sh` is an error.

The root wizard rejects a peer list with an invalid IPv4 entry. An empty
peer list is valid. The root wizard trims the whitespace around each
entry. An invalid octet is an error.

The root wizard rejects a `bootstrap_expect` value that is not a number
from 1 to 99.

### Root `.env`

The root wizard owns these keys:

- `CONSUL_ADDR`
- `CONSUL_JOIN_IPS` (local mode)
- `CONSUL_BOOTSTRAP_EXPECT` (local mode)
- `PUBLIC_IP`

The root wizard preserves every other line. It writes the file with mode
0640. In remote mode, it removes `CONSUL_JOIN_IPS` and
`CONSUL_BOOTSTRAP_EXPECT`.

### Non-interactive input

These values come from the environment:

- `CONSUL_ADDR`
- `CONSUL_JOIN_IPS`
- `CONSUL_BOOTSTRAP_EXPECT`
- `CONSUL_HTTP_TOKEN`
- `SETUP_SERVICES`
- `PUBLIC_IP`

When `CONSUL_ADDR` is absent and stdin is not a TTY, the root wizard uses
`http://consul:8500` (local). The root wizard does not prompt when stdin
is not a TTY.

## Standalone and integrated modes

`standalone` means remote Consul plus one service container. Consul is
still required.

`integrated` means local Consul.

Optional capability flags do not define standalone or integrated mode.

### Capability flags

Three capability flags control optional peers and features:

- `LITEFS_ENABLED`
- `OIDC_ENABLED`
- `TLS_ENABLED`

Each flag defaults to `0`. A flag does not select the Consul location.

### Stack domain

`STACK_DOMAIN` is the canonical stack domain. Services read it from the root
`.env` file. It defaults to `sh.lan`. No service may use the `lan` domain.

### Shared secrets

Services read the Consul management token at container start. The token is
`initial_management` in `config/consul/secrets/agent.hcl`. A service must not
copy this token into its own secret tree at wizard time.

Services read the LDAP password at container start. The password is in
`config/ldap/secrets/user-pass`. The lldap wizard writes that file.

### Assembler ownership

The assembler owns the root `compose.yaml`. `scripts/compose-assemble.sh`
generates the file. A service adds one fragment under `compose/`. A service
never edits the root `compose.yaml` or `scripts/compose-assemble.sh`.

### Mode selection

`CONSUL_ADDR` selects the mode. No capability flag selects the mode. Run
`setup.sh` once. The assembler regenerates `compose.yaml` from the
fragments.

## Out of scope

This contract covers placement only.

- Backup scope, encryption format, and schedule: separate document.
- Restore procedure: separate document.
- CI smoke tests for rendering: separate document.
- The template renderer choice: not decided by this contract.

## Not decided

- The `${STACK_ROOT:-.}` path prefix for relocatable checkouts:
  not decided.
- The encrypted restore of `secrets/` against re-entering them
  through the wizard: not decided.
