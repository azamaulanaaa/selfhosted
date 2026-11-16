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

- `state/` is the only committed tree for per-application files.
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
logic. It finds the services by scanning `state/*/setup.sh`. It asks
the stack-wide questions (for example `PUBLIC_IP`). It asks which
services to enable. Then it calls each selected service wizard in turn.

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
