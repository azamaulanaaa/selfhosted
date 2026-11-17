# Rendered by consul-template. Do not edit.
# HTTPS is served on both vhosts. The TLS mode comes from CADDY_TLS_MODE in the
# root .env (compose substitutes it into the caddy container):
#   internal     caddy's internal CA (tls internal)
#   letsencrypt  ACME with CADDY_TLS_EMAIL as contact (tls <email>)
#   existing     bring-your-own certs from /etc/caddy/certs (mounted from
#                config/caddy/certs). Layout comes from CADDY_TLS_CERT_LAYOUT:
#                wildcard (one pair for all vhosts) or per-vhost (one pair each).
# Any other value: no tls directive is rendered and caddy falls back to
# automatic HTTPS. The vhost labels come from STACK_DOMAIN. Caddy never
# decides them. consul-template rewrites this file; caddy reloads itself on
# change (--watch).

{{ define "smart_proxy" }}
  {{ $name := index . 0 }}
  {{ $local_addr := index . 1 }}
  {{ $redirect_paths := "[]" | parseJSON }}
  {{ if gt (len .) 2 }}
    {{ $redirect_paths = index . 2 | parseJSON }}
  {{ end }}

  {{ $path := printf "%s/litefs" $name }}
  {{ $my_addr := env "IP_ADDR" }}
  {{ $upstream := $my_addr }}

  {{ if keyExists $path }}
    {{ $value := key $path }}
    {{ if ne $value "" }}
      {{ with $data := $value | parseJSON }}
        {{ $upstream = index $data "advertise-url" | regexReplaceAll ".*//(.*):.*" "$1" }}
      {{ end }}
    {{ end }}

    {{ $is_remote := ne $upstream $my_addr }}

    {{ if $is_remote }}
      @writes {
        method POST PUT DELETE PATCH MKCOL COPY MOVE LOCK UNLOCK PROPPATCH
      }

      handle @writes {
        reverse_proxy http://{{ $upstream }}:17170 {
          header_up Host {host}
        }
      }

      {{ if gt (len $redirect_paths) 0 }}
        @redirect_paths {
          {{ range $redirect_paths }}
            path {{ . }}
          {{ end }}
        }

        handle @redirect_paths {
          reverse_proxy http://{{ $upstream }}:17170 {
            header_up Host {host}
          }
        }
      {{ end }}
    {{ end }}

    handle {
      reverse_proxy {{ $local_addr }} {
        header_up Host {host}
      }
    }
  {{ end }}
{{ end }}

# Emit the TLS directive for one vhost. Argument: the vhost name.
{{ define "tls_for" }}
{{- $mode := env "CADDY_TLS_MODE" -}}
{{- $layout := env "CADDY_TLS_CERT_LAYOUT" -}}
{{- if eq $mode "internal" }}
	tls internal
{{- else if eq $mode "letsencrypt" }}
{{- $email := env "CADDY_TLS_EMAIL" -}}
{{- if $email }}
	tls {{ $email }}
{{- else }}
	# CADDY_TLS_EMAIL not set; caddy falls back to automatic HTTPS
{{- end }}
{{- else if eq $mode "existing" }}
{{- if eq $layout "wildcard" }}
	tls /etc/caddy/certs/wildcard/fullchain.pem /etc/caddy/certs/wildcard/privkey.pem
{{- else }}
	tls /etc/caddy/certs/{{ . }}/fullchain.pem /etc/caddy/certs/{{ . }}/privkey.pem
{{- end }}
{{- else }}
	# TLS mode not configured (CADDY_TLS_MODE unset or unknown); caddy falls back to automatic HTTPS
{{- end }}
{{ end }}

# The consul web UI. Renders once a DC exists with at least one server registered.
https://consul.{{ env "STACK_DOMAIN" }} {
{{ template "tls_for" "consul" }}
	reverse_proxy {{ range service "consul" }}{{ .Address }}:8500 {{ end }} {
	}
}

# The LLDAP UI. Rendered only when an lldap primary is elected:
#   - key lldap/litefs exists in the consul KV with {"advertise-url": ...}.
# Until a primary is elected the vhost renders with no handlers and caddy
# answers an empty 200.
https://lldap.{{ env "STACK_DOMAIN" }} {
{{ template "tls_for" "lldap" }}
	{{ template "smart_proxy" (sprig_list "lldap" "http://lldap:17170" "[]") }}
}
