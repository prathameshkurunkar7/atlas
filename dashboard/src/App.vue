<template>
	<div class="min-h-screen text-ink-gray-8">
		<div class="mx-auto max-w-5xl px-6 py-10 sm:px-8">
			<!-- Header: the host is the subject. The one live host number that isn't a
         table — pool fill — sits inline here, quiet. Version facts are demoted
         to the foot; identity that never changes doesn't earn the top slot. -->
			<header class="mb-8 flex items-baseline justify-between gap-4">
				<div class="flex items-baseline gap-4">
					<h1 class="text-base font-medium text-ink-gray-9">
						{{ state?.host?.hostname || "Atlas host" }}
					</h1>
					<span v-if="state?.pool" class="mono text-sm text-ink-gray-5">
						pool {{ state.pool.data_percent }}% · {{ state.pool.size }}
					</span>
				</div>
				<div class="flex items-baseline gap-4">
					<button
						class="text-sm text-ink-gray-5 hover:text-ink-gray-8"
						:title="`Theme: ${mode} — click to switch`"
						@click="cycleMode"
					>
						{{ themeGlyph }} {{ mode }}
					</button>
					<button class="text-sm text-ink-gray-5 hover:text-ink-gray-8" @click="load">
						Refresh
					</button>
				</div>
			</header>

			<p v-if="error" class="text-sm text-ink-gray-5">
				Could not read host state. {{ error }}
			</p>

			<div v-if="state" class="grid grid-cols-[9.5rem_1fr] gap-0">
				<!-- One nav, both levels. -->
				<div class="border-r border-ink-gray-2 pr-4">
					<Rail
						:domains="domains"
						:domain="selected.domain"
						:table="selected.table"
						@select="select"
					/>
				</div>

				<!-- The panel: exactly one table, its rows the real thing. The page opens
           on Machines — the volatile subject you came for — no click, no scroll. -->
				<div class="min-w-0 pl-6">
					<div class="mb-3 flex items-baseline gap-3">
						<h2 class="text-sm font-medium text-ink-gray-9">
							{{ activeTable?.label }}
						</h2>
						<span v-if="activeTable?.summary" class="text-sm text-ink-gray-4">{{
							activeTable.summary
						}}</span>
					</div>

					<!-- nftables renders as grouped rule text, not a table. -->
					<template v-if="selected.table === 'nftables'">
						<p v-if="!state.nft_tables.length" class="text-sm text-ink-gray-4">
							None.
						</p>
						<div v-for="t in state.nft_tables" :key="t.name" class="mb-6 last:mb-0">
							<div class="mb-2 flex items-baseline gap-3">
								<span class="mono text-sm text-ink-gray-7"
									>{{ t.family }} {{ t.name }}</span
								>
								<span class="text-sm text-ink-gray-4">{{
									t.persisted ? "persisted" : "ephemeral"
								}}</span>
							</div>
							<div v-for="c in t.chains" :key="c.name" class="mb-3 pl-4 last:mb-0">
								<div class="mb-1 text-sm text-ink-gray-5">
									chain {{ c.name }}
									<span class="text-ink-gray-4">({{ c.type }})</span>
								</div>
								<pre
									class="mono whitespace-pre-wrap text-sm leading-relaxed text-ink-gray-7"
									>{{ c.rules.join("\n") }}</pre
								>
							</div>
						</div>
					</template>

					<!-- Every other table is a borderless DataTable. Empty → a quiet 'None.' -->
					<template v-else-if="activeTable">
						<p v-if="!activeTable.rows.length" class="text-sm text-ink-gray-4">
							None.
						</p>
						<DataTable v-else :columns="activeTable.columns" :rows="activeTable.rows">
							<template #state="{ value }">
								<span class="inline-flex items-center gap-2">
									<Dot :on="value === 'Running'" />
									<span class="text-ink-gray-7">{{ value }}</span>
								</span>
							</template>
							<template #active="{ row }">
								<span class="inline-flex items-center gap-2">
									<Dot :on="row.active === 'active'" />
									<span class="text-ink-gray-7"
										>{{ row.active }} · {{ row.sub }}</span
									>
								</span>
							</template>
							<template #iface_state="{ value }">
								<span class="inline-flex items-center gap-2">
									<Dot :on="value === 'UP'" />
									<span class="text-ink-gray-7">{{ value }}</span>
								</span>
							</template>
							<template #uuid="{ value }">
								<span class="mono text-ink-gray-7" :title="value">{{
									short(value)
								}}</span>
							</template>
							<template #attached_vm="{ value }">
								<span class="mono text-ink-gray-7" :title="value">{{
									short(value)
								}}</span>
							</template>
							<template #size="{ row }">
								<span class="mono text-ink-gray-7">{{ vmSize(row) }}</span>
							</template>
							<template #origin="{ row }">
								<span class="mono text-ink-gray-5">{{ diskOrigin(row) }}</span>
							</template>
							<template #datapct="{ row }">
								<span class="text-ink-gray-7">{{ dataPct(row) }}</span>
							</template>
							<template #snapdetail="{ row }">
								<span class="mono text-ink-gray-5">{{
									row.origin_lv || "—"
								}}</span>
							</template>
						</DataTable>
					</template>
				</div>
			</div>

			<!-- Demoted footer: identity + versions. Read once a month, so last. -->
			<footer v-if="state" class="mt-14 border-t border-ink-gray-2 pt-4">
				<dl class="flex flex-wrap gap-x-6 gap-y-1.5">
					<Fact label="Linux" :value="state.host.linux" />
					<Fact label="Kernel" :value="state.host.kernel_version" mono />
					<Fact v-if="state.host.cpu_model" label="CPU" :value="state.host.cpu_model" />
					<Fact label="Arch" :value="state.host.architecture" mono />
					<Fact label="Firecracker" :value="state.host.firecracker_version" mono />
					<Fact label="Jailer" :value="state.host.jailer_version" mono />
					<Fact label="Python" :value="state.host.python_version" mono />
					<Fact label="Uplink" :value="state.host.uplink" mono />
					<Fact label="Read at" :value="collectedAt" />
				</dl>
			</footer>
		</div>
	</div>
