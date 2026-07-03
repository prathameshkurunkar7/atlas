import frappeUIPreset from "frappe-ui/tailwind";

// Use frappe-ui's design tokens (the --ink-gray / --surface / --outline scale
// and Inter) so the dashboard reads as Frappe without pulling any colour in.
// We deliberately touch only the neutral tokens in the app CSS.
export default {
	presets: [frappeUIPreset],
	content: [
		"./index.html",
		"./src/**/*.{vue,js,ts}",
		"./node_modules/frappe-ui/src/**/*.{vue,js,ts}",
	],
};
