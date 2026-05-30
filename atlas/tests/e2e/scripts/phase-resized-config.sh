#!/bin/bash
# e2e: assert a VM's firecracker.json machine-config matches expected vcpu/mem
# and the disk LV has grown to at least DISK_GB.
set -euo pipefail

: "${VIRTUAL_MACHINE_NAME:?}"
: "${VCPUS:?}"
: "${MEMORY_MB:?}"
: "${DISK_GB:?}"

# Config lives inside the VM's jail; the disk is the VM's LV.
jail_root="/var/lib/atlas/virtual-machines/${VIRTUAL_MACHINE_NAME}/jail/firecracker/${VIRTUAL_MACHINE_NAME}/root"
config_path="${jail_root}/firecracker.json"
disk_device="/dev/atlas/atlas-vm-${VIRTUAL_MACHINE_NAME}"

actual_vcpus="$(sudo jq -r '."machine-config".vcpu_count' "$config_path")"
actual_mem="$(sudo jq -r '."machine-config".mem_size_mib' "$config_path")"
[ "$actual_vcpus" = "$VCPUS" ] || { echo "vcpu_count=${actual_vcpus} want=${VCPUS}" >&2; exit 1; }
[ "$actual_mem" = "$MEMORY_MB" ] || { echo "mem_size_mib=${actual_mem} want=${MEMORY_MB}" >&2; exit 1; }

# Disk is a block device now — blockdev --getsize64, not stat -c %s (which
# returns 0 for a block special). Measure the LV directly.
want_bytes="$(( DISK_GB * 1024 * 1024 * 1024 ))"
actual_bytes="$(sudo blockdev --getsize64 "$disk_device")"
[ "$actual_bytes" -ge "$want_bytes" ] \
    || { echo "disk LV ${actual_bytes} bytes < want ${want_bytes}" >&2; exit 1; }

echo "resized vcpus=${actual_vcpus} mem=${actual_mem} disk>=${DISK_GB}G"
