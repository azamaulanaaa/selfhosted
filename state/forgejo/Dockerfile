# syntax=docker/dockerfile:1
# Forgejo wrapped with LiteFS, with consul-template embedded.
# Consul is mandatory. CONSUL_ADDR selects local or remote Consul.
# consul-template renders app.ini and the git post-receive hook at container
# start and on every change. With LITEFS_ENABLED=1, LiteFS replicates the
# SQLite database that Forgejo uses for its data. A single node is the LiteFS
# primary. Only the primary can write the database. Leader election uses a
# Consul lease. The entrypoint creates the Consul policy and token that LiteFS
# uses for the lease.
# This image contains no secrets.

FROM codeberg.org/forgejo/forgejo:17.0.1

# Install FUSE 3 for the LiteFS mount, curl to download the binaries, gosu to
# drop root before Forgejo starts, and unzip to install consul-template.
# The base image already has curl, but the version is pinned here so that the
# build is reproducible. Forgejo runs as uid 1000 and gid 1000 in the base image.
# Versions are pinned to the main and community repositories of Alpine 3.24,
# which is the runner image of the pinned base.
RUN apk add --no-cache curl=8.23.0-r0 fuse3=3.18.3-r0 gosu=1.19-r6 unzip=6.0-r16

# Pin the LiteFS version and one hash per supported architecture.
# Supported platforms are linux/amd64 and linux/arm64. Both hashes below were
# verified on 2026-11-16 from the litefs v0.5.14 release assets. To update
# them, download each asset from the release page, run sha256sum, and replace
# the values here.
ARG LITEFS_VERSION=0.5.14
# SHA-256 of litefs-v0.5.14-linux-amd64.tar.gz.
ARG LITEFS_SHA256_AMD64=231190010850c57ab43e278a0b521e50a9fc63a7c571d683dd7febd4ab2cdf30
# SHA-256 of litefs-v0.5.14-linux-arm64.tar.gz.
ARG LITEFS_SHA256_ARM64=c783d1b32ede08e03fbdb8c638861c6496f9401df7d8102aac7cac4c61d6a0ec

RUN set -eu; \
    case "$(uname -m)" in \
        x86_64) LITEFS_ARCH=amd64; LITEFS_SHA256="${LITEFS_SHA256_AMD64}" ;; \
        aarch64 | arm64) LITEFS_ARCH=arm64; LITEFS_SHA256="${LITEFS_SHA256_ARM64}" ;; \
        *) echo "error: unsupported architecture: $(uname -m). Supported: linux/amd64, linux/arm64." >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/litefs.tar.gz \
        "https://github.com/superfly/litefs/releases/download/v${LITEFS_VERSION}/litefs-v${LITEFS_VERSION}-linux-${LITEFS_ARCH}.tar.gz"; \
    printf '%s  %s\n' "${LITEFS_SHA256}" /tmp/litefs.tar.gz > /tmp/litefs.sha256; \
    sha256sum -c /tmp/litefs.sha256; \
    tar --no-same-owner -C /usr/local/bin -xzf /tmp/litefs.tar.gz; \
    rm -f /tmp/litefs.tar.gz /tmp/litefs.sha256; \
    litefs version

# Pin the consul-template version. Both values change together on a bump:
#   version: https://releases.hashicorp.com/consul-template/index.json
#   hashes:  https://releases.hashicorp.com/consul-template/<version>/consul-template_<version>_SHA256SUMS
ARG CONSUL_TEMPLATE_VERSION=0.43.1

# Download the official static binary and verify it against the published
# SHA256SUMS. The build fails on a mismatch. The release tree is removed after
# install.
WORKDIR /tmp/ct-build
RUN arch="$(uname -m)" \
    && case "$arch" in \
         x86_64) CT_ARCH=amd64 ;; \
         aarch64 | arm64) CT_ARCH=arm64 ;; \
         *) echo "error: unsupported architecture '$arch'. Supported: x86_64 (amd64), aarch64/arm64." >&2; exit 1 ;; \
       esac \
    && curl -fsSLO "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_SHA256SUMS" \
    && curl -fsSLO "https://releases.hashicorp.com/consul-template/${CONSUL_TEMPLATE_VERSION}/consul-template_${CONSUL_TEMPLATE_VERSION}_linux_${CT_ARCH}.zip" \
    && grep "linux_${CT_ARCH}.zip" "consul-template_${CONSUL_TEMPLATE_VERSION}_SHA256SUMS" >consul-template.sha256 \
    && sha256sum -c consul-template.sha256 \
    && unzip -o "consul-template_${CONSUL_TEMPLATE_VERSION}_linux_${CT_ARCH}.zip" consul-template \
    && install -m 0755 consul-template /usr/local/bin/consul-template \
    && rm -rf /tmp/ct-build

# Let non-root users access the FUSE mount. The mount uses allow-other.
RUN printf 'user_allow_other\n' >>/etc/fuse.conf

# consul-template renders into this directory at run time. The templates are
# mounted read-only from state/forgejo.
WORKDIR /srv
RUN mkdir -p /etc/consul-template/templates /run/forgejo

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

# The base image sets CMD to its own s6 supervisor. Clear it so that the base
# CMD is not passed as arguments to this entrypoint.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
