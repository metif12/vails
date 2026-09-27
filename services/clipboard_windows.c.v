// clipboard_windows.c.v - Windows backend of the clipboard service: the
// user32 clipboard with CF_UNICODETEXT. Compiled on Windows ONLY (V
// `_windows` suffix rule).
//
// No COM here, and no C shim either: the clipboard is a flat set of plain C
// functions, so `fn C.*` declarations are enough. What IS fiddly is memory
// ownership, and it is the reason this file exists rather than five lines in
// clipboard.v:
//   - the text must be UTF-16, and a GlobalAlloc'd GMEM_MOVEABLE block is
//     what SetClipboardData takes ownership of. string.to_wide() allocates
//     memory we must NOT hand over (vlib/clipboard hit this too), so the
//     UTF-8 -> UTF-16 conversion is done with MultiByteToWideChar into a
//     block we own;
//   - reading means locking the handle the *other* process allocated and
//     converting UTF-16 back to UTF-8 without copying it (string_from_wide
//     reads the NUL terminator).
//
// Threading: handlers run on the webview main thread. OpenClipboard is a
// global lock, so a busy clipboard is retried a bounded number of times
// (25 ms total) rather than failing the command; nothing here blocks on a
// human, so the ADR-0010 rule holds (no `blocking` command).
module services

import time
import webview

#include <windows.h>
#flag windows -luser32

fn C.OpenClipboard(hwnd voidptr) int
fn C.CloseClipboard()
fn C.EmptyClipboard() int
fn C.IsClipboardFormatAvailable(format u32) int
fn C.SetClipboardData(format u32, data voidptr) voidptr
fn C.GetClipboardData(format u32) voidptr
fn C.GlobalAlloc(flags u32, size i64) voidptr
fn C.GlobalFree(handle voidptr) voidptr
fn C.GlobalLock(handle voidptr) voidptr
fn C.GlobalUnlock(handle voidptr) int
fn C.MultiByteToWideChar(codepage u32, flags u32, src voidptr, src_len int, dst voidptr, dst_len int) int

// CF_UNICODETEXT, GMEM_MOVEABLE, CP_UTF8, MB_ERR_INVALID_CHARS: the only
// four numbers this service needs. Redeclared as literals on purpose (see
// AGENTS.md §2: minimum signature surface), because a CF_UNICODETEXT
// mismatch would silently write ANSI data into a UTF-16 clipboard.
const cf_unicode_text = u32(13)
const gmem_moveable = u32(0x0002)
const cp_utf8 = u32(65001)
const mb_err_invalid_chars = u32(0x0008)

// Bounded retry for the global clipboard lock: five attempts 5 ms apart.
// A clipboard held by another app is a transient condition, not an error to
// hand the frontend; 25 ms of main-thread time is still imperceptible.
const open_attempts = 5
const open_retry = 5 * time.millisecond

// open_clipboard takes the global clipboard lock. A NULL window is fine for
// reading (no owner is claimed); writing passes the real HWND.
fn open_clipboard(hwnd voidptr) ! {
	for _ in 0 .. open_attempts {
		if unsafe { C.OpenClipboard(hwnd) } != 0 {
			return
		}
		time.sleep(open_retry)
	}
	return error('services: the clipboard is locked by another application (' +
		'OpenClipboard failed ' + open_attempts.str() + ' times)')
}

// text_handle converts text to a NUL-terminated UTF-16 block suitable for
// SetClipboardData. Empty text is legal and yields a block holding just the
// terminator, which is how a frontend clears the clipboard.
//
// MB_ERR_INVALID_CHARS makes invalid UTF-8 fail here instead of turning into
// U+FFFD silently, so a V string that is not valid UTF-8 is a params problem
// the frontend can see, not mojibake on the user's clipboard.
fn text_handle(text string) !voidptr {
	mut units := 0
	if text.len > 0 {
		units = unsafe {
			C.MultiByteToWideChar(cp_utf8, mb_err_invalid_chars, voidptr(text.str),
				text.len, unsafe { nil }, 0)
		}
		if units <= 0 {
			return error('services: the text is not valid UTF-8')
		}
	}
	handle := unsafe { C.GlobalAlloc(gmem_moveable, i64(units + 1) * i64(sizeof(u16))) }
	if handle == unsafe { nil } {
		return error('services: GlobalAlloc failed for ' + (units + 1).str() +
			' UTF-16 units')
	}
	p := unsafe { C.GlobalLock(handle) }
	if p == unsafe { nil } {
		unsafe { C.GlobalFree(handle) }
		return error('services: GlobalLock failed')
	}
	mut written := 0
	if units > 0 {
		written = unsafe {
			C.MultiByteToWideChar(cp_utf8, mb_err_invalid_chars, voidptr(text.str),
				text.len, p, units)
		}
	}
	if written != units {
		unsafe {
			C.GlobalUnlock(handle)
			C.GlobalFree(handle)
		}
		return error('services: the UTF-8 -> UTF-16 conversion wrote ' +
			written.str() + ' of ' + units.str() + ' units')
	}
	unsafe {
		locked := &u16(p)
		locked[units] = u16(0)
		C.GlobalUnlock(handle)
	}
	return handle
}

fn read_text_native(_ctx webview.Ctx) !string {
	open_clipboard(unsafe { nil })!
	defer {
		unsafe { C.CloseClipboard() }
	}
	// A clipboard holding no text is a normal state, not a failure: the
	// contract says read_text resolves with the empty string.
	if unsafe { C.IsClipboardFormatAvailable(cf_unicode_text) } == 0 {
		return ''
	}
	handle := unsafe { C.GetClipboardData(cf_unicode_text) }
	if handle == unsafe { nil } {
		return error('services: GetClipboardData(CF_UNICODETEXT) returned nothing')
	}
	p := unsafe { C.GlobalLock(handle) }
	if p == unsafe { nil } {
		return error('services: GlobalLock failed on the clipboard data')
	}
	// string_from_wide reads up to the NUL terminator, so the handle stays
	// locked only for the conversion, not for the caller.
	text := unsafe { string_from_wide(&u16(p)) }
	unsafe { C.GlobalUnlock(handle) }
	return text
}

fn write_text_native(ctx webview.Ctx, text string) ! {
	// EmptyClipboard makes the window that opened the clipboard its owner.
	// With a NULL window the owner is NULL, and MSDN is explicit that this
	// makes SetClipboardData fail; even where the call survives, the data
	// belongs to nobody and the OS is free to drop it. So the write path
	// takes a real HWND, and the rule itself lives in pure V
	// (require_parent) where it is testable.
	require_parent(ctx, 'write_text')!
	open_clipboard(ctx.parent)!
	defer {
		unsafe { C.CloseClipboard() }
	}
	handle := text_handle(text)!
	unsafe {
		if C.EmptyClipboard() == 0 {
			C.GlobalFree(handle)
			return error('services: EmptyClipboard failed')
		}
		if C.SetClipboardData(cf_unicode_text, handle) == unsafe { nil } {
			C.GlobalFree(handle)
			return error('services: SetClipboardData(CF_UNICODETEXT) failed')
		}
	}
	// On success the clipboard owns the block; freeing it here would empty
	// the user's clipboard.
}
