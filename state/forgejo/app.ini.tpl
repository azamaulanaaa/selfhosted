# Rendered by consul-template from state/forgejo/app.ini.tpl. Do not edit.
# The wizard writes the answers to config/forgejo/forgejo.env. compose loads
# that file into the container. consul-template reads the env values with the
# env function and reads the two secret files with the file function.
# No provider name is fixed here. The operator chooses it in the wizard.
# Forgejo reads app.ini at startup. A restart is required after a re-render.

[DEFAULT]
APP_NAME = {{ or (env "FORGEJO_APP_NAME") "Forgejo" }}
RUN_USER = git
RUN_MODE = prod

[server]
PROTOCOL = http
DOMAIN = {{ env "STACK_DOMAIN" }}
ROOT_URL = https://forgejo.{{ env "STACK_DOMAIN" }}/
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3000
OFFLINE_MODE = true

[database]
DB_TYPE = sqlite3
PATH = /data/gitea/gitea.db

[repository]
ROOT = /data/gitea/forgejo-repositories
SCRIPT_TYPE = bash

[security]
INSTALL_LOCK = true
SECRET_KEY = {{ file "/etc/forgejo/secrets/secret-key" | trimSpace }}

[oauth2]
ENABLED = true

[oauth2.client]
# A generic OpenID Connect client. No service name is hardcoded.
NAME = {{ or (env "FORGEJO_OIDC_PROVIDER_NAME") "oidc" }}
PROVIDER = openidConnect
CLIENT_ID = {{ env "FORGEJO_OIDC_CLIENT_ID" }}
CLIENT_SECRET = {{ file "/etc/forgejo/secrets/oidc-client-secret" | trimSpace }}
OPENID_CONNECT_URL = {{ env "FORGEJO_OIDC_ISSUER_URL" }}
ENABLE_AUTO_REGISTRATION = {{ or (env "FORGEJO_OIDC_AUTO_REGISTER") "false" }}
OPENID_CONNECT_SCOPES = openid,profile,email
