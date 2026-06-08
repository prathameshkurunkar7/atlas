<script setup>
import { computed, reactive, ref } from "vue";
import { Button, Dialog, FormControl, ErrorMessage, confirmDialog, toast } from "frappe-ui";

import PageHeader from "../components/PageHeader.vue";
import ResourceList from "../components/ResourceList.vue";
import { useSshKeys, useSshKeyDoctype } from "../data/machines";

// The user's registered SSH keys (owner-scoped by the backend). Manageable here
// outside the New Machine dialog: add a key, delete one. Keys are pure data —
// no lifecycle, no Tasks.
const keys = useSshKeys();
const keyDoctype = useSshKeyDoctype();

const rows = computed(() => keys.data ?? []);
const isEmpty = computed(() => !keys.loading && rows.value.length === 0);

const columns = [
	{
		label: "Name",
		key: "key_name",
		width: "minmax(12rem, 1.5fr)",
		getLabel: ({ row }) => row.key_name || row.name,
	},
	{ label: "Fingerprint", key: "fingerprint", type: "copy", width: "minmax(16rem, 2fr)" },
	{
		label: "",
		key: "name",
		type: "link",
		width: "minmax(6rem, 0.5fr)",
		align: "right",
		getLabel: () => "Delete",
	},
];

// Add-key dialog.
const showAdd = ref(false);
const form = reactive({ key_name: "", public_key: "" });
const error = ref("");

const emptyAction = {
	label: "Add SSH key",
	variant: "solid",
	theme: "gray",
	iconLeft: "lucide-plus",
	onClick: () => openAdd(),
};

function openAdd() {
	form.key_name = "";
	form.public_key = "";
	error.value = "";
	showAdd.value = true;
}

async function addKey() {
	error.value = "";
	if (!form.key_name.trim() || !form.public_key.trim()) {
		error.value = "Give the key a name and paste its public key.";
		return;
	}
	try {
		await keyDoctype.insert.submit({ key_name: form.key_name, public_key: form.public_key });
		await keys.reload();
		toast.success("SSH key added");
		showAdd.value = false;
	} catch (e) {
		error.value =
			keyDoctype.insert.error?.messages?.[0] ||
			e.messages?.[0] ||
			e.message ||
			"Could not add the key";
	}
}

// The Delete cell emits a 'link' event from ResourceList; confirm, then delete.
function onLink({ row }) {
	confirmDialog({
		title: `Delete ${row.key_name || row.name}?`,
		message: "The key is removed from your account. Machines already created keep their copy.",
		onConfirm: async ({ hideDialog }) => {
			await keyDoctype.delete.submit({ name: row.name });
			await keys.reload();
			toast.success("Deleted");
			hideDialog();
		},
	});
}
</script>

<template>
	<PageHeader title="SSH Keys">
		<template #actions>
			<Button
				v-if="!isEmpty"
				variant="solid"
				theme="gray"
				icon-left="lucide-plus"
				label="Add SSH key"
				@click="openAdd"
			/>
		</template>
	</PageHeader>

	<ResourceList
		:columns="columns"
		:rows="rows"
		:loading="keys.loading"
		empty-title="No SSH keys yet"
		empty-message="Add a key so you can sign in to the machines you create."
		:empty-action="emptyAction"
		@link="onLink"
	/>

	<Dialog v-model="showAdd" :options="{ title: 'Add SSH key' }">
		<template #body-content>
			<form class="space-y-4" @submit.prevent="addKey" @pointerdown.stop>
				<FormControl
					v-model="form.key_name"
					label="Key name"
					placeholder="laptop"
					required
				/>
				<FormControl
					v-model="form.public_key"
					type="textarea"
					label="Public key"
					placeholder="ssh-ed25519 AAAA… you@host"
					required
				/>
				<ErrorMessage :message="error" />
			</form>
		</template>
		<template #actions>
			<div class="flex justify-end gap-2">
				<Button label="Cancel" @click="showAdd = false" />
				<Button
					variant="solid"
					theme="gray"
					label="Add key"
					:loading="keyDoctype.insert.loading"
					@click="addKey"
				/>
			</div>
		</template>
	</Dialog>
</template>
