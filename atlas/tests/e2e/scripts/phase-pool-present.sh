#!/bin/bash
# Pool e2e: read back the LVM thin pool bootstrap-server.sh creates. Asserts the
# kernel target is loaded, the volume group + thin pool LV exist, and the
# reboot-survival oneshot is enabled. Fail-loud: any missing piece exits
# non-zero and fails the Task. Each check prints the OBSERVED value first.
set -euo pipefail

fail() { echo "POOL FAIL: $1" >&2; exit 1; }
note() { echo "  [probe] $1"; }

# --- dm_thin_pool kernel target loaded (and not blocklisted) ---
# `lvs` would also fail without it, but assert directly so the failure is
# legible: a missing target is a module problem, not an LVM-state problem.
thin_loaded="$(lsmod | awk '$1 == "dm_thin_pool" {print "yes"}' || true)"
note "dm_thin_pool loaded: ${thin_loaded:-no}"
[ "$thin_loaded" = "yes" ] || fail "dm_thin_pool not loaded — thin pools cannot run"
test -f /etc/modules-load.d/60-atlas-lvm.conf \
    || fail "dm_thin_pool not persisted for reboot (60-atlas-lvm.conf missing)"
echo "dm_thin_pool OK (loaded + persisted)"

# --- volume group present ---
vg="$(sudo vgs --noheadings -o vg_name atlas 2>/dev/null | tr -d ' ' || true)"
note "volume group: ${vg:-<none>}"
[ "$vg" = "atlas" ] || fail "volume group 'atlas' missing (got: ${vg:-<none>})"
echo "volume group OK (atlas)"

# --- thin pool LV present and is actually a thin pool ---
# lv_attr first char 't' == thin pool. Print attrs so a wrong type is visible.
pool_attr="$(sudo lvs --noheadings -o lv_attr atlas/pool0 2>/dev/null | tr -d ' ' || true)"
note "pool0 lv_attr: ${pool_attr:-<absent>}"
[ -n "$pool_attr" ] || fail "thin pool atlas/pool0 missing"
case "$pool_attr" in
    t*) ;;
    *) fail "atlas/pool0 is not a thin pool (lv_attr: $pool_attr)" ;;
esac
echo "thin pool OK (atlas/pool0)"

# --- reboot-survival oneshot enabled ---
pool_svc="$(systemctl is-enabled atlas-pool.service 2>/dev/null || true)"
note "atlas-pool.service: ${pool_svc:-<unknown>}"
[ "$pool_svc" = "enabled" ] || fail "atlas-pool.service not enabled (got: ${pool_svc:-<unknown>})"
echo "atlas-pool.service OK (enabled)"

echo "POOL PROBE OK"
