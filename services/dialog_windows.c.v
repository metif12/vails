// dialog_windows.c.v - Windows backend of the dialog service: MessageBoxW
// plus the Common Item Dialog (IFileOpenDialog / IFileSaveDialog).
// Compiled on Windows ONLY (V `_windows` suffix rule).
//
// V has no COM projection (ADR-0002), so the COM code lives in
// dialog_shim.h behind a plain UTF-8 C ABI; this file is the V-side glue
// (string conversion, the 64 KB path buffer, HRESULT/return-code
// mapping). Handlers run on the webview main thread, which is the thread
// that owns the STA the item dialog needs (ADR-0014).
module services

import webview

#insert "@VMODROOT/services/dialog_shim.h"

// ole32: CoInitializeEx/CoCreateInstance/CoTaskMemFree
// shell32: the Common Item Dialog lives in shell32 (SHCreateItemFromParsingName)
// user32: MessageBoxW
#flag windows -lole32 -lshell32 -luser32

fn C.vails_dialog_open(hwnd voidptr, title &char, filters &char, default_path &char, multi int, out &u8, out_len int) int
fn C.vails_dialog_save(hwnd voidptr, title &char, filters &char, default_path &char, default_name &char, out &u8, out_len int) int
fn C.vails_dialog_message(hwnd voidptr, title &char, message &char, buttons int) int
fn C.vails_dialog_last_error() &char

// path_buffer is generous on purpose: a multi-selection of long paths must
// not fail with "does not fit" on a machine with deep trees. Heap, because
// 64 KB has no business on the stack.
const path_buffer_len = 65536

// with_buffer runs native_call with the shared path buffer and converts
// its return code. native_call takes the buffer, so every command uses the
// same path-flattening and error mapping: dialog_rc (pure V) owns the
// mapping, this file owns the shim's error message.
type BufferCall = fn (out &u8, len int) int

fn with_buffer(native_call BufferCall) !Result {
	// Heap-allocated (cap+len): 64 KB has no business on the stack, and a
	// path buffer that outlives one call would be a use-after-free.
	mut buf := []u8{cap: path_buffer_len, len: path_buffer_len}
	rc := native_call(unsafe { &buf[0] }, buf.len)
	reason := if rc < 0 {
		unsafe { C.vails_dialog_last_error().vstring() }
	} else {
		''
	}
	return dialog_rc(rc, buf.bytestr(), reason)
}

// button_flags maps the frontend's button-set names to the shim's numeric
// contract (0 = ok, 1 = okcancel, 2 = yesnocancel). The mapping lives in
// both backends: it is the only place the wire values become platform
// numbers.
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

fn open_native(ctx webview.Ctx, opts Options) !Result {
	// Parent the picker to the webview window so it opens in front of the
	// app; a nil handle is acceptable (the OS centers it), not fatal.
	parent := if ctx.has_parent() { ctx.parent } else { unsafe { nil } }
	filters := native_filter_string(opts.filters)
	multi := if opts.multi { 1 } else { 0 }
	return with_buffer(fn [parent, filters, multi, opts] (out &u8, len int) int {
		unsafe {
			return C.vails_dialog_open(parent, opts.title.str, filters.str,
				opts.default_path.str, multi, out, len)
		}
	})
}

fn save_native(ctx webview.Ctx, opts Options) !Result {
	parent := if ctx.has_parent() { ctx.parent } else { unsafe { nil } }
	filters := native_filter_string(opts.filters)
	return with_buffer(fn [parent, filters, opts] (out &u8, len int) int {
		unsafe {
			return C.vails_dialog_save(parent, opts.title.str, filters.str,
				opts.default_path.str, opts.default_name.str, out, len)
		}
	})
}

fn message_native(ctx webview.Ctx, opts Options) !Result {
	parent := if ctx.has_parent() { ctx.parent } else { unsafe { nil } }
	buttons := button_flags(opts.buttons)
	rc := unsafe { C.vails_dialog_message(parent, opts.title.str, opts.message.str, buttons) }
	if rc < 0 {
		return error('dialog: message box failed')
	}
	// IDOK/IDYES = accepted, IDCANCEL/IDNO = canceled.
	mut button := 'none'
	if rc == 1 {
		button = 'ok'
	} else if rc == 2 {
		button = 'cancel'
	} else if rc == 6 {
		button = 'yes'
	} else if rc == 7 {
		button = 'no'
	}
	accepted := rc == 1 || rc == 6
	return Result{
		canceled: !accepted
		button:   button
	}
}
