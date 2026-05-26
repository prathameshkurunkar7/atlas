"""Catalog of scripts that can be invoked as Tasks on a Server.

`allowed_scripts()` is the operator-visible whitelist for the Run Task dialog.
`resolve()` is the file-system lookup used by the SSH runner; it searches both
the production scripts directory and the e2e test-only directory, because e2e
probe scripts (which never appear in the picker) need to be findable too.
"""

from pathlib import Path

import frappe

_REPO_ROOT = Path(frappe.get_app_path("atlas", "..")).resolve()
SCRIPTS_DIRECTORY = _REPO_ROOT / "scripts"
E2E_SCRIPTS_DIRECTORY = _REPO_ROOT / "atlas" / "tests" / "e2e" / "scripts"
SCRIPT_SEARCH_PATHS = [SCRIPTS_DIRECTORY, E2E_SCRIPTS_DIRECTORY]


def allowed_scripts() -> list[str]:
	"""Return the sorted list of `.sh` filenames runnable on a server host."""
	if not SCRIPTS_DIRECTORY.is_dir():
		return []
	return sorted(
		entry.name
		for entry in SCRIPTS_DIRECTORY.iterdir()
		if entry.is_file() and entry.suffix == ".sh"
	)


def script_path(script: str) -> Path:
	"""Resolve a script name to its absolute path, asserting it is allowed."""
	if script not in allowed_scripts():
		raise ValueError(f"Unknown script: {script}")
	return SCRIPTS_DIRECTORY / script


def resolve(script: str) -> Path:
	"""Locate a script in either the production or e2e directory. Raises
	FileNotFoundError if not present in either."""
	for directory in SCRIPT_SEARCH_PATHS:
		candidate = directory / script
		if candidate.is_file():
			return candidate
	raise FileNotFoundError(
		f"Script not found in any of {[str(p) for p in SCRIPT_SEARCH_PATHS]}: {script}"
	)
