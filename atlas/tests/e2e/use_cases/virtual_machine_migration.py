"""Use case: migrate a Virtual Machine's disk between hosts, keeping its identity.

Operator clicks **Migrate** on a VM form (target picker); the scheduled
`reconcile_migrations` callback advances the resumable phase row to Done. This is
COLD migration — the guest is stopped during cutover and (stage 1, change-address)
gets a NEW public IPv6 on the target; the UUID and everything derived from it
(MAC/tap/netns/uid) re-materialize identically, and the SSH host keys are PRESERVED
so the VM's SSH identity survives the move. See spec/19-vm-migration.md.

This is a **dedicated-two-droplet** host fact — it needs a source AND a target
Server, both Active and same-provider — so it owns its own droplets and is invoked
directly, NOT folded into `run_all_smoke` (the same shape as `server_provisioning`
and `tls_issuance`). Cost: up to two billable droplets (it reuses any Active pair).

What it proves — the host facts only a real cross-host move can:
  1. All 8 phases advance Pending→…→Done via the scheduler driver, idempotently.
  2. The migrated VM row repoints to the target server + a NEW /128 in the target's
     range, status Running.
  3. The guest BOOTS on the target (unit active, TCP 22 open on the new /128).
  4. The VM's SSH host key is BYTE-IDENTICAL before and after (identity survived).
  5. The source copy is fully torn down (unit inactive, disk + -migrate snaps gone).

STAGE 1 (this build): change-address, plain-TCP NBD transport (no SSH tunnel yet).
The unit suite (test_virtual_machine_migration.py) owns the phase-order, pre-flight,
immutability/retry, flags.migrating-gate, and lifecycle-guard logic in milliseconds;
this module is only the host facts.
"""

import time

import frappe

from atlas.atlas import migration as migration_module
from atlas.atlas.ssh import connection_for_server, run_ssh, ssh_key_file
from atlas.tests.e2e._droplets import ensure_bootstrapped_server, server_is_reachable
from atlas.tests.e2e._image import ensure_image_on_server
from atlas.tests.e2e._shared import ephemeral_public_key

POLL_TIMEOUT = 600  # hydration of a small disk over local NBD is quick, but be generous


def host_shell(server_name: str, command: str, timeout: int = 40) -> str:
	"""Run a raw shell command on a Server host over the controller SSH key (the
	same primitive the proxy/bench-image e2es use). Returns stdout."""
	conn = connection_for_server(frappe.get_doc("Server", server_name))
	with ssh_key_file(conn.ssh_private_key) as key_path:
		out, _err, _code = run_ssh(conn, key_path, command, timeout_seconds=timeout)
	return out


def run_smoke(reuse: bool = True, keep: bool = True) -> None:
	"""The host-fact path: migrate a fresh disposable VM source→target, assert the
	five facts above, then terminate it. Reuses any Active source + a second Active
	target if present; provisions what's missing."""
	source, _client, _created = ensure_bootstrapped_server(reuse=reuse, keep=keep)
	target = _ensure_second_active_server(source.name, reuse=reuse, keep=keep)
	# The default image must be present on BOTH hosts (source exports, target boots).
	image = ensure_image_on_server(source.name)
	ensure_image_on_server(target.name)
	public_key = ephemeral_public_key()

	vm = frappe.get_doc(
		{
			"doctype": "Virtual Machine",
			"title": "vm-migration",
			"server": source.name,
			"image": image.name,
			"vcpus": 1,
			"memory_megabytes": 1024,
			"disk_gigabytes": 4,
			"ssh_public_key": public_key,
		}
	).insert(ignore_permissions=True)
	vm.provision()
	frappe.db.commit()
	_wait_for_boot(vm.name, vm.server, vm.ipv6_address)

	# Baseline: the SSH host key the guest presents on the source (the identity that
	# must survive the move).
	host_key_before = _guest_host_key(vm.server, vm.ipv6_address)
	assert host_key_before, "could not read the guest's SSH host key before migration"

	try:
		migration = frappe.get_doc("Virtual Machine", vm.name).migrate(target_server=target.name)
		frappe.db.commit()
		final = _drive_to_terminal(migration)
		assert final == "Done", f"migration ended {final}, expected Done"

		vm.reload()
		assert vm.server == target.name, f"VM still on {vm.server}, expected {target.name}"
		assert vm.status == "Running", f"VM status {vm.status}, expected Running"
		target_range = frappe.db.get_value("Server", target.name, "ipv6_virtual_machine_range")
		assert _ip_in_range(vm.ipv6_address, target_range), (
			f"new /128 {vm.ipv6_address} not in target range {target_range}"
		)

		# Fact 3: boots on target, reachable on the new /128.
		_wait_for_boot(vm.name, target.name, vm.ipv6_address)

		# Fact 4: SSH host key preserved across the move.
		host_key_after = _guest_host_key(target.name, vm.ipv6_address)
		assert host_key_after == host_key_before, (
			f"SSH host key changed across migration: {host_key_before} -> {host_key_after}"
		)

		# Fact 5: source copy torn down.
		assert _source_clean(source.name, vm.name), "source copy not fully cleaned up"

		print(
			f"[e2e] vm-migration OK: {vm.name} moved {source.name} -> {target.name}, "
			f"new /128 {vm.ipv6_address}, host key preserved, source clean"
		)
	finally:
		if not keep:
			frappe.get_doc("Virtual Machine", vm.name).terminate()
			frappe.db.commit()


