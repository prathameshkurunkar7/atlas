"""The VM service seam — how Atlas core attaches service-specific behavior to the
generic Virtual Machine lifecycle without knowing what those services are.

Atlas core owns "a VM exists": provision, start/stop, terminate, base networking
(spec/README non-goals; spec/06). Everything service-specific — reverse-proxy
routing, the customer gateway, the WireGuard host mesh, bench/site deploy — belongs
in a SEPARATE app (`satellite`, spec/28) that attaches here through this registry.
Core defines the contract (`VMService`); satellite populates it via the
`atlas_vm_services` hook, so **core never imports satellite**. On a bare Atlas with
no satellite installed the registry is empty and every seam call site is a no-op —
the VM lifecycle behaves exactly as it did before the seam existed.

The seam is bidirectional (spec/28 §3):

  - 3A (Atlas → satellite): the core lifecycle calls each registered service at the
    defined hook points — `validate` (insert-time rules/defaults),
    `provision_variables` (extra Task env), `on_provision` (post-provision side
    effects), `on_status_change` (optional lifecycle reactions), and `teardown`
    (ordered, on terminate). `vm_services()` builds the ordered list from the hook.

  - 3B (satellite → Atlas): a service never opens SSH, calls a provider, or mutates
    a host/guest itself. It drives every infra effect through the exposed execution
    API below (`run_host_script`, `run_guest_script`), which wraps Atlas's SSH/Task
    engine — and, critically, its Fake seam — so a service is testable without a
    droplet. Script trees a service ships are contributed to the runner's catalog via
    the `atlas_script_directories` hook (see `scripts_catalog`).

This generalizes the good precedent already in `hooks.py`: Central reporting is not
inline in the VM controller — it is `doc_events` observers. The seam is that idea
made explicit, ordered, and lifecycle-aware, and turned around so the service also
drives infra back through Atlas.
"""

from __future__ import annotations

import contextlib
from typing import TYPE_CHECKING, Protocol, runtime_checkable

import frappe

if TYPE_CHECKING:
	from atlas.atlas.doctype.task.task import Task
	from atlas.atlas.doctype.virtual_machine.virtual_machine import VirtualMachine


# ---------------------------------------------------------------------------
# 3A. The lifecycle registry (Atlas → satellite)
# ---------------------------------------------------------------------------


@runtime_checkable
class VMService(Protocol):
	"""A service-specific attachment to the VM lifecycle. Satellite registers one
	implementation per concern (mesh, gateway, routing, proxy, bench). A service
	implements only the hook points it cares about, but the Protocol lists them all
	so core can call any of them uniformly and in a stable order.

	`applies_to` is the cheap gate — it reads the VM's custom fields only (no DB
	fan-out) and every other hook runs for a VM only when it returns True. That keeps
	an unrelated VM (an operator's bare compute box) untouched by a service it has no
	role in, and keeps a bare Atlas (empty registry) a pure no-op."""

	name: str

	def applies_to(self, vm: "VirtualMachine") -> bool:
		"""Does this service attach to this VM? Cheap; reads custom fields only."""
		...

	def validate(self, vm: "VirtualMachine") -> None:
		"""Insert/save-time rules and defaults for this service (role exclusivity,
		field defaults). Runs inside the VM's own `validate()`; may `frappe.throw`."""
		...

	def provision_variables(self, vm: "VirtualMachine") -> dict:
		"""Extra Task variables to merge into the provision env (a routing base URL,
		the private-plane identity, …). Merged into `_provision_variables()`."""
		...

	def on_provision(self, vm: "VirtualMachine") -> None:
		"""Side effects after the provision Task (e.g. a host-mesh reconcile). Runs
		after the provision has committed, so a failure here never rolls back the
		VM — the converging reconcile brings the fabric to match."""
		...

	def on_status_change(self, vm: "VirtualMachine", old: str, new: str) -> None:
		"""Optional reaction to a status transition (e.g. Running → Stopped)."""
		...

	def teardown(self, vm: "VirtualMachine") -> None:
		"""Ordered teardown on terminate. Core runs its generic teardown around this
		(detach Reserved IP, delete Snapshots); a service drops its own routes / peers
		/ mesh membership here. Must be idempotent."""
		...


