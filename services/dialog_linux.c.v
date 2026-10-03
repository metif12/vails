// dialog_linux.c.v - Linux backend of the dialog service: a GtkFileChooserDialog
// and a GtkMessageDialog. Compiled on Linux ONLY (V `_linux` suffix rule).
//
// This file was a stub from ADR-0014 (wave 1) until 2026-09-29, and the reason
// it gave - "needs a Linux toolchain" - had expired two waves earlier; what was
// actually left was the last S1 item that needed someone to click a modal
// window. It does not any more: a GTK dialog can be answered programmatically
// from an idle callback, which is what the E2E proof in tests/e2e_linux does.
//
// Three things here are not the GTK2 answers and are the reason this is worth
// writing down:
//
//  1. THE PARENT IS `Ctx.toplevel`, NOT `Ctx.parent`. The chooser's parent
//     parameter is a `GtkWindow*`. `Ctx.parent` is a GdkWindow, which is a
//     different object entirely and is not accepted there. ADR-0023 added
//     `toplevel` for the window menu bar and this is the second consumer; the
//     stub's own comment said to parent to `Ctx.parent`, which would have been
//     a type error at best.
//
//  2. `gtk_dialog_run` SPINS A NESTED MAIN LOOP. That is the documented
//     ADR-0014 exception that lets the dialog commands be `blocking: true`, and
//     it is why a handler may park here. The two rules that come with it: never
//     `gtk_main_quit` from a response handler (it would kill the whole app's
//     loop, not just the dialog), and never assume the loop you return to is
//     the one you were called from.
//
//  3. FILENAMES ARE NOT UTF-8 ON DISK. The chooser hands back a `gchar*` in
//     the filesystem encoding, and `vails_filename_to_utf8` (list_shim.h) is
//     the explicit conversion that makes a path with non-ASCII characters
//     survive the trip. Reading the pointer as a V string would be correct on
//     a UTF-8 filesystem and wrong everywhere else, which is the kind of wrong
//     nobody finds on their own machine.
module services

import webview

// The GList walk lives in C for the reason list_shim.h's header says: V cannot
// chase `->data` / `->next`, and the result is deliberately the same
// NUL-separated buffer the Windows shim produces, so dialog.parse_paths (pure
// V, shared, tested) splits it on both platforms.
#insert "@VMODROOT/services/list_shim.h"

fn C.vails_list_to_utf8(list voidptr, out &u8, out_len int) int

// GTK is already linked by the webview backend, so no #flag is needed for these.
// The response ids are in dialog.v (shared, and tested on every platform).
fn C.gtk_file_chooser_dialog_new(title &char, parent voidptr, action int, first_button &char, ...) voidptr
fn C.gtk_file_chooser_set_select_multiple(chooser voidptr, enable bool)
fn C.gtk_file_chooser_set_current_folder(chooser voidptr, folder &char) int
fn C.gtk_file_chooser_set_current_name(chooser voidptr, name &char)
fn C.gtk_file_chooser_set_do_overwrite_confirmation(chooser voidptr, do_it bool)
fn C.gtk_file_chooser_get_filename(chooser voidptr) &char
fn C.gtk_file_chooser_get_filenames(chooser voidptr) voidptr
fn C.gtk_file_filter_new() voidptr
fn C.gtk_file_filter_set_name(filter voidptr, name &char)
fn C.gtk_file_filter_add_pattern(filter voidptr, pattern &char)
fn C.gtk_file_chooser_add_filter(chooser voidptr, filter voidptr)
fn C.gtk_file_chooser_set_filter(chooser voidptr, filter voidptr)
fn C.gtk_dialog_run(dialog voidptr) int
fn C.gtk_dialog_add_button(dialog voidptr, text &char, response int)
fn C.gtk_window_set_transient_for(window voidptr, parent voidptr)
fn C.gtk_message_dialog_new(parent voidptr, flags int, type_ int, buttons int, message_format &char, ...) voidptr
fn C.gtk_widget_show_all(widget voidptr)
fn C.gtk_widget_destroy(widget voidptr)
fn C.gtk_main_iteration_do(blocking bool) bool
fn C.vails_filename_to_utf8(filename &char) &char
fn C.gtk_init_check(argc voidptr, argv voidptr) int
fn C.g_list_free(list voidptr)
fn C.g_free(mem voidptr)

