# Rendered by consul-template. Do not edit.
# HTTP only for now; TLS is out of scope for this issue.
# The vhost labels come from the STACK_DOMAIN variable of the consul-template
# process (compose sets it from the root .env). Caddy never decides them.
# consul-template rewrites this file; caddy reloads itself on change (--watch).

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

# The consul web UI. Renders once a DC exists with at least one server registered.
http://consul.{{ env "STACK_DOMAIN" }} {
	reverse_proxy {{ range service "consul" }}{{ .Address }}:8500 {{ end }} {
	}
}

# The LLDAP UI. Rendered only when an lldap primary is elected:
#   - key lldap/litefs exists in the consul KV with {"advertise-url": ...}.
# Until a primary is elected the vhost renders with no handlers and caddy
# answers an empty 200 for lldap.<STACK_DOMAIN>.
http://lldap.{{ env "STACK_DOMAIN" }} {
	{{ template "smart_proxy" (sprig_list "lldap" "http://lldap:17170" "[]") }}
}
