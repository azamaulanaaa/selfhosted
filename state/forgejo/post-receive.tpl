{{ "#!/bin/sh" }}
# Rendered by consul-template from state/forgejo/post-receive.tpl. Do not edit.
# Forgejo wraps this hook with its own post-receive dispatcher. This script is
# executed for every push on every repository. It pushes the updated repository
# to each peer that publishes an advertise URL under forgejo/peers in Consul KV.
# consul-template re-renders this file when the peer list changes.
# Authentication uses the git credential helper of the Forgejo user.

set -u

repo_path=$(pwd)
repo_name=${repo_path##*/}
repo_name=${repo_name%.git}
owner=${repo_path%/*}
owner=${owner##*/}

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

exit 0
