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
	// Phase 5 S1 wave 1 (ADR-0014). The catalog order is the order the
	// .d.ts blocks and the JS snippets are emitted in.
	return [
		dialog_manifest(),
		os_info_manifest(),
	]
}
