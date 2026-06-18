#!/usr/bin/env bash
# Bake the golden bench image — run INSIDE a freshly-provisioned Ubuntu guest
# (spec/08-images.md § golden bench image). Installs bench-cli, runs `bench init`
# (the heavy, per-site-invariant work: apt MariaDB + Redis, the ZFS pool, the uv
# venv, the Frappe clone, Node + npm deps, the admin frontend, and — because
# nginx=true — the supervisor + nginx production bring-up), installs ERPNext, bakes a
# `site.local` site, runs `bench setup production`, and leaves the whole stack
# RUNNING and SERVING. The built VM is then snapshotted by Atlas; that snapshot is
# the reusable "golden bench image" `deploy-site.py` lands on — a snapshot-booted
# clone comes up serving the baked site, so deploy-site.py does only the per-VM
# rename (site.local → FQDN) + `bench setup nginx`; no admin reset (the baked
# password is the shared throwaway).
#
# This mirrors proxy/build.sh: the AUTHORITATIVE build, uploaded verbatim and run
# over guest-SSH by atlas.atlas.bench_image.build_bench. Idempotent (spec taste
# #16: retry = re-run) — bench-cli's `init` is itself idempotent, re-cloning
# bench-cli is a `git pull`, and every step below skips when its output exists.
#
# Bakes a SITE under the fixed standard name `site.local`, with ERPNext installed.
# The slow per-signup steps — `bench new-site` (DB schema + frappe install) and
# `install-app erpnext` (the heaviest) — are paid ONCE here. deploy-site.py
# RENAMES the baked site to the per-VM FQDN at deploy time (a directory move),
# moving that cost off the signup path entirely. The routing identity (Contract
# A) is per-VM — the rename target, applied per clone, not baked.
#
# Why this image SERVES on boot (not "leaves the bench stopped"): MariaDB + Redis
# are enabled system services, and a systemd boot unit (atlas-bench.service,
# written below) brings the bench-owned supervisord up after the ZFS mount +
# MariaDB. bench-cli's own supervisord is NOT a systemd service (it is started by
# hand by `bench start`), so without this unit a snapshot-booted clone would boot
# with nothing serving. ZFS is enabled (bench.toml [volume] enabled = true): the
# bench code and the MariaDB datadir both live on ZFS datasets, so the pool must
# auto-import + mount before MariaDB and the bench start (§7).
#
# Run as root. Reads the committed tree from the directory this script lives in.

set -euo pipefail

# --- Pinned versions. Bumping any of these is a deliberate image update rolled
# as a new golden snapshot (the same discipline proxy/build.sh's pins follow).
# bench-cli is pinned to a commit, not `main`, so the bake is reproducible; the
# Frappe branch (and the ZFS volume / production schema bench.toml uses) is pinned
# in bench.toml. ---
BENCH_CLI_REPO="https://github.com/frappe/bench-cli"
BENCH_CLI_REF="6e7cc568b4be1f535fafcc859201d060991b85c1"  # main @ 2026-06-17

BENCH_CLI_DIR="/root/bench-cli"
BENCH_NAME="atlas"
# The baked site. A clone of this image already carries a fully-created Frappe +
# ERPNext site under this name; deploy-site.py renames it to the per-VM FQDN at
# deploy time (a directory move, not a `bench new-site`) — see that script and
# the README "Serving model". Kept in lockstep with bench/deploy-site.py's
# BAKED_SITE and warm.sh's BAKED_SITE.
BAKED_SITE="site.local"
# The baked Administrator password — a SHARED throwaway, the SAME on every clone.
# deploy-site.py no longer resets it per VM (that cost a ~28s CPU-throttled `bench
# frappe` boot that dominated the deploy); the owner is handed this and rotates it
# after first login. warm.sh logs in with it to pre-warm the desk before the warm
# snapshot freezes. Kept in lockstep with warm.sh ("$BENCH_NAME-baked") AND with
# the controller's Site.BAKED_ADMIN_PASSWORD (which hands it to the owner).
BAKED_ADMIN_PASSWORD="$BENCH_NAME-baked"
BENCH_DIR="$BENCH_CLI_DIR/benches/$BENCH_NAME"
BENCH="$BENCH_CLI_DIR/bench"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export DEBIAN_FRONTEND=noninteractive
# We run as root, so every `sudo` bench-cli shells out to is a passthrough and
# `bench init` never needs a sudo password — there is no passwordless-sudo step
# to skip (bench-cli's install.sh sets that up for non-root users; init itself
# does not prompt). So no IS_SUDOERS_SETUP / sudoers dance is needed here.

