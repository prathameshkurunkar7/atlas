"""Image-row helpers for the e2e harness."""

import frappe

from atlas.tests.e2e._config import DEFAULT_IMAGE
from atlas.tests.e2e._tasks import wait_for_task


def ensure_default_image_row() -> "frappe.model.document.Document":
	"""Insert or refresh the default `Virtual Machine Image` row to `DEFAULT_IMAGE`.

	Returns the Document. Does not touch any server. Phase 4 uses this when
	it wants to exercise `sync_to_server` explicitly without the probe
	short-circuit baked into `ensure_image_on_server`.
	"""
	image_name = DEFAULT_IMAGE["image_name"]
	if frappe.db.exists("Virtual Machine Image", image_name):
		image = frappe.get_doc("Virtual Machine Image", image_name)
		image.update(DEFAULT_IMAGE)
		image.is_active = 1
		image.save(ignore_permissions=True)
		frappe.db.commit()
		return image
	image = frappe.get_doc({
		"doctype": "Virtual Machine Image",
		**DEFAULT_IMAGE,
		"is_active": 1,
	}).insert(ignore_permissions=True)
	frappe.db.commit()
	return image


def ensure_image_on_server(server_name: str) -> "frappe.model.document.Document":
	"""Sync DEFAULT_IMAGE to `server_name`. `sync-image.sh` is idempotent and
	short-circuits when the rootfs is already present on disk, so re-calling
	is cheap (one SSH roundtrip).
	"""
	image = ensure_default_image_row()
	task_name = image.sync_to_server(server_name)
	task = wait_for_task(task_name, timeout_seconds=900, poll_seconds=5)
	if task.status != "Success":
		raise AssertionError(f"sync-image failed: {(task.stderr or '')[:500]}")
	return image
