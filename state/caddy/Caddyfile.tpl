# Rendered by consul-template. Do not edit.
# HTTPS is served on all vhosts. The TLS mode comes from CADDY_TLS_MODE in the
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
#
# The vhost registry is a JSON array. The root setup.sh assembles it from the
# enabled state/<service>/vhost.json descriptors into config/caddy/vhosts.json.
# The container mounts that file at /etc/consul-template/vhosts.json. Set
# CADDY_VHOSTS_FILE to read another path. An empty array renders the fallback
# vhosts so a standalone checkout still works.

{{ define "smart_proxy" }}
  {{ $name := index . 0 }}
  {{ $local_addr := index . 1 }}
  {{ $redirect_paths := "[]" | parseJSON }}
  {{ if gt (len .) 2 }}
    {{ $redirect_paths = index . 2 | parseJSON }}
  {{ end }}

  {{ $path := printf "%s/litefs" $name }}
  {{ $my_addr := env "IP_ADDR" }}
  {{ $upstream := $my_addr }}{{ $parts := split ":" $local_addr }}{{ $upstream_port := index $parts (subtract 1 (len $parts)) }}

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
        reverse_proxy http://{{ $upstream }}:{{ $upstream_port }} {
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
          reverse_proxy http://{{ $upstream }}:{{ $upstream_port }} {
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
  {{ else }}
    # LiteFS is off. Serve every request from the local upstream.
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

# Emit one vhost for one registry descriptor. Argument: the descriptor object.
# A descriptor has one of three modes:
#   catalog  range the Consul service and append the port
#   litefs   route through the smart_proxy template
#   static   reverse_proxy the fixed upstream, with optional X-Real-IP
# parseJSON returns interface{} values. The image exposes the sprig helpers
# with the sprig_ prefix, so sprig_toString converts a value to a string.
{{ define "render_vhost" }}
	{{ $name := index . "name" }}
	{{ $mode := index . "mode" }}
	{{ $upstream := index . "upstream" }}
	{{ $service := index . "service" }}
	{{ $port := index . "port" }}
	{{ $redirect_paths := index . "redirect_paths" }}
	{{ $x_real_ip := index . "x_real_ip" }}
https://{{ $name }}.{{ env "STACK_DOMAIN" }} {
{{ template "tls_for" (sprig_toString $name) }}
	{{ if eq (sprig_toString $mode) "catalog" }}
	reverse_proxy {{ range service (sprig_toString $service) }}{{ .Address }}:{{ $port }} {{ end }} {
	}
	{{ else if eq (sprig_toString $mode) "litefs" }}
	{{ if $redirect_paths }}
	{{ template "smart_proxy" (sprig_list (sprig_toString $name) (sprig_toString $upstream) (sprig_toString $redirect_paths)) }}
	{{ else }}
	{{ template "smart_proxy" (sprig_list (sprig_toString $name) (sprig_toString $upstream) "[]") }}
	{{ end }}
	{{ else if eq (sprig_toString $mode) "static" }}
	reverse_proxy {{ sprig_toString $upstream }} {
		header_up Host {host}
		{{ if $x_real_ip }}
		header_up X-Real-IP {remote_host}
		{{ end }}
	}
	{{ end }}
}
{{ end }}

# The registry path. CADDY_VHOSTS_FILE wins. The default is the compose mount.
{{ $vhosts_file := env "CADDY_VHOSTS_FILE" }}
{{ if not $vhosts_file }}{{ $vhosts_file = "/etc/consul-template/vhosts.json" }}{{ end }}
{{ $registry := parseJSON (file $vhosts_file) }}

# The fallback descriptors. The template uses them when the registry is empty.
{{ $fallback := parseJSON `
[
  {"name":"consul","mode":"catalog","service":"consul","port":8500},
  {"name":"lldap","mode":"litefs","upstream":"http://lldap:17170","redirect_paths":"[]"},
  {"name":"tinyauth","mode":"litefs","upstream":"http://tinyauth:3000","redirect_paths":"[]"},
  {"name":"forgejo","mode":"static","upstream":"http://forgejo:3000"},
  {"name":"vaultwarden","mode":"static","upstream":"http://vaultwarden:80","x_real_ip":true}
]` }}

{{ $vhosts := $fallback }}
{{ if gt (len $registry) 0 }}{{ $vhosts = $registry }}{{ end }}
{{ range $vhosts }}{{ template "render_vhost" . }}
{{ end }}
