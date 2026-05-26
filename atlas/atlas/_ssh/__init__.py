"""Internal SSH package. Public surface is re-exported from `atlas.atlas.ssh`."""

from atlas.atlas._ssh.runner import (
	connection_for_server,
	execute_task,
	run_task,
)
from atlas.atlas._ssh.transport import (
	KNOWN_HOSTS_PATH,
	REMOTE_STAGING_DIRECTORY,
	SSH_OPTIONS,
	Connection,
	upload_files,
	wait_for_ssh,
)

__all__ = [
	"KNOWN_HOSTS_PATH",
	"REMOTE_STAGING_DIRECTORY",
	"SSH_OPTIONS",
	"Connection",
	"connection_for_server",
	"execute_task",
	"run_task",
	"upload_files",
	"wait_for_ssh",
]
