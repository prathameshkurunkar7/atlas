<template>
	<div class="-mx-2 overflow-x-auto">
		<table class="w-full border-collapse text-sm">
			<thead>
				<tr class="text-left align-bottom">
					<th
						v-for="col in columns"
						:key="col.key"
						class="whitespace-nowrap px-2 pb-2 font-normal text-ink-gray-4"
						:class="col.align === 'right' ? 'text-right' : ''"
					>
						{{ col.label }}
					</th>
				</tr>
			</thead>
			<tbody>
				<tr
					v-for="(row, i) in rows"
					:key="i"
					class="align-top text-ink-gray-8 hover:bg-surface-gray-1"
				>
					<td
						v-for="col in columns"
						:key="col.key"
						class="whitespace-nowrap px-2 py-1.5"
						:class="[
							col.align === 'right' ? 'text-right' : '',
							col.mono ? 'mono' : '',
						]"
					>
						<slot :name="col.key" :row="row" :value="row[col.key]">
							<span :class="cellClass(row, col)">{{ display(row[col.key]) }}</span>
						</slot>
					</td>
				</tr>
			</tbody>
		</table>
	</div>
</template>

<script setup>
defineProps({
	columns: { type: Array, required: true },
	rows: { type: Array, required: true },
});

// Empty / null cells render as a muted dash so the grid stays legible without
// borders — the eye tracks the em-dash instead of an empty gap.
function display(value) {
	if (value === null || value === undefined || value === "") return "—";
	return value;
}

function cellClass(row, col) {
	const value = row[col.key];
	if (value === null || value === undefined || value === "") return "text-ink-gray-3";
	return col.muted ? "text-ink-gray-5" : "";
}
</script>
