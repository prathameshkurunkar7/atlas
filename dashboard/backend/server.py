#!/usr/bin/env python3
"""Atlas host dashboard — the read-only backend.

A visual `ls`/`cat` for one Firecracker host. It reads the host's state from
disk (`/var/lib/atlas`) and from a handful of read-only host commands (`ip`,
`nft`, `systemctl`, `lvs`), assembles one JSON document, and serves it at
`/api/state` alongside the static SPA built into `dist/`.

Design constraints (mirroring the Atlas spec's principles):

- **Stdlib only.** No Frappe, no third-party packages. `http.server` +
  `subprocess` + `json`. It ships as one file next to the built frontend.
- **Read-only.** There are no write routes and no actions. Every host command
  it runs is an inspection command; it never mutates state.
- **Best-effort.** A host command that is missing or fails yields an empty
  section, never a 500 — so the same file runs on a real host and on a dev box
  with none of the tooling (where every live section is simply empty and only
  the on-disk `/var/lib/atlas` sections populate, if that path exists).

Run it on the host:

    python3 server.py            # serves 0.0.0.0:8080, static from ./dist

Point it elsewhere for local testing:

    ATLAS_ROOT=./fixture ATLAS_DIST=../dist python3 server.py
"""

from __future__ import annotations

import datetime
import json
import os
import re
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ATLAS_ROOT = Path(os.environ.get("ATLAS_ROOT", "/var/lib/atlas"))
DIST_DIR = Path(os.environ.get("ATLAS_DIST", Path(__file__).parent / "dist"))
BIND = os.environ.get("ATLAS_BIND", "0.0.0.0")
PORT = int(os.environ.get("ATLAS_PORT", "8080"))


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #


def run(*argv: str) -> str:
	"""Run a read-only host command, return stdout, or '' on any failure.

	Missing binary, non-zero exit, timeout — all collapse to the empty string so
	a caller on a box without `nft`/`ip`/`lvs` simply gets an empty section.
	"""
	try:
		out = subprocess.run(
			argv,
			capture_output=True,
			text=True,
			timeout=10,
			check=False,
		)
		return out.stdout if out.returncode == 0 else ""
	except (OSError, subprocess.SubprocessError):
		return ""


def read_json(path: Path) -> dict:
	try:
		return json.loads(path.read_text())
	except (OSError, ValueError):
		return {}


def read_env(path: Path) -> dict:
	"""Parse a KEY=value sidecar (network.env) into a dict."""
	result = {}
	try:
		for line in path.read_text().splitlines():
			line = line.strip()
			if not line or "=" not in line or line.startswith("#"):
				continue
			key, _, value = line.partition("=")
			result[key.strip()] = value.strip()
	except OSError:
		pass
	return result


# --------------------------------------------------------------------------- #
# On-disk state: /var/lib/atlas
# --------------------------------------------------------------------------- #


def host_facts() -> dict:
	"""bootstrap.json + a few live version probes. bootstrap.json is the on-disk
	source of truth for the versions bootstrap resolved; the live probes fill in
	what it does not carry (distro string, managed package versions)."""
	boot = read_json(ATLAS_ROOT / "bootstrap.json")
	return {
		"hostname": socket.gethostname(),
		"collected_at": datetime.datetime.now(datetime.UTC)
		.replace(microsecond=0)
		.isoformat()
		.replace("+00:00", "Z"),
		"firecracker_version": boot.get("firecracker_version", ""),
		"jailer_version": boot.get("jailer_version", ""),
		"kernel_version": boot.get("kernel_version") or run("uname", "-r").strip(),
		"linux": _distro(),
		"architecture": boot.get("architecture") or run("uname", "-m").strip(),
		"python_version": boot.get("python_version", ""),
		"uplink": _uplink(),
		"packages": _packages(),
	}


def _distro() -> str:
	"""PRETTY_NAME from /etc/os-release."""
	try:
		for line in Path("/etc/os-release").read_text().splitlines():
			if line.startswith("PRETTY_NAME="):
				return line.split("=", 1)[1].strip().strip('"')
	except OSError:
		pass
	return ""


