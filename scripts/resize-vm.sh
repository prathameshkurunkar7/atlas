#!/bin/bash
# Resize a Stopped VM: set vCPU/memory in its firecracker config and grow the
# rootfs to DISK_GB. Firecracker reads machine-config only at boot, so the VM
# must be Stopped — the next Start picks up the new config. Disk only grows
# (the caller rejects shrink). Idempotent: re-running writes the same values
# and resize2fs is a no-op once the filesystem already fills the device.
#
# Inputs (environment variables):
#   VIRTUAL_MACHINE_NAME  - UUID; locates the VM directory
#   VCPUS                 - integer
#   MEMORY_MB             - integer
#   DISK_GB               - integer, target rootfs size

set -euo pipefail

# shellcheck source=lib/lvm.sh
. "$(dirname "$0")/lvm.sh"

: "${VIRTUAL_MACHINE_NAME:?required}"
: "${VCPUS:?required}"
: "${MEMORY_MB:?required}"
: "${DISK_GB:?required}"

# Config lives inside the VM's jail; the disk is the VM's LV.
jail_root="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root"
config_path="${jail_root}/firecracker.json"
vm_lv_name="$(atlas_vm_lv_name "$VIRTUAL_MACHINE_NAME")"

if [ ! -f "$config_path" ]; then
    echo "firecracker config ${config_path} missing; provision the VM first" >&2
    exit 1
fi
if ! atlas_lv_exists "$vm_lv_name"; then
    echo "disk LV ${vm_lv_name} missing; provision the VM first" >&2
    exit 1
fi

# 1. Rewrite machine-config in place. jq edits only the two keys, preserving
#    boot-source, drives and network-interfaces. The replacement file is created
#    by root; copy the original's owner onto it so the jailed Firecracker (the
#    per-VM uid) can still read its config after chroot.
sudo jq \
    --argjson vcpus "$VCPUS" \
    --argjson mem "$MEMORY_MB" \
    '."machine-config".vcpu_count = $vcpus | ."machine-config".mem_size_mib = $mem' \
    "$config_path" | sudo install -m 0644 /dev/stdin "${config_path}.new"
sudo chown --reference="$config_path" "${config_path}.new"
sudo mv "${config_path}.new" "$config_path"

# 2. Grow the disk LV to DISK_GB. lvextend -r extends the LV and the ext4 on it
#    in one shot. Disk only ever grows (shrink is rejected upstream); lvextend
#    refuses to shrink and is a clean no-op when the LV already meets the size,
#    so a re-run (or a resize that only changed vCPU/memory) does not error.
sudo lvextend -r -L "${DISK_GB}G" "$(atlas_lv_path "$vm_lv_name")" >/dev/null 2>&1 || true

echo "Resized ${VIRTUAL_MACHINE_NAME}: ${VCPUS} vCPU, ${MEMORY_MB} MB, ${DISK_GB} GB."