</template>

<script setup>
import { ref, computed, onMounted, h } from "vue";
import Rail from "./components/Rail.vue";
import DataTable from "./components/DataTable.vue";
import Dot from "./components/Dot.vue";
import { mode, cycleMode } from "./theme.js";

const themeGlyph = computed(() => ({ light: "○", dark: "●", system: "◐" }[mode.value]));

// Tiny inline definition-list cell for the footer facts.
const Fact = (props) =>
	h("div", { class: "flex items-baseline gap-2 text-xs" }, [
		h("dt", { class: "text-ink-gray-4" }, props.label),
		h(
			"dd",
			{ class: props.mono ? "mono text-ink-gray-6" : "text-ink-gray-6" },
			props.value ?? "—"
		),
	]);
Fact.props = ["label", "value", "mono"];

const state = ref(null);
const error = ref("");
// The page opens here — Machines, the most volatile subject.
const selected = ref({ domain: "machines", table: "machines" });

async function load() {
	error.value = "";
	try {
		// Preserve any ?src= fixture selector the dev mock reads.
		const res = await fetch("/api/state" + window.location.search, { cache: "no-store" });
		if (!res.ok) throw new Error(`HTTP ${res.status}`);
		state.value = await res.json();
	} catch (e) {
		error.value = String(e.message || e);
	}
}
onMounted(load);

function select({ domain, table }) {
	selected.value = { domain, table: table || domainDefaultTable(domain) };
}
function domainDefaultTable(domain) {
	return domains.value.find((d) => d.id === domain)?.tables?.[0]?.id;
}

function short(uuid) {
	return uuid ? String(uuid).slice(0, 8) : "—";
}

// FIELDS.md #2: per-VM size — the single most operator-relevant fact the old
// page omitted. e.g. "1 · 1024m". The cgroup caps are on the row for a tooltip.
function vmSize(vm) {
	if (vm.vcpus == null && vm.mem_mib == null) return "—";
	return `${vm.vcpus ?? "?"} · ${vm.mem_mib ?? "?"}m`;
}

// FIELDS.md #4: per-volume data%. VMs carry disk_data_percent; snapshots
// data_percent. One slot serves both tables.
function dataPct(row) {
	const v = row.disk_data_percent ?? row.data_percent;
	return v == null ? "—" : v + "%";
}

// FIELDS.md #4: disk origin is the disk-provable "what image is this VM" —
// an image base, or a warm/clone snapshot (lineage). Prefer the LV origin.
function diskOrigin(vm) {
	if (vm.disk_origin) {
		const kind = vm.disk_origin.includes("-snap-") ? "snap" : "image";
		return `${kind} ${vm.disk_origin.replace(/^atlas-(image|snap)-/, "")}`;
	}
	return vm.image || "—";
}

const collectedAt = computed(() => {
	const t = state.value?.host?.collected_at;
	return t ? t.replace("T", " ").replace("Z", " UTC") : "—";
});

