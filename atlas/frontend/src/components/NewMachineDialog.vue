<script setup>
import { reactive, ref, computed, watch } from "vue";
import { Dialog, FormControl, Button, Badge, ErrorMessage, call, toast } from "frappe-ui";

import { useImages, useSshKeys, useSshKeyDoctype, osBrand, FIXED } from "../data/machines";

const props = defineProps({
	modelValue: { type: Boolean, default: false },
});
const emit = defineEmits(["update:modelValue", "created"]);

// The user picks the base image — the shared, read-only Virtual Machine Images
// the operator keeps Active. Server placement stays automatic (filled by the
// controller's before_insert). Only Active images are offered.
const images = useImages();
const imageOptions = computed(() =>
	(images.data ?? [])
		.filter((i) => i.is_active)
		.map((i) => ({ label: i.title || i.image_name || i.name, value: i.name }))
);

// The same options, decorated with OS name/version so the picker renders
// selectable cards. The first active image is tagged "Recommended", mirroring
// the standalone.
const imageCards = computed(() =>
	(images.data ?? [])
		.filter((i) => i.is_active)
		.map((i, idx) => {
			const brand = osBrand(i.image_name || i.name);
			return {
				value: i.name,
				label: i.title || brand.name,
				version: brand.version,
				note: idx === 0 ? "Recommended" : "",
			};
		})
);

// Five tiers — no Custom for users. The `value` is the Virtual Machine
// .size_preset Select key (the canonical key in atlas/atlas/sizes.py); the
// fields are the resource values the controller stores. `vcpus` is the guest
// thread count; `cpu_max_cores` is the cgroup cpu.max bandwidth cap. "Shared Nx"
// are oversubscribable fractions of a core; "Dedicated 1x" is a full core. `vcpu`
// is the human compute string for the summary. Keep this in sync with
// atlas/atlas/sizes.py SIZE_PRESETS — test_sizes.py pins them together.
const SIZES = [
	{
		label: "Shared 1x",
		value: "Shared 1x",
		vcpu: "Shared · 1/16 core",
		vcpus: 1,
		cpu_max_cores: 0.0625,
		memory_megabytes: 512,
		disk_gigabytes: 10,
	},
	{
		label: "Shared 2x",
		value: "Shared 2x",
		vcpu: "Shared · 1/8 core",
		vcpus: 1,
		cpu_max_cores: 0.125,
		memory_megabytes: 1024,
		disk_gigabytes: 20,
	},
	{
		label: "Shared 4x",
		value: "Shared 4x",
		vcpu: "Shared · 1/4 core",
		vcpus: 1,
		cpu_max_cores: 0.25,
		memory_megabytes: 2048,
		disk_gigabytes: 40,
	},
	{
		label: "Shared 8x",
		value: "Shared 8x",
		vcpu: "Shared · 1/2 core",
		vcpus: 1,
		cpu_max_cores: 0.5,
		memory_megabytes: 4096,
		disk_gigabytes: 80,
	},
	{
		label: "Dedicated 1x",
		value: "Dedicated 1x",
		vcpu: "Dedicated · 1 core",
		vcpus: 1,
		cpu_max_cores: 1,
		memory_megabytes: 8192,
		disk_gigabytes: 160,
	},
];
const SIZE_BY_VALUE = Object.fromEntries(SIZES.map((s) => [s.value, s]));

// PLACEHOLDER: per-preset price for the summary panel. The backend has no
// pricing yet — display-only, scaled off the size's CPU bandwidth × FIXED.priceMo.
// Remove with the FIXED block in data/machines.js when real pricing lands.
function priceFor(size) {
	return Math.max(2, Math.round(size.cpu_max_cores * FIXED.priceMo));
}

const form = reactive({
	title: "",
	image: "",
	// Default to "Shared 1x" (the base shared tier).
	size_preset: SIZES[0].value,
	ssh_key: "",
});
const creating = ref(false);
const error = ref("");

const open = computed({
	get: () => props.modelValue,
	set: (v) => emit("update:modelValue", v),
});

// Summary panel: the chosen size's resources + placeholder price/region.
const selectedSize = computed(() => SIZE_BY_VALUE[form.size_preset] ?? SIZES[0]);
const sizeHint = computed(() => {
	const s = selectedSize.value;
	const gb = Math.round((s.memory_megabytes / 1024) * 10) / 10;
	return `${s.vcpu} · ${gb} GB RAM · ${s.disk_gigabytes} GB SSD`;
});
const priceMo = computed(() => priceFor(selectedSize.value));
const priceHr = computed(() => priceMo.value / (24 * 30));
const region = FIXED.region;

