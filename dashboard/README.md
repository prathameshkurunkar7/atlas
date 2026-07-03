# Atlas host dashboard

A read-only visual `ls`/`cat` for one Firecracker host. It makes the host's
state legible so the operator knows what to do next on the Controller or over
SSH — it takes **no actions**. Refresh the page to see updates; there is no
realtime.

Two parts:

- **Frontend** — a Vite + Vue 3 SPA styled with [frappe-ui]'s design tokens
  (the neutral `--ink-gray` / `--surface` scale + Inter). Monochrome, flat, no
  modals. Built to static files in `dist/`.
- **Backend** — one stdlib-only Python file (`backend/server.py`). It reads the
  host's state from `/var/lib/atlas` and a handful of read-only host commands
  (`ip`, `nft`, `systemctl`, `lvs`), serves it at `/api/state`, and serves the
  static `dist/` next to it. No Frappe, no dependencies, no write routes.

## What it shows

Host facts (Firecracker / jailer / kernel / Linux / Python / arch, Atlas-managed
package versions, thin-pool usage) and one section each for: virtual machines,
images, snapshots, reserved IPs, addresses, interfaces, routes, proxy-NDP
entries, IP rules, nftables ruleset, and the Atlas systemd units (per-VM
Firecracker units, the pool oneshot, migration-forwarders, the firewall).

Every section is **best-effort**: a missing binary or path yields an empty
section, never an error — so the same backend runs on a real host and on a dev
box (where only the on-disk sections populate).

## Develop

```
npm install
npm run dev        # http://localhost:5173, /api/state mocked from mock/state.json
```

The dev server serves the checked-in fixture `mock/state.json` at `/api/state`
(see the mock plugin in `vite.config.js`), so the UI runs with no host.

Edit `mock/state.json` — it is the canonical example of the state shape the
backend produces — and refresh.

## Build & ship

```
npm run build      # -> dist/
```

Copy `dist/` and `backend/server.py` onto the host, then:

```
python3 backend/server.py            # 0.0.0.0:8080, static from ./dist, root /var/lib/atlas
```

Point it elsewhere for local testing against a fixture directory:

```
ATLAS_ROOT=./backend/fixture ATLAS_DIST=./dist ATLAS_PORT=8092 python3 backend/server.py
```

Environment: `ATLAS_ROOT` (default `/var/lib/atlas`), `ATLAS_DIST` (default
`./dist` next to the server), `ATLAS_BIND` (default `0.0.0.0`), `ATLAS_PORT`
(default `8080`).

[frappe-ui]: https://ui.frappe.io
