#!/bin/bash
# Snapshot a Stopped VM's disk: take an LVM thin CoW snapshot of its disk LV.
# Disk-only — no Firecracker memory-state snapshot. The caller guarantees the
# VM is Stopped, so the disk is cleanly unmounted and the snapshot is
# consistent. Instant and O(1): the snapshot shares the VM disk's blocks until
# one side is written. Pure host op — no jail interaction. Idempotent:
# re-running reuses the existing snapshot LV.
#
# Inputs (environment variables):
#   VIRTUAL_MACHINE_NAME  - UUID; identifies the source disk LV (atlas-vm-<uuid>)
#   SNAPSHOT_ROOTFS_PATH  - the snapshot's /dev/atlas/<name> device path; its
#                           basename is the snapshot LV name to create
#
# Output: prints `SIZE_BYTES=<n>` (the snapshot device's byte count) on stdout.

set -euo pipefail

# shellcheck source=lib/lvm.sh
. "$(dirname "$0")/lvm.sh"

: "${VIRTUAL_MACHINE_NAME:?required}"
: "${SNAPSHOT_ROOTFS_PATH:?required}"

vm_lv_name="$(atlas_vm_lv_name "$VIRTUAL_MACHINE_NAME")"
snap_lv_name="$(atlas_lv_name_from_path "$SNAPSHOT_ROOTFS_PATH")"

if ! atlas_lv_exists "$vm_lv_name"; then
    echo "disk LV not found for ${VIRTUAL_MACHINE_NAME} (${vm_lv_name}); provision the VM first" >&2
    exit 1
fi

# Pre-flight: refuse if the thin pool is nearly full. A thin snapshot consumes
# no space up front, but every subsequent CoW write to either side allocates
# from the pool; taking snapshots against an almost-full pool courts a
# pool-exhaustion stall (errorwhenfull queues 60s then EIOs every VM). 90% is
# the documented operator-paged threshold (no autoscaler this slice). data and
# metadata fill independently, so check both.
data_pct="$(sudo lvs --noheadings -o data_percent "atlas/${ATLAS_POOL}" | tr -d ' ' | cut -d. -f1)"
meta_pct="$(sudo lvs --noheadings -o metadata_percent "atlas/${ATLAS_POOL}" | tr -d ' ' | cut -d. -f1)"
if [ "${data_pct:-0}" -ge 90 ] || [ "${meta_pct:-0}" -ge 90 ]; then
    echo "thin pool ${ATLAS_POOL} too full for a safe snapshot (data ${data_pct}%, metadata ${meta_pct}%)" >&2
    exit 1
fi

# Thin CoW snapshot of the VM's disk LV. atlas_lv_from_origin is idempotent
# (re-activates if the snapshot LV already exists) and activates it with -K so
# the activation-skip flag a fresh snapshot carries does not leave it inactive.
atlas_lv_from_origin "$vm_lv_name" "$snap_lv_name"

echo "SIZE_BYTES=$(sudo blockdev --getsize64 "$(atlas_lv_path "$snap_lv_name")")"
echo "Snapshotted ${VIRTUAL_MACHINE_NAME} to ${snap_lv_name}."