// The user's SSH keys (owner-scoped by the backend). The picker selects one; the
// chosen key's body is copied into the VM's immutable ssh_public_key on create.
const sshKeysResource = useSshKeys();
const sshKeyDoctype = useSshKeyDoctype();
const sshKeyOptions = computed(() =>
	(sshKeysResource.data ?? []).map((k) => ({
		label: k.fingerprint ? `${k.key_name} (${k.fingerprint.slice(0, 25)}…)` : k.key_name,
		value: k.name,
	}))
);
// "Add a new key" inline form — so a first-time user with no keys is never
// stuck. Open automatically when the user has zero keys.
const addingKey = ref(false);
const newKey = reactive({ key_name: "", public_key: "" });
const savingKey = ref(false);

// Default to the first available image once they load (and whenever the dialog
// opens with none chosen), so Create is one click in the common single-image
// case while still letting the user switch.
watch(
	[imageOptions, open],
	([options, isOpen]) => {
		if (isOpen && !form.image && options.length) form.image = options[0].value;
	},
	{ immediate: true }
);

// Default the key picker to the first key, and surface the add-key form when the
// user has none.
watch(
	[sshKeyOptions, open],
	([options, isOpen]) => {
		if (!isOpen) return;
		if (!form.ssh_key && options.length) form.ssh_key = options[0].value;
		addingKey.value = options.length === 0;
	},
	{ immediate: true }
);

async function saveNewKey() {
	error.value = "";
	if (!newKey.key_name.trim() || !newKey.public_key.trim()) {
		error.value = "Give the key a name and paste its public key.";
		return;
	}
	savingKey.value = true;
	try {
		// Standard endpoint via the doctype composable; the controller derives the
		// fingerprint and rejects a malformed key.
		const doc = await sshKeyDoctype.insert.submit({
			key_name: newKey.key_name,
			public_key: newKey.public_key,
		});
		await sshKeysResource.reload();
		form.ssh_key = doc.name;
		addingKey.value = false;
		newKey.key_name = "";
		newKey.public_key = "";
	} catch (e) {
		error.value =
			sshKeyDoctype.insert.error?.messages?.[0] ||
			e.messages?.[0] ||
			e.message ||
			"Could not add the key";
	} finally {
		savingKey.value = false;
	}
}

function reset() {
	form.title = "";
	form.image = imageOptions.value[0]?.value ?? "";
	form.size_preset = SIZES[0].value;
	form.ssh_key = sshKeyOptions.value[0]?.value ?? "";
	error.value = "";
}

async function create() {
	error.value = "";
	if (!form.ssh_key) {
		error.value = "Add or choose an SSH key.";
		return;
	}
	// Resolve the chosen key's public-key body — the VM stores the body
	// (immutable, injected into the rootfs), not a link to the SSH Key row.
	const chosen = (sshKeysResource.data ?? []).find((k) => k.name === form.ssh_key);
	let publicKey = chosen?.public_key;
	if (!publicKey) {
		// The list view omits the (large) public_key body; fetch it for the chosen
		// key before insert.
		const full = await call("frappe.client.get", { doctype: "SSH Key", name: form.ssh_key });
		publicKey = full?.public_key;
	}
	if (!publicKey) {
		error.value = "Could not read the chosen SSH key.";
		return;
	}
	creating.value = true;
	try {
		// Standard Frappe endpoint: frappe.client.insert. The user chose the
		// image; `server` is omitted — the controller fills it in before_insert,
		// and after_insert auto-provisions, so one Create boots the machine.
		const size = selectedSize.value;
		const doc = await call("frappe.client.insert", {
			doc: {
				doctype: "Virtual Machine",
				title: form.title,
				image: form.image,
				size_preset: form.size_preset,
				ssh_public_key: publicKey,
				vcpus: size.vcpus,
				cpu_max_cores: size.cpu_max_cores,
				memory_megabytes: size.memory_megabytes,
				disk_gigabytes: size.disk_gigabytes,
			},
		});
		toast.success("Machine created");
		open.value = false;
		reset();
		emit("created", doc.name);
	} catch (e) {
		error.value = e.messages?.[0] || e.message || "Could not create the machine";
	} finally {
		creating.value = false;
	}
}
</script>

