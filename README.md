# Selfhosting

![Checks](https://github.com/azamaulanaaa/selfhosting/actions/workflows/ci.yml/badge.svg)

This repository contains the checks, hooks, CI, release flow, and smolvm
sandbox for the selfhosting stack. The sections below show how to install
the hooks, run the checks, commit, and release a version.

To add the checks and tools to an existing repository, see
[Add the checks and tools](docs/adopt.md).

## Requirements

You need `git` and `make`.

The checks need these tools on `PATH`: `cog`, `dclint`, `dockerfmt`,
`editorconfig-checker`, `gitleaks`, `hadolint`, `jactionlint`,
`markdownlint-cli2`, `shellcheck`, `shfmt`, and `zizmor`.

If you use [`mise`](https://mise.jdx.dev/), run `mise install`. Then
activate `mise` in your shell so the tools are on `PATH`.

The sandbox needs `smolvm` and a working host accelerator. See
[Compatibility and limits](#compatibility-and-limits).

## Setup

Run this command from the repository root:

```bash
make hooks
```

The target sets `core.hooksPath` to `.githook`. The target also makes
the two hook files executable.

## Checks

`make ci` runs every check. It calls `scripts/ci.sh`. That script runs
each `scripts/check-*.sh` file in name order. The run stops when a check
fails. On a host with smolvm and a working accelerator, the checks run
inside a smolvm microVM. The microVM is offline and mounts the
repository read-only at `/workspace`. Without them, `make ci` prints a
warning and runs the checks on the host. Set `SMOLVM_ENABLED=1` to
require smolvm. The checks then stop with exit code 3 when smolvm
cannot run. Set `SMOLVM_ADDR` to run
the checks on a remote server. The server has no authentication by
default. Put it behind an authenticated TLS proxy. Set
`SMOLVM_SERVE_TOKEN` to send a bearer token. The scripts do not print
the token. See the [smolvm documentation](docs/smolvm.md).

Run these commands to check one area at a time:

```bash
make check-jactionlint
make check-bash
make check-commits
make check-dclint
make check-dockerfmt
make check-editorconfig
make check-gitleaks
make check-hadolint
make check-markdown
make check-mise
make check-shfmt
make check-zizmor
```

`make check-mise` prints a skip message and exits 0 when `mise` is
absent. `make help` lists every target.

The checks do not change files. They report a problem and exit non-zero.

Run these commands to use the sandbox:

```bash
make smolvm
make smolvm-pack
make smolvm-preflight
make smolvm-verify
make smolvm-exec
make smolvm-clean
```

The sandbox is offline: the microVM runs a baked pack and asks the
registry for nothing. The repository is mounted read-only at
`/workspace`. `make smolvm-preflight` probes whether this host is
ready. `make smolvm-verify` checks that the isolation holds from
inside the guest and from the host. `make smolvm` runs the checks
inside a smolvm microVM against the live working tree.
`make smolvm-pack` builds the cached pack that the sandbox runs
from. It refuses to run while `SMOLVM_ADDR` is set.
`make smolvm-clean` removes the cached packs and deletes the dangling
machines of this checkout. Every resource name has an owner:
`smolvm-build-<owner>-<hash>`, `smolvm-run-<owner>-*`, and
`smolvm-remote-<owner>-*`. With a remote address it also deletes
`smolvm-ci-<owner>-<key>.qcow2` cache bases on the server. In local mode
the owner is the first 12 hex characters of the SHA-256 of the canonical
checkout path. Set `SMOLVM_OWNER` to use a name instead. A shared server
requires `SMOLVM_OWNER`. Use one unique value for each repository. An
empty value stops a remote command before any API call. The value uses
lowercase letters, digits, hyphen, and underscore. It starts with a
letter or a digit. It has at most 16 characters. The target prints the
plan and asks one time. Use `--dry-run` to print the plan only, or
`--yes` to skip the prompt. Set `SMOLVM_CLEAN_ASSUME_YES=1` to skip the
prompt too. A non-interactive run without a skip flag stops with an
error. Machines and bases of another owner stay. When `SMOLVM_OWNER` is
unset, a moved checkout gets a new token. Its old resources become
foreign and are reported, not deleted.
`make smolvm-exec ARGS='...'` runs one command inside the sandbox.
Set `SMOLVM_ADDR` to run the checks on a remote `smolvm serve` server.
Set `SMOLVM_OWNER` to a unique name for this repository. The remote
path needs `curl` and `tar`. It has no host fallback. It sends the git
metadata with the working tree so the checks can read the history.
`make smolvm-pack` refuses to run while `SMOLVM_ADDR` is set. Unset the
variable before you build a local pack.

Set `SMOLVM_CPUS` and `SMOLVM_MEMORY_MB` to change the CPU count and
memory of the machine. The defaults are 1 CPU and 512 MiB. Each value
must be a positive integer.

The [smolvm documentation](docs/smolvm.md) describes the environment
variables, the cache key, and the verify step.

## Format

`make ci` does not write files. Run this command to apply the formatters:

```bash
make format
```

The target calls `scripts/format.sh`. That script runs each
`scripts/format-*.sh` file in name order. The run stops when a formatter
fails.

Run these commands to apply one formatter at a time:

```bash
make format-shfmt
make format-dockerfmt
make format-dclint
```

`make format-shfmt` formats the bash files with `shfmt`.
`make format-dclint` fixes the Docker Compose files with `dclint`.
`make format-dockerfmt` formats the Dockerfile and Containerfile files
with `dockerfmt`. Commit the changed files after `make format`.

GitHub Actions runs the same checks on pull requests and pushes to
`main`. The workflow is `.github/workflows/ci.yml`. The
[check pipeline](docs/ci.md) describes the workflow.

## Git hooks

`make hooks` installs two hooks:

- `.githook/pre-commit` runs `scripts/ci.sh` before each commit.
- `.githook/pre-push` runs `scripts/ci.sh` before each push.

The commit history check does not use a hook. `make check-commits` and
the CI workflow run `scripts/check-commits.sh`.

Do not use `--no-verify` to skip a hook. A failed hook shows a problem.
Fix the problem. Then commit or push again.

## Commit format

Write every commit subject in this form:

```text
<type>(<scope>): <description>
```

`<scope>` is optional. Use one of these types: `feat`, `fix`, `docs`,
`test`, `refactor`, `perf`, `build`, `ci`, `chore`.

The [release workflow](docs/release.md) describes the format and the
version rules.

## Release

Run the release on the `main` branch. `cog.toml` permits a bump on that
branch only. Run this command:

```bash
make release
```

`make release` runs `cog bump --auto` in a smolvm microVM when smolvm
is available. The repository mount stays read-only. The guest clones
the repository to a writable temporary directory. It runs the bump
there. It returns the changelog, one version commit, and the tag as a
git bundle. The host validates the bundle and applies it. The host then
applies the changelog, the version commit, and the tag.

Auto mode prints a warning and runs `cog bump --auto` on the host when
smolvm or the accelerator is unavailable. The host path can change the
repository directly. Set `SMOLVM_ENABLED=0` to force the host path.
Set `SMOLVM_ENABLED=1` to require the sandbox. The run then exits 3 when
no sandbox is available. Set `SMOLVM_ADDR` to use a remote `smolvm
serve` server. See the [smolvm documentation](docs/smolvm.md).

The host applies the bundle only after it validates the bundle. The
checks cover the tag, the parent commit, the changed path, and the author
and committer email. A failure does not apply the release. Concurrent
work stays.

Pass release arguments with `ARGS`. For example:

```bash
make release ARGS='--dry-run'
```

`--auto` is the default selector. When `ARGS` holds `--auto`,
`--version`, `--major`, `--minor`, or `--patch`, the release does not add
`--auto`.

Run this command to see the next version on the host:

```bash
cog bump --dry-run --auto
```

The command changes nothing. A sandbox release with `--dry-run` also
changes nothing and exits 0.

The first release needs an explicit version. Run one of these commands:

```bash
make release ARGS='--version 1.0.0'
make release ARGS='--version 0.1.0'
```

Use `1.0.0` when the public interface is stable. Use `0.1.0` when the
interface can change. The flags `--major`, `--minor`, and `--patch` also
replace `--auto`.

## Compatibility and limits

The local sandbox ran on Linux x86_64 with KVM and smolvm 1.35.1. The
remote session flow, a streamed stdin, and a local-directory upload ran
against `smolvm serve` v1.35.4. The streamed exec path ran against
v1.33.0. Check each version against your server before you rely on a
feature.

The remote release path ran on `smolvm serve` v1.35.5 with the cache
disk off.

These paths are not verified:

- The full `make ci` run over HTTP. Live remote runs used
  `make smolvm-exec`.
- The local sandbox release path. No live `smolvm machine run` release
  has run.
- The release pack build and cache reuse path. The remote release ran
  with `SMOLVM_SERVE_CACHE=0`.
- A successful cache publish and a warm init. The tested Windows server
  attached a seed base but refused every publish.
- macOS on Apple Silicon. The detection exists, but the path is
  untested.
- The isolation check on a KVM host. `make smolvm-verify` has not
  printed `result=isolation_held` there yet.

See the [smolvm documentation](docs/smolvm.md) for the full list.

## Repository layout

- `.github/workflows/ci.yml` defines the check workflow for GitHub
  Actions.
- `.githook/` contains the two Git hooks.
- `scripts/` contains the check scripts, the format scripts, the
  `ci.sh` entry point, the release scripts, and the `smolvm.sh`,
  `smolvm-clean.sh`, `smolvm-exec.sh`, and `smolvm-serve.sh` helpers.
- `smol/` contains the smolvm base machine, the shared `init.sh`
  provisioning script, and the pack build script.
- `docs/` contains the check, the release, and the smolvm documents.
- `cog.toml` contains the `Cocogitto` settings for commits, changelog,
  and tags.
- `Makefile` contains the command targets for setup, checks, and
  release.
- `mise.toml` contains the tool version constraints.
- `LICENSE` contains the license text.

## Services

- `garage` is an S3-compatible object store. It always uses Consul
  service discovery. See the [Garage document](docs/garage.md).

## Documentation

- The [Garage document](docs/garage.md) describes the object store modes,
  ports, data directories, and the Garage CLI steps.
- The [check pipeline](docs/ci.md) describes how the checks run and how
  to add a check.
- The [release workflow](docs/release.md) describes the commit format
  and the release steps.
- The [smolvm](docs/smolvm.md) describes the sandbox settings,
  the pack cache, and the known limits.

## License

This project uses the MIT License. See [`LICENSE`](LICENSE).

Copyright (c) 2026 Selfhosting maintainers.