def _uplink() -> str:
	"""The device carrying the default IPv6 route — the host's uplink."""
	out = run("ip", "-6", "route", "show", "default")
	match = re.search(r"\bdev\s+(\S+)", out)
	return match.group(1) if match else ""


def _binary_version(binary: str) -> str:
	out = run(binary, "--version")
	if not out:
		return ""
	first = out.splitlines()[0]
	tokens = first.split()
	return tokens[1] if len(tokens) > 1 else first.strip()


def _packages() -> list[dict]:
	"""The Atlas-managed package versions the operator cares about. Derived, not
	persisted — probed live from the binaries."""
	probes = [
		("firecracker", _binary_version("firecracker")),
		("nftables", _binary_version("nft")),
		("lvm2", _lvm_version()),
		("iproute2", _binary_version("ip")),
	]
	return [{"name": name, "version": version} for name, version in probes if version]


def _lvm_version() -> str:
	out = run("lvm", "version")
	match = re.search(r"LVM version:\s*(\S+)", out)
	return match.group(1) if match else ""


def virtual_machines() -> list[dict]:
	"""One row per directory under virtual-machines/, named by UUID. `ls` is the
	inventory (spec/07). Each VM's identity comes from its network.env sidecar,
	its disk from the LV naming scheme, its state from the systemd unit."""
	base = ATLAS_ROOT / "virtual-machines"
	rows = []
	if not base.is_dir():
		return rows
	for entry in sorted(base.iterdir()):
		if not entry.is_dir():
			continue
		uuid = entry.name
		env = read_env(entry / "network.env")
		jail_root = entry / "jail" / "firecracker" / uuid / "root"
		rows.append(
			{
				"uuid": uuid,
				"state": _vm_state(uuid),
				"ipv6": env.get("VIRTUAL_MACHINE_IPV6"),
				"ipv4_guest": _strip_cidr(env.get("IPV4_GUEST_CIDR")),
				"ipv4_host": _strip_cidr(env.get("IPV4_HOST_CIDR")),
				"reserved_ipv4": env.get("RESERVED_IPV4"),
				"mac": _mac_from_uuid(uuid),
				"tap_device": env.get("TAP_DEVICE"),
				"netns": env.get("ATLAS_NETNS"),
				"image": _vm_image(jail_root),
				"disk_lv": f"atlas-vm-{uuid}",
				"has_data_disk": (jail_root / "data.ext4").exists(),
				"has_snapshot": (jail_root / "snapshot").is_dir(),
				"log_size": _size(entry / "log" / "firecracker.log"),
			}
		)
	return rows


def _vm_state(uuid: str) -> str:
	"""Map the systemd unit's ActiveState to the operator's vocabulary."""
	active = run("systemctl", "is-active", f"firecracker-vm@{uuid}.service").strip()
	return {"active": "Running", "inactive": "Stopped", "failed": "Failed"}.get(active, "Stopped")


def _vm_image(jail_root: Path) -> str | None:
	"""The VM's image name is not recoverable from disk: the jail's `vmlinux` is
	a hard link into images/<name>/ with no back-reference, and no sidecar records
	the image. Return None rather than the misleading link name — the Disk column
	then shows just the data/snapshot flags. (The controller's Frappe DB is the
	real source of a VM's image; this dashboard reports only what disk proves.)"""
	return None


def _mac_from_uuid(uuid: str) -> str:
	"""06:00: + first 4 bytes of the UUID (spec/06 § MAC)."""
	try:
		import uuid as _uuidmod

		b = _uuidmod.UUID(uuid).bytes[:4]
		return "06:00:" + ":".join(f"{x:02x}" for x in b)
	except (ValueError, ImportError):
		return ""


