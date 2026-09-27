// dialog_linux.c.v - Linux backend of the dialog service.
//
// STUB (Phase 5 S1 wave 1, ADR-0014): this file was written before a Linux
// toolchain existed on the dev machine, so the GTK chooser was deliberately
// not written blind - an uncompiled C file is a liability, not progress
// (AGENTS.md §4: write the pure-V seam first and stub the native side with
// 'not implemented on …').
//
// That reason has expired: the WSL image now has V (/root/vsrc/v), GTK 3.24
// and webkit2gtk-4.1, so this file can be compiled and proven (see the
// checklist in tests/e2e_linux/README.md). It is still a stub because the
// GTK chooser is the last S1 item that needs a human answering a modal
// window, and it is scheduled after clipboard/notification in Phase 5b.
//
// What the implementation has to do (see tests/e2e_linux/README.md for the
// manual test):
//   - parent the GtkFileChooserDialog to Ctx.parent (the GdkWindow);
//   - run it from the GTK main loop. The handler already runs on that
//     loop, but gtk_dialog_run() spins a nested loop, which is the reason
//     the dialog service is allowed to block (ADR-0014). Do NOT call
//     gtk_main_quit from a response handler;
//   - map the response to the same Result shape (canceled / paths);
//   - keep UTF-8: g_filename_to_utf8/g_filename_from_utf8.
module services

import webview

// button_flags mirrors the Windows mapping so both backends agree on what
// the frontend's button-set names mean.
fn button_flags(buttons string) int {
	match buttons {
		buttons_ok_cancel {
			return 1
		}
		buttons_yes_no_cancel {
			return 2
		}
		else {
			return 0
		}
	}
}

fn open_native(_ctx webview.Ctx, _opts Options) !Result {
	return error('dialog.open: not implemented on linux yet (Phase 5b — needs a Linux toolchain; see tests/e2e_linux/README.md)')
}

fn save_native(_ctx webview.Ctx, _opts Options) !Result {
	return error('dialog.save: not implemented on linux yet (Phase 5b — needs a Linux toolchain; see tests/e2e_linux/README.md)')
}

fn message_native(_ctx webview.Ctx, _opts Options) !Result {
	return error('dialog.message: not implemented on linux yet (Phase 5b — needs a Linux toolchain; see tests/e2e_linux/README.md)')
}
