#!/bin/bash
# e2e: assert a VM is Paused by querying its Firecracker API socket.
# GET / returns InstanceInfo whose `state` is "Not started" | "Running" |
# "Paused" (firecracker swagger: describeInstance / InstanceInfo).
set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?}"

# The API socket is created by Firecracker inside its jail. The jail path nests
# the UUID twice, past the 108-byte sun_path limit, so connect via a SHORT
# relative path: cd into the socket directory (inside sudo — it is 0700-owned by
# the per-VM uid) and address it as just firecracker.socket (cf. pause-vm.sh).
socket_directory="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root/run"
state="$(sudo sh -c "cd '${socket_directory}' && curl --fail --silent --unix-socket firecracker.socket http://localhost/" \
    | jq -r '.state // empty')"
if [ "$state" != "Paused" ]; then
    echo "expected Paused, API reports state=${state:-<none>}" >&2
    exit 1
fi
echo "paused"