# --- 1. Pre-init packages. `bench init` installs the bulk itself — MariaDB
# (11.8 from the official repo) + Redis, build-essential + pkg-config +
# libmariadb-dev + git, Node via nodesource, and (because [production].nginx =
# true) supervisor + nginx. So build.sh installs ONLY what must be present BEFORE
# init runs: cloning bench-cli and fetching uv on a minimal rootfs need
# git/curl/ca-certificates; the ZFS userspace tools must be present before init's
# volume step ([volume] enabled = true, see bench.toml); and build-essential is
# the C toolchain the §1 DKMS zfs.ko build below needs — that build runs BEFORE
# init's own build-essential install, so it stays here (init installing it again
# is a no-op). pkg-config/libmariadb-dev are NOT pre-installed — they are only
# needed by init's app-venv build, which pulls them in itself. ---
apt-get update
apt-get install -y --no-install-recommends \
	ca-certificates curl git build-essential zfsutils-linux

# The Atlas guest boots the Firecracker `vmlinux`, which ships NO /lib/modules
# tree and NO builtin ZFS — so `zfsutils-linux` (userspace only) leaves
# `modprobe zfs` FATAL ("Module zfs not found"), which would abort init's
# ZFS volume step ([volume] enabled = true). PROVEN on a real host: the matching
# kernel-headers package IS in noble-updates and the running vmlinux loads
# externally-built modules, so build zfs.ko with DKMS against the running kernel,
# then load it. Install the EXACT linux-headers-$(uname -r) (not the
# linux-headers-generic meta, which drags a newer ABI and DKMS-builds a second
# unused copy). `zfs-dkms` runs depmod + builds into
# /lib/modules/$(uname -r)/updates/dkms/ on install — that .ko travels in the
# snapshot, so the §7 cold-boot path (modules-load.d + zfs-import-cache) works too.
# Idempotent: an already-built module is a no-op; `modprobe zfs` is the gate
# `bench init`'s volume step needs. ---
apt-get install -y --no-install-recommends \
	"linux-headers-$(uname -r)" zfs-dkms
modprobe zfs

# --- 2. Install bench-cli at the pinned commit (the install.sh recipe, but
# pinned — never `curl | bash` of a moving main at boot). Clone-or-update so a
# re-run is a fast-forward, then check out the exact ref. uv is installed to a
# SYSTEM path (/usr/local/bin), not just /root/.local/bin: bench-cli's
# admin_env_manager resolves uv with shutil.which(), which misses ~/.local/bin on
# the non-interactive PATH an SSH command gets. ---
if [ -d "$BENCH_CLI_DIR/.git" ]; then
	git -C "$BENCH_CLI_DIR" fetch --quiet origin
else
	git clone --quiet "$BENCH_CLI_REPO" "$BENCH_CLI_DIR"
fi
git -C "$BENCH_CLI_DIR" checkout --quiet "$BENCH_CLI_REF"
chmod +x "$BENCH"

if ! command -v uv >/dev/null 2>&1; then
	curl -LsSf https://astral.sh/uv/install.sh | sh
fi
for b in uv uvx; do
	[ -x /root/.local/bin/$b ] && install -m 0755 /root/.local/bin/$b /usr/local/bin/$b
done
export PATH="$BENCH_CLI_DIR:/usr/local/bin:/root/.local/bin:$PATH"

# Persist PATH for every future login shell (deploy-site.py / warm.sh reach bench
# over a fresh SSH session, which sources /etc/profile.d). Idempotent: overwrite.
install -m 0644 /dev/stdin /etc/profile.d/atlas-bench.sh <<EOF
export PATH="$BENCH_CLI_DIR:/usr/local/bin:/root/.local/bin:\$PATH"
EOF

