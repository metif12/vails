// tray_windows.c.v - Windows backend of the tray service: one persistent
// shell icon whose clicks come back through the window host seam (ADR-0017).
// Compiled on Windows ONLY (V `_windows` suffix rule).
//
// Two services now share the shell: the balloon (notification) is transient
// and removes its own icon on a worker, this one is persistent and stays until
// the app removes it. The shell identifies an icon by (hWnd, uId), so the uId
// below is the tray's own and must never be the balloon's - otherwise the
// balloon's cleanup would delete the tray's icon (ADR-0017).
//
// uCallbackMsg is the whole point: it is what makes the icon clickable at all,
// and it is the message webview/host.v subclasses the window for. A click
// arrives here, is classified in pure V (services/tray.v) and becomes
// tray:clicked - the first OS-initiated event in Vails.
module services

import webview

// tray_icon_id is this service's own icon id ('TRAY'). Distinct from
// notification_icon_id by necessity, not by taste.
const tray_icon_id = u32(0x54524159)

// The tray menu's own user32 calls. trayicon_windows.c.v already puts user32
// on the link line for this module, so there is no #flag here.
//
// SetForegroundWindow and PostMessageW are the shell's tray-menu contract (it
// is the same dance the notification-area samples document): the shell will not
// let a background process take the foreground on its own, so an app that shows
// a tray menu has to take it itself and hand it straight back with a WM_NULL.
// Skipping either half is how a tray menu flashes and closes.
fn C.SetForegroundWindow(window voidptr) int
fn C.PostMessageW(hwnd voidptr, msg u32, wparam u64, lparam i64) int
fn C.TrackPopupMenuEx(menu voidptr, flags u32, x int, y int, hwnd voidptr, rect voidptr) int
fn C.GetCursorPos(pt voidptr) int

// Menu flags (tpm_returncmd, tpm_rightalign), the Point struct and the
// MenuBuilder are deliberately NOT redeclared here. Every .c.v of a module
// compiles into one translation unit and one namespace (ADR-0018 Notes), so a
// second copy of any of them is a "duplicate const"/"cannot register struct"
// error rather than a shadow. The menu service's copies are the ones this file
// uses, which is the point: one set of flag values and one builder for the
// popup, the window bar and the tray menu, so the three cannot drift.

// wm_null is the message that hands the foreground back after a tray menu. It
// has no equivalent name in the menu service, because the menu service is
// never the one taking the foreground.
const wm_null = u32(0x0000)

// set_tray_native installs or replaces the icon, and installs the window seam
// on the first call.
//
// The delete-then-add is not redundant: the shell keeps the previous hIcon when
// a notification omits NIF_ICON, so changing the icon path has to start from
// nothing, and a path that will not load has to be able to clear a good icon.
fn set_tray_native(mut st &TrayState, opts TrayOptions) ! {
	require_parent(st.ctx, 'tray.set')!
	// The seam is installed here, not by webview.run: an app that never shows a
	// tray icon gets no subclass on its window at all (ADR-0017).
	if st.hook == unsafe { nil } {
		// `owner`, not `st`: see webview.attach's "One caller-side rule".
		owner := st
		hook := webview.attach(st.ctx, fn [owner] (e webview.HostEvent) !bool {
			return on_host_message(owner, e)!
		}) or {
			return error('tray: could not hook the window for tray clicks: ' +
				err.msg())
		}
		st.hook = hook
	}
	icon_remove(st.ctx.parent, tray_icon_id)
	mut nid := NotifyIconData{
		cb_size:        u32(sizeof(NotifyIconData))
		hwnd:           st.ctx.parent
		uid:            tray_icon_id
		// NIF_MESSAGE is what makes the icon clickable, and its value is the
		// seam's message: a click the frontend never hears about would be an
		// icon that looks alive and is not.
		u_flags:        nif_message | nif_icon | nif_tip
		u_callback_msg: webview.host_message
		h_icon:         load_icon(opts.icon)
	}
	set_wide_field(nid.sz_tip, if opts.tooltip == '' { 'Vails' } else { opts.tooltip })
	if icon_add(&nid) == 0 {
		return error('tray: the shell refused the icon (is the notification area ' +
			'available in this session?)')
	}
	// Every add, not just the first: the shell forgets the version when the
	// icon is replaced, and tray.set is a "set or replace" command.
	icon_set_version(st.ctx.parent, tray_icon_id)
	st.set = true
}

