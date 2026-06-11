"""`/verify?token=…` — the email-verification gate that fulfils a Site Request.

This is step 4-6 of Contract C (spec/14-self-serve.md): the user clicks the link we emailed,
we look the `Site Request` up by its token, and — only now — fulfil it (create
the `User`, insert the `Site` as that user, mark Fulfilled). Then we log them in
and bounce them to the dashboard SPA, where they watch the Site go
`Pending → … → Running` (02's status) and see the admin handoff (03's password).

Guest-accessible (the link lands here before they have a session). A missing,
already-used, or expired token renders the page with a clean error message
(`verify.html`), never a traceback — this is a public URL. A valid token
redirects to the SPA, so the page body is only ever seen on the failure path.
"""

import frappe
from frappe.auth import LoginManager

no_cache = 1


def get_context(context):
	"""Resolve the token, fulfil, log in, redirect. On any user-facing problem,
	hand the template a message to render (no redirect) rather than raising."""
	token = (frappe.form_dict.get("token") or "").strip()
	request = _request_for_token(token)
	if not request:
		context.error = "This verification link is invalid or has already been used."
		return context

	try:
		site = request.verify()
	except frappe.ValidationError as exception:
		# Expired token, or the subdomain got taken since the request was made
		# (the fulfilment race) — verify() throws a clean message; surface it.
		context.error = str(exception)
		return context

	_login(request.email)
	# Land on the per-site status page (NOT the machines list) so the user watches
	# their site provision step-by-step in real time. verify() returns the Site;
	# its name is the FQDN the page resolves + gates to this now-logged-in owner.
	frappe.local.flags.redirect_location = f"/site-status?site={frappe.utils.quote(site.name)}"
	raise frappe.Redirect


def _request_for_token(token: str):
	"""The `Site Request` whose token matches, or None. A blank token never
	matches (don't return the first row when the query string is missing)."""
	if not token:
		return None
	name = frappe.db.get_value("Site Request", {"token": token}, "name")
	if not name:
		return None
	return frappe.get_doc("Site Request", name)


def _login(email: str) -> None:
	"""Sign the verified user in (set the session cookie), the same way
	`frappe.www.login.login_via_key` does after a one-time login key — so they
	reach the login-gated SPA without a separate sign-in step."""
	frappe.local.login_manager = LoginManager()
	frappe.local.login_manager.login_as(email)
