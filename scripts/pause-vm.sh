#!/bin/bash
# Pause a Running VM: freeze its vCPUs via Firecracker's API socket. Guest RAM
# stays resident (this is not a shutdown). Idempotent: pausing an already-paused
# microVM keeps it paused (Firecracker returns 2xx either way).
#
# Inputs:
#   VIRTUAL_MACHINE_NAME  - UUID; selects the API socket

set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?required}"

# The API socket is created by Firecracker inside its jail. It is a unix-domain
# socket on the host filesystem; the VM's network namespace does not affect
# reaching it. BUT the jail path nests the UUID twice
# (.../<uuid>/jail/firecracker/<uuid>/root/run/firecracker.socket) — ~115 chars,
# past the 108-byte sun_path limit, so curl --unix-socket with the absolute path
# fails "Unix socket path too long". Connect via a SHORT relative path instead:
# cd into the socket's directory (the test below still uses the absolute path —
# stat() has no length limit) and address it as just firecracker.socket.
socket_directory="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root/run"
socket="${socket_directory}/firecracker.socket"
if [ ! -S "$socket" ]; then
    echo "API socket ${socket} not present; is the VM running?" >&2
    exit 1
fi

# --fail makes curl exit non-zero on a 4xx/5xx so a refused pause surfaces as a
# failed Task rather than a silent success. The cd runs INSIDE sudo (as root):
# the socket directory is 0700-owned by the per-VM uid, so an unprivileged cd
# would be denied. curl then resolves the relative --unix-socket against that cwd.
sudo sh -c "cd '${socket_directory}' && curl --fail --silent --show-error \
    --unix-socket firecracker.socket \
    -X PATCH 'http://localhost/vm' \
    -H 'Content-Type: application/json' \
    -d '{\"state\": \"Paused\"}'"

echo "Paused ${VIRTUAL_MACHINE_NAME}."
