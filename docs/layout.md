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
├── compose.yaml            # stack definition (repo root)
├── setup.sh                # interactive wizard
├── config/
│   └── <app>/
│       ├── <app>.env       # wizard answers (domain, email, ...)
│       └── secrets/        # API keys as files, mode 600
├── state/
│   └── <app>/
│       ├── <app>.env.example # committed example of config/<app>/<app>.env
│       └── Caddyfile       # hand-maintained advanced config, OR
│       └── Caddyfile.tpl # rendered at runtime; output not committed
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

### `data/` — runtime only

- `data/` is gitignored.
- `data/<app>/run/` holds renderer output. It is disposable.
  `setup.sh` or the renderer may delete and recreate it. It is never
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

## Out of scope

This contract covers placement only.

- Backup scope, encryption format, and schedule: separate document.
- Restore procedure: separate document.
- CI smoke tests for rendering: separate document.
- The template renderer choice (`consul-template` or `gomplate`):
  not decided by this contract.
- The compose file layout (single root `compose.yaml` against
  per-application files): not decided by this contract. The tree
  above shows a root `compose.yaml` as the current form.

## Not decided

- The `${STACK_ROOT:-.}` path prefix for relocatable checkouts:
  not decided.
- The encrypted restore of `secrets/` against re-entering them
  through the wizard: not decided.
