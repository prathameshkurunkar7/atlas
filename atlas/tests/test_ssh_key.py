"""SSH Key DocType: validation, fingerprint derivation, owner scoping.

SSH Key is a per-user owned DocType (spec/02 § SSH Key, spec/11). A dashboard
user registers a key once and chooses it on machine create; the VM copies the
key body into its own immutable `ssh_public_key`. These tests pin:

1. `validate()` derives the standard `SHA256:<base64nopad>` fingerprint.
2. A malformed key fails loud at the boundary (Taste 17) — not stored to fail
   opaquely at provision time.
3. `if_owner` scoping: a user sees only their own keys; an operator sees all.
"""

import base64
import hashlib

import frappe
from frappe.tests import IntegrationTestCase

from atlas.atlas.doctype.ssh_key.ssh_key import fingerprint

USER_A_EMAIL = "atlas-sshkey-a@example.com"
USER_B_EMAIL = "atlas-sshkey-b@example.com"
SYSMGR_EMAIL = "atlas-sshkey-sysmgr@example.com"

# A complete, valid ed25519 public key (valid base64 body, padded).
VALID_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDLM3M2qZ8mLkUo6L1l0wq3rT7kqQ0jJ8wKf5cN0pQaX laptop@example"


def _expected_fingerprint(public_key: str) -> str:
	blob = public_key.split()[1]
	raw = base64.b64decode(blob)
	digest = base64.b64encode(hashlib.sha256(raw).digest()).decode().rstrip("=")
	return f"SHA256:{digest}"


def _ensure_atlas_user_role() -> None:
	if not frappe.db.exists("Role", "Atlas User"):
		frappe.get_doc({"doctype": "Role", "role_name": "Atlas User", "desk_access": 0}).insert(
			ignore_permissions=True
		)


def _make_user(email: str, *, role: str | None) -> str:
	if frappe.db.exists("User", email):
		user = frappe.get_doc("User", email)
	else:
		user = frappe.get_doc(
			{
				"doctype": "User",
				"email": email,
				"first_name": "SSH",
				"last_name": "Key",
				"send_welcome_email": 0,
				"enabled": 1,
			}
		).insert(ignore_permissions=True)
	for role_row in list(user.get("roles") or []):
		user.remove(role_row)
	if role:
		user.append("roles", {"role": role})
	user.save(ignore_permissions=True)
	return user.name


class TestSSHKeyValidation(IntegrationTestCase):
	def test_pure_fingerprint_helper(self) -> None:
		self.assertEqual(fingerprint(VALID_KEY), _expected_fingerprint(VALID_KEY))
		self.assertTrue(fingerprint(VALID_KEY).startswith("SHA256:"))

	def test_validate_derives_fingerprint_on_insert(self) -> None:
		_ensure_atlas_user_role()
		self.addCleanup(frappe.set_user, "Administrator")
		doc = frappe.get_doc({"doctype": "SSH Key", "key_name": "laptop", "public_key": VALID_KEY}).insert(
			ignore_permissions=True
		)
		self.assertEqual(doc.fingerprint, _expected_fingerprint(VALID_KEY))

	def test_whitespace_is_stripped(self) -> None:
		doc = frappe.get_doc(
			{
				"doctype": "SSH Key",
				"key_name": "padded",
				"public_key": f"  \n{VALID_KEY}\n  ",
			}
		).insert(ignore_permissions=True)
		self.assertEqual(doc.public_key, VALID_KEY)
		self.assertEqual(doc.fingerprint, _expected_fingerprint(VALID_KEY))

	def test_unknown_type_rejected(self) -> None:
		with self.assertRaises(frappe.ValidationError):
			frappe.get_doc(
				{"doctype": "SSH Key", "key_name": "bad", "public_key": "not-a-key AAAA x"}
			).insert(ignore_permissions=True)

	def test_missing_blob_rejected(self) -> None:
		with self.assertRaises(frappe.ValidationError):
			frappe.get_doc({"doctype": "SSH Key", "key_name": "bad", "public_key": "ssh-ed25519"}).insert(
				ignore_permissions=True
			)

	def test_bad_base64_rejected(self) -> None:
		with self.assertRaises(frappe.ValidationError):
			frappe.get_doc(
				{
					"doctype": "SSH Key",
					"key_name": "bad",
					"public_key": "ssh-ed25519 not!valid!base64!!! x@y",
				}
			).insert(ignore_permissions=True)


class TestSSHKeyOwnerScoping(IntegrationTestCase):
	def setUp(self) -> None:
		_ensure_atlas_user_role()
		self.user_a = _make_user(USER_A_EMAIL, role="Atlas User")
		self.user_b = _make_user(USER_B_EMAIL, role="Atlas User")
		self.sysmgr = _make_user(SYSMGR_EMAIL, role="System Manager")
		self.addCleanup(frappe.set_user, "Administrator")

	def _insert_key_as(self, email: str, name: str):
		previous = frappe.session.user
		frappe.set_user(email)
		try:
			return frappe.get_doc({"doctype": "SSH Key", "key_name": name, "public_key": VALID_KEY}).insert()
		finally:
			frappe.set_user(previous)

	def test_user_reads_own_key_not_others(self) -> None:
		key_a = self._insert_key_as(self.user_a, "a-key")
		frappe.set_user(self.user_a)
		self.assertTrue(frappe.has_permission("SSH Key", "read", doc=key_a.name))
		frappe.set_user(self.user_b)
		self.assertFalse(
			frappe.has_permission("SSH Key", "read", doc=key_a.name),
			"a different Atlas User must not read someone else's key",
		)

	def test_list_is_owner_scoped(self) -> None:
		key_a = self._insert_key_as(self.user_a, "a-only")
		frappe.set_user(self.user_b)
		names = {row.name for row in frappe.get_list("SSH Key", limit_page_length=0)}
		self.assertNotIn(key_a.name, names)
		frappe.set_user(self.user_a)
		names = {row.name for row in frappe.get_list("SSH Key", limit_page_length=0)}
		self.assertIn(key_a.name, names)

	def test_operator_sees_all_keys(self) -> None:
		key_a = self._insert_key_as(self.user_a, "operator-visible")
		frappe.set_user(self.sysmgr)
		self.assertTrue(frappe.has_permission("SSH Key", "read", doc=key_a.name))
		names = {row.name for row in frappe.get_list("SSH Key", limit_page_length=0)}
		self.assertIn(key_a.name, names)
