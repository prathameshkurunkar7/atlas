#!/bin/bash
# e2e: assert the VM's disk is an LVM thin volume, exposed into the jail as a
# block-special node owned by the per-VM uid. This is the LVM × jailer contract:
# a green boot that still booted off a file (or a node the jailed FC can't open)
# is a failure.
set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?}"
: "${ATLAS_FC_UID:?}"

jail_root="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root"
jail_node="${jail_root}/rootfs.ext4"
lv_name="atlas-vm-${VIRTUAL_MACHINE_NAME}"
lv_device="/dev/atlas/${lv_name}"

# 1. The disk LV exists and is an activated, sized block device.
if ! sudo test -b "$lv_device"; then
    echo "disk LV device missing or not a block device: ${lv_device}" >&2
    exit 1
fi
lv_size="$(sudo blockdev --getsize64 "$lv_device")"
[ "${lv_size:-0}" -gt 0 ] || { echo "disk LV has zero size: ${lv_device}" >&2; exit 1; }

# 2. The in-jail rootfs.ext4 is a BLOCK SPECIAL node (not a regular file). A
#    regression that laid down a file copy would fail here.
node_type="$(sudo stat -c %F "$jail_node" 2>/dev/null || echo missing)"
if [ "$node_type" != "block special file" ]; then
    echo "in-jail rootfs.ext4 is '${node_type}', expected 'block special file': ${jail_node}" >&2
    exit 1
fi

# 3. The node points at the disk LV (same major:minor). Proves it is THIS VM's
#    disk, not some stale or wrong device.
node_majmin="$(sudo stat -c '%t:%T' "$jail_node")"   # hex major:minor
# lsblk right-pads MAJ:MIN with spaces ("252:5  "); strip them so the
# string compare below is against a clean "major:minor".
lv_majmin_dec="$(lsblk -ndo MAJ:MIN "$lv_device" | tr -d '[:space:]')"
node_major_dec="$(( 16#${node_majmin%%:*} ))"
node_minor_dec="$(( 16#${node_majmin##*:} ))"
if [ "${node_major_dec}:${node_minor_dec}" != "$lv_majmin_dec" ]; then
    echo "in-jail node ${node_major_dec}:${node_minor_dec} != LV ${lv_majmin_dec}" >&2
    exit 1
fi

# 4. Owned by the per-VM uid (gid == uid), so the jailed, de-privileged FC can
#    open it via pure DAC.
node_uid="$(sudo stat -c %u "$jail_node")"
if [ "$node_uid" != "$ATLAS_FC_UID" ]; then
    echo "in-jail rootfs.ext4 owned by uid ${node_uid}, expected ${ATLAS_FC_UID}" >&2
    exit 1
fi

echo "vm-disk-is-lv OK: ${lv_name} ${lv_size} bytes, node ${node_major_dec}:${node_minor_dec} uid=${node_uid}"
