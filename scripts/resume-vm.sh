#!/bin/bash
# Resume a Paused VM: unfreeze its vCPUs via Firecracker's API socket.
# Idempotent: resuming an already-running microVM is ignored by Firecracker
# (returns 2xx).
#
# Inputs:
#   VIRTUAL_MACHINE_NAME  - UUID; selects the API socket

set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?required}"

# The API socket is created by Firecracker inside its jail (a host-filesystem
# unix socket; the VM's network namespace doesn't affect reaching it). The jail
# path nests the UUID twice, exceeding the 108-byte sun_path limit, so we connect
# via a SHORT relative path: cd into the socket directory and address it as just
# firecracker.socket. See pause-vm.sh for the full rationale.
socket_directory="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root/run"
socket="${socket_directory}/firecracker.socket"
if [ ! -S "$socket" ]; then
    echo "API socket ${socket} not present; is the VM running?" >&2
    exit 1
fi

# cd runs inside sudo (as root): the socket directory is 0700-owned by the per-VM
# uid. curl resolves the relative --unix-socket against that cwd.
sudo sh -c "cd '${socket_directory}' && curl --fail --silent --show-error \
    --unix-socket firecracker.socket \
    -X PATCH 'http://localhost/vm' \
    -H 'Content-Type: application/json' \
    -d '{\"state\": \"Resumed\"}'"

echo "Resumed ${VIRTUAL_MACHINE_NAME}."