// set_tray_menu_native attaches a menu to the tray icon.
//
// The menu is shown on demand rather than stored for the shell to show, which
// is the Windows shape: the shell has no idea what a tray icon's menu contains,
// so the app gets the click and shows the menu itself. The WAMY message
// (WM_CONTEXTMENU with the shell's magic wParam) is what arrives for that, and
// on_host_message declines it so it is not also reported as tray:clicked — that
// half of the contract is pure V, in tray_menu_click.
//
// The menu is built with the menu service's own build_menu, which is why the
// three menus in Vails cannot disagree about an item's command id, its depth
// limit or what a separator is.
fn set_tray_menu_native(mut st &TrayState, items []MenuItem) ! {
	require_parent(st.ctx, 'tray.set_menu')!
	// Replace first, unconditionally: an empty list then means "remove" through
	// exactly the same path, rather than being a special case that can drift.
	free_tray_menu(mut st)
	if items.len == 0 {
		return
	}
	root := unsafe { C.CreatePopupMenu() }
	if root == unsafe { nil } {
		return error('tray.set_menu: CreatePopupMenu failed')
	}
	mut b := &MenuBuilder{}
	build_menu(mut b, root, items)
	st.menu_ids = b.ids
	st.menu_handle = root
	st.menu = true
}

// free_tray_menu detaches and destroys the icon's menu. Split out because both
// "replace it" and "the icon is going away" need it, and DestroyMenu on a
// pointer the shell might still be showing is the bug this avoids.
fn free_tray_menu(mut st &TrayState) {
	if st.menu_handle != unsafe { nil } {
		unsafe {
			C.DestroyMenu(st.menu_handle)
		}
	}
	st.menu_handle = unsafe { nil }
	st.menu_ids = []
	st.menu_context = unsafe { nil }
	st.menu = false
}

// destroy_tray_native removes the icon and unhooks the window. The order is
// fixed: the menu and the icon go first, so no click can arrive for a tray that
// is gone, and only then does the window stop routing messages to a service
// that no longer has an icon.
fn destroy_tray_native(mut st &TrayState) ! {
	if st.hook != unsafe { nil } {
		mut hook := st.hook
		st.hook = unsafe { nil }
		webview.detach(mut hook)
	}
	if !st.set {
		return
	}
	require_parent(st.ctx, 'tray.destroy')!
	free_tray_menu(mut st)
	icon_remove(st.ctx.parent, tray_icon_id)
	st.set = false
}

// simulate_click_native posts the message the shell posts on a click, so the
// whole path can be proven without a mouse (see simulate_click's doc). The
// post is asynchronous by nature: the page sees tray:clicked a moment later,
// through the same seam a real click would use.
fn simulate_click_native(st &TrayState, button string) ! {
	require_parent(st.ctx, 'simulate_click')!
	if !st.set {
		return error('tray: no icon is installed, so there is nothing to click ' +
			'(call tray.set first)')
	}
	webview.post_message(st.ctx, webview.host_message, 0, button_lparam(button))!
}

// show_tray_menu_native is the Windows tray-menu dance, in the order the shell
// requires it:
//
//  1. take the foreground — the shell will not let a background app show a
//     tray menu, because a menu that appeared without the user activating the
//     app first could be used to steal keystrokes;
//  2. TrackPopupMenuEx at the cursor, with TPM_RETURNCMD so the chosen id comes
//     back from the call and no WM_COMMAND has to be routed anywhere;
//  3. post WM_NULL to our own window — the documented way to give the
//     foreground back. Skipping it leaves the app foregrounded, which is the
//     classic symptom of a tray menu that "sticks".
//
// The chosen id is a 1-based position in the menu's flat id table, so it maps
// back to the frontend's string exactly the way a popup's does.
fn show_tray_menu_native(st &TrayState, e webview.HostEvent) ! {
	handle := st.menu_handle
	if handle == unsafe { nil } {
		return
	}
	_ = e
	mut pt := Point{}
	mut rc := 0
	unsafe {
		C.GetCursorPos(voidptr(&pt))
		// The WAMY message carries screen coordinates in lParam; the cursor is
		// the same place in practice and is what every shell sample uses, and it
		// is also right when the click was synthesised (simulate_click), which
		// has no meaningful coordinates.
		C.SetForegroundWindow(st.ctx.parent)
		rc = C.TrackPopupMenuEx(handle, tpm_returncmd | tpm_rightalign, pt.x, pt.y,
			st.ctx.parent, unsafe { nil })
		C.PostMessageW(st.ctx.parent, wm_null, 0, 0)
	}
	if rc <= 0 || rc > st.menu_ids.len {
		// 0 is a dismissal, which is an answer and not a failure. There is no
		// tray:canceled event to send it on: the tray never had one, and a menu
		// the user closed is not an error any more than a popup the user closed
		// is.
		return
	}
	emit_menu_clicked(st.ctx, st.menu_ids[rc - 1])!
}
