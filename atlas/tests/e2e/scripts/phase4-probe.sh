#!/bin/bash
# Phase 4 e2e: verify image files are on the server with sane sizes.
set -euo pipefail

: "${IMAGE_NAME:?}"
: "${KERNEL_FILENAME:?}"
: "${ROOTFS_FILENAME:?}"
: "${DEFAULT_DISK_GB:?}"

image_dir="/var/lib/atlas/images/${IMAGE_NAME}"
kernel="${image_dir}/${KERNEL_FILENAME}"
rootfs="${image_dir}/${ROOTFS_FILENAME}"

test -f "$kernel" || { echo "missing kernel: $kernel" >&2; exit 1; }
test -f "$rootfs" || { echo "missing rootfs: $rootfs" >&2; exit 1; }

# Kernel must be the DECOMPRESSED vmlinux Firecracker boots (ELF magic
# 7f 45 4c 46), not the packed zstd bzImage we downloaded. sync-image.sh
# extracts it; a regression that ships the packed file would fail here.
magic="$(head -c 4 "$kernel" | od -An -tx1 | tr -d ' \n')"
if [ "$magic" != "7f454c46" ]; then
    echo "kernel is not ELF (magic=$magic): $kernel" >&2
    exit 1
fi

# ext4 within 5% of nominal.
nominal=$((DEFAULT_DISK_GB * 1024 * 1024 * 1024))
size="$(stat -c %s "$rootfs")"
floor=$((nominal * 95 / 100))
if [ "$size" -lt "$floor" ]; then
    echo "rootfs too small: $size bytes (floor $floor)" >&2
    exit 1
fi

echo "image $IMAGE_NAME present (kernel=$(stat -c %s "$kernel") rootfs=$size)"

# Base image is also a read-only thin LV (the snapshot origin for every VM
# disk). lv_attr decodes: char 1 == volume type ('V' thin volume), char 2 ==
# permissions ('r' read-only). The file above is the import source; this LV is
# what `lvcreate -s` snapshots from at provision time.
lv_name="atlas-image-${IMAGE_NAME}"
lv_attr="$(sudo lvs --noheadings -o lv_attr "atlas/${lv_name}" 2>/dev/null | tr -d ' ' || true)"
test -n "$lv_attr" || { echo "missing base image LV: atlas/${lv_name}" >&2; exit 1; }
case "$lv_attr" in
    V*) ;;
    *) echo "base LV atlas/${lv_name} is not a thin volume (lv_attr: $lv_attr)" >&2; exit 1 ;;
esac
case "$lv_attr" in
    ?r*) ;;
    *) echo "base LV atlas/${lv_name} is not read-only (lv_attr: $lv_attr)" >&2; exit 1 ;;
esac
echo "base image LV OK (atlas/${lv_name}, lv_attr=$lv_attr)"
