# Sourced library — NOT a standalone Task. Lives in scripts/lib/ so the
# scripts_catalog (which lists scripts/*.sh top-level) never treats it as
# runnable. Uploaded next to its callers by script_uploads.py and sourced as
# "$(dirname "$0")/lvm.sh".
#
# Shared LVM thin-pool helpers. Every per-VM disk is a thin LV that is a CoW
# snapshot of a read-only base image LV; the pool itself sits on a loopback
# PV (a sparse backing file on the root fs — a stock DO droplet has no spare
# block device). The functions here are the only place that knows the pool
# layout, so the real-block-device follow-on (spec/09) is a one-line change in
# atlas_pool_ensure and nothing else.
#
# Naming is derived, never stored (mirrors derive_mac/derive_tap in
# networking.py): VM disk = atlas-vm-<uuid>, snapshot = atlas-snap-<uuid>,
# base image = atlas-image-<image_name>. The volume group is "atlas", the
# thin pool is "pool0", and device nodes appear at /dev/atlas/<name>.

# Pool layout. The backing file is sparse, so POOL_DATA_SIZE is an overcommit
# ceiling, not real disk consumed up front. Metadata is sized explicitly
# because the auto-formula under-sizes for snapshot-heavy use and metadata
# exhaustion is the nastier failure mode.
ATLAS_VG="atlas"
ATLAS_POOL="pool0"
ATLAS_POOL_DIR="/var/lib/atlas/pool"
ATLAS_POOL_IMG="${ATLAS_POOL_DIR}/atlas-pool.img"
ATLAS_POOL_DATA_SIZE="${ATLAS_POOL_DATA_SIZE:-200G}"
ATLAS_POOL_METADATA_SIZE="${ATLAS_POOL_METADATA_SIZE:-1G}"

# atlas_lv_path NAME
#   Echo the device path for an LV in the atlas VG. The single source of truth
#   for where a named LV lives, so callers never hand-build /dev paths.
atlas_lv_path() {
    local name="$1"
    printf '/dev/%s/%s' "$ATLAS_VG" "$name"
}

# atlas_vm_lv_name UUID   → atlas-vm-<uuid>     (a VM's own disk LV)
# atlas_snap_lv_name UUID → atlas-snap-<uuid>   (a disk snapshot LV)
# atlas_image_lv_name NAME → atlas-image-<name> (a base image LV)
#   Name derivation, the single place the LV naming scheme lives (mirrors
#   derive_tap/derive_netns in networking.py — names are derived, never stored).
atlas_vm_lv_name() { printf 'atlas-vm-%s' "$1"; }
atlas_snap_lv_name() { printf 'atlas-snap-%s' "$1"; }
atlas_image_lv_name() { printf 'atlas-image-%s' "$1"; }

# atlas_lv_name_from_path DEVICE
#   The LV name for an /dev/atlas/<name> device path — i.e. its basename. Used to
#   recover an origin LV name from a snapshot's stored device path (clone/restore
#   pass the snapshot's device path as SNAPSHOT_ROOTFS_PATH).
atlas_lv_name_from_path() {
    printf '%s' "${1##*/}"
}

# atlas_lv_exists NAME
#   Succeed iff the named LV exists in the atlas VG. Quiet — used only as a gate.
atlas_lv_exists() {
    local name="$1"
    sudo lvs --noheadings "${ATLAS_VG}/${name}" >/dev/null 2>&1
}

