#!/bin/bash
# Delete a VM disk snapshot. Idempotent: a missing LV is a no-op.
# Run from Virtual Machine Snapshot.on_trash when the row is deleted.
#
# Inputs:
#   SNAPSHOT_ROOTFS_PATH  - the snapshot's /dev/atlas/<name> device path; its
#                           basename is the snapshot LV to remove

set -euo pipefail

# shellcheck source=lib/lvm.sh
. "$(dirname "$0")/lvm.sh"

: "${SNAPSHOT_ROOTFS_PATH:?required}"

snap_lv_name="$(atlas_lv_name_from_path "$SNAPSHOT_ROOTFS_PATH")"
# atlas_lv_remove is guarded (refuses pool/image LVs) and a no-op if absent. A
# snapshot LV is an independent thin volume — removing it never affects the VM
# disk it was taken from, nor any clone made from it (clones are independent
# thin LVs once created).
atlas_lv_remove "$snap_lv_name"

echo "Deleted snapshot ${snap_lv_name}."
