{{ "#!/bin/sh" }}
# Rendered from state/forgejo/post-receive.tpl. Do not edit.
# Forgejo wraps this hook with its own post-receive dispatcher. This script is
# executed for every push on every repository. In integrated mode the peer
# block below pushes the updated repository to the other peers that publish an
# advertise URL under forgejo/peers in Consul KV. consul-template re-renders
# this file when the peer list changes. In standalone mode the peer block is
# removed and the hook does nothing.

set -u

repo_path=$(pwd)
repo_name=${repo_path##*/}
repo_name=${repo_name%.git}
owner=${repo_path%/*}
owner=${owner##*/}

# BEGIN CONSUL PEER BLOCK
{{ $local_ip := env "PUBLIC_IP" }}
{{ $git_port := or (env "FORGEJO_PEER_GIT_PORT") "3000" }}
{{ range tree "forgejo/peers" }}
{{ if .Value }}
{{ with $peer := .Value | parseJSON }}
{{ $advertise := index $peer "advertise-url" }}
{{ if $advertise }}
{{ $peer_ip := $advertise | regexReplaceAll ".*//([^:/]+)(:[0-9]+)?.*" "$1" | regexReplaceAll "[^A-Za-z0-9.-]" "" }}
{{ if ne $peer_ip $local_ip }}
git push --mirror "http://{{ $peer_ip }}:{{ $git_port }}/${owner}/${repo_name}.git" || echo "warning: push to {{ $peer_ip }} failed" >&2
{{ end }}
{{ end }}
{{ end }}
{{ end }}
{{ end }}
# END CONSUL PEER BLOCK

exit 0