# atlas_pool_ensure
#   Idempotently bring up the thin pool: a sparse backing file, a loop device,
#   a PV/VG, and the thin pool LV. Re-running is a no-op once the pool exists
#   (gated on lvs), mirroring the nft/firecracker --version gates in bootstrap.
#   The loop device is re-established on every call, so this is also what an
#   atlas-pool.service oneshot runs after a reboot (bootstrap is not re-run on
#   boot). The ONLY line that differs for a real attached block device is the
#   loop_device assignment — everything from pvcreate down is identical.
atlas_pool_ensure() {
    if atlas_lv_exists "$ATLAS_POOL"; then
        # Pool already created. Make sure its loop device is attached (survives
        # a reboot, where the file persists but the loop binding does not), then
        # ensure the VG sees it.
        if ! sudo losetup -j "$ATLAS_POOL_IMG" | grep -q .; then
            sudo losetup --find "$ATLAS_POOL_IMG"
        fi
        # -K: per-VM disk LVs are thin snapshots (lvcreate -s), which carry the
        # activation-skip flag. A bare `vgchange -ay` honors that flag and leaves
        # them INACTIVE — so after a reboot the pool would be up but every VM disk
        # would be missing its /dev/atlas node. -K overrides the skip so the disks
        # come back. (Each VM additionally self-heals its own node via vm-disk-up.sh
        # at unit start, but activating here keeps `lvs`/operator tooling honest.)
        sudo vgchange -ay -K "$ATLAS_VG" >/dev/null
        return 0
    fi

    sudo install -d -m 0700 "$ATLAS_POOL_DIR"
    if [ ! -f "$ATLAS_POOL_IMG" ]; then
        sudo truncate -s "$ATLAS_POOL_DATA_SIZE" "$ATLAS_POOL_IMG"
    fi

    local loop_device
    loop_device="$(sudo losetup -j "$ATLAS_POOL_IMG" | head -n1 | cut -d: -f1)"
    if [ -z "$loop_device" ]; then
        loop_device="$(sudo losetup --find --show "$ATLAS_POOL_IMG")"
    fi

    if ! sudo pvs "$loop_device" >/dev/null 2>&1; then
        sudo pvcreate "$loop_device" >/dev/null
    fi
    if ! sudo vgs "$ATLAS_VG" >/dev/null 2>&1; then
        sudo vgcreate "$ATLAS_VG" "$loop_device" >/dev/null
    fi
    # Thin pool: explicit metadata size, fill the VG with data space. Guard the
    # create on a *fresh* existence check, not just the one at the top: on a
    # reboot LVM's own event-based autoactivation can attach the PV and surface
    # pool0 *after* the top-of-function check saw nothing, racing us here. Without
    # this gate lvcreate then aborts with "Logical volume pool0 already exists"
    # (exit 5) and the oneshot fails even though the pool is fine. With it, a
    # concurrently-activated pool just falls through to the vgchange below.
    if ! atlas_lv_exists "$ATLAS_POOL"; then
        sudo lvcreate \
            --type thin-pool \
            --name "$ATLAS_POOL" \
            --poolmetadatasize "$ATLAS_POOL_METADATA_SIZE" \
            --extents '100%FREE' \
            "$ATLAS_VG" >/dev/null
    fi
    # Whether we just created the pool or raced LVM's autoactivation, make sure
    # the VG (and the skip-flagged VM disk LVs) are active before returning.
    sudo vgchange -ay -K "$ATLAS_VG" >/dev/null
}

# atlas_lv_activate NAME
#   Activate an LV with -K so snapshots (created with the activation-skip flag)
#   come up, wait for udev to create the node, and fall back to vgmknodes if the
#   node is still missing. Returns once /dev/atlas/<name> is a block device.
atlas_lv_activate() {
    local name="$1" device
    device="$(atlas_lv_path "$name")"
    sudo lvchange -ay -K "${ATLAS_VG}/${name}" >/dev/null
    sudo udevadm settle
    if [ ! -b "$device" ]; then
        sudo vgmknodes "$ATLAS_VG" >/dev/null
        sudo udevadm settle
    fi
    test -b "$device"
}

# atlas_lv_from_origin ORIGIN_NAME NEW_NAME
#   Create NEW_NAME as a thin CoW snapshot of ORIGIN_NAME and activate it.
#   Instant and O(1): unwritten origin blocks are shared, and the origin stays
#   independent (it can be removed without breaking dependents). Idempotent —
#   no-op if NEW_NAME already exists. ORIGIN_NAME may itself be a snapshot
#   (clone path), which is how chained snapshots are created.
atlas_lv_from_origin() {
    local origin_name="$1" new_name="$2"
    if atlas_lv_exists "$new_name"; then
        atlas_lv_activate "$new_name"
        return 0
    fi
    # No -L / --thinpool: snapshotting a thin LV inherits its pool and size.
    sudo lvcreate -s "${ATLAS_VG}/${origin_name}" -n "$new_name" >/dev/null
    atlas_lv_activate "$new_name"
}

