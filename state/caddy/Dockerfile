# Custom image: caddy with consul-template embedded.
# The build context is state/caddy. Only entrypoint.sh is copied.
# Supports linux/amd64 and linux/arm64. A multi-arch image is built
# with docker buildx, or on a native arm64 host.
FROM caddy:2.11.9

# Pin the consul-template version. Both values change together on a bump:
#   version: https://releases.hashicorp.com/consul-template/index.json (stable releases)
#   hashes:  https://releases.hashicorp.com/consul-template/<version>/consul-template_<version>_SHA256SUMS
ARG CONSUL_TEMPLATE_VERSION=0.43.1

# Download the official static binary and verify it against the published
# SHA256SUMS. The build fails on a mismatch. The release tree is removed after install.
WORKDIR /tmp/ct-build
RUN arch="$(uname -m)" \
    && case "$arch" in \
         x86_64) CT_ARCH=amd64 ;; \
         aarch64|arm64) CT_ARCH=arm64 ;; \
         *) echo "error: unsupported architecture '$arch'. Supported: x86_64 (amd64), aarch64/arm64." >&2; exit 1 ;; \
       esac \
    && curl -fsSLO "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_SHA256SUMS" \
    && curl -fsSLO "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_${CT_ARCH}.zip" \
    && grep "linux_${CT_ARCH}.zip" "consul-template_${CONSUL_TEMPLATE_VERSION}_SHA256SUMS" >consul-template.sha256 \
    && sha256sum -c consul-template.sha256 \
    && unzip -o "consul-template_${CONSUL_TEMPLATE_VERSION}_linux_${CT_ARCH}.zip" consul-template \
    && install -m 0755 consul-template /usr/local/bin/consul-template \
    && rm -rf /tmp/ct-build

# The templates directory is mounted read-only at run time.
WORKDIR /srv
RUN mkdir -p /etc/consul-template/templates

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
