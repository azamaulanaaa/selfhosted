# Vaultwarden

Vaultwarden is a small, Bitwarden-compatible password manager. It serves the
Bitwarden web vault and the Bitwarden clients. This stack runs the official
`vaultwarden/server` image. It does not build a custom image.

The service uses OIDC through Tinyauth. It has no local password login.
Attachments and Sends are disabled. The service uses SQLite on one node.

All configuration secrets are files under `config/vaultwarden/secrets/`. The
environment file holds only non-secret settings and `_FILE` paths.

## Single sign-on only

`SSO_ONLY=true` disables password login. The user signs in through the OIDC
issuer. In the combined stack, Tinyauth is the issuer. In standalone mode,
the issuer is an external OIDC provider.

The master password is still required. SSO replaces the account login. It
does not replace the master password that unlocks the vault. A new user
creates a master password after the first SSO login.

The OIDC callback URL is:

```text
https://vaultwarden.<STACK_DOMAIN>/identity/connect/oidc-signin
```

### Tinyauth client

Add one Tinyauth client before the first login:

- Name: `vaultwarden`
- Redirect URI:
  `https://vaultwarden.<STACK_DOMAIN>/identity/connect/oidc-signin`

Use the Tinyauth wizard or the Tinyauth admin UI. The Tinyauth wizard writes
the client secret to `config/tinyauth/secrets/oidc/vaultwarden`. The
Vaultwarden wizard reads that file when it exists. When the file is absent,
the wizard asks for the client secret.

The redirect URI must match exactly. A mismatch stops the OIDC flow at
Tinyauth.

## Modes

The root `setup.sh` resolves Consul before it runs this wizard. Consul is
always required. The Vaultwarden container does not read `CONSUL_ADDR`. The
compose fragment has no Consul address and no Consul flag.

### Rootless runtime

Rootless nerdctl runs the container as user 0. The runtime maps container
user 0 to the host user. The host user owns the files under `config/` and
`data/`. Container root reads those files.

Set `STACK_ROOTLESS=1`, `STACK_UID=0`, and `STACK_GID=0` in the root `.env`.
The compose fragment uses `${STACK_UID:-1000}` and `${STACK_GID:-1000}` as
the container user. The wizard reads the same keys.

