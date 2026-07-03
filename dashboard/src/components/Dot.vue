<template>
	<!-- Monochrome status: a filled dot for live/on, a hollow ring for
       stopped/off. No colour — weight and fill carry the meaning. -->
	<span
		class="inline-block h-1.5 w-1.5 rounded-full align-middle"
		:class="on ? 'bg-ink-gray-8' : 'border border-ink-gray-4'"
	/>
</template>

<script setup>
defineProps({ on: { type: Boolean, default: false } });
</script>