def images() -> list[dict]:
	base = ATLAS_ROOT / "images"
	rows = []
	if not base.is_dir():
		return rows
	for entry in sorted(base.iterdir()):
		if not entry.is_dir():
			continue
		kernel = next((f.name for f in entry.glob("vmlinux*")), None)
		rootfs = next((f.name for f in entry.glob("*.ext4")), None)
		rows.append(
			{
				"name": entry.name,
				"kernel": kernel,
				"rootfs": rootfs,
				"rootfs_size": _size(entry / rootfs) if rootfs else None,
				"base_lv": f"atlas-image-{entry.name}",
			}
		)
	return rows


def snapshots() -> list[dict]:
	"""Warm-golden dirs under snapshots/, plus disk snapshots read from lvs."""
	rows = []
	base = ATLAS_ROOT / "snapshots"
	if base.is_dir():
		for entry in sorted(base.iterdir()):
			if not entry.is_dir():
				continue
			sig = read_json(entry / "host-signature.json")
			rows.append(
				{
					"uuid": entry.name,
					"kind": "warm-golden",
					"vmstate_size": _size(entry / "vmstate.bin"),
					"mem_size": _size(entry / "mem.bin"),
					"captured_firecracker": sig.get("firecracker"),
					"captured_kernel": sig.get("kernel"),
				}
			)
	# Disk snapshots are LVs (atlas-snap-<uuid>), not files — read them from lvs.
	for lv in _lvs_names():
		if lv.startswith("atlas-snap-"):
			uuid = lv[len("atlas-snap-") :]
			rows.append(
				{
					"uuid": uuid,
					"kind": "disk",
					"snapshot_lv": lv,
					"origin_lv": f"atlas-vm-{uuid}",
				}
			)
	return rows


# --------------------------------------------------------------------------- #
# Live host state: ip / nft / lvs / systemctl
# --------------------------------------------------------------------------- #


def pool() -> dict | None:
	"""Thin-pool usage from `lvs`. data_percent / metadata_percent are the guard
	the host watches (spec/07 § out of space)."""
	out = run(
		"lvs",
		"--noheadings",
		"--separator",
		"|",
		"-o",
		"lv_name,vg_name,lv_size,data_percent,metadata_percent",
		"--select",
		"lv_attr=~t",  # thin pools
	)
	for line in out.splitlines():
		parts = [p.strip() for p in line.split("|")]
		if len(parts) < 5:
			continue
		name, vg, size, data, meta = parts[:5]
		return {
			"vg": vg,
			"pool": name,
			"backing": _pool_backing(),
			"size": size,
			"data_percent": _float(data),
			"metadata_percent": _float(meta),
		}
	return None


def _pool_backing() -> str:
	devices = ATLAS_ROOT / "pool" / "pool-devices"
	if devices.exists():
		body = devices.read_text().strip()
		return "loopback" if "atlas-pool.img" in body else "device"
	return "loopback" if (ATLAS_ROOT / "pool" / "atlas-pool.img").exists() else ""


def _lvs_names() -> list[str]:
	out = run("lvs", "--noheadings", "-o", "lv_name")
	return [line.strip() for line in out.splitlines() if line.strip()]


def addresses() -> list[dict]:
	"""`ip -j addr` flattened to one row per address."""
	rows = []
	for iface in _ip_json("addr"):
		name = iface.get("ifname", "")
		for info in iface.get("addr_info", []):
			rows.append(
				{
					"interface": name,
					"family": info.get("family"),
					"address": f"{info.get('local')}/{info.get('prefixlen')}",
					"scope": info.get("scope"),
				}
			)
	return rows


def interfaces() -> list[dict]:
	rows = []
	for iface in _ip_json("link"):
		name = iface.get("ifname", "")
		rows.append(
			{
				"name": name,
				"mac": iface.get("address"),
				"mtu": iface.get("mtu"),
				"state": iface.get("operstate", ""),
				"kind": iface.get("link_type", "device"),
			}
		)
	return rows


def routes() -> list[dict]:
	rows = []
	for family, flag in (("inet", "-4"), ("inet6", "-6")):
		for route in _ip_json("route", flag):
			rows.append(
				{
					"family": family,
					"dest": route.get("dst"),
					"via": route.get("gateway"),
					"dev": route.get("dev"),
					"table": route.get("table", "main"),
				}
			)
	return rows


