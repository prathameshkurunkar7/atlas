"""Unit tests for the Pilot controller — the bench-backed tenant environment.

A Pilot owns a backing Virtual Machine, is fronted at `<subdomain>.<region domain>`
(Contract A), and carries the one-click login handoff minted after the guest deploy.
The bench provision moved OFF the Virtual Machine onto the Pilot (the VM stays a
pure microVM), so these tests cover: the routing label gate, the synchronous VM
creation in after_insert, the wait→deploy→mint→Running orchestration, and the
regenerate seam.

All milliseconds, no host: the backing VM runs on a Fake server, so `deploy_site`'s
SSH work is short-circuited (a synthesized placeholder login URL). The VM's own boot
job doesn't run in-test (enqueue_after_commit), so the orchestration test flips the
VM to Running itself and mocks the wait — only the pure orchestration is asserted.
The real guest mint is proven in the bench-image e2e.
"""

from __future__ import annotations

from unittest.mock import patch

import frappe
from frappe.tests import IntegrationTestCase

from atlas.atlas.doctype.pilot import pilot as pilot_module
from atlas.atlas.doctype.tenant.tenant import ensure_tenant
from atlas.tests import fixtures

ROOT_DOMAIN = "blr1.frappe.dev"
REGION = "blr1"
TEAM = "team-acme"
TENANT_EMAIL = "owner@acme.example.com"


def _ensure_root_domain() -> None:
	frappe.db.set_single_value("Atlas Settings", "region", REGION)
	if not frappe.db.exists("Root Domain", ROOT_DOMAIN):
		frappe.get_doc(
			{
				"doctype": "Root Domain",
				"domain": ROOT_DOMAIN,
				"region": REGION,
				"is_active": 1,
				"dns_provider_type": "Route53",
				"tls_provider_type": "Let's Encrypt",
			}
		).insert(ignore_permissions=True)
	frappe.db.set_value("Root Domain", ROOT_DOMAIN, "is_active", 1)
	for name in frappe.get_all("Root Domain", filters={"is_active": 1}, pluck="name"):
		if name != ROOT_DOMAIN:
			frappe.db.set_value("Root Domain", name, "is_active", 0)


