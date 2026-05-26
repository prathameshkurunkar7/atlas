frappe.ui.form.on("Server", {
	refresh(frm) {
		if (frm.is_new()) {
			return;
		}
		frm.add_custom_button("Bootstrap", () => {
			frappe.confirm(`Bootstrap ${frm.doc.name}?`, () => {
				frm.call("bootstrap").then(({message}) => {
					frappe.show_alert({
						message: `Bootstrap Task: ${message}`,
						indicator: "blue",
					});
					frm.reload_doc();
				});
			});
		});
		frm.add_custom_button("Run Task", () => {
			open_run_task_dialog(frm);
		});
		frm.add_custom_button("Reboot", () => {
			frappe.confirm(
				`Reboot ${frm.doc.name}? SSH will drop; the Task will end Failure.`,
				() => {
					frm.call("reboot").then(({message}) => {
						frappe.show_alert({
							message: `Reboot Task: ${message}`,
							indicator: "orange",
						});
						frappe.set_route("Form", "Task", message);
					});
				},
			);
		});
	},
});


function open_run_task_dialog(frm) {
	frm.call("get_scripts").then(({message: scripts}) => {
		const dialog = new frappe.ui.Dialog({
			title: "Run Task",
			fields: [
				{
					fieldname: "script",
					label: "Script",
					fieldtype: "Select",
					options: (scripts || []).join("\n"),
					reqd: 1,
				},
				{
					fieldname: "variables",
					label: "Variables (JSON)",
					fieldtype: "Code",
					options: "JSON",
					default: "{}",
				},
			],
			primary_action_label: "Run",
			primary_action(values) {
				frm.call("run_task_dialog", {
					script: values.script,
					variables: values.variables,
				}).then(({message: task_name}) => {
					dialog.hide();
					frappe.set_route("Form", "Task", task_name);
				});
			},
		});
		dialog.show();
	});
}