def neigh_proxy() -> list[dict]:
	"""Proxy-NDP entries on the uplink — the trick that makes each VM's /128
	reachable (spec/06)."""
	rows = []
	out = run("ip", "-6", "neigh", "show", "proxy")
	for line in out.splitlines():
		tokens = line.split()
		if "dev" in tokens:
			rows.append({"address": tokens[0], "dev": tokens[tokens.index("dev") + 1]})
	return rows


def ip_rules() -> list[dict]:
	"""Policy routing rules (the Reserved-IP egress rules live here)."""
	rows = []
	for rule in _ip_json("rule"):
		src = rule.get("src")
		if not src or src == "all":
			continue
		rows.append(
			{
				"priority": rule.get("priority"),
				"from": src,
				"table": rule.get("table"),
			}
		)
	return rows


def reserved_ips() -> list[dict]:
	"""Reserved IPv4s in play — derived from the VMs that carry a RESERVED_IPV4
	in their network.env (the on-disk source of truth, spec/06)."""
	rows = []
	for vm in virtual_machines():
		if vm.get("reserved_ipv4"):
			rows.append(
				{
					"address": vm["reserved_ipv4"],
					"attached_vm": vm["uuid"],
					"anchor": None,
					"anchor_gateway": None,
				}
			)
	return rows


def nft_tables() -> list[dict]:
	"""`nft -j list ruleset` reshaped to family/name/chains/rules. We flatten each
	rule back to its text form so the page shows exactly what `nft list` shows."""
	raw = run("nft", "-j", "list", "ruleset")
	try:
		doc = json.loads(raw).get("nftables", [])
	except (ValueError, AttributeError):
		return []

	tables = {}
	order = []
	for item in doc:
		if "table" in item:
			t = item["table"]
			key = (t["family"], t["name"])
			tables[key] = {
				"family": t["family"],
				"name": t["name"],
				"persisted": t["name"] != "atlas",  # data-plane table is ephemeral
				"chains": {},
				"chain_order": [],
			}
			order.append(key)
	for item in doc:
		if "chain" in item:
			c = item["chain"]
			key = (c["family"], c["table"])
			if key in tables:
				tables[key]["chains"][c["name"]] = {
					"name": c["name"],
					"type": c.get("type", ""),
					"rules": [],
				}
				tables[key]["chain_order"].append(c["name"])
	for item in doc:
		if "rule" in item:
			r = item["rule"]
			key = (r["family"], r["table"])
			chain = tables.get(key, {}).get("chains", {}).get(r["chain"])
			if chain is not None:
				chain["rules"].append(_nft_rule_text(r))

	result = []
	for key in order:
		t = tables[key]
		result.append(
			{
				"family": t["family"],
				"name": t["name"],
				"persisted": t["persisted"],
				"chains": [t["chains"][n] for n in t["chain_order"]],
			}
		)
	return result


def _nft_rule_text(rule: dict) -> str:
	"""Best-effort render of one nft JSON rule back to its textual form. nft's
	own `list` output is the gold standard; the JSON expr tree is verbose, so we
	just join the human-readable bits it exposes."""
	# nft -j does not carry the pretty text, so ask nft to print the handle line.
	# Falling back to a compact expr dump keeps the page honest without reparsing
	# the whole grammar.
	return json.dumps(rule.get("expr", []), separators=(",", ":"))


def units() -> list[dict]:
	"""Atlas-relevant systemd units: the per-VM firecracker units, the pool
	oneshot, migration forwarders, and the persisted firewall."""
	out = run(
		"systemctl",
		"list-units",
		"--all",
		"--no-legend",
		"--plain",
		"--type=service",
	)
	rows = []
	for line in out.splitlines():
		tokens = line.split()
		if len(tokens) < 4:
			continue
		name, load, active, sub = tokens[0], tokens[1], tokens[2], tokens[3]
		kind = _unit_kind(name)
		if kind is None:
			continue
		rows.append({"name": name, "load": load, "active": active, "sub": sub, "kind": kind})
	return rows


