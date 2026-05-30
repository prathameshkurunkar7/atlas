#!/bin/bash
# e2e: assert a snapshot's LV is gone (after delete or terminate).
# SNAPSHOT_ROOTFS_PATH is the snapshot's /dev/atlas/<name> device path; its
# basename is the LV name. Authoritative check is `lvs` (a stale device-mapper
# node can linger briefly), with the device path as a belt-and-suspenders check.
set -euo pipefail

: "${SNAPSHOT_ROOTFS_PATH:?}"

lv_name="${SNAPSHOT_ROOTFS_PATH##*/}"
if sudo lvs --noheadings "atlas/${lv_name}" >/dev/null 2>&1; then
    echo "expected snapshot LV gone, still present: atlas/${lv_name}" >&2
    exit 1
fi
if sudo test -b "$SNAPSHOT_ROOTFS_PATH"; then
    echo "expected snapshot device gone, still a block device: ${SNAPSHOT_ROOTFS_PATH}" >&2
    exit 1
fi
echo "gone"
