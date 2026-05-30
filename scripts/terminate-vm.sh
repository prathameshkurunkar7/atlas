#!/bin/bash
# Delete all on-host state for a VM. Idempotent.
#
# Inputs:
#   VIRTUAL_MACHINE_NAME

set -euo pipefail

# shellcheck source=lib/lvm.sh
. "$(dirname "$0")/lvm.sh"

: "${VIRTUAL_MACHINE_NAME:?required}"

unit="firecracker-vm@${VIRTUAL_MACHINE_NAME}.service"
vm_directory="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}"

sudo systemctl disable --now "$unit" 2>/dev/null || true

# In case the unit failed before ExecStopPost ran, tear down networking
# explicitly. vm-network-down.sh is itself idempotent.
if sudo test -f "${vm_directory}/network.env"; then
    sudo /var/lib/atlas/bin/vm-network-down.sh "$VIRTUAL_MACHINE_NAME" || true
fi

# Removing the VM directory takes the jail tree (kernel link, config, API
# socket, and the rootfs.ext4 block NODE) with it — they all live under jail/
# inside this directory. The node is just a pointer; the LV it points at is a
# separate object removed next.
sudo rm -rf "$vm_directory"

# Remove the VM's disk LV. atlas_lv_remove is idempotent (no-op if gone) and
# guarded: it refuses to remove the thin pool or a base image LV, so a bug that
# passed a wrong name here can never destroy shared state. The VM's own
# snapshots (atlas-snap-<snapshot-uuid>) are removed by the per-snapshot
# delete path (delete-snapshot-vm.sh), which the controller cascades on
# terminate — their names are not derivable from this VM's UUID, so they are
# NOT removed here.
atlas_lv_remove "$(atlas_vm_lv_name "$VIRTUAL_MACHINE_NAME")"

echo "Deleted ${VIRTUAL_MACHINE_NAME}."
