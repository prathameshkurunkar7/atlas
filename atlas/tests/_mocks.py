"""Shared mock helpers for unit tests.

Production code never touches these — they exist purely so per-file tests
don't each carry a `MagicMock(); .name = ...` reimplementation.
"""

from unittest.mock import MagicMock


def fake_task(name: str = "task", status: str = "Success", **attrs: object) -> MagicMock:
	"""Return a `MagicMock` shaped like a Task row.

	`name` is assigned via attribute set (the MagicMock constructor's `name=`
	kwarg names the mock itself, not its `.name` attribute). Extra attributes
	are forwarded — e.g. `fake_task(stdout="hello", stderr="")` to pin output.
	"""
	mock = MagicMock()
	mock.name = name
	mock.status = status
	for key, value in attrs.items():
		setattr(mock, key, value)
	return mock
