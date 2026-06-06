#!/bin/bash
# Reserved-IP e2e (SNAT / egress half): SSH into a VM that has a Reserved IP
# attached, over its public IPv6, and prove its IPv4 EGRESS is stamped with the
# reserved IP — not the host's shared NAT44 address.
#
# This is the outbound mirror of the inbound DNAT probe (which the use case runs
# controller-side against the reserved v4). Per spec/06-networking.md, attaching
# a Reserved IP inserts a per-guest SNAT at the head of the `inet atlas`
# postrouting chain, ahead of the host-wide `100.64.0.0/16 masquerade`, so this
# one guest egresses as its reserved IP.
#
# Method: from inside the guest, curl https://1.1.1.1/cdn-cgi/trace — an IPv4
# literal (no DNS) that echoes the client's observed source address back as
# `ip=<addr>`. We assert that address equals the reserved IP. Same endpoint the
# egress probe already uses; here we read the body instead of just the status.
#
# Inputs:
#   VIRTUAL_MACHINE_IPV6  - destination for the SSH hop (the guest's only inbound).
#   RESERVED_IPV4         - the attached reserved IP the egress must be stamped as.
#   SSH_PRIVATE_KEY       - private half of the key Atlas injected.

set -euo pipefail
# Disable bash -x tracing: SSH_PRIVATE_KEY is in scope and any expansion would
# trace the key into stderr, which we capture into the Task row.
{ set +x; } 2>/dev/null

: "${VIRTUAL_MACHINE_IPV6:?}"
: "${RESERVED_IPV4:?}"
: "${SSH_PRIVATE_KEY:?}"

key_file="$(mktemp /tmp/atlas-snat-probe-XXXXXX.key)"
trap 'rm -f "$key_file"' EXIT
printf '%s\n' "$SSH_PRIVATE_KEY" >"$key_file"
chmod 0600 "$key_file"

# Wait for sshd in the guest (first boot regenerates host keys).
deadline=$((SECONDS + 90))
while ! ssh \
        -i "$key_file" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "root@${VIRTUAL_MACHINE_IPV6}" true 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "guest ssh not ready after 90s at ${VIRTUAL_MACHINE_IPV6}" >&2
        exit 1
    fi
    sleep 3
done

guest() {
    ssh \
        -i "$key_file" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        "root@${VIRTUAL_MACHINE_IPV6}" "$@"
}

guest bash -s "$RESERVED_IPV4" <<'REMOTE'
set -euo pipefail
reserved_ipv4="$1"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Ask an external v4 echo what source address it saw. 1.1.1.1 is a literal, so
# this forces the v4 egress path and needs no DNS. The trace body has one
# `ip=<addr>` line.
trace="$(curl -4 --max-time 20 -sS 'https://1.1.1.1/cdn-cgi/trace')" \
    || fail "curl -4 to 1.1.1.1/cdn-cgi/trace failed (v4 egress not working at all)"

observed="$(printf '%s\n' "$trace" | awk -F= '$1=="ip"{print $2}' | tr -d '\r')"
[ -n "$observed" ] || fail "no ip= line in trace: $trace"

[ "$observed" = "$reserved_ipv4" ] \
    || fail "egress source is ${observed}, want the reserved IP ${reserved_ipv4} (per-guest SNAT not overriding the shared masquerade)"

echo "OK reserved-ip-snat ${observed}"
REMOTE
