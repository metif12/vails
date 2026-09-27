// notification_windows.c.v - Windows backend of the notification service: a
// shell balloon (Shell_NotifyIconW with NIF_INFO). Compiled on Windows ONLY
// (V `_windows` suffix rule).
//
// Two flat shell calls, no COM and no shim - the reason this service is
// implemented at all while a WinRT toast is not (see notification.v and
// ADR-0015). The shell draws it as a real notification on Windows 10/11.
//
// The lifetime is the interesting part. A tray icon is not a toast: the icon
// lives in the notification area until it is deleted, so a balloon left
// behind would grow a row of dead icons. The icon therefore goes away on a
// V worker - spawn, sleep the clamped timeout, NIM_DELETE - which is the
// ADR-0010 rule applied to a shell resource instead of to a computation. No
// window procedure is needed, which is exactly why this is a two-file
// service and `tray` is not.
module services

import time
import webview

#include <windows.h>
#include <shellapi.h>
#flag windows -lshell32 -luser32

fn C.Shell_NotifyIconW(message u32, data voidptr) int
fn C.LoadIconW(hinstance voidptr, name &u16) voidptr

// Shell messages, NOTIFYICONDATA flags, NIIF flags and the one icon id this
// service uses. Redeclared as literals (AGENTS.md §2) so a wrong flag set is
// a visible diff and not a macro surprise.
const nim_add = u32(0x00000000)
const nim_delete = u32(0x00000002)
const nif_message = u32(0x00000001)
const nif_icon = u32(0x00000002)
const nif_tip = u32(0x00000004)
const nif_info = u32(0x00000010)
const niif_info = u32(0x00000001)
const niif_large = u32(0x00000002)
const niif_respect_quiet_time = u32(0x00000080)
// IDI_INFORMATION: the shared "info" icon. Any icon would do; this one is
// always present, so there is no asset to ship (icons are a Phase 7 concern).
const idi_information = 32516
// The icon id we register under. A per-service id keeps this service from
// colliding with whatever else in the app owns tray icons.
const icon_id = u32(0x5641_494C)

// NotifyIconData is NOTIFYICONDATAW, field for field (snake_case, because V
// will not have it otherwise). The sizes are part of the contract (cbSize
// tells the shell how much we wrote), so the fixed-width fields are declared
// as arrays, not as V strings.
struct NotifyIconData {
	cb_size        u32
	hwnd           voidptr
	uid            u32
	u_flags        u32
	u_callback_msg u32
	h_icon         voidptr
	sz_tip         [128]u16
	dw_state       u32
	dw_state_mask  u32
	sz_info        [256]u16
	u_timeout      u32
	sz_info_title  [64]u16
	dw_info_flags  u32
	guid_item      [16]u8
	h_balloon_icon voidptr
}

// make_int_resource mirrors the MAKEINTRESOURCE macro: the icon id travels
// *as* the pointer value, not as a pointer to the id.
fn make_int_resource(id int) &u16 {
	mut value := u16(id)
	return &value
}

// set_wide_field copies text into one of the struct's fixed-width wide
// fields, NUL-terminated and truncated to fit. Truncation (not rejection) is
// deliberate: the shell field is 256 units for the body and 64 for the
// title, and a frontend sending a long paragraph should get a shown
// notification with a clipped tail rather than an error.
fn set_wide_field(field []u16, text string) {
	mut i := 0
	unsafe {
		src := text.to_wide()
		for i < field.len - 1 {
			c := src[i]
			if c == u16(0) {
				break
			}
			field[i] = c
			i++
		}
		field[i] = u16(0)
	}
}

// delete_icon removes the tray icon. It is the whole body of the lifetime
// worker, and it is also what a future `tray` service would call on shutdown.
fn delete_icon(hwnd voidptr) {
	nid := NotifyIconData{
		cb_size: u32(sizeof(NotifyIconData))
		hwnd:    hwnd
		uid:     icon_id
	}
	unsafe {
		C.Shell_NotifyIconW(nim_delete, voidptr(&nid))
	}
}

// remove_after is the lifetime worker: sleep, then delete. Detached on
// purpose - if the app exits first, the shell drops the icon with the
// process, so joining would only delay exit by the timeout.
fn remove_after(hwnd voidptr, timeout_ms int) {
	time.sleep(timeout_ms * time.millisecond)
	delete_icon(hwnd)
}

fn is_supported_native() bool {
	// The shell API has been in Windows since 2000, so this is a constant
	// answer, stated as code rather than implied by the absence of a stub.
	return true
}

fn notify_native(ctx webview.Ctx, opts NotificationOptions) ! {
	// A tray icon is attached to a window, and the webview window is the one
	// handle this service has (the same reason dialog parents itself to it).
	require_parent(ctx, 'notification.notify')!
	mut nid := NotifyIconData{
		cb_size:       u32(sizeof(NotifyIconData))
		hwnd:          ctx.parent
		uid:           icon_id
		u_flags:       nif_info | nif_icon | nif_tip
		h_icon:        unsafe { C.LoadIconW(unsafe { nil }, make_int_resource(idi_information)) }
		// uTimeout is documented to be honored only on Windows 7; the sleep in
		// remove_after is the mechanism that actually works, but setting it
		// costs nothing and is what the field is for.
		u_timeout:     u32(opts.timeout_ms)
		dw_info_flags: niif_info | niif_large | niif_respect_quiet_time
	}
	set_wide_field(nid.sz_tip, 'Vails')
	set_wide_field(nid.sz_info_title, opts.title)
	set_wide_field(nid.sz_info, opts.body)
	added := unsafe { C.Shell_NotifyIconW(nim_add, voidptr(&nid)) }
	if added == 0 {
		// A NULL hIcon is not fatal (the shell picks a default), so only the
		// shell's own refusal is reported.
		return error('notification: the shell refused the notification (is the ' +
			'notification area available in this session?)')
	}
	spawn remove_after(ctx.parent, opts.timeout_ms)
}
