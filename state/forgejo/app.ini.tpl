# Rendered from state/forgejo/app.ini.tpl. Do not edit.
# consul-template renders this file in every mode. state/forgejo/render.sh
# renders it in the smoke test only. The renderer reads non-secret values from
# the environment and reads secrets from 0600 files through their *_FILE paths.
# Forgejo reads app.ini at startup. A restart is required after a re-render.

[DEFAULT]
APP_NAME = {{ or (env "FORGEJO_APP_NAME") "Forgejo" }}
RUN_USER = git
RUN_MODE = prod

[server]
PROTOCOL = http
DOMAIN = {{ or (env "STACK_DOMAIN") "sh.lan" }}
{{ if eq (env "TLS_ENABLED") "1" }}
ROOT_URL = https://forgejo.{{ or (env "STACK_DOMAIN") "sh.lan" }}/
{{ else }}
ROOT_URL = http://{{ env "PUBLIC_IP" }}:3000/
{{ end }}
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

{{ if eq (env "OIDC_ENABLED") "1" }}
[oauth2]
ENABLED = true

[oauth2.client]
NAME = {{ or (env "FORGEJO_OIDC_PROVIDER_NAME") "oidc" }}
PROVIDER = openidConnect
CLIENT_ID = {{ env "FORGEJO_OIDC_CLIENT_ID" }}
CLIENT_SECRET = {{ file "/etc/forgejo/secrets/oidc-client-secret" | trimSpace }}
OPENID_CONNECT_URL = {{ env "FORGEJO_OIDC_ISSUER_URL" }}
ENABLE_AUTO_REGISTRATION = {{ or (env "FORGEJO_OIDC_AUTO_REGISTER") "false" }}
OPENID_CONNECT_SCOPES = openid,profile,email
{{ else }}
[oauth2]
ENABLED = false
{{ end }}
