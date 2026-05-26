"""Phase 4 e2e: sync an image to a real server."""

from atlas.atlas.ssh import run_task
from atlas.tests.e2e._shared import (
	ensure_default_image_row,
	phase,
	wait_for_task,
)


def run(reuse: bool = True, keep: bool = True) -> None:
	"""Sync the default image to a bootstrapped server.

	With `reuse=True` (default), uses an existing Active+reachable server;
	with `keep=True`, leaves any freshly provisioned droplet behind for the
	next phase to reuse.
	"""
	with phase("phase-4", reuse=reuse, keep=keep) as server:
		image = ensure_default_image_row()

		task_name = image.sync_to_server(server.name)
		task = wait_for_task(task_name, timeout_seconds=900, poll_seconds=5)
		assert task.status == "Success", f"sync-image failed: {(task.stderr or '')[:500]}"

		_assert_image_on_server(server.name, image)

		# Idempotency: re-sync should short-circuit.
		task_name = image.sync_to_server(server.name)
		task = wait_for_task(task_name, timeout_seconds=120, poll_seconds=2)
		assert task.status == "Success"
		assert "already" in task.stdout.lower()


def _assert_image_on_server(server_name: str, image) -> None:
	task = run_task(
		server=server_name,
		script="phase4-probe.sh",
		variables={
			"IMAGE_NAME": image.image_name,
			"KERNEL_FILENAME": image.kernel_filename,
			"ROOTFS_FILENAME": image.rootfs_filename,
			"DEFAULT_DISK_GB": str(image.default_disk_gigabytes),
		},
		timeout_seconds=60,
	)
	assert task.status == "Success", f"probe failed: {task.stderr[:500]}"