# atlas_lv_from_file SOURCE_FILE NEW_NAME DISK_GB
#   Create NEW_NAME as a thin LV of DISK_GB, dd SOURCE_FILE into it, and mark it
#   read-only. This is how a pristine image ext4 *file* becomes the read-only
#   base LV that every per-VM disk snapshots from. Idempotent — no-op if
#   NEW_NAME already exists (a re-synced image keeps its existing base LV; a new
#   image build is a new name). DISK_GB must be >= the source file size; the LV
#   is created at DISK_GB so the ext4's free space lands in the base and every
#   snapshot inherits it without a per-VM lvextend.
#
# Created with -V (a thin volume in the pool, not a snapshot), so the bytes are
# private to the base — the base has no origin and can never be orphaned. The
# data blocks are shared CoW-style only once per-VM snapshots are taken off it.
atlas_lv_from_file() {
    local source_file="$1" new_name="$2" disk_gb="$3"
    if atlas_lv_exists "$new_name"; then
        return 0
    fi
    # -V creates a thin volume in pool0; -n names it. Build under a .part name
    # is unnecessary for LVs (the existence gate above is the idempotency guard),
    # but dd + permission-flip must both complete before the LV is usable, so a
    # failure mid-way leaves a writable, half-populated LV — remove it on error.
    sudo lvcreate --type thin --thinpool "$ATLAS_POOL" \
        -V "${disk_gb}G" -n "$new_name" "$ATLAS_VG" >/dev/null
    atlas_lv_activate "$new_name"
    if ! sudo dd if="$source_file" of="$(atlas_lv_path "$new_name")" \
        bs=4M conv=fsync status=none; then
        sudo lvremove -f "${ATLAS_VG}/${new_name}" >/dev/null 2>&1 || true
        return 1
    fi
    # Read-only at the LVM layer: the base is never mounted writable, so a stray
    # write (or a snapshot mounted by the wrong name) cannot corrupt the shared
    # origin. Per-VM snapshots are independently writable regardless of this.
    sudo lvchange --permission r "${ATLAS_VG}/${new_name}" >/dev/null
}

# atlas_lv_mknod_into_jail LV_NAME JAIL_NODE UID
#   Expose LV_NAME's block device inside a jailer chroot as a block-special node
#   at JAIL_NODE, owned by UID (gid == uid), mode 0660. The jailer chroots
#   Firecracker and runs it as UID, so it cannot reach /dev/atlas/<name>; the
#   node must live inside the jail. firecracker.json points at this node by a
#   jail-relative name, so FC opens it post-chroot as a plain block device.
#
# The jailer creates only its own 4 char devices under dev/ after chroot and
# never deletes existing nodes, so a block node at the jail root survives every
# (re)start. On rebuild the LV's dev_t can change, so we always remove and
# re-create the node (idempotent). Device access is pure DAC (cgroup v2 has no
# devices.allow and the jailer attaches no device BPF) — correct ownership +
# mode is sufficient unless the launcher slice sets a DeviceAllow filter.
atlas_lv_mknod_into_jail() {
    local lv_name="$1" jail_node="$2" uid="$3" device majmin major minor
    device="$(atlas_lv_path "$lv_name")"
    # `lsblk -ndo MAJ:MIN` right-pads the column with spaces ("252:5  "), and
    # mknod rejects a minor with trailing whitespace. Strip all whitespace
    # before splitting so major/minor are clean integers.
    majmin="$(lsblk -ndo MAJ:MIN "$device" | tr -d '[:space:]')"
    major="${majmin%%:*}"
    minor="${majmin##*:}"
    sudo rm -f "$jail_node"
    sudo mknod "$jail_node" b "$major" "$minor"
    sudo chown "${uid}:${uid}" "$jail_node"
    sudo chmod 0660 "$jail_node"
}

# atlas_lv_remove NAME
#   Remove an LV. No-op if it is already gone (idempotent teardown). Guarded:
#   refuses to remove the thin pool or a base image LV, so VM/snapshot teardown
#   can never destroy shared state even if handed a wrong name.
atlas_lv_remove() {
    local name="$1"
    case "$name" in
        "$ATLAS_POOL"|atlas-image-*)
            echo "atlas_lv_remove: refusing to remove protected LV '${name}'" >&2
            return 1
            ;;
    esac
    if atlas_lv_exists "$name"; then
        sudo lvremove -f "${ATLAS_VG}/${name}" >/dev/null
    fi
}