# --- 3. Create the bench from the committed bench.toml (pins Frappe + the
# localhost-only MariaDB root password + the supervisor/nginx production config +
# the ZFS volume — see bench.toml). `bench new` scaffolds benches/<name>/; we drop
# our pinned bench.toml over the generated one so the image's config is the
# committed one, not bench-cli's template defaults. `bench new` is
# non-interactive (it takes the name positionally and prompts for nothing), and
# we overwrite its generated bench.toml on the next line regardless. ---
if [ ! -f "$BENCH_DIR/bench.toml" ]; then
	"$BENCH" new "$BENCH_NAME"
fi
install -m 0644 "$SRC_DIR/bench.toml" "$BENCH_DIR/bench.toml"

# `bench init` is the heavy, idempotent step. It installs + starts MariaDB and,
# on this fresh guest, SECURES it itself (sets root_password via `ALTER USER root
# IDENTIFIED BY 'atlas'` and drops the anonymous users/test db) — so build.sh no
# longer touches MariaDB auth. Because bench.toml sets `[production].nginx = true`,
# init also installs supervisor + nginx and sets up the production process group +
# nginx config (with no site vhost yet — `setup production` regenerates that in §6
# once the site exists). Because [volume] enabled = true it ALSO creates the ZFS
# pool on the file vdev and migrates the bench dir + /var/lib/mysql onto datasets
# (the §1 zfs.ko is the prerequisite). It greps its own success line.
#
# bench-cli creates the site (§5) over the unix socket as OS-root (`--db-socket`,
# the password is ignored under socket auth), and MariaDB binds localhost only on
# this single-tenant VM — so there is no TCP root login to provision and the old
# `mysql_native_password` ALTER is gone. MariaDB is left RUNNING by init (the
# "stop on fresh install" path is dedicated-instance only; this is the shared
# instance), so §5's install-app reaches the DB directly.
"$BENCH" -b "$BENCH_NAME" init 2>&1 | tee /root/bench-init.log
grep -q "Bench initialised" /root/bench-init.log

# --- 4. Install ERPNext (version-16) into the bench. `get-app` clones + uv-pip
# installs it into the venv and builds assets; it does NOT need Redis or a
# running bench. Idempotent: skip if already cloned. ---
if [ ! -d "$BENCH_DIR/apps/erpnext" ]; then
	"$BENCH" -b "$BENCH_NAME" get-app https://github.com/frappe/erpnext --branch version-16
fi

# --- 5. Bake the site. `bench new-site` creates the MariaDB schema, installs
# frappe, and builds any still-missing app assets (frappe's, here — erpnext's were
# built by §4's get-app); `install-app erpnext` (the heaviest per-signup step)
# installs the ERPNext schema. new-site's `--apps` only VALIDATES the app is
# present — it does NOT install it — so install-app is a separate, required step.
# install-app enqueues background jobs, so Redis must be running: start the
# bench-owned supervisord (which runs redis) first. Idempotent: skip if the site
# exists. ---
"$BENCH" -b "$BENCH_NAME" start >/root/bench-start.log 2>&1 &
# Wait for the QUEUE redis (port 11000 = bench.toml [redis] queue_port; the
# redis_queue common_site_config URL install-app enqueues its background jobs
# onto) to accept connections before new-site/install-app run.
for _ in $(seq 1 30); do
	redis-cli -p 11000 ping >/dev/null 2>&1 && break
	sleep 1
done

if [ ! -d "$BENCH_DIR/sites/$BAKED_SITE" ]; then
	"$BENCH" -b "$BENCH_NAME" new-site "$BAKED_SITE" \
		--admin-password "$BAKED_ADMIN_PASSWORD" --apps erpnext
	"$BENCH" -b "$BENCH_NAME" frappe --site "$BAKED_SITE" install-app erpnext
	"$BENCH" -b "$BENCH_NAME" frappe --site "$BAKED_SITE" migrate
fi

# Take the baked site PAST the setup-wizard gate so a renamed clone serves the
# app at `/`, not a redirect to /setup-wizard (memory: fresh-site-setup-gate).
# The real gate is `Installed Application.is_setup_complete` for the frappe row
# (NOT just System Settings); set both. `bench frappe … execute` auto-commits.
# Baked here so deploy-site.py's rename path stays a pure directory move.
"$BENCH" -b "$BENCH_NAME" frappe --site "$BAKED_SITE" execute \
	frappe.db.set_value \
	--args '["Installed Application", {"app_name": "frappe"}, "is_setup_complete", 1]'