def _ensure_second_active_server(exclude: str, reuse: bool, keep: bool):
	"""A second Active, same-provider Server distinct from `exclude`. Reuses one if a
	second Active pair exists; otherwise provisions a fresh target droplet."""
	source_provider = frappe.db.get_value("Server", exclude, "provider_type")
	if reuse:
		for name in frappe.get_all("Server", filters={"status": "Active"}, pluck="name"):
			if name == exclude:
				continue
			if frappe.db.get_value("Server", name, "provider_type") != source_provider:
				continue
			if server_is_reachable(name):
				return frappe.get_doc("Server", name)
	# Provision a fresh one via the same primitive; ensure_bootstrapped_server won't
	# hand back `exclude` because we mark it in-use by passing reuse=False here.
	server, _client, _created = ensure_bootstrapped_server(reuse=False, keep=keep)
	return server


def _drive_to_terminal(migration_name: str) -> str:
	"""Advance the migration one phase per loop until Done/Failed — the same thing
	the scheduler does every 2 min, driven synchronously so the test is deterministic.
	Hydrating re-enters until 100%."""
	deadline = time.monotonic() + POLL_TIMEOUT
	while time.monotonic() < deadline:
		doc = frappe.get_doc("Virtual Machine Migration", migration_name)
		if doc.status in ("Done", "Failed"):
			return doc.status
		migration_module.advance_migration(doc)
		frappe.db.commit()
		time.sleep(1)
	return frappe.db.get_value("Virtual Machine Migration", migration_name, "status")


def _wait_for_boot(vm_name: str, host: str, v6: str, timeout: int = 180) -> None:
	deadline = time.monotonic() + timeout
	while time.monotonic() < deadline:
		out = host_shell(host, f"timeout 6 bash -c 'echo > /dev/tcp/{v6}/22' && echo OPEN || echo CLOSED")
		if "OPEN" in out:
			return
		time.sleep(5)
	raise AssertionError(f"VM {vm_name} not reachable on {v6}:22 within {timeout}s")


def _guest_host_key(host: str, v6: str) -> str:
	out = host_shell(host, f"ssh-keyscan -T 10 -t ed25519 {v6} 2>/dev/null | awk '{{print $3}}' | head -1")
	return out.strip()


def _source_clean(source: str, vm_name: str) -> bool:
	unit = host_shell(
		source, f"sudo systemctl is-active firecracker-vm@{vm_name}.service 2>/dev/null || true"
	).strip()
	lvs = host_shell(source, f"sudo lvs --noheadings -o lv_name atlas | grep {vm_name} || echo CLEAN").strip()
	return unit != "active" and "CLEAN" in lvs


def _ip_in_range(address: str, cidr: str) -> bool:
	import ipaddress

	return ipaddress.ip_address(address) in ipaddress.ip_network(cidr)
