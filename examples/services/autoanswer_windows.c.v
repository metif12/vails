// autoanswer_windows.c.v - the Windows counterpart of autoanswer_linux.c.v.
//
// It exists to keep examples/services/main.v free of `#ifdef OS`: the probe is
// armed through one call that means "if this platform can answer its own
// dialog, do so" rather than a platform check at the call site. That is also
// the honest answer on Windows — a MessageBoxW has no supported
// answer-it-from-a-timer path, so the dialog proof there is a documented
// manual click (tests/e2e_windows/README.md) and this returns false.
module main

import os

// arm_dialog_auto_answer is a no-op here; only the Linux half has a shim.
fn arm_dialog_auto_answer(response_id int, delay_ms int) {}

fn arm_dialog_probe() bool {
	// The env var is deliberately NOT read here. Nothing is armed on Windows
	// for any probe, so the only correct answer to "did you arm anything" is
	// always no — and returning a value that depends on the environment would
	// invite a caller to think a dialog had been taken care of when it had not.
	//
	// A MessageBoxW is owned by the user and has no supported
	// answer-it-from-a-timer path. The Windows proof for dialog is a real click,
	// recorded by hand: tests/e2e_windows/README.md.
	_ := os.getenv('VAILS_SERVICES_PROBE')
	return false
}