class TestPilot(IntegrationTestCase):
	def setUp(self) -> None:
		_ensure_root_domain()
		self.provider = fixtures.make_provider_row("fake-test-provider", provider_type="Fake")
		fixtures.set_atlas_settings(self.provider, ssh_public_key="ssh-ed25519 AAAAFLEET")
		# set_atlas_settings may reset region; re-pin it for the FQDN derivation.
		frappe.db.set_single_value("Atlas Settings", "region", REGION)
		frappe.db.set_single_value("Atlas Settings", "ssh_public_key", "ssh-ed25519 AAAAFLEET")
		self.server = self._make_server()
		self.admin_image = fixtures.make_image("fake-bench-admin-image", build_mode="admin")
		for name in frappe.get_all("Pilot", pluck="name"):
			frappe.delete_doc("Pilot", name, force=1, ignore_permissions=True)
		# The Subdomain autoname is the bare label, so a leftover `acme` from a prior
		# test collides with the one this pilot's auto_provision creates — clear them.
		for name in frappe.get_all("Subdomain", pluck="name"):
			frappe.delete_doc("Subdomain", name, force=1, ignore_permissions=True)
		self.addCleanup(frappe.set_user, "Administrator")

	def _make_server(self):
		server = frappe.new_doc("Server")
		server.update(
			{
				"title": "fake-test-server",
				"provider_type": "Fake",
				"provider_resource_id": None,
				"size": fixtures.DEFAULT_DIGITALOCEAN_SIZE,
				"status": "Active",
				"ipv4_address": "203.0.113.10",
				"ipv6_address": "2001:db8:abcd::1",
				"ipv6_prefix": "2001:db8:abcd::/64",
				# /120 (256 addresses) so a run's worth of per-pilot VMs (they aren't torn
				# down between tests) doesn't exhaust the range mid-suite.
				"ipv6_virtual_machine_range": "2001:db8:abcd::/120",
			}
		)
		return server.insert(ignore_permissions=True)

	def _spec(self) -> dict:
		return {"server": self.server.name, "image": self.admin_image.name}

	def _new_pilot(self, subdomain: str = "acme"):
		return fixtures.make_pilot(subdomain, vm_spec=self._spec(), tenant=ensure_tenant(TEAM, TENANT_EMAIL))

	# ----- identity + label gate ----------------------------------------

	def test_autoname_is_the_fqdn(self) -> None:
		pilot = self._new_pilot("acme")
		self.assertEqual(pilot.name, "acme.blr1.frappe.dev")
		self.assertEqual(pilot.bench_fqdn, "acme.blr1.frappe.dev")
		self.assertEqual(pilot.gateway_url, "https://acme.blr1.frappe.dev")

	def test_bad_label_is_rejected(self) -> None:
		"""A dotted / uppercase subdomain fails loud at insert (Contract-A rule)."""
		with self.assertRaises(frappe.ValidationError):
			self._new_pilot("Not.A.Label")

	def test_after_insert_creates_and_links_the_backing_vm(self) -> None:
		"""The VM is created synchronously in after_insert (so create_vm can return its
		identity) and linked. It inherits build_mode from the bench image."""
		pilot = self._new_pilot("acme")
		self.assertTrue(pilot.virtual_machine)
		vm = frappe.get_doc("Virtual Machine", pilot.virtual_machine)
		self.assertEqual(vm.title, "acme")
		self.assertEqual(vm.build_mode, "admin")
		# The pilot mirrors the mode onto its own row for the mint/TTL logic.
		self.assertEqual(pilot.build_mode, "admin")

	# ----- orchestration -------------------------------------------------

	def _drive_provision(self, pilot):
		"""Run auto_provision with the (enqueue-only) boot job stood in for: flip the
		backing VM to Running and mock the wait. deploy is real (Fake short-circuit)."""
		frappe.db.set_value("Virtual Machine", pilot.virtual_machine, "status", "Running")
		with (
			patch.object(pilot_module, "_wait_for_vm_running") as m_wait,
			patch.object(pilot_module.frappe.db, "commit"),
		):
			pilot_module.auto_provision(pilot.name)
		return m_wait

	def test_provision_mints_login_before_running(self) -> None:
		pilot = self._new_pilot("acme")
		m_wait = self._drive_provision(pilot)
		pilot.reload()
		self.assertEqual(pilot.status, "Running")
		m_wait.assert_called_once_with(pilot.virtual_machine)
		# admin mode → the synthesized Fake login URL, stamped with an expiry.
		self.assertEqual(pilot.login_url, "https://acme.blr1.frappe.dev/app?sid=fake-sid")
		self.assertTrue(pilot.login_url_expires_at)

	def test_provision_creates_and_links_the_subdomain(self) -> None:
		"""Like a Site, a provisioned pilot creates a Subdomain (proxy route) pointing
		its label at the backing VM, and links it back as subdomain_doc."""
		pilot = self._new_pilot("acme")
		self._drive_provision(pilot)
		pilot.reload()
		self.assertTrue(pilot.subdomain_doc)
		subdomain = frappe.get_doc("Subdomain", pilot.subdomain_doc)
		self.assertEqual(subdomain.subdomain, "acme")
		self.assertEqual(subdomain.virtual_machine, pilot.virtual_machine)
		self.assertTrue(subdomain.active)

	def test_provision_failure_marks_failed_and_raises(self) -> None:
		pilot = self._new_pilot("acme")
		frappe.db.set_value("Virtual Machine", pilot.virtual_machine, "status", "Running")
		with (
			patch.object(pilot_module, "_wait_for_vm_running"),
			patch.object(pilot_module, "_deploy", side_effect=RuntimeError("mint boom")),
			patch.object(pilot_module.frappe.db, "commit"),
			self.assertRaises(RuntimeError),
		):
			pilot_module.auto_provision(pilot.name)
		pilot.reload()
		self.assertEqual(pilot.status, "Failed")
		# The mint failed before the route, so no Subdomain was created.
		self.assertFalse(pilot.subdomain_doc)

	# ----- regenerate ----------------------------------------------------

	def test_regenerate_login_url_remints_and_returns_vm_payload(self) -> None:
		pilot = self._new_pilot("acme")
		self._drive_provision(pilot)
		pilot.reload()
		old_expiry = pilot.login_url_expires_at
		fresh = "https://acme.blr1.frappe.dev/app?sid=fresh"
		with (
			patch.object(pilot_module, "_regenerate_login", return_value={"login_url": fresh}) as m_regen,
			patch.object(pilot_module.frappe.db, "commit"),
		):
			payload = pilot.regenerate_login_url()
		m_regen.assert_called_once_with(pilot)
		pilot.reload()
		self.assertEqual(pilot.login_url, fresh)
		self.assertGreaterEqual(pilot.login_url_expires_at, old_expiry)
		# The returned payload is the VM-shaped mirror Central re-reads.
		self.assertEqual(payload["login_url"], fresh)
		self.assertEqual(payload["gateway_url"], "https://acme.blr1.frappe.dev")
		self.assertEqual(payload["name"], pilot.virtual_machine)

	def test_regenerate_login_url_refused_before_running(self) -> None:
		pilot = self._new_pilot("acme")
		self.assertEqual(pilot.status, "Pending")
		with self.assertRaises(frappe.ValidationError):
			pilot.regenerate_login_url()

	# ----- teardown ------------------------------------------------------

	def test_terminate_tears_down_the_backing_vm(self) -> None:
		pilot = self._new_pilot("acme")
		vm_name = pilot.virtual_machine
		with patch("atlas.atlas.doctype.virtual_machine.virtual_machine.VirtualMachine.terminate") as m_term:
			pilot.terminate()
		pilot.reload()
		self.assertEqual(pilot.status, "Terminated")
		m_term.assert_called_once()
		self.assertTrue(vm_name)

	def test_terminate_deletes_the_subdomain(self) -> None:
		"""Teardown takes the pilot off the front door: the Subdomain is deleted and the
		link cleared. Mirrors Site.terminate()."""
		pilot = self._new_pilot("acme")
		self._drive_provision(pilot)
		pilot.reload()
		subdomain_name = pilot.subdomain_doc
		self.assertTrue(subdomain_name)
		with patch("atlas.atlas.doctype.virtual_machine.virtual_machine.VirtualMachine.terminate"):
			pilot.terminate()
		pilot.reload()
		self.assertFalse(pilot.subdomain_doc)
		self.assertFalse(frappe.db.exists("Subdomain", subdomain_name))

	# ----- VM → Pilot lookup --------------------------------------------

	def test_pilot_for_vm_finds_the_owner(self) -> None:
		pilot = self._new_pilot("acme")
		found = pilot_module.pilot_for_vm(pilot.virtual_machine)
		self.assertIsNotNone(found)
		self.assertEqual(found.name, pilot.name)

	def test_pilot_for_vm_none_for_plain_vm(self) -> None:
		vm = fixtures.make_virtual_machine(self.server, self.admin_image, title="plain")
		self.assertIsNone(pilot_module.pilot_for_vm(vm.name))
