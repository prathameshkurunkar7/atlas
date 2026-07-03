<template>
	<section class="mb-12">
		<div class="mb-3 flex items-baseline gap-3">
			<h2 class="text-sm font-medium text-ink-gray-9">{{ title }}</h2>
			<span v-if="count !== undefined" class="text-sm text-ink-gray-4">{{ count }}</span>
		</div>
		<slot v-if="!empty" />
		<p v-else class="text-sm text-ink-gray-4">None.</p>
	</section>
</template>

<script setup>
defineProps({
	title: { type: String, required: true },
	// Shown next to the title as a plain count; omit to hide.
	count: { type: Number, default: undefined },
	empty: { type: Boolean, default: false },
});
</script>
