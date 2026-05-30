#!/bin/bash
# Host-side disk for a VM. Invoked by ExecStartPre in the systemd unit (must run
# before the jailer's ExecStart so the disk node exists when Firecracker opens
# rootfs.ext4). Reads /var/lib/atlas/virtual-machines/$1/network.env for the
# per-VM uid. Idempotent — safe to re-run on every (re)start.
#
# Why this exists: the VM disk is a thin snapshot LV. `lvcreate -s` marks it
# activation-skip, so after a host reboot the pool comes up but the disk LV does
# not auto-activate, and its device-mapper minor can renumber. The rootfs.ext4
# block node mknod'd into the jail at provision time then dangles. provision is
# NOT re-run on boot, so without this hook an enabled VM would restart-loop
# against a missing/stale disk. This re-activates the LV (-K overrides the skip)
# and re-mknods the jail node with the LV's current major:minor — the disk
# analogue of vm-network-up.sh, reconstructible from on-disk state without the
# Frappe DB.

set -euo pipefail

virtual_machine_name="${1:?virtual machine name required}"
. "/var/lib/atlas/virtual-machines/${virtual_machine_name}/network.env"

: "${ATLAS_FC_UID:?missing in network.env}"

# Durable copy of the thin-pool helper library (laid down by bootstrap), NOT the
# per-task staged copy — this runs from a systemd unit, not a Task.
. /var/lib/atlas/bin/lvm.sh

jail_root="/var/lib/atlas/virtual-machines/${virtual_machine_name}/jail/firecracker/${virtual_machine_name}/root"
lv_name="$(atlas_vm_lv_name "$virtual_machine_name")"

# Activate the disk LV (-K, via atlas_lv_activate) and refresh the in-jail block
# node to the LV's current major:minor. Both are idempotent: a no-reboot restart
# re-activates an already-active LV (no-op) and re-mknods the same dev_t.
atlas_lv_activate "$lv_name"
atlas_lv_mknod_into_jail "$lv_name" "${jail_root}/rootfs.ext4" "$ATLAS_FC_UID"
