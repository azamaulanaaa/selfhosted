#!/bin/sh
# Create and own the Consul data directory before the server starts.
# Rootless mode sets the mode only. Container root maps to the host user.
set -eu

mkdir -p /consul/data
if [ "${STACK_ROOTLESS:-0}" = "1" ]; then
  chmod 0700 /consul/data
else
  chown 100:1000 /consul/data
  chmod 0700 /consul/data
fi