// GtkFileChooserAction, as literals (AGENTS.md §2).
const gtk_file_chooser_action_open = 0
const gtk_file_chooser_action_save = 1

// GtkMessageDialogType and GtkButtonsType, as literals.
const gtk_message_dialog_info = 0
const gtk_message_dialog_question = 3
const gtk_buttons_ok = 1
const gtk_buttons_ok_cancel = 2
const gtk_buttons_yes_no_cancel = 8

// GtkDialogFlags. GTK_DIALOG_MODAL is what makes the nested loop behave like a
// dialog rather than a second window the user can work around; GTK_DIALOG_DESTROY_WITH_PARENT ties the chooser's lifetime to the window so a window close does not orphan it.
const gtk_dialog_modal = 1
const gtk_dialog_destroy_with_parent = 2

// dialog_parent is the window a GTK dialog is parented to, or nil.
//
// nil is a real answer here rather than a failure: an unparented dialog is
// centered on its own, which is what a developer with no window wired up wants,
// and what a test needs. The alternative — refusing — would make the service
// unusable in exactly the headless case it is easiest to exercise in.
fn dialog_parent(ctx webview.Ctx) voidptr {
	if ctx.has_toplevel() {
		return ctx.toplevel
	}
	return unsafe { nil }
}

// apply_filters installs the frontend's type list on a chooser.
//
// The extension list is turned into GTK glob patterns here rather than in
// dialog.v, because this is the only place that knows GTK's spelling — and the
// two platforms genuinely spell it differently (Windows' shim builds
// "Images (*.png;*.jpg)" in C, GTK wants "*.png" per pattern), so sharing a
// string would mean sharing the Windows convention on a platform that does not
// use it.
//
// A filter with no extensions is skipped rather than added as an
// accept-everything entry: `{"name":"All files","extensions":""}` from a
// frontend that did not mean to filter is better served by no filter at all.
fn apply_filters(chooser voidptr, filters []Filter) {
	for f in filters {
		if f.extensions == '' {
			continue
		}
		filter := unsafe { C.gtk_file_filter_new() }
		if filter == unsafe { nil } {
			continue
		}
		unsafe {
			C.gtk_file_filter_set_name(filter, f.name.str)
		}
		for raw_ext in f.extensions.split(',') {
			ext := raw_ext.trim_space()
			if ext == '' {
				continue
			}
			// Accept "png" and ".png" alike, and build a glob. A bare extension
			// is matched case-insensitively by GTK's own matcher, which is what
			// a user expects of "*.PNG" on a filesystem that has .PNG files.
			pattern := (if ext.starts_with('.') { ext } else { '.' + ext }) + '*'
			unsafe {
				C.gtk_file_filter_add_pattern(filter, pattern.str)
			}
		}
		unsafe {
			C.gtk_file_chooser_add_filter(chooser, filter)
		}
	}
}

// path_buffer_len matches the Windows shim's, so the two platforms fail the
// same way on the same input: a picker that somehow produced more than 64 KB of
// paths is a bug, and the bound is what turns it into a reported error rather
// than a truncated (and therefore wrong) answer.
const path_buffer_len = 65536