"$BENCH" -b "$BENCH_NAME" frappe --site "$BAKED_SITE" execute \
	frappe.db.set_single_value --args '["System Settings", "setup_complete", 1]'

# --- 6. Production bring-up. Assets are already built: bench-cli's `get-app`
# (§4) builds erpnext's assets as its last step, and `new-site` (§5) builds any
# remaining app whose assets are missing (frappe) — so the standalone `bench
# build` this step used to run was a redundant re-loop of the same per-app builds
# plus a `reload_web` that §8's full supervisor restart supersedes; it is dropped.
# `bench setup production` flips dns_multitenant on, regenerates the nginx config
# WITH the site vhost, and reloads the supervisor group. Idempotent + whole-bench
# (not per-site), so deploy-site.py / warm.sh re-run it safely per clone. No
# letsencrypt.email is set, so it never attempts certbot — TLS terminates at the
# edge proxy (spec/14-self-serve.md). ---
"$BENCH" -b "$BENCH_NAME" setup production

# `bench setup production` emits the site vhost with a bare `listen 80;` (IPv4
# only) and `server_name site.local`. Two edits, both load-bearing on the
# no-rename serving model (spec/14-self-serve.md):
#   * `listen [::]:80` — the EDGE proxy reaches each site over the VM's public
#     /128; IPv6 is the only inbound path (vm-inbound-ipv6-only). Without a v6
#     listener the vhost never matches a v6 request (dead on the path that matters).
#   * `default_server` — the site stays on disk as `site.local`, but the proxy
#     forwards `Host: <fqdn>`, which does NOT match `server_name site.local`.
#     Marking the (single) block `default_server` makes nginx serve it for ANY
#     unmatched Host, so `<fqdn>` is handled and proxied to gunicorn (which serves
#     `default_site = site.local` regardless of Host). Baking it means the golden's
#     frozen/booted nginx already serves any Host on v4+v6 — so a WARM clone needs
#     NO per-clone nginx step at all. Same edit deploy-site.py (_add_ipv6_listen)
#     applies on the cold path. Idempotent — the presence check skips a re-add.
add_ipv6_listeners() {
	shopt -s nullglob
	for conf in "$BENCH_DIR"/config/nginx/sites/*.conf "$BENCH_DIR"/config/nginx.conf; do
		[ -f "$conf" ] || continue
		grep -q 'listen \[::\]:80' "$conf" && continue
		sed -i 's/^\([[:space:]]*\)listen 80;/\1listen 80 default_server;\n\1listen [::]:80 default_server;/' "$conf"
	done
	shopt -u nullglob
}
add_ipv6_listeners

# --- 7. Cold-boot bring-up. Everything the bench needs (the bench code AND the
# MariaDB data) lives on ZFS datasets — `bench init` mounts bench-pool/benches at
# /root/bench-cli/benches and bench-pool/mariadb at /var/lib/mysql. So on a cold
# boot of the snapshot, the pool must auto-import + mount BEFORE MariaDB and the
# bench start, or both come up against empty dirs and die.

# 7a. ZFS auto-import at boot from the cachefile (a file-backed pool isn't
# auto-discovered by a device scan). Ensure zfs.ko loads early on every boot (the
# DKMS .ko built in §1 travels in the snapshot under /lib/modules/$(uname -r)).
echo zfs > /etc/modules-load.d/zfs.conf
zpool set cachefile=/etc/zfs/zpool.cache bench-pool
systemctl enable zfs-import-cache.service zfs-mount.service zfs.target zfs-import.target 2>/dev/null || true
systemctl disable --now zfs-import-scan.service 2>/dev/null || true

# 7b. MariaDB + nginx must wait for the ZFS mount (their data/config live on it).
# Order on the concrete zfs-mount.service, not zfs.target (which can hang
# "activating" if zed is half-disabled, silently starving anything After=it).
install -d /etc/systemd/system/mariadb.service.d /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/mariadb.service.d/10-zfs.conf <<'EOF'
[Unit]
After=zfs-mount.service
Wants=zfs-mount.service
EOF
cat > /etc/systemd/system/nginx.service.d/10-zfs.conf <<'EOF'
[Unit]
After=zfs-mount.service
Wants=zfs-mount.service
[Service]
Restart=on-failure
RestartSec=1
EOF

# 7c. The bench-owned supervisord as a systemd boot unit. bench-cli's supervisor
# manager expects `bench start` to launch supervisord by hand; for an unattended
# boot we run it as a `system` unit, after the ZFS mount + MariaDB, and wait in
# ExecStartPre until both the benches mount and MariaDB's socket are actually up
# (the mount/DB can lose the ordering race on a busy boot). Everything runs as
# root in this image, so no User= / linger dance. supervisord -n stays in the
# foreground so systemd supervises it directly.
SUPERVISORD_DIR="$BENCH_DIR/config/supervisor"
SUPERVISORD_CONF="$SUPERVISORD_DIR/supervisord.conf"
install -m 0644 /dev/stdin /etc/systemd/system/atlas-bench.service <<EOF
[Unit]
Description=Atlas bench (bench-cli supervisord)
After=zfs-mount.service mariadb.service network-online.target
Wants=zfs-mount.service mariadb.service
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$BENCH_DIR
ExecStartPre=/bin/sh -c 'until mountpoint -q $BENCH_CLI_DIR/benches && mysqladmin --protocol=socket ping >/dev/null 2>&1; do sleep 0.1; done'
ExecStart=/usr/bin/supervisord -n -c $SUPERVISORD_CONF
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mariadb.service 2>/dev/null || systemctl enable mysql.service 2>/dev/null || true
systemctl enable redis-server.service 2>/dev/null || true
systemctl enable nginx.service 2>/dev/null || true
systemctl enable atlas-bench.service 2>/dev/null || true

# Remove the stock Ubuntu default nginx vhost. It listens `[::]:80 default_server`
# (server_name _), so it OWNS the IPv6 :80 socket and answers 404 to every v6
# request that doesn't match a named vhost — and the edge proxy reaches each site
# over its public /128 (IPv6 is the only inbound path). Left in place it silently
# shadows the real site on the v6 path while v4 looks fine. Idempotent (`-f`).
rm -f /etc/nginx/sites-enabled/default

# --- 8. Make the running stack serve, and assert it. The bench-owned supervisord
# was started by hand in §5 (for install-app); hand it over to the systemd unit so
# the same supervisord that serves at runtime is the one systemd supervises (and
# that boots a cold clone). `bench stop` issues `supervisorctl shutdown`, which
# returns BEFORE supervisord has fully exited and released its pidfile + unix
# socket — so the systemd `supervisord -n` that follows would collide on a stale
# socket/pidfile. Wait for the pidfile to vanish, then sweep any leftover socket,
# before starting the unit. Then reload nginx for the v6 listeners, and prove the
# site answers on BOTH families — the readiness probe and the edge proxy's south
# hop arrive over v6, so a v4-only 200 would ship a golden that fails every real
# probe. ---
"$BENCH" -b "$BENCH_NAME" stop >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
	[ -f "$SUPERVISORD_DIR/supervisord.pid" ] || break
	sleep 0.5
done
rm -f "$SUPERVISORD_DIR/supervisord.pid" "$SUPERVISORD_DIR/supervisord.sock"
systemctl restart atlas-bench.service
systemctl reload nginx 2>/dev/null || systemctl restart nginx

for _ in $(seq 1 60); do
	curl -sf -o /dev/null -H "Host: $BAKED_SITE" http://127.0.0.1/api/method/ping && break
	sleep 1
done
for host_ip in 127.0.0.1 "[::1]"; do
	ping_body="$(curl -sg -m 10 -H "Host: $BAKED_SITE" "http://$host_ip/api/method/ping" || true)"
	if [[ "$ping_body" != *pong* ]]; then
		echo "serve check FAILED: ping via $host_ip returned: $ping_body" >&2
		exit 1
	fi
done

# --- 9. Trim build cruft so golden copies are lean, then assert the bake
# produced a working bench (frappe + erpnext installed). The e2e re-asserts it
# over guest-SSH after the snapshot boots. The stack is LEFT RUNNING + SERVING. ---
apt-get clean
rm -rf /var/lib/apt/lists/* /root/.cache 2>/dev/null || true
"$BENCH" -b "$BENCH_NAME" list-site-apps "$BAKED_SITE"

echo "Golden bench image baked: bench-cli @ ${BENCH_CLI_REF:0:12}, bench '${BENCH_NAME}' with ERPNext + baked site '${BAKED_SITE}', production stack running and serving on v4 + v6."
