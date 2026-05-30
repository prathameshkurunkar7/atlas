#!/bin/bash
# e2e: assert a snapshot's LVM thin volume exists and is a usable block device.
# SNAPSHOT_ROOTFS_PATH is the snapshot's /dev/atlas/<name> device path.
set -euo pipefail

: "${SNAPSHOT_ROOTFS_PATH:?}"

# The snapshot is an LV: a block-special device, not a file. test -b confirms
# the node exists and is a block device; blockdev --getsize64 confirms it is an
# activated, sized volume (a deactivated LV has a node but no size).
if ! sudo test -b "$SNAPSHOT_ROOTFS_PATH"; then
    echo "snapshot LV device missing or not a block device: ${SNAPSHOT_ROOTFS_PATH}" >&2
    exit 1
fi
size="$(sudo blockdev --getsize64 "$SNAPSHOT_ROOTFS_PATH")"
[ "${size:-0}" -gt 0 ] || { echo "snapshot LV has zero size: ${SNAPSHOT_ROOTFS_PATH}" >&2; exit 1; }
echo "present $size bytes"