# Test seam: when set to a list, `vm_services()` returns it instead of building from
# the hook. Lets a unit test inject a fake `VMService` (or an empty list) without
# editing app hooks or installing satellite. Production leaves it None. Use the
# `use_services` context manager rather than assigning this directly.
_override: list[VMService] | None = None


def vm_services() -> list[VMService]:
	"""The registered services, in declared order.

	Built from the `atlas_vm_services` hook — a list of dotted class paths each app
	contributes; Atlas contributes none, satellite contributes its service classes.
	Empty on a bare Atlas, so every seam call site no-ops. Rebuilt each call (the
	hook is cached by Frappe and instantiation is cheap), so a freshly installed app
	or a test override is picked up without a process restart."""
	if _override is not None:
		return _override
	return [frappe.get_attr(dotted)() for dotted in frappe.get_hooks("atlas_vm_services")]


def services_for(vm: "VirtualMachine") -> list[VMService]:
	"""The registered services that apply to this VM, in declared order — the list
	every seam call site iterates. A service that raises from `applies_to` (a bug in
	that service) must not wedge the whole lifecycle, so a raise is logged and the
	service skipped rather than propagated."""
	applicable: list[VMService] = []
	for service in vm_services():
		try:
			if service.applies_to(vm):
				applicable.append(service)
		except Exception:
			frappe.log_error(f"VMService {getattr(service, 'name', service)!r} applies_to failed")
	return applicable


@contextlib.contextmanager
def use_services(services: list[VMService]):
	"""Test helper: run the block with `vm_services()` returning `services` (often a
	single fake service, or `[]` to assert the empty-registry no-op)."""
	global _override
	previous = _override
	_override = services
	try:
		yield
	finally:
		_override = previous


# ---------------------------------------------------------------------------
# 3B. The exposed execution API (satellite → Atlas)
# ---------------------------------------------------------------------------
#
# A service holds the DECISION (the desired routing map, peer set, deploy step) and
# ships the setup scripts; Atlas holds the EXECUTION (SSH, providers, the VM fabric).
# These functions are the whole of that execution surface a service is allowed to
# touch: it opens no SSH and calls no provider itself. Both wrap `run_task`, so they
# ride the existing SSH/Task engine, record a Task row, and honor the Fake-server
# seam (a service is exercised end-to-end in tests with no droplet).


def run_host_script(
	server: str, script: str, variables: dict | None = None, timeout_seconds: int = 1800
) -> "Task":
	"""Run a registered script on a HOST (Server) over its IPv4, as a recorded Task —
	the executor for host-plane effects (the WireGuard host mesh / gateway wg lives in
	the host root netns, reached over the host's IPv4). Wraps `run_task(server=…)`, so
	a Fake-backed server synthesizes the Task with no SSH."""
	from atlas.atlas.ssh import run_task

	return run_task(
		server=server, script=script, variables=variables or {}, timeout_seconds=timeout_seconds
	)


def run_guest_script(
	virtual_machine: str, script: str, variables: dict | None = None, timeout_seconds: int = 1800
) -> "Task":
	"""Run a registered script on a GUEST over its public IPv6 `/128`, as a recorded
	Task attributed to the VM — the executor for in-guest effects (proxy map sync,
	cert push, deploy). A Fake-backed VM synthesizes the Task with no SSH, mirroring
	`run_task`'s Fake-host seam, so a satellite service that reconciles guest state is
	testable without a droplet (the plan's "swap the executor, not scattered mocks")."""
	from atlas.atlas.providers.fake_tasks import is_fake_server, run_fake_task

	vm = frappe.get_doc("Virtual Machine", virtual_machine)
	if is_fake_server(vm.server):
		return run_fake_task(vm.server, script, variables or {}, vm.name)

	from atlas.atlas.ssh import connection_for_guest, run_task

	return run_task(
		connection=connection_for_guest(vm),
		script=script,
		variables=variables or {},
		virtual_machine=vm.name,
		timeout_seconds=timeout_seconds,
	)