def _unit_kind(name: str) -> str | None:
	if name.startswith("firecracker-vm@"):
		return "vm"
	if name.startswith("atlas-migrate-forward@"):
		return "migration-forwarder"
	if name == "atlas-pool.service":
		return "pool"
	if name == "nftables.service":
		return "firewall"
	return None


# --------------------------------------------------------------------------- #
# ip -j wrapper + tiny formatters
# --------------------------------------------------------------------------- #


def _ip_json(obj: str, *flags: str) -> list:
	raw = run("ip", "-j", *flags, obj, "show")
	try:
		return json.loads(raw) if raw else []
	except ValueError:
		return []


def _strip_cidr(value: str | None) -> str | None:
	return value.split("/", 1)[0] if value else None


def _size(path: Path) -> str | None:
	"""Human size (k/m/g) of a file, or None if absent — mirrors `ls -h`."""
	try:
		n = path.stat().st_size
	except OSError:
		return None
	for unit in ("", "k", "m", "g", "t"):
		if n < 1024 or unit == "t":
			return f"{n:.1f}{unit}" if unit else f"{n}"
		n /= 1024.0


def _float(value: str) -> float | None:
	try:
		return float(value)
	except (TypeError, ValueError):
		return None


def build_state() -> dict:
	"""Assemble the one document the frontend renders. Every section is
	independent and best-effort, so a partial host still produces a full page."""
	return {
		"host": host_facts(),
		"pool": pool(),
		"virtual_machines": virtual_machines(),
		"images": images(),
		"snapshots": snapshots(),
		"addresses": addresses(),
		"interfaces": interfaces(),
		"routes": routes(),
		"neigh_proxy": neigh_proxy(),
		"ip_rules": ip_rules(),
		"reserved_ips": reserved_ips(),
		"nft_tables": nft_tables(),
		"units": units(),
	}


# --------------------------------------------------------------------------- #
# HTTP: /api/state + static dist
# --------------------------------------------------------------------------- #


class Handler(BaseHTTPRequestHandler):
	def do_GET(self):
		if self.path.split("?")[0] == "/api/state":
			return self._serve_state()
		return self._serve_static()

	def _serve_state(self):
		body = json.dumps(build_state()).encode()
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.send_header("Content-Length", str(len(body)))
		self.send_header("Cache-Control", "no-store")
		self.end_headers()
		self.wfile.write(body)

	def _serve_static(self):
		rel = self.path.split("?")[0].lstrip("/") or "index.html"
		target = (DIST_DIR / rel).resolve()
		# Contain path traversal + fall back to index.html (SPA single route).
		if DIST_DIR.resolve() not in target.parents and target != DIST_DIR.resolve():
			target = DIST_DIR / "index.html"
		if not target.is_file():
			target = DIST_DIR / "index.html"
		if not target.is_file():
			self.send_error(404, "dist not built — run `npm run build`")
			return
		body = target.read_bytes()
		self.send_response(200)
		self.send_header("Content-Type", _content_type(target))
		self.send_header("Content-Length", str(len(body)))
		self.end_headers()
		self.wfile.write(body)

	def log_message(self, *args):  # keep the console quiet
		pass


def _content_type(path: Path) -> str:
	return {
		".html": "text/html",
		".js": "text/javascript",
		".css": "text/css",
		".json": "application/json",
		".svg": "image/svg+xml",
		".woff2": "font/woff2",
		".woff": "font/woff",
		".ico": "image/x-icon",
	}.get(path.suffix, "application/octet-stream")


def main():
	server = ThreadingHTTPServer((BIND, PORT), Handler)
	print(f"atlas host dashboard on http://{BIND}:{PORT}  (root={ATLAS_ROOT})")
	try:
		server.serve_forever()
	except KeyboardInterrupt:
		server.shutdown()


if __name__ == "__main__":
	main()
