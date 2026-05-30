#!/bin/bash
# Rebuild/Restore a Stopped VM's disk from a source, keeping its identity
# (name, IPv6, MAC, tap, SSH key). The source is either one of the VM's own
# snapshots (Restore) or a base image's pristine rootfs (Rebuild). Either way
# the VM keeps its UUID, so step 2's freshly-derived host keys / machine-id /
# hostname match the VM the operator already knows.
#
# The caller guarantees the VM is Stopped (the unit is down, rootfs unmounted),
# so swapping the file underneath it is safe. firecracker.json, network.env and
# the systemd unit already exist from the original provision and are untouched.
# Idempotent: re-running replaces the rootfs again with the same source.
#
# Inputs (environment variables):
#   VIRTUAL_MACHINE_NAME  - UUID; locates the VM directory and seeds identity
#   DISK_GB               - target rootfs size (the VM's current disk size)
#   VIRTUAL_MACHINE_IPV6  - injected into the rootfs network env
#   IPV4_GUEST_CIDR       - guest side of the NAT44 /30, injected into the env
#   IPV4_GATEWAY          - host side of the /30 (no mask), the guest's v4 gw
#   SSH_PUBLIC_KEY        - injected into authorized_keys
#   ATLAS_FC_UID          - per-VM uid; the rebuilt rootfs is chowned back to it
#   One source, exactly:
#     SNAPSHOT_ROOTFS_PATH  - absolute path to a snapshot rootfs (Restore), OR
#     IMAGE_NAME + ROOTFS_FILENAME - a base image under /var/lib/atlas/images (Rebuild)

set -euo pipefail

# shellcheck source=lib/lvm.sh
. "$(dirname "$0")/lvm.sh"
# shellcheck source=lib/prepare-rootfs.sh
. "$(dirname "$0")/prepare-rootfs.sh"

: "${VIRTUAL_MACHINE_NAME:?required}"
: "${DISK_GB:?required}"
: "${VIRTUAL_MACHINE_IPV6:?required}"
: "${IPV4_GUEST_CIDR:?required}"
: "${IPV4_GATEWAY:?required}"
: "${SSH_PUBLIC_KEY:?required}"
: "${ATLAS_FC_UID:?required}"

vm_directory="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}"
# The disk is the VM's LV; rebuild swaps the LV's contents. The jail node at
# rootfs.ext4 points at it and is re-created here (the LV's dev_t can change).
jail_root="${vm_directory}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root"
vm_lv_name="$(atlas_vm_lv_name "$VIRTUAL_MACHINE_NAME")"

if [ ! -d "$jail_root" ]; then
    echo "jail ${jail_root} missing; provision the VM before rebuilding" >&2
    exit 1
fi

# Resolve the origin LV. Snapshot LV wins (Restore); otherwise the base image LV
# (Rebuild). SNAPSHOT_ROOTFS_PATH is the snapshot's /dev/atlas/<name> path.
if [ -n "${SNAPSHOT_ROOTFS_PATH:-}" ]; then
    origin_lv_name="$(atlas_lv_name_from_path "$SNAPSHOT_ROOTFS_PATH")"
    if ! atlas_lv_exists "$origin_lv_name"; then
        echo "snapshot LV not found: ${origin_lv_name} (from ${SNAPSHOT_ROOTFS_PATH})" >&2
        exit 1
    fi
else
    : "${IMAGE_NAME:?required (or pass SNAPSHOT_ROOTFS_PATH)}"
    origin_lv_name="$(atlas_image_lv_name "$IMAGE_NAME")"
    if ! atlas_lv_exists "$origin_lv_name"; then
        echo "base image LV not present: ${origin_lv_name}; run Sync to Server first" >&2
        exit 1
    fi
fi

# Replace the existing disk: drop the old VM LV, then recreate it as a fresh CoW
# snapshot of the origin. atlas_prepare_lv no-ops when the LV exists, so the
# lvremove is what forces the swap. atlas_lv_remove's guard refuses pool/image
# names; atlas-vm-<uuid> is neither, so this is allowed.
atlas_lv_remove "$vm_lv_name"
atlas_prepare_lv "$origin_lv_name" "$vm_lv_name" "$DISK_GB"
rootfs_device="$(atlas_lv_path "$vm_lv_name")"
atlas_inject_identity "$rootfs_device" "$VIRTUAL_MACHINE_NAME" "$VIRTUAL_MACHINE_IPV6" \
    "$SSH_PUBLIC_KEY" "$IPV4_GUEST_CIDR" "$IPV4_GATEWAY"

# Re-mknod the jail node: the new LV's dev_t differs from the old one, so the
# existing node would point at a stale device. atlas_lv_mknod_into_jail removes
# and re-creates it, owned by the per-VM uid (0660) so the jailed FC can open it.
atlas_lv_mknod_into_jail "$vm_lv_name" "${jail_root}/rootfs.ext4" "$ATLAS_FC_UID"

echo "Rebuilt ${VIRTUAL_MACHINE_NAME} from ${origin_lv_name}."
