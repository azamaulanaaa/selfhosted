# syntax=docker/dockerfile:1
# Tinyauth wrapped with LiteFS in integrated mode.
# LiteFS replicates only the SQLite database that Tinyauth keeps in /data.
# The OIDC key files live in the secrets tree at /etc/tinyauth/secrets/oidc.
# LiteFS does not replicate the OIDC key files. Copy the same keys to every
# node before you start a second node.
# In integrated mode a single node is the LiteFS primary. Only the primary can
# write the database. Leader election uses a Consul lease. The entrypoint
# creates the Consul policy and token that LiteFS uses for the lease.
# In standalone mode the app runs directly on local SQLite with no peer.
# This image contains no secrets.

FROM ghcr.io/tinyauthapp/tinyauth:v5.2.0

# Install FUSE 3 for the LiteFS mount, curl to download LiteFS, and gosu to
# drop root before the app starts. The base image runs the binary as root.
# The tinyauth user in the base image has uid 1000 and gid 1000.
# Versions are pinned to the main and community repositories of Alpine 3.24,
# which is the runner image of the pinned base.
RUN apk add --no-cache curl=8.23.0-r0 fuse3=3.18.3-r0 gosu=1.19-r6

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

# Let non-root users access the FUSE mount. The mount uses allow-other.
RUN printf 'user_allow_other\n' >>/etc/fuse.conf

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