In rootless mode, the wizard does not chown the secret directory, the OIDC
secret file, or the data store. It keeps the mode changes. The host user
stays the owner. The full contract is in
[layout](layout.md#rootless-container-runtime).

### Standalone

Standalone means remote Consul, an external OIDC provider, and an external
HTTPS reverse proxy. The container serves HTTP. The reverse proxy terminates
TLS and forwards to port 8080 on `PUBLIC_IP`.

```bash
STACK_DOMAIN=example.com \
CONSUL_ADDR=https://consul.example.com:8501 \
VAULTWARDEN_OIDC_ISSUER=https://auth.example.com \
VAULTWARDEN_OIDC_CLIENT_ID=vaultwarden \
VAULTWARDEN_OIDC_CLIENT_SECRET='<client secret>' \
bash setup.sh
```

The issuer must start with `https://`. The external OIDC provider must
accept the callback URL above. The external proxy must forward the
`X-Real-IP` header. The compose fragment sets `IP_HEADER=X-Real-IP`.

The public URL is `https://vaultwarden.<STACK_DOMAIN>` by default. Set
`VAULTWARDEN_DOMAIN` to use another public URL.

### Integrated

Integrated means local Tinyauth and local Caddy. The Vaultwarden wizard
detects `state/tinyauth/setup.sh`. It then defaults the issuer to
`https://tinyauth.<STACK_DOMAIN>` and the client ID to `vaultwarden`. The
Caddy vhost serves `vaultwarden.<STACK_DOMAIN>` and proxies `vaultwarden:80`.

The service has the vhost descriptor `state/vaultwarden/vhost.json`. The
descriptor uses `static` mode with the upstream `http://vaultwarden:80`. It
sets `x_real_ip`, so Caddy sends `X-Real-IP` and Vaultwarden reads that
header. The root wizard assembles the enabled descriptors into
`config/caddy/vhosts.json`. The descriptor schema is in
[layout](layout.md#vhost-registry).

## Setup

Run the wizard from the repository root:

```bash
bash setup.sh vaultwarden
```

The wizard asks these questions:

- OIDC issuer. Default `https://tinyauth.<STACK_DOMAIN>` when local Tinyauth
  exists.
- OIDC client ID. Default `vaultwarden`.
- OIDC client secret. The wizard reads the local Tinyauth file when it
  exists. Otherwise it asks with a hidden prompt.
- `Allow new users through SSO? [Y/n]`.

The public URL is `https://vaultwarden.<STACK_DOMAIN>`. Set
`VAULTWARDEN_DOMAIN` to override it.

The non-interactive environment variables are:

- `STACK_DOMAIN`
- `VAULTWARDEN_DOMAIN`
- `VAULTWARDEN_OIDC_ISSUER`
- `VAULTWARDEN_OIDC_CLIENT_ID`
- `VAULTWARDEN_OIDC_CLIENT_SECRET`
- `VAULTWARDEN_SSO_SIGNUPS` (`yes` or `no`)
- `VAULTWARDEN_ROTATE_OIDC_SECRET` (`1` replaces the existing secret)
- `STACK_ROOTLESS` (`1` skips the chown calls)
- `STACK_UID` (container user id, default `1000`)
- `STACK_GID` (container group id, default `1000`)
- `PUBLIC_IP` (compose only, not read by this wizard)

The wizard writes these files:

<!-- markdownlint-disable MD013 -->
| Path                                             | Mode | Owner                  | When     |
| ------------------------------------------------ | ---- | ---------------------- | -------- |
| `config/vaultwarden/vaultwarden.env`             | 600  | current user           | always   |
| `config/vaultwarden/secrets`                     | 700  | `STACK_UID` when able  | always   |
| `config/vaultwarden/secrets/oidc-client-secret`  | 600  | `STACK_UID`            | always   |
| `config/vaultwarden/secrets/admin_token`         | 600  | `STACK_UID`            | optional |
| `config/vaultwarden/secrets/smtp_password`       | 600  | `STACK_UID`            | optional |
| `data/vaultwarden/store`                         | 700  | `STACK_UID`            | always   |
<!-- markdownlint-enable MD013 -->

The wizard never prints a secret value. It prints paths only.

The container mounts the whole secrets directory. The container user is
`STACK_UID:STACK_GID`, default `1000:1000`. The wizard sets the directory
owner to that identity. When `chown` fails, it prints a warning. Set the
owner by hand in that case. The container must traverse the directory to
read the secret files. In rootless mode the wizard skips this chown.

The wizard makes each secret file readable by the container user. It uses
`chown STACK_UID:STACK_GID`. When `chown` fails, it uses `chgrp STACK_GID`
and mode 640. When both fail, it prints a warning. Set the owner by hand in
that case. In rootless mode the wizard skips this chown.

The data store needs owner `STACK_UID:STACK_GID` so the container can write
the SQLite database. The wizard sets it when possible and prints a warning
when it cannot. In rootless mode the host user stays the owner.

The wizard is idempotent. A second run rewrites the managed keys in the
environment file and keeps the other lines. It keeps the existing OIDC secret
unless the Tinyauth secret changed, a new secret was entered, or
`VAULTWARDEN_ROTATE_OIDC_SECRET=1` is set. It keeps an existing admin token
or SMTP password unless the matching environment variable is set.

## No secure files

Vaultwarden calls attachments and Sends "secure files". This stack disables
all of them:

- `SENDS_ALLOWED=false`
- `USER_ATTACHMENT_LIMIT=0`
- `ORG_ATTACHMENT_LIMIT=0`
- `USER_SEND_LIMIT=0`

The web vault does not offer attachments or Sends. The Bitwarden clients
receive an error when a user tries to create one.

This stack has no S3 backend. The upstream `s3` feature is experimental.
The official `vaultwarden/server` image does not include it. Do not add S3
settings. A custom image with the feature is out of scope for this stack.

`SIGNUPS_VERIFY=false` and `REQUIRE_DEVICE_EMAIL=false` complete the
no-email setup. Email verification and device email are not available.

## Admin and email

The admin panel is disabled by default. The wizard writes
`ADMIN_TOKEN_FILE=/run/secrets/vaultwarden/admin_token` only when
`config/vaultwarden/secrets/admin_token` exists. Set
`VAULTWARDEN_ADMIN_TOKEN` to create that file. The file has mode 600. The
wizard never prints the value.

The stack does not configure SMTP by default. These features are unavailable
until you add SMTP settings:

- Invitations
- Email verification
- Email two-factor authentication

The wizard does not prompt for admin or SMTP settings. It accepts these
optional environment variables without a prompt:

- `VAULTWARDEN_ADMIN_TOKEN`
- `VAULTWARDEN_SMTP_HOST`
- `VAULTWARDEN_SMTP_FROM`
- `VAULTWARDEN_SMTP_PORT`
- `VAULTWARDEN_SMTP_SECURITY`
- `VAULTWARDEN_SMTP_USERNAME`
- `VAULTWARDEN_SMTP_PASSWORD`

`VAULTWARDEN_ADMIN_TOKEN` writes `config/vaultwarden/secrets/admin_token`.
`VAULTWARDEN_SMTP_PASSWORD` writes
`config/vaultwarden/secrets/smtp_password`. The other SMTP variables write
non-secret keys to the environment file.

The wizard writes `ADMIN_TOKEN_FILE` only when `admin_token` exists. It
writes `SMTP_PASSWORD_FILE` only when `smtp_password` exists. It never writes
`ADMIN_TOKEN` or `SMTP_PASSWORD` values to the environment file.

On a rerun, an existing `admin_token` or `smtp_password` file stays unless
the matching environment variable is set.

For SMTP, the environment file holds only the non-secret settings:

```text
SMTP_HOST=mail.example.com
SMTP_FROM=vaultwarden@example.com
SMTP_PORT=587
SMTP_SECURITY=starttls
SMTP_USERNAME=vaultwarden
```

The secret paths are also in the environment file when the files exist:

```text
ADMIN_TOKEN_FILE=/run/secrets/vaultwarden/admin_token
SMTP_PASSWORD_FILE=/run/secrets/vaultwarden/smtp_password
```

To add a secret by hand, write the file under
`config/vaultwarden/secrets/` with mode 600. Then run the wizard. The wizard
writes the matching `_FILE` key. Do not add `ADMIN_TOKEN` or `SMTP_PASSWORD`
to the environment file. Vaultwarden also accepts `_FILE` variants for other
secret keys. Add a mount for the file when you use one.

## Data and secrets

All configuration secrets are files under `config/vaultwarden/secrets/`.
Back up these paths:

- `data/vaultwarden/store`: the SQLite database, `config.json`, the RSA
  signing keys, and the icon cache. The directory has mode 700.
- `config/vaultwarden/secrets/oidc-client-secret`: the OIDC client secret.
  The file has mode 600. It must match the Tinyauth client.
- `config/vaultwarden/secrets/admin_token`: the optional admin token. The
  file has mode 600.
- `config/vaultwarden/secrets/smtp_password`: the optional SMTP password.
  The file has mode 600.
- `config/vaultwarden/vaultwarden.env`: the non-secret settings and the
  `_FILE` paths. The file has mode 600. It holds no secret values.

Back up the secrets encrypted. The store holds the vault data and the
signing keys. A restore without the store loses every vault.

## Single-node limit

Vaultwarden is single-node. It uses SQLite in `data/vaultwarden/store`. Do
not start two containers on the same SQLite file. Do not copy the store to a
second node and start it there.

This stack does not use LiteFS for Vaultwarden. High availability needs
PostgreSQL and S3. The stack does not enable either for this service. The
upstream S3 feature is experimental and absent from the official image.

The scaling manifest marks `data/vaultwarden/store` as `node-local` for this
reason. The OIDC secret is `shared` because every node that serves the same
Tinyauth client needs the same value. A shared secret does not make the
database safe to share.

## Scaling manifest and checker

The manifest is `state/vaultwarden/scaling.tsv`. The columns are path, mode,
scope, when, presence, and purpose. The rows are:

<!-- markdownlint-disable MD013 -->
| Path                                             | Mode | Scope      | Presence | Purpose                                      |
| ------------------------------------------------ | ---- | ---------- | -------- | -------------------------------------------- |
| `config/vaultwarden/vaultwarden.env`             | 600  | node-local | required | Wizard answers and secret file paths.        |
| `config/vaultwarden/secrets/oidc-client-secret`  | 600  | shared     | required | OIDC client secret for the Tinyauth client.  |
| `config/vaultwarden/secrets/admin_token`         | 600  | shared     | optional | Optional admin token.                        |
| `config/vaultwarden/secrets/smtp_password`       | 600  | shared     | optional | Optional SMTP password.                      |
| `config/vaultwarden/secrets`                     | 700  | shared     | required | Vaultwarden secret directory.                |
| `data/vaultwarden/store`                         | 700  | node-local | required | SQLite database and signing keys.            |
<!-- markdownlint-enable MD013 -->

Run the offline checker from the combined stack:

```bash
scripts/check-scaling.sh --services vaultwarden /srv/node-a
```

The checker reads the manifest. It checks the mode and the presence of each
path. It does not contact the node, start a container, or read the database.

## Clean

Remove the configuration:

```bash
bash setup.sh vaultwarden clean
```

Add `--data` to remove `data/vaultwarden` too. Add `--yes` for a scripted
run. The clean command removes `config/vaultwarden/`. With `--data` it also
removes `data/vaultwarden/`. It never touches `state/`, the root `.env`, or
the other services.

## Checks

Run the service smoke check before you start the service:

```bash
bash state/vaultwarden/smoke.sh
```

The check uses scratch trees. It needs no Docker, no Consul, and no network.
It covers both modes, the file modes, the disabled features, the compose
fragment, the scaling manifest, and the vhost descriptor.

The compose fragment is `compose/vaultwarden.yaml`. Regenerate the root
`compose.yaml` with this command after a fragment change:

```bash
scripts/compose-assemble.sh
```

## Image

The image is `vaultwarden/server:1.37.4` (Debian). The tag is not a digest
pin. Pin a digest before a production deploy:

```text
vaultwarden/server:1.37.4@sha256:<digest>
```

The container serves HTTP on port 80. The compose fragment publishes
`${PUBLIC_IP:-127.0.0.1}:8080`. Caddy proxies `vaultwarden:80` on the shared
network in integrated mode. The external HTTPS proxy terminates TLS in
standalone mode.
