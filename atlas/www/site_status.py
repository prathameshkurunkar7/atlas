"""`/site-status?site=<fqdn>` — the live provisioning view a verified user lands
on (plan 04 SPA work / spec 14 "the dashboard Site screen").

After clicking the verification link the user is logged in and redirected here
(see `atlas/www/verify.py`). This page shows the six provisioning steps
(`atlas.atlas.site_status`) as a live checklist — pushed over realtime by
`Site.auto_provision` on every transition, with a slow polling fallback so the
view is never wrong if a socket event is missed. Once the site reaches Running it
reveals the live URL and the one-time Administrator password (the admin handoff).

Owner-gated: the Site is owner-scoped (permissions.py), so we resolve it as the
session user and 404-style message on a Site that isn't theirs (or a guest) — a
public-ish URL must never leak another user's site or password.
"""

import frappe

from atlas.atlas.site_status import progress_payload

no_cache = 1


def get_context(context):
	"""Resolve the owner's Site, hand the template its first-render state. On any
	access problem (no name, not found, not theirs, guest) render a clean error —
	never a traceback, never another user's data."""
	# Pin the page title so Frappe's web renderer doesn't derive a meta title by
	# scanning the body (which can pick up the hidden error-branch heading).
	context.title = "Creating your site"
	if frappe.session.user == "Guest":
		# They reached this without verifying/logging in. Send them to sign in,
		# bouncing back here afterward so a refresh-after-timeout still works.
		target = frappe.request.url if frappe.request else "/site-status"
		frappe.local.flags.redirect_location = f"/login?redirect-to={frappe.utils.quote(target)}"
		raise frappe.Redirect

	name = (frappe.form_dict.get("site") or "").strip()
	site = _owned_site(name)
	if not site:
		context.error = "We couldn't find that site, or it isn't yours."
		return context

	context.site_name = site.name
	# First-render state: the same payload realtime pushes, so the page's initial
	# paint and its live updates share one shape (no first-paint/then-jump flicker).
	context.initial = frappe.as_json(progress_payload(site))
	# The live URL is the FQDN over https (Contract A). Shown once Running.
	context.site_url = f"https://{site.name}"
	# Admin password is revealed ONLY when serving (spec: gated on status==Running),
	# and read through the decrypt path — never embedded otherwise.
	context.admin_password = site.get_password("admin_password") if site.status == "Running" else ""
	return context


def _owned_site(name: str):
	"""The Site row IF it exists and belongs to the session user (operators see
	any). None otherwise — the caller renders one neutral "not found or not yours"
	message for every miss, so a non-owner can't probe which FQDNs exist."""
	if not name or not frappe.db.exists("Site", name):
		return None
	site = frappe.get_doc("Site", name)
	if not site.has_permission("read"):
		return None
	return site
