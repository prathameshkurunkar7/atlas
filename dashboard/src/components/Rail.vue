<template>
	<!-- The one navigation mechanism: domains, and the tables inside a domain as
       indented sub-items. No tabs, no second model. Active is a darker grey, not
       a fill or a border — the monochrome rule. -->
	<nav class="min-w-0">
		<template v-for="d in domains" :key="d.id">
			<button
				class="flex w-full items-baseline justify-between gap-3 py-1.5 text-left"
				@click="$emit('select', { domain: d.id, table: d.tables?.[0]?.id })"
			>
				<span
					class="text-sm"
					:class="d.id === domain ? 'text-ink-gray-9' : 'text-ink-gray-6'"
				>
					{{ d.label }}
				</span>
				<span class="mono text-xs text-ink-gray-4">{{ d.count }}</span>
			</button>

			<!-- Sub-items appear only for the open domain, and only when it has more
           than one table. Machines / Images stay a single bare panel. -->
			<template v-if="d.id === domain && d.tables && d.tables.length > 1">
				<button
					v-for="t in d.tables"
					:key="t.id"
					class="flex w-full items-baseline justify-between gap-3 py-1 pl-3.5 text-left"
					@click="$emit('select', { domain: d.id, table: t.id })"
				>
					<span class="text-[13px]" :class="tableClass(t)">{{ t.label }}</span>
					<span
						class="mono text-[11px]"
						:class="t.count ? 'text-ink-gray-4' : 'text-ink-gray-3'"
					>
						{{ t.count }}
					</span>
				</button>
			</template>
		</template>
	</nav>
</template>

<script setup>
const props = defineProps({
	// [{ id, label, count, tables: [{ id, label, count }] }]
	domains: { type: Array, required: true },
	domain: { type: String, required: true },
	table: { type: String, default: undefined },
});
defineEmits(["select"]);

// Active sub-item is ink-9; an empty table (count 0) sits at ink-3 — present but
// visibly quiet, so you can tell "no IP rules" from "haven't looked yet".
function tableClass(t) {
	if (t.id === props.table) return "text-ink-gray-9";
	return t.count ? "text-ink-gray-5" : "text-ink-gray-3";
}
</script>