<template>
	<Dialog v-model="open" :options="{ title: 'New Machine' }">
		<template #body-content>
			<!-- reka-ui's DialogOverlay (which wraps the content) runs a
           `pointerdown.left.prevent` handler to suppress backdrop text
           selection. Because frappe-ui nests the content *inside* the overlay,
           that preventDefault bubbles up and cancels focus for every field —
           left-click won't focus an input (Tab and right-click still work).
           Stopping pointerdown here keeps it from reaching the overlay, so
           clicks inside the form focus normally; backdrop clicks (outside the
           form) still dismiss the dialog. -->
			<form class="space-y-4" @submit.prevent="create" @pointerdown.stop>
				<FormControl v-model="form.title" label="Name" required />

				<!-- Image picker as selectable cards (OS mark + name + version),
             matching the list's OS marks. The grid caps its height and scrolls
             so a long image list never blows out the dialog. -->
				<div>
					<label class="mb-1.5 block text-xs text-ink-gray-5">Image</label>
					<div class="grid max-h-44 grid-cols-2 gap-2 overflow-y-auto">
						<button
							v-for="img in imageCards"
							:key="img.value"
							type="button"
							class="flex min-w-0 items-center gap-2.5 rounded-lg border p-2.5 text-left transition"
							:class="
								form.image === img.value
									? 'border-outline-gray-4 ring-1 ring-outline-gray-3'
									: 'border-outline-gray-2 hover:border-outline-gray-3'
							"
							@click="form.image = img.value"
						>
							<div class="min-w-0 flex-1">
								<div class="truncate text-sm font-medium text-ink-gray-9">
									{{ img.label }}
								</div>
								<div class="truncate text-xs text-ink-gray-5">
									{{ img.version ? `Version ${img.version}` : img.value }}
								</div>
							</div>
							<Badge
								v-if="img.note"
								variant="subtle"
								theme="green"
								:label="img.note"
								class="shrink-0"
							/>
						</button>
					</div>
				</div>

				<FormControl
					v-model="form.size_preset"
					type="select"
					label="Size"
					:options="SIZES.map((s) => ({ label: s.label, value: s.value }))"
				/>
				<p class="-mt-2 text-sm text-ink-gray-5">{{ sizeHint }}</p>

				<!-- SSH key: pick a registered key, or add one inline. The chosen key's
             body is copied into the VM on create. -->
				<div>
					<div class="mb-1.5 flex items-center justify-between">
						<label class="block text-xs text-ink-gray-5">SSH key</label>
						<button
							v-if="sshKeyOptions.length"
							type="button"
							class="text-xs text-ink-gray-5 hover:text-ink-gray-9"
							@click="addingKey = !addingKey"
						>
							{{ addingKey ? "Choose existing" : "+ Add a new key" }}
						</button>
					</div>

					<FormControl
						v-if="!addingKey"
						v-model="form.ssh_key"
						type="select"
						:options="sshKeyOptions"
					/>

					<div v-else class="space-y-2 rounded-lg border border-outline-gray-2 p-3">
						<FormControl
							v-model="newKey.key_name"
							label="Key name"
							placeholder="laptop"
						/>
						<FormControl
							v-model="newKey.public_key"
							type="textarea"
							label="Public key"
							placeholder="ssh-ed25519 AAAA… you@host"
						/>
						<div class="flex justify-end gap-2">
							<Button
								v-if="sshKeyOptions.length"
								label="Cancel"
								size="sm"
								@click="addingKey = false"
							/>
							<Button
								variant="subtle"
								theme="gray"
								size="sm"
								label="Save key"
								:loading="savingKey"
								@click="saveNewKey"
							/>
						</div>
					</div>
				</div>

				<!-- Live summary: what you're about to create. Region + price are
             placeholder (see data/machines.js FIXED / priceFor). -->
				<div class="rounded-lg border border-outline-gray-2 bg-surface-gray-1 p-3">
					<div class="mb-2 text-xs font-medium text-ink-gray-5">Summary</div>
					<dl class="space-y-1.5 text-sm">
						<div class="flex justify-between">
							<dt class="text-ink-gray-5">Region</dt>
							<dd class="text-ink-gray-9">{{ region.flag }} {{ region.name }}</dd>
						</div>
						<div class="flex justify-between">
							<dt class="text-ink-gray-5">Compute</dt>
							<dd class="text-ink-gray-9">
								{{ selectedSize.vcpu }} ·
								{{ Math.round((selectedSize.memory_megabytes / 1024) * 10) / 10 }}
								GB
							</dd>
						</div>
						<div class="flex justify-between">
							<dt class="text-ink-gray-5">Disk</dt>
							<dd class="text-ink-gray-9">
								{{ selectedSize.disk_gigabytes }} GB SSD
							</dd>
						</div>
						<div
							class="mt-1 flex items-baseline justify-between border-t border-outline-gray-2 pt-2"
						>
							<dd class="text-base font-medium text-ink-gray-9">
								${{ priceMo
								}}<span class="text-sm font-normal text-ink-gray-5"> /mo</span>
							</dd>
							<dd class="font-mono text-xs text-ink-gray-5">
								≈ ${{ priceHr.toFixed(3) }} / hr
							</dd>
						</div>
					</dl>
				</div>

				<ErrorMessage :message="error" />
			</form>
		</template>
		<template #actions>
			<div class="flex justify-end gap-2">
				<Button label="Cancel" @click="open = false" />
				<Button
					variant="solid"
					theme="gray"
					label="Create"
					:loading="creating"
					@click="create"
				/>
			</div>
		</template>
	</Dialog>
</template>
