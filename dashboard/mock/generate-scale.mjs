// Generate a large-scale fixture for the dashboard: a busy host with a big
// fleet, so the SPA can be exercised at production-ish volumes (table paging,
// section counts, render cost). Emits mock/state-scale.json in the exact shape
// backend/server.py produces and mock/state.json documents.
//
//   node mock/generate-scale.mjs
//
// Deterministic: a tiny seeded PRNG keeps the fixture stable across runs so it
// diffs cleanly and reviews sanely. Tweak the COUNTS below and re-run.

import { writeFileSync } from "node:fs";
import { resolve } from "node:path";

const COUNTS = {
  vms: 1000,
  snapshots: 500, // ~proportional to VM count (one per two VMs)
  images: 25,
  reserved_ips: 25,
  ndp: 100,
};

// --- deterministic RNG (mulberry32) --------------------------------------
let _seed = 0x9e3779b9;
function rnd() {
  _seed |= 0;
  _seed = (_seed + 0x6d2b79f5) | 0;
  let t = Math.imul(_seed ^ (_seed >>> 15), 1 | _seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
const chance = (p) => rnd() < p;
const hex = (n) =>
  Array.from(
    { length: n },
    () => "0123456789abcdef"[Math.floor(rnd() * 16)]
  ).join("");

// A stable UUIDv4-shaped string.
function uuid() {
  return `${hex(8)}-${hex(4)}-4${hex(3)}-${"89ab"[Math.floor(rnd() * 4)]}${hex(
    3
  )}-${hex(12)}`;
}

// --- images --------------------------------------------------------------
const BASES = [
  "ubuntu-24.04",
  "ubuntu-22.04",
  "debian-12",
  "alpine-3.20",
  "fedora-40",
];
const images = Array.from({ length: COUNTS.images }, (_, i) => {
  const base = BASES[i % BASES.length];
  const name = `${base}-${String(i).padStart(2, "0")}`;
  return {
    name,
    kernel: `vmlinux-${base}`,
    rootfs: `${name}-server.ext4`,
    rootfs_size: `${(1.5 + rnd() * 3).toFixed(2)}g`,
    base_lv: `atlas-image-${name}`,
  };
});

// --- virtual machines ----------------------------------------------------
// Guest/host tap IPs walk the CGNAT 100.64/10 range in /31-ish pairs, matching
// the fixture's host=guest-1 convention. VM v6 walks the host /64.
const STATES = [
  "Running",
  "Running",
  "Running",
  "Running",
  "Stopped",
  "Paused",
  "Failed",
];
const V6_PREFIX = "2400:6180:100:d0";

const vms = [];
for (let i = 0; i < COUNTS.vms; i++) {
  const id = uuid();
  const short = id.slice(0, 8);
  const state = pick(STATES);
  const running = state === "Running";
  const guest = 10 + i * 4;
  const octet3 = Math.floor(guest / 256);
  const octet4 = guest % 256;
  const hostOctet4 = octet4 - 1;
  const b = short.match(/../g); // 4 bytes for the MAC/tap
  vms.push({
    uuid: id,
    state,
    ipv6: `${V6_PREFIX}::${(i + 2).toString(16)}`,
    ipv4_guest: `100.64.${octet3}.${octet4}`,
    ipv4_host: `100.64.${octet3}.${hostOctet4}`,
    reserved_ipv4: null, // filled in by the reserved-IP pass below
    mac: `06:00:${b[0]}:${b[1]}:${b[2]}:${b[3]}`,
    tap_device: `atlas-${short}${short[0]}`,
    netns: `atlas-${short}`,
    image: pick(images).name,
    disk_lv: `atlas-vm-${id}`,
    has_data_disk: chance(0.3),
    has_snapshot: false, // set by the snapshot pass
    log_size: `${(20 + rnd() * 480).toFixed(1)}k`,
  });
}

// --- snapshots (proportional to VMs) -------------------------------------
// A mix of warm-golden (memory) captures and disk snapshots taken off real VMs.
// Disk snapshots flip their source VM's has_snapshot flag so the two agree.
const snapshots = [];
const snapVmStep = Math.max(1, Math.floor(vms.length / COUNTS.snapshots));
for (let i = 0; i < COUNTS.snapshots; i++) {
  if (chance(0.15)) {
    snapshots.push({
      uuid: uuid(),
      kind: "warm-golden",
      vmstate_size: `${(200 + rnd() * 800).toFixed(1)}k`,
      mem_size: `${pick([512, 1024, 2048])}.00m`,
      captured_firecracker: "v1.16.0",
      captured_kernel: "6.8.0-45-generic",
    });
  } else {
    const vm = vms[(i * snapVmStep) % vms.length];
    vm.has_snapshot = true;
    snapshots.push({
      uuid: vm.uuid,
      kind: "disk",
      snapshot_lv: `atlas-snap-${vm.uuid}`,
      origin_lv: `atlas-vm-${vm.uuid}`,
    });
  }
}

// --- reserved IPs --------------------------------------------------------
// Each attaches to a distinct Running VM via the anchor DNAT model. The VM's
// reserved_ipv4 mirror is set so the VM row and the Reserved IP row agree.
const reserved_ips = [];
const runningVms = vms.filter((v) => v.state === "Running");
for (let i = 0; i < COUNTS.reserved_ips && i < runningVms.length; i++) {
  const vm = runningVms[(i * 7) % runningVms.length];
  const addr = `203.0.113.${40 + i}`;
  vm.reserved_ipv4 = addr;
  reserved_ips.push({
    address: addr,
    attached_vm: vm.uuid,
    anchor: "10.47.0.10",
    anchor_gateway: "10.47.0.1",
  });
}

// --- proxy-NDP entries ---------------------------------------------------
// The host answers NDP for these VM /128s on the uplink. Draw from Running VMs.
const neigh_proxy = [];
for (let i = 0; i < COUNTS.ndp && i < runningVms.length; i++) {
  neigh_proxy.push({ address: runningVms[i].ipv6, dev: "eth0" });
}

// --- routes: per-VM /128 (v6) + per-reserved-IP DNAT already in nft -------
// Keep this bounded — one /128 route per Running VM plus the defaults, matching
// the real backend which lists the routing table verbatim.
const routes = [];
for (const vm of runningVms) {
  routes.push({
    family: "inet6",
    dest: `${vm.ipv6}/128`,
    via: "fe80::3",
    dev: `veth-${vm.uuid.slice(0, 8)}`,
    table: "main",
  });
}
routes.push(
  {
    family: "inet6",
    dest: "default",
    via: "fe80::1",
    dev: "eth0",
    table: "main",
  },
  {
    family: "inet",
    dest: "default",
    via: "203.0.113.1",
    dev: "eth0",
    table: "main",
  }
);

// --- ip rules: one per reserved IP anchor --------------------------------
const ip_rules = reserved_ips.map((r, i) => ({
  priority: 100 + i,
  from: vms.find((v) => v.uuid === r.attached_vm).ipv4_guest,
  table: `anchor-${r.attached_vm.slice(0, 8)}`,
}));

// --- interfaces & addresses ----------------------------------------------
// Every VM contributes a tap; keep the host device rows too.
const interfaces = [
  {
    name: "eth0",
    mac: "9e:1a:2b:33:44:d1",
    mtu: 1500,
    state: "UP",
    kind: "device",
  },
];
for (const vm of vms) {
  if (vm.state === "Terminated") continue;
  interfaces.push({
    name: vm.tap_device,
    mac: vm.mac,
    mtu: 1500,
    state: vm.state === "Running" ? "UP" : "DOWN",
    kind: "tap",
    netns: vm.netns,
  });
}

const addresses = [
  {
    interface: "eth0",
    family: "inet",
    address: "203.0.113.10/20",
    scope: "global",
  },
  {
    interface: "eth0",
    family: "inet6",
    address: `${V6_PREFIX}:0:1:4ae1:d001/64`,
    scope: "global",
  },
  {
    interface: "eth0",
    family: "inet6",
    address: "fe80::9c1a:2bff:fe33:44d1/64",
    scope: "link",
  },
  {
    interface: "eth0",
    family: "inet",
    address: "10.47.0.10/16",
    scope: "global",
    note: "anchor",
  },
];

// --- nftables: forward accept pairs + DNAT/SNAT per reserved IP -----------
const forwardRules = ["ip daddr 169.254.169.254 drop"];
for (const vm of runningVms) {
  const veth = `veth-${vm.uuid.slice(0, 8)}`;
  forwardRules.push(`iifname "${veth}" accept`, `oifname "${veth}" accept`);
}
for (const r of reserved_ips) {
  forwardRules.push(
    `ip daddr ${vms.find((v) => v.uuid === r.attached_vm).ipv4_guest} accept`
  );
}
const preRules = reserved_ips.map(
  (r) =>
    `ip daddr ${r.anchor} dnat to ${
      vms.find((v) => v.uuid === r.attached_vm).ipv4_guest
    }`
);
const postRules = reserved_ips.map(
  (r) =>
    `ip saddr ${vms.find((v) => v.uuid === r.attached_vm).ipv4_guest} snat to ${
      r.anchor
    }`
);
postRules.push('ip saddr 100.64.0.0/16 oifname "eth0" masquerade');

const nft_tables = [
  {
    family: "inet",
    name: "atlas",
    persisted: false,
    chains: [
      { name: "forward", type: "filter", rules: forwardRules },
      { name: "prerouting", type: "nat", rules: preRules },
      { name: "postrouting", type: "nat", rules: postRules },
    ],
  },
  {
    family: "inet",
    name: "atlas-mgmt",
    persisted: true,
    chains: [
      {
        name: "input",
        type: "filter",
        rules: [
          'iifname "lo" accept',
          "ct state established,related accept",
          'iifname "wg0" accept',
          "udp dport 51820 accept",
          "meta l4proto icmpv6 accept",
          "policy drop",
        ],
      },
    ],
  },
];

// --- systemd units: one firecracker-vm@ per VM + the fixed host units ------
const units = vms.map((vm) => {
  const running = vm.state === "Running" || vm.state === "Paused";
  return {
    name: `firecracker-vm@${vm.uuid}.service`,
    load: "loaded",
    active: running ? "active" : "inactive",
    sub: running ? "running" : "dead",
    kind: "vm",
  };
});
units.push(
  {
    name: "atlas-pool.service",
    load: "loaded",
    active: "active",
    sub: "exited",
    kind: "pool",
  },
  {
    name: "nftables.service",
    load: "loaded",
    active: "active",
    sub: "exited",
    kind: "firewall",
  }
);

// --- assemble ------------------------------------------------------------
const running = vms.filter((v) => v.state === "Running").length;
const state = {
  host: {
    hostname: "atlas-scale-01",
    collected_at: "2026-07-03T18:22:07Z",
    firecracker_version: "v1.16.0",
    jailer_version: "v1.16.0",
    kernel_version: "6.8.0-45-generic",
    linux: "Ubuntu 24.04.1 LTS",
    architecture: "x86_64",
    python_version: "3.14.0",
    uplink: "eth0",
    packages: [
      { name: "atlas", version: "1.0.0+g15a6c84" },
      { name: "firecracker", version: "1.16.0" },
      { name: "nftables", version: "1.0.9" },
      { name: "lvm2", version: "2.03.16" },
      { name: "iproute2", version: "6.1.0" },
    ],
  },
  pool: {
    vg: "atlas",
    pool: "pool0",
    backing: "nvme",
    backing_device: "/dev/nvme0n1",
    size: "2.00t",
    data_percent: 68.4,
    metadata_percent: 22.1,
  },
  virtual_machines: vms,
  images,
  snapshots,
  addresses,
  interfaces,
  routes,
  neigh_proxy,
  ip_rules,
  reserved_ips,
  nft_tables,
  units,
};

const out = resolve("mock", "state-scale.json");
writeFileSync(out, JSON.stringify(state, null, 2) + "\n");
console.log(
  `wrote ${out}: ${vms.length} VMs (${running} running), ${snapshots.length} snapshots, ` +
    `${images.length} images, ${reserved_ips.length} reserved IPs, ${neigh_proxy.length} NDP`
);
