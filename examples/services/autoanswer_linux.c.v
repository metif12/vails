// autoanswer_linux.c.v - the Linux half of the dialog E2E probe.
//
// Compiled on Linux only (V `_linux` suffix rule). The Windows half needs
// nothing: MessageBoxW on a real desktop has a real human-free way to be
// answered only by clicking, so that proof is a documented manual check (see
// tests/e2e_windows/README.md) rather than an automated one.
module main

import time
import os

// @VMODROOT is the repo root, not this example's directory — the same
// resolution services/list_shim.h relies on — so the path is written out from
// the root rather than assumed to be local.
#insert "@VMODROOT/examples/services/autoanswer_shim.h"

fn C.vails_probe_auto_answer(response_id int, delay_ms int)

// arm_dialog_auto_answer schedules a press of `response_id` on whichever modal
// GTK dialog appears next, `delay_ms` from now.
//
// The delay is not cosmetic. The call has to be armed BEFORE the page issues
// the dialog call, because that call blocks the main thread inside
// gtk_dialog_run - a timer armed afterwards would only start once the dialog
// had already been answered by a human who is not there. See the ordering note
// in probe_script.
fn arm_dialog_auto_answer(response_id int, delay_ms int) {
	unsafe {
		C.vails_probe_auto_answer(response_id, delay_ms)
	}
}

// arm_dialog_probe arms a press of GTK_RESPONSE_OK on the next modal dialog, if
// this run is the dialog probe. Returns true when it armed something, so the
// caller can say so rather than leaving a silent no-op to be guessed at.
fn arm_dialog_probe() bool {
	if os.getenv('VAILS_SERVICES_PROBE') != 'dialog' {
		return false
	}
	// -5 is GTK_RESPONSE_OK. The example repeats the constant rather than
	// importing services.dialog: the shim needs it, and services is already
	// imported for the probe's own reporting.
	arm_dialog_auto_answer(-5, 600 * int(time.millisecond))
	return true
}
