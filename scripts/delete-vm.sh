#!/bin/bash
# Delete all on-host state for a VM. Idempotent.
#
# Inputs:
#   VIRTUAL_MACHINE_NAME

set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?required}"

unit="firecracker-vm@${VIRTUAL_MACHINE_NAME}.service"
vm_directory="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}"

systemctl disable --now "$unit" 2>/dev/null || true

# In case the unit failed before ExecStopPost ran, tear down networking
# explicitly. vm-network-down.sh is itself idempotent.
if [ -f "${vm_directory}/network.env" ]; then
    /var/lib/atlas/bin/vm-network-down.sh "$VIRTUAL_MACHINE_NAME" || true
fi

rm -rf "$vm_directory"
rm -f "/var/lib/atlas/run/${VIRTUAL_MACHINE_NAME}.sock"

echo "Deleted ${VIRTUAL_MACHINE_NAME}."
