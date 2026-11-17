# Rendered by the caddy entrypoint in standalone mode. Do not edit.
# The entrypoint replaces __STACK_DOMAIN__ with STACK_DOMAIN from the root .env.
# Upstreams are static. There are no consul-template calls.
# TLS uses the internal CA, so the certificates are self-signed.

https://__STACK_DOMAIN__ {
	tls internal
	respond "caddy standalone mode"
}

https://consul.__STACK_DOMAIN__ {
	tls internal
	reverse_proxy consul:8500
}

https://lldap.__STACK_DOMAIN__ {
	tls internal
	reverse_proxy lldap:17170
}

https://tinyauth.__STACK_DOMAIN__ {
	tls internal
	reverse_proxy tinyauth:3000
}

https://forgejo.__STACK_DOMAIN__ {
	tls internal
	reverse_proxy forgejo:3000
}
