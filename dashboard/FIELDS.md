# Field gaps — real state vs. the current contract

Generated 2026-07-03 by running the dashboard's read-only probes against both
**active** `scaleway.local` hosts and merging the result:

- **f1-aditya-blr3** (`51.159.110.51`) — no running VMs; carries the four
  `atlas-mig6-*` migration forwarders (it's the migration *target*).
- **f2-aditya-blr3** (`51.159.202.202`) — 26 running VMs of 33 dirs; a
  reserved-IP VM; the busy host.

The two archived DO servers (`mig-source`/`mig-target`) were skipped — they are
the test-fixture remnants, not real hosts.

Everything below is what the hosts *prove on disk / in the kernel* that the
current `backend/server.py` + `mock/state.json` don't yet surface. The raw
merged sample is `mock/state-scaleway-real.json`.

## High value — the dashboard is currently misleading without these

1. **`network.env` has `HOST_VETH` / `NAMESPACE_VETH`, and the backend ignores
   them.** The real sidecar keys are:
   `TAP_DEVICE, VIRTUAL_MACHINE_IPV6, ATLAS_NETNS, HOST_VETH, NAMESPACE_VETH,
   IPV4_HOST_CIDR, IPV4_GUEST_CIDR, ATLAS_FC_UID` (+ `RESERVED_IPV4` on the few
   that have one). The backend reads `TAP_DEVICE` but the **nft `forward` rules,
   the per-VM `/128` routes, and the proxy-NDP entries are all keyed on the
   host-side veth `atlas-h<uuid>`, not the tap.** Without `HOST_VETH` the page
   can't join a VM to its own firewall/route/NDP rows — they read as anonymous.
   → Add `host_veth`, `namespace_veth` to each VM row; use them to correlate.

2. **Per-VM capacity (`vcpus`, `mem_mib`) is on disk and not shown.** Each VM's
   `jail/.../root/firecracker.json` carries `machine-config.vcpu_count` and
   `mem_size_mib` (e.g. 1 vCPU / 1024 MiB). The `jailer-launch.sh` adds the real
   enforced ceilings: `--cgroup memory.max=…`, `cpu.max='200000 100000'`,
   `cpu.weight=25`. This is the single most operator-relevant fact the dashboard
   omits — "how big is each VM, and what's it capped at."
   → Read `firecracker.json` for `vcpus`/`mem_mib`; optionally parse the cgroup
   caps from `jailer-launch.sh`.

3. **`ATLAS_FC_UID` — the per-VM jailer uid.** It owns the jail and shows up in
   every `ls -l`/`lvs` ownership line; it's how you map a stray process/file back
   to a VM. Cheap to surface from `network.env`.

4. **VM disk origin + fill are in `lvs` and dropped.** `lvs -o …,origin,data_percent`
   shows each `atlas-vm-<uuid>`'s **origin** (`atlas-image-*`, or a warm
   `atlas-snap-*` for clones — clone lineage!) and its **per-volume data%**. The
   backend only reads thin-*pool* percentages. Origin is the closest disk-provable
   answer to "what image is this VM?" — the very thing `_vm_image()` gives up on.
   → Join `lvs` origin/data% into each VM row and each snapshot row.

## Medium value

5. **`host-signature.json` carries `cpu_model` + `microcode` + `cpu_flags_sha256`.**
   Real: `AMD EPYC 4245P 6-Core Processor`. The host header shows arch but not the
   CPU. `cpu_model` belongs in host facts; the warm-restore guard fields
   (microcode, flags hash) belong on the snapshot row.

6. **Snapshot taxonomy is richer than `warm-golden` / `disk`.** Real `lvs` shows
   a third kind: `atlas-snap-<uuid>-migrate` (in-flight migration snapshots, the
   `-k` "skip activation" ones). And the on-disk `snapshots/` dir was **empty** on
   both hosts while disk snapshots existed — so today's Snapshots section would
   render only the LV-derived rows. Add a `disk-migrate` kind and don't imply the
   warm-golden dir is the main source.

7. **`snapshot/READY` marker + `firecracker.pid`.** `has_snapshot` is true for a
   staged-but-not-resumed warm pair too; the `READY` marker distinguishes "pending
   restore" from "live snapshot dir". `firecracker.pid` in the jail is a cheap
   liveness cross-check against the unit's `ActiveState`.

8. **Interfaces: real uplink is `enp3s0f0np0` with a DOWN peer `enp3s0f1np1`, plus
   `mig6-*` TUN devices** (migration socat tunnels, MTU 1280, on f1). The mock's
   `eth0`/`veth-*`/`tap` naming is idealized; the real page should not assume
   `eth0`. The `mig6-*` TUNs pair with the `atlas-mig6-*` units — worth grouping.

9. **Reserved-IP model on Scaleway has no anchor.** Real nft does
   `snat ip to 51.159.76.127` / `dnat ip to 100.64.0.14` directly — there is **no
   anchor / anchor_gateway** (that's the DigitalOcean model). The `reserved_ips`
   row's `anchor`/`anchor_gateway` are correctly null here; add the `guest_ipv4`
   the DNAT targets so the row is self-explanatory. Backend's `reserved_ips()`
   derives from `RESERVED_IPV4` in `network.env` — confirmed present, good.

## Low value / cosmetic

10. **Pool backing is a real device (`/dev/md2`, a RAID1 md), not loopback**, and
    real pool size is `886.24g`. `_pool_backing()` already handles device vs
    loopback; just confirm the `pool-devices` read path (it contained `/dev/md2`).

11. **`bootstrap.json` `python_version` is the string `"Python 3.14.3"`** (with the
    `Python ` prefix), but the *running* `python3` is `3.12.3`. The header should
    label this "bootstrap python" to avoid implying it's the live interpreter.

12. **Units carry a `description`** ("Atlas Firecracker VM <uuid>", the socat
    command line for forwarders). Worth keeping for the forwarder rows — the socat
    line shows the tunnel's peer host:port at a glance.

13. **No `atlas-mgmt` firewall table exists on the real hosts** — the mock invents
    one. Either drop it from the mock or make clear it's aspirational (spec/06 §
    management firewall), so the page doesn't render a phantom persisted table.

## Not recoverable from disk (leave as `—`, by design)

- **VM image name** stays `null`: `_vm_image()`'s reasoning holds — `vmlinux` is an
  unlabeled hard link. But note **`lvs` origin (#4) is a partial answer** for
  clones whose disk descends from `atlas-image-<name>`; warm clones descend from
  `atlas-snap-*` and lose the trail, matching the "server is a cache" principle.
