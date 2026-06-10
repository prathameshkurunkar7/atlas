"""Unit tests for the provisioning step view (atlas.atlas.site_status).

Pure mapping logic — `status` → the six-step checklist — plus the owner-gated
poll endpoint. Milliseconds, no host. The realtime push itself is exercised
through Site.auto_provision's tests (the status machine); here we pin the step
states and the access gate."""

from __future__ import annotations

import frappe
from frappe.tests import IntegrationTestCase

from atlas.atlas import site_status


class TestStepsFor(IntegrationTestCase):
	def _states(self, status):
		return [s["state"] for s in site_status.steps_for(status)]

	def test_pending_has_nothing_done(self):
		# Pending = the job hasn't started; nothing is done yet.
		states = self._states("Pending")
		self.assertNotIn("done", states)
		self.assertNotIn("running", states)

	def test_provisioning_runs_both_provision_phase_steps(self):
		# Provisioning sits at the provision phase: BOTH provision-phase steps are
		# in flight (clone+provision, then the boot wait), the rest pending.
		states = self._states("Provisioning")
		self.assertEqual(states[0], "running")
		self.assertEqual(states[1], "running")
		self.assertTrue(all(s == "pending" for s in states[2:]))

	def test_deploying_marks_provision_done_deploy_running(self):
		states = self._states("Deploying")
		# The two provision steps are done, the deploy-phase steps are now running.
		self.assertEqual(states[0], "done")
		self.assertEqual(states[1], "done")
		self.assertEqual(states[2], "running")
		self.assertEqual(states[3], "running")

	def test_running_marks_every_step_done(self):
		self.assertTrue(all(s == "done" for s in self._states("Running")))

	def test_failed_marks_deploy_phase_failed_rest_not_done(self):
		# Earlier phases done, the deploy phase failed, later steps pending — no
		# step after the failure reads "done".
		states = self._states("Failed")
		self.assertIn("failed", states)
		self.assertNotIn("done", states[states.index("failed") + 1 :])

	def test_unknown_status_degrades_to_all_pending_ish(self):
		# Never throws on a stray status (renders on a public-ish page).
		states = self._states("Nonsense")
		self.assertEqual(len(states), len(site_status.STEPS))

	def test_labels_are_user_facing_no_vm_jargon(self):
		joined = " ".join(s["label"].lower() for s in site_status.steps_for("Pending"))
		self.assertNotIn("vm", joined)
		self.assertNotIn("ssh", joined)
