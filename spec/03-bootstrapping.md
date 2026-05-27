# Bootstrapping a server

A server starts as a vanilla Ubuntu 24.04 droplet. Bootstrap is the task that
turns it into a Firecracker host.

## The script

There is one script:
[`atlas/scripts/bootstrap-server.sh`](../scripts/bootstrap-server.sh). It does
everything in a single SSH session. It is the canonical artifact — the spec
is a reading guide, not the source of truth. If the script and this document
disagree, the script wins. Update both.

### Inputs (environment variables)

| Variable               | Notes                                                  |
| ---------------------- | ------------------------------------------------------ |
| `FIRECRACKER_VERSION`  | Pinned in the `Server Provider` defaults, currently `v1.15.1`. |
| `ARCHITECTURE`         | `x86_64` for this iteration.                           |

### What the script does

Read the file. It is ~70 lines.

In summary, in this order:

1. Verifies architecture matches and `/dev/kvm` is readable+writable.
2. Installs `ca-certificates`, `curl`, `e2fsprogs`, `iproute2`, `jq`,
   `nftables`, `squashfs-tools`.
3. Installs Firecracker at `/usr/local/bin/firecracker` if not at the pinned
   version.
4. Writes `/etc/sysctl.d/60-atlas.conf` with IPv6 forwarding and proxy NDP.
5. Creates the `inet atlas` nftables table and `forward` chain.
6. Creates the `/var/lib/atlas/` directory tree.
7. Writes `FIRECRACKER_VERSION`, `KERNEL_VERSION`, `ARCHITECTURE` to
   `/var/lib/atlas/bootstrap.json` (the single source of truth) and
   `cat`s it on stdout.

The Python side `json.loads` the trailing JSON object and writes the
fields onto the `Server` document. `jq` is invoked with `-nc` (compact,
single-line) so the trailing line is a single object; the parser scans
backwards for the last non-empty line.

### Files that must already be on the server

The bootstrap script does not itself fetch helper scripts or the systemd unit
template — uploading them is the caller's job, so that we keep the contents
of `atlas/scripts/` as the single source of truth. Before running
`bootstrap-server.sh`, the caller uploads:

- `scripts/vm-network-up.sh` → `/var/lib/atlas/bin/vm-network-up.sh`
- `scripts/vm-network-down.sh` → `/var/lib/atlas/bin/vm-network-down.sh`
- `scripts/systemd/firecracker-vm@.service` → `/etc/systemd/system/firecracker-vm@.service`

The `Server.bootstrap()` Python method orchestrates this:

```
1. open ssh connection
2. mkdir -p /tmp/atlas-bootstrap, /var/lib/atlas/bin
3. scp the helper scripts and unit file into place, chmod 0755
4. scp bootstrap-server.sh into /tmp/atlas-bootstrap/
5. ssh "FIRECRACKER_VERSION=v1.15.1 ARCHITECTURE=x86_64 bash -x /tmp/atlas-bootstrap/bootstrap-server.sh"
6. parse trailing JSON object from stdout into Server fields
7. systemctl daemon-reload happens at the end of step 5
```

This is one Task: `bootstrap-server.sh`. The pre-copy step is not a Task,
it's plumbing, and its commands are not interesting individually. They do
appear on stderr of the task because we run the SSH wrapper with `-x`.

### Idempotency

Every action is idempotent:

- `apt-get install -y` is idempotent.
- The Firecracker install is gated on `firecracker --version`.
- File writes use `install -m mode -T` (atomic, overwrite).
- nftables creates are guarded with `nft list ... || nft add ...`.
- `mkdir -p` and `systemctl daemon-reload` are naturally idempotent.

Re-running `Bootstrap` is the recovery path. There is no separate "repair"
mode and there will not be one.

### Pinned versions

`FIRECRACKER_VERSION = v1.15.1`. To bump, edit the default on the
`Server Provider`, re-run `Bootstrap` on every server. The script is
idempotent so re-running is the only thing the operator does.

`ARCHITECTURE = x86_64`. `aarch64` is on the roadmap.

### Failure modes

| Failure                          | Resulting Server status | Operator action               |
| -------------------------------- | ----------------------- | ----------------------------- |
| SSH never comes up               | `Pending`               | Investigate the droplet on DO.|
| `/dev/kvm` missing               | `Broken`                | Wrong droplet size — recreate.|
| `apt-get` fails                  | `Broken`                | Re-run Bootstrap.             |
| Firecracker download fails       | `Broken`                | Re-run Bootstrap.             |
| Architecture mismatch            | `Broken`                | Wrong droplet image — recreate.|

There is no automatic retry. The escape hatch is the same code path: click
`Bootstrap` again. The Task list shows every attempt.

## Why a shell script (and not pyinfra)

Read [04-tasks.md](./04-tasks.md). Short version: pyinfra's idea — declarative
ops desugared to commands per host — is good. The implementation is too much
machinery for a building block. A shell script is a single file, readable
top-to-bottom, and runs in one process on the server. When pain forces a
better abstraction, we will reach for it then, and we will likely build a
small subset of pyinfra ourselves instead of taking the dependency. See the
[roadmap](./09-roadmap.md).
