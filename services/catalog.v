// catalog.v — the built-in service catalog (T5): the single place that
// answers "which services does this Vails build ship".
//
// Order is stable because `vails dts` and `vails doctor` emit in it.
// Each service contributes one manifest here; nothing else in the
// codebase needs to know a service exists (a service registers itself
// through services.install, which walks its manifest).
//
// Phase 5 S1 fills this list one service at a time, each with its own
// native backend + tests (see ROADMAP).
module services

// manifests returns the built-in service manifests. Pure-V and
// OS-agnostic: a manifest describes a service's contract, not its
// platform support, so the same list is valid on every OS.
pub fn manifests() []Service {
	// Phase 5 S1 wave 1 (ADR-0014) then wave 2 (ADR-0015) then wave 3
	// (ADR-0017). The catalog order is the order the .d.ts blocks and the JS
	// snippets are emitted in, and it follows the catalog order ADR-0014
	// recorded (dialog → notification → menu → tray → clipboard → opener →
	// os-info) with the two services that needed the window host seam - menu
	// and tray - moved in where that order has them, after notification.
	//
	// `drop` is last (ROADMAP F1) because it is the only service whose window is
	// an *input* surface rather than an output or a decoration: every other entry
	// here puts something in front of the user, and this one asks the user for
	// something. The order is cosmetic - nothing looks a service up by position -
	// but appending is the honest way to add one.
	return [
		dialog_manifest(),
		notification_manifest(),
		menu_manifest(),
		tray_manifest(),
		clipboard_manifest(),
		opener_manifest(),
		os_info_manifest(),
		drop_manifest(),
	]
}
