// clipboard_linux.c.v - Linux backend of the clipboard service: the GTK
// clipboard. Compiled on Linux ONLY (V `_linux` suffix rule).
//
// The GTK clipboard is used instead of xclip/xsel on purpose: the webview
// backend already links GTK and owns the display connection, so
// gtk_clipboard_get works with no extra package (xclip is not installed in
// the WSL image this was verified on) and no extra process per read.
//
// Threading: gtk_clipboard_wait_for_text blocks while the *owning*
// application is still serving the request, which is a real but short wait
// (milliseconds in practice). It is not a modal wait on a human, so the
// command is not marked blocking (ADR-0014) - and the frontend should still
// treat a read as cheap, not as free.
module services

import webview

#include <gtk/gtk.h>
#pkgconfig gtk+-3.0

fn C.gtk_clipboard_get(target u32) voidptr
fn C.gtk_clipboard_wait_for_text(clipboard voidptr) &char
fn C.gtk_clipboard_set_text(clipboard voidptr, text &char, len i32)
fn C.g_free(mem voidptr)

// GDK_SELECTION_CLIPBOARD: the one users mean by "the clipboard" (X11 also
// has PRIMARY, which is what a middle-click pastes; not our business).
const gdk_selection_clipboard = u32(69)

fn read_text_native(_ctx webview.Ctx) !string {
	cb := unsafe { C.gtk_clipboard_get(gdk_selection_clipboard) }
	if cb == unsafe { nil } {
		return error('services: no GDK clipboard (is GTK initialized?)')
	}
	// NULL means "this clipboard has no text", which the contract maps to
	// the empty string - not to an error.
	raw := unsafe { C.gtk_clipboard_wait_for_text(cb) }
	if raw == unsafe { nil } {
		return ''
	}
	// cstring_to_vstring COPIES; vstring() reuses the GTK-owned block, so
	// reading it after the g_free below would be a use-after-free (ADR-0015
	// Notes - the same trap bit the Linux bridge first).
	text := unsafe { cstring_to_vstring(raw) }
	unsafe { C.g_free(voidptr(raw)) }
	return text
}

fn write_text_native(ctx webview.Ctx, text string) ! {
	// GTK needs no owner window (it keeps the data in this process), but
	// require_parent is still applied so the command's contract is the same
	// on both platforms: write_text only works on a live, wired window.
	require_parent(ctx, 'write_text')!
	cb := unsafe { C.gtk_clipboard_get(gdk_selection_clipboard) }
	if cb == unsafe { nil } {
		return error('services: no GDK clipboard (is GTK initialized?)')
	}
	// len -1 means "NUL-terminated"; the V string is already UTF-8, which is
	// what GTK wants (no g_convert needed here).
	unsafe { C.gtk_clipboard_set_text(cb, text.str, -1) }
}