// collect_paths reads a multi-select chooser's filenames through the shim and
// splits them with the shared parser.
//
// The `(paths, reason)` shape is chosen to match the Windows half's
// `dialog_rc(rc, buf, reason)`: a native call that reports failure as a code
// and success as a buffer should not need a `!Result` to be wrapped once per
// platform. An empty reason means success, which is also what makes the caller
// able to destroy the chooser on every path instead of returning from inside.
fn collect_paths(chooser voidptr) ([]string, string) {
	mut buf := []u8{cap: path_buffer_len, len: path_buffer_len}
	list := unsafe { C.gtk_file_chooser_get_filenames(chooser) }
	if list == unsafe { nil } {
		return []string{}, ''
	}
	mut written := 0
	unsafe {
		written = C.vails_list_to_utf8(list, &buf[0], buf.len)
	}
	if written < 0 {
		return []string{}, 'the selected paths did not fit in ' +
			path_buffer_len.str() + ' bytes'
	}
	return parse_paths(buf.bytestr()), ''
}

// single_path reads the one filename a non-multi chooser holds. It is the
// counterpart to collect_paths: the shim exists for the GList case, and a
// single selection is a plain g_free rather than a list walk.
fn single_path(chooser voidptr) []string {
	raw := unsafe { C.gtk_file_chooser_get_filename(chooser) }
	if raw == unsafe { nil } {
		return []string{}
	}
	defer {
		unsafe {
			C.g_free(voidptr(raw))
		}
	}
	utf8 := unsafe { C.vails_filename_to_utf8(raw) }
	if utf8 == unsafe { nil } {
		return []string{}
	}
	defer {
		unsafe {
			C.g_free(voidptr(utf8))
		}
	}
	return [unsafe { utf8.vstring() }]
}

// dialog_display_available reports whether a display can be reached.
//
// This is not defensive programming for its own sake. Every GTK entry point
// requires a successful gtk_init, and calling one without it is undefined
// behaviour that in practice segfaults inside the library with no message and
// no V frames in the backtrace. A service can legitimately be called before
// the webview is up, or from a process with no DISPLAY at all, so the question
// has to be asked once and the refusal reported as an error. That is the
// difference between a diagnosable "no display" and an unexplained crash.
//
// gtk_init_check rather than gtk_init, because this must not open a display as
// a side effect of asking whether one exists.
fn dialog_display_available() bool {
	return unsafe { C.gtk_init_check(unsafe { nil }, unsafe { nil }) } != 0
}

fn open_native(ctx webview.Ctx, opts Options) !Result {
	if !dialog_display_available() {
		return error('dialog.open: no display available (DISPLAY is unset, or the ' +
			'app is running headless)')
	}
	parent := dialog_parent(ctx)
	chooser := unsafe {
		C.gtk_file_chooser_dialog_new(opts.title.str, parent,
			gtk_file_chooser_action_open, unsafe { nil })
	}
	if chooser == unsafe { nil } {
		return error('dialog.open: gtk_file_chooser_dialog_new failed')
	}
	unsafe {
		C.gtk_dialog_add_button(chooser, c'Cancel', gtk_response_cancel)
		C.gtk_dialog_add_button(chooser, c'Open', gtk_response_accept)
		if opts.multi {
			C.gtk_file_chooser_set_select_multiple(chooser, true)
		}
		if opts.default_path != '' {
			C.gtk_file_chooser_set_current_folder(chooser, opts.default_path.str)
		}
	}
	apply_filters(chooser, opts.filters)
	rc := unsafe { C.gtk_dialog_run(chooser) }
	// Read the answer BEFORE destroying the chooser. The filenames are owned by
	// the widget, so destroying it first would leave the paths dangling - which
	// is the reason this function has one exit instead of a return per branch.
	mut res := Result{
		canceled: true
	}
	mut reason := ''
	if gtk_chooser_accepted(rc) {
		mut paths := []string{}
		if opts.multi {
			found, why := collect_paths(chooser)
			paths = found.clone()
			if why != '' {
				reason = 'dialog.open: ' + why
			}
		} else {
			paths = single_path(chooser)
		}
		if reason == '' {
			res = Result{
				canceled: false
				paths:    paths
			}
		}
	}
	unsafe {
		C.gtk_widget_destroy(chooser)
	}
	if reason != '' {
		return error(reason)
	}
	return res
}

