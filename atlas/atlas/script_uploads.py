"""Per-script sidecar uploads.

Some scripts need supporting files on the server before they run. The Server
bootstrap is special: its uploads are durable state (helper scripts + systemd
unit) placed by `Server.bootstrap()` directly, not through this map.

The map below is consulted by `ssh.py::_run_remote_script()` before each
script invocation. Paths in the value tuples are (local_relative_to_repo_root,
remote_absolute).
"""

# prepare-rootfs.sh is a sourced shell library (not a standalone Task). The
# scripts that lay down a per-VM rootfs source it by relative path, so it must
# land in the staging directory next to them.
_PREPARE_ROOTFS = ("scripts/lib/prepare-rootfs.sh", "/tmp/atlas/prepare-rootfs.sh")

# lvm.sh is the sourced LVM thin-pool helper library, same staging contract as
# prepare-rootfs.sh. Every script that creates, exposes, or removes a per-VM
# disk LV sources it by relative path, so it lands next to each caller. (The
# bootstrap also needs it, but bootstrap's helpers are durable state placed by
# Server.bootstrap() directly, not through this map — see the module docstring.)
_LVM = ("scripts/lib/lvm.sh", "/tmp/atlas/lvm.sh")

SCRIPT_UPLOADS: dict[str, list[tuple[str, str]]] = {
	"sync-image.sh": [
		("scripts/guest/atlas-network.service", "/tmp/atlas/atlas-network.service"),
		_LVM,
	],
	"provision-vm.sh": [_PREPARE_ROOTFS, _LVM],
	"rebuild-vm.sh": [_PREPARE_ROOTFS, _LVM],
	"snapshot-vm.sh": [_LVM],
	"delete-snapshot-vm.sh": [_LVM],
	"resize-vm.sh": [_LVM],
	"terminate-vm.sh": [_LVM],
}


def files_to_upload(script: str) -> list[tuple[str, str]]:
	return SCRIPT_UPLOADS.get(script, [])
