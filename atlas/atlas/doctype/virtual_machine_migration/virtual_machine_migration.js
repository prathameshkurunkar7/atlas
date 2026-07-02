// Virtual Machine Migration — a read-mostly form: the scheduler drives the phase
// machine (spec/19 §7), so the operator watches progress and, on a Failed row,
// clicks Retry. There are no per-phase manual buttons — the lifecycle guard
// blocks concurrent VM actions while a migration runs, so the row alone is the
// control surface.

frappe.ui.form.on("Virtual Machine Migration", {
	refresh(frm) {
		if (frm.is_new()) return;
		render_progress(frm);
		add_retry_button(frm);
		subscribe_to_realtime(frm);
	},
});

// The phase order, mirrored from migration.PHASE_ORDER, for a simple progress
// read-out. Done/Failed are terminal and handled separately.
const PHASES = [
	"Pending",
	"ExportingSnapshot",
	"TargetPreparing",
	"InjectingIdentity",
	"Hydrating",
	"CutoverStarting",
	"Repointing",
	"Cleanup",
	"Done",
];

function render_progress(frm) {
	frm.set_intro("");
	const status = frm.doc.status;

	if (status === "Failed") {
		const at = frm.doc.error_at_status
			? __(" (failed at {0})", [frm.doc.error_at_status])
			: "";
		frm.set_intro(
			__("Migration failed{0}. Fix the cause, then click Retry to resume from that phase.", [
				at,
			]),
			"red"
		);
		return;
	}

	if (status === "Done") {
		if (frm.doc.keep_address) {
			frm.set_intro(
				__(
					"Done — the VM kept its address; traffic is now forwarded from the source host until collapsed. Manage the forward from the Virtual Machine."
				),
				"green"
			);
		} else {
			frm.set_intro(
				__("Done — the VM moved to a new address and the proxy was re-pointed."),
				"green"
			);
		}
		return;
	}

	// In-flight: show which phase, and the hydration % while copying.
	const index = PHASES.indexOf(status);
	const step = index >= 0 ? `${index + 1}/${PHASES.length}` : "";
	let message = __("In progress — phase <b>{0}</b> {1}", [status, step]);
	if (status === "Hydrating" && frm.doc.hydration_percent != null) {
		message += __(" — hydrating {0}%", [frm.doc.hydration_percent]);
	}
	if (frm.doc.keep_address && frm.doc.tunnel_status) {
		message += __(" — tunnel {0}", [frm.doc.tunnel_status]);
	}
	frm.set_intro(message, "blue");
}

function add_retry_button(frm) {
	if (frm.doc.status !== "Failed") return;
	frappe.atlas.add_primary(frm, __("Retry"), () => {
		frm.call("retry").then(() => {
			frappe.show_alert(
				{
					message: __("Retrying — the scheduler will resume the phase."),
					indicator: "blue",
				},
				5
			);
			frm.reload_doc();
		});
	});
}

function subscribe_to_realtime(frm) {
	if (frm._atlas_migration_realtime_registered) return;
	frm._atlas_migration_realtime_registered = true;
	// The scheduler advances the row on its own cadence; a live doctype update
	// nudges the form so the operator sees phase/hydration move without a manual
	// refresh. Guarded to this row.
	frappe.realtime.on("doc_update", (data) => {
		if (data && data.doctype === "Virtual Machine Migration" && data.name === frm.doc.name) {
			frm.reload_doc();
		}
	});
}