fn save_native(ctx webview.Ctx, opts Options) !Result {
	if !dialog_display_available() {
		return error('dialog.save: no display available (DISPLAY is unset, or the ' +
			'app is running headless)')
	}
	parent := dialog_parent(ctx)
	chooser := unsafe {
		C.gtk_file_chooser_dialog_new(opts.title.str, parent,
			gtk_file_chooser_action_save, unsafe { nil })
	}
	if chooser == unsafe { nil } {
		return error('dialog.save: gtk_file_chooser_dialog_new failed')
	}
	unsafe {
		C.gtk_dialog_add_button(chooser, c'Cancel', gtk_response_cancel)
		C.gtk_dialog_add_button(chooser, c'Save', gtk_response_accept)
		// Without this a Save that names an existing file silently overwrites it,
		// which is not a thing a user asked for by naming a file.
		C.gtk_file_chooser_set_do_overwrite_confirmation(chooser, true)
		if opts.default_path != '' {
			C.gtk_file_chooser_set_current_folder(chooser, opts.default_path.str)
		}
		if opts.default_name != '' {
			C.gtk_file_chooser_set_current_name(chooser, opts.default_name.str)
		}
	}
	apply_filters(chooser, opts.filters)
	rc := unsafe { C.gtk_dialog_run(chooser) }
	// Same one-exit shape as open_native: read the answer, then destroy.
	mut res := Result{
		canceled: true
	}
	if gtk_chooser_accepted(rc) {
		// A save is always single-selection - the whole point is naming one
		// file - so it goes through single_path and never the GList shim.
		paths := single_path(chooser)
		if paths.len > 0 {
			res = Result{
				canceled: false
				paths:    paths
			}
		}
	}
	unsafe {
		C.gtk_widget_destroy(chooser)
	}
	return res
}

// message_native is the odd one out: it needs no file system, so it is the one
// dialog that can be fully answered by the E2E proof without a chooser.
//
// GTK wants a printf-style format string, and a frontend's message is arbitrary
// text that may contain a '%'. Passing it straight through would turn "%s" in a
// message into a read of a garbage pointer, so the message is passed as a
// literal argument with a "%s" format - which is the only safe way to hand GTK
// untrusted text.
fn message_native(ctx webview.Ctx, opts Options) !Result {
	if !dialog_display_available() {
		return error('dialog.message: no display available (DISPLAY is unset, or ' +
			'the app is running headless)')
	}
	parent := dialog_parent(ctx)
	kind := if opts.buttons == buttons_yes_no_cancel {
		gtk_message_dialog_question
	} else {
		gtk_message_dialog_info
	}
	buttons := button_flags(opts.buttons)
	dialog := unsafe {
		C.gtk_message_dialog_new(parent, gtk_dialog_modal | gtk_dialog_destroy_with_parent,
			kind, buttons, c'%s', opts.message.str, unsafe { nil })
	}
	if dialog == unsafe { nil } {
		return error('dialog.message: gtk_message_dialog_new failed')
	}
	// A title is optional in GTK; setting it only when there is one keeps an
	// empty title from rendering as a blank bar.
	if opts.title != '' {
		unsafe {
			C.gtk_window_set_title(dialog, opts.title.str)
		}
	}
	unsafe {
		C.gtk_widget_show_all(dialog)
	}
	rc := unsafe { C.gtk_dialog_run(dialog) }
	unsafe {
		C.gtk_widget_destroy(dialog)
	}
	return gtk_message_result(rc)
}

// button_flags mirrors the Windows mapping so both backends agree on what the
// frontend's button-set names mean. GTK's own GtkButtonsType is a different
// set of integers from the shim's 0/1/2 contract, so this is where the two are
// translated — and it is pure V, which is what makes it testable on both
// platforms.
fn button_flags(buttons string) int {
	match buttons {
		buttons_ok_cancel {
			return gtk_buttons_ok_cancel
		}
		buttons_yes_no_cancel {
			return gtk_buttons_yes_no_cancel
		}
		else {
			return gtk_buttons_ok
		}
	}
}
