# syntax=docker/dockerfile:1
# Garage S3-compatible object store with a small BusyBox userland.
# The official Garage image is built FROM scratch, so it has no shell.
# The entrypoint needs a shell to render the runtime config and read secrets.
# A first stage prepares a static BusyBox and the CA certificates.
# The final stage keeps the Garage binary from the official image.
# This image contains no secrets.

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS tools

# Install the static BusyBox and the CA certificates.
# The CA certificates let Garage verify an HTTPS Consul address.
RUN apk add --no-cache busybox-static=1.37.0-r20 ca-certificates=20261020-r0 \
    && mkdir -p /rootfs/bin \
    && cp /bin/busybox.static /rootfs/bin/busybox \
    && for applet in $(/rootfs/bin/busybox --list); do \
        ln -sf busybox "/rootfs/bin/$applet"; \
    done \
    && mkdir -p /rootfs/etc \
    && cp -a /etc/ssl /rootfs/etc/ssl

FROM dxflrs/garage:v2.5.0@sha256:677e5b758e4425a325b811c425c026bf35a4bf42f7ddbaa773de3f4fd779a5a5

# Copy the BusyBox applets and the CA certificates into the final image.
# The applets are relative symlinks to /bin/busybox.
COPY --from=tools /rootfs/bin /bin
COPY --from=tools /rootfs/etc/ssl /etc/ssl

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENV GARAGE_CONFIG_TEMPLATE=/etc/garage/garage.toml
ENV GARAGE_RUNTIME_CONFIG=/run/garage/garage.toml
ENV GARAGE_RUNTIME_DIR=/run/garage

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Clear the base image CMD. The entrypoint starts the server itself.
CMD []
