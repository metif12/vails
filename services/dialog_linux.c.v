// dialog_linux.c.v - Linux backend of the dialog service.
//
// STUB (Phase 5 S1 wave 1, ADR-0014): this machine has no WSL/Linux V, so
// the GTK chooser is deliberately not written blind - an uncompiled C file
// is a liability, not progress (AGENTS.md §4: write the pure-V seam first
// and stub the native side with 'not implemented on …').
//
// What the implementation has to do when Linux is available (see
// tests/e2e_linux/README.md for the manual test):
//   - parent the GtkFileChooserDialog to Ctx.parent (the GdkWindow);
//   - run it from the GTK main loop. The handler already runs on that
//     loop, but gtk_dialog_run() spins a nested loop, which is the reason
//     the dialog service is allowed to block (ADR-0014). Do NOT call
//     gtk_main_quit from a response handler;
//   - map the response to the same Result shape (canceled / paths);
//   - keep UTF-8: g_filename_to_utf8/g_filename_from_utf8.
module services

import webview

fn open_native(_ctx webview.Ctx, _opts Options) !Result {
	return error('dialog.open: not implemented on linux yet (Phase 5b — needs a Linux toolchain; see tests/e2e_linux/README.md)')
}

fn save_native(_ctx webview.Ctx, _opts Options) !Result {
	return error('dialog.save: not implemented on linux yet (Phase 5b — needs a Linux toolchain; see tests/e2e_linux/README.md)')
}

fn message_native(_ctx webview.Ctx, _opts Options) !Result {
	return error('dialog.message: not implemented on linux yet (Phase 5b — needs a Linux toolchain; see tests/e2e_linux/README.md)')
}