// ---- Column definitions ----------------------------------------------------
// Machines leads with size + disk (the FIELDS.md high-value facts), then net.
const vmCols = [
	{ key: "state", label: "State" },
	{ key: "uuid", label: "UUID" },
	{ key: "size", label: "vCPU · mem", mono: true },
	{ key: "origin", label: "Disk origin" },
	{ key: "datapct", label: "Disk %", align: "right" },
	{ key: "ipv6", label: "IPv6", mono: true },
	{ key: "reserved_ipv4", label: "Reserved v4", mono: true },
];
const imageCols = [
	{ key: "name", label: "Image" },
	{ key: "kernel", label: "Kernel", mono: true },
	{ key: "rootfs_size", label: "Rootfs", mono: true, align: "right" },
	{ key: "base_lv_size", label: "Base LV", mono: true, align: "right" },
];
const snapCols = [
	{ key: "uuid", label: "UUID" },
	{ key: "kind", label: "Kind" },
	{ key: "snapdetail", label: "Origin LV" },
	{ key: "datapct", label: "Data %", align: "right" },
];
const addrCols = [
	{ key: "interface", label: "Interface", mono: true },
	{ key: "family", label: "Family", mono: true },
	{ key: "address", label: "Address", mono: true },
	{ key: "scope", label: "Scope" },
];
const ifaceCols = [
	{ key: "iface_state", label: "State" },
	{ key: "name", label: "Name", mono: true },
	{ key: "kind", label: "Kind" },
	{ key: "mac", label: "MAC", mono: true },
	{ key: "mtu", label: "MTU", mono: true, align: "right" },
];
const routeCols = [
	{ key: "family", label: "Family", mono: true },
	{ key: "dest", label: "Destination", mono: true },
	{ key: "via", label: "Via", mono: true },
	{ key: "dev", label: "Device", mono: true },
];
const ripCols = [
	{ key: "address", label: "Address", mono: true },
	{ key: "attached_vm", label: "VM" },
	{ key: "guest_ipv4", label: "Guest v4", mono: true },
];
const ndpCols = [
	{ key: "address", label: "Address", mono: true },
	{ key: "dev", label: "Device", mono: true },
];
const ruleCols = [
	{ key: "priority", label: "Priority", mono: true, align: "right" },
	{ key: "from", label: "From", mono: true },
	{ key: "table", label: "Table", mono: true },
];
const pkgCols = [
	{ key: "name", label: "Package" },
	{ key: "version", label: "Version", mono: true },
];
const unitCols = [
	{ key: "active", label: "State" },
	{ key: "name", label: "Unit", mono: true },
	{ key: "kind", label: "Kind" },
];

// ---- Domain model ----------------------------------------------------------
// Ordered by volatility: what changes minute-to-minute first, static last.
// Each table carries its columns, rows and a one-line summary shown by the head.
const domains = computed(() => {
	const s = state.value;
	if (!s) return [];

	const vms = s.virtual_machines || [];
	const running = vms.filter((v) => v.state === "Running").length;
	const units = s.units || [];
	const unitsUp = units.filter((u) => u.active === "active").length;

	// ifaces need a renamed state key so the DataTable slot doesn't collide with VM state.
	const ifaceRows = (s.interfaces || []).map((i) => ({ ...i, iface_state: i.state }));

	const D = (id, label, tables) => ({
		id,
		label,
		count: tables.reduce((n, t) => n + t.count, 0),
		tables,
	});
	const T = (id, label, columns, rows, summary) => ({
		id,
		label,
		columns,
		rows,
		count: rows.length,
		summary,
	});

	return [
		D("machines", "Machines", [
			T(
				"machines",
				"Machines",
				vmCols,
				vms,
				vms.length ? `${running} running · ${vms.length - running} stopped` : ""
			),
		]),
		D("images", "Images", [
			T("images", "Images", imageCols, s.images || [], ""),
			T("snapshots", "Snapshots", snapCols, s.snapshots || [], ""),
		]),
		D("network", "Network", [
			T("addresses", "Addresses", addrCols, s.addresses || [], ""),
			T("interfaces", "Interfaces", ifaceCols, ifaceRows, ""),
			T("routes", "Routes", routeCols, s.routes || [], ""),
			T("reserved", "Reserved IPs", ripCols, s.reserved_ips || [], ""),
			T("ndp", "Proxy NDP", ndpCols, s.neigh_proxy || [], ""),
			T("rules", "IP rules", ruleCols, s.ip_rules || [], ""),
		]),
		D("firewall", "Firewall", [
			{
				id: "nftables",
				label: "nftables",
				columns: [],
				rows: [],
				count: nftRuleCount(s),
				summary: nftSummary(s),
			},
		]),
		D("system", "System", [
			T(
				"units",
				"Units",
				unitCols,
				units,
				units.length ? `${unitsUp} up · ${units.length - unitsUp} dead` : ""
			),
			T("packages", "Packages", pkgCols, s.host?.packages || [], ""),
		]),
	];
});

function nftRuleCount(s) {
	return (s.nft_tables || []).reduce(
		(n, t) => n + t.chains.reduce((m, c) => m + c.rules.length, 0),
		0
	);
}
function nftSummary(s) {
	const tables = s.nft_tables || [];
	if (!tables.length) return "";
	return `${tables.length} ${tables.length === 1 ? "table" : "tables"} · ${nftRuleCount(
		s
	)} rules`;
}

const activeTable = computed(() => {
	const d = domains.value.find((d) => d.id === selected.value.domain);
	if (!d) return null;
	return d.tables.find((t) => t.id === selected.value.table) || d.tables[0];
});
</script>
