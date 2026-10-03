// trayicon_windows.c.v - the Windows shell-icon primitive, used by the tray
// service. Compiled on Windows ONLY (V `_windows` suffix rule).
//
// This file used to be shared by `notification` and `tray` (ADR-0017):
// ADR-0015 predicted the balloon would show which half of the shell-icon
// code is reusable, and it was right - the NOTIFYICONDATA layout, the
// wide-string field writer and the add/remove calls were one thing, and two
// services that each declared their own copy of the struct could not both
// compile in one module. ADR-0018 then replaced the balloon with a WinRT
// toast, so `tray` is the only user left and the file is simply its
// primitive. The uId contract below is unchanged and still worth reading
// before adding a second shell icon.
//
// The uId is the other half of the contract: Shell_NotifyIconW identifies an
// icon by (hWnd, uId), so two icons on the same window must use different
// uIds or one will overwrite the other and the loser's cleanup will delete
// the winner's icon.
module services

#include <windows.h>
#include <shellapi.h>
#flag windows -lshell32 -luser32

fn C.Shell_NotifyIconW(message u32, data voidptr) int
fn C.LoadIconW(hinstance voidptr, name &u16) voidptr
fn C.LoadImageW(hinstance voidptr, name &u16, type_ u32, cx int, cy int, flags u32) voidptr

// Shell messages and NOTIFYICONDATA flags, redeclared as literals
// (AGENTS.md §2) so a wrong flag set is a visible diff and not a macro
// surprise.
//
// Only what `tray` uses. The balloon flags (NIF_INFO) and the NIIF_*
// family belonged to `notification` until ADR-0018 replaced it with a WinRT
// toast, and are gone with it - this file is now the tray's primitive
// rather than a primitive two services happened to share.
const nim_add = u32(0x00000000)
const nim_delete = u32(0x00000002)
const nim_setversion = u32(0x00000004)
const nif_message = u32(0x00000001)
const nif_icon = u32(0x00000002)
const nif_tip = u32(0x00000004)

// NOTIFYICON_VERSION_4 is what a tray menu is built on. Before it is set, the
// shell sends a plain WM_RBUTTONUP and there is no way to ask "show a menu and
// tell me which item", because the shell cannot know the menu is ours. With it,
// the shell posts the "WAMY" message (WM_CONTEXTMENU with a magic wParam) and
// the app is expected to show its menu and hand it to the *foreground* window's
// thread — see set_tray_menu_native. So the icon has to be told which version it
// speaks, once, after it is added and on every add after that.
const notifyicon_version_4 = u32(0x00000004)

// Stock icons, as MAKEINTRESOURCE ids. IDI_APPLICATION is the tray's
// fallback, so the service needs no asset to ship (app icons are a Phase 7
// concern).
const idi_application = 32515

// LoadImage types/flags, for the tray's icon-from-a-path case.
const image_icon = u32(1)
const lr_loadfromfile = u32(0x00000010)
const lr_defaultsize = u32(0x00000040)

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

// set_wide_field copies text into one of the struct's fixed-width wide fields,
// NUL-terminated and truncated to fit. Truncation (not rejection) is
// deliberate: the shell field is 128 units for the tooltip, and a frontend
// sending a longer string should get a shown icon with a clipped tail rather
// than an error.
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

// shell_notify is the one Shell_NotifyIconW call this service makes. The
// return value is the shell's own refusal flag: 0 means the shell would not
// take the icon, which is a real failure with a real reason (no notification
// area in this session, for instance).
fn shell_notify(message u32, nid &NotifyIconData) int {
	return unsafe { C.Shell_NotifyIconW(message, voidptr(nid)) }
}

// icon_remove deletes the icon. It is the cleanup half of `tray.destroy`.
fn icon_remove(hwnd voidptr, uid u32) {
	nid := NotifyIconData{
		cb_size: u32(sizeof(NotifyIconData))
		hwnd:    hwnd
		uid:     uid
	}
	shell_notify(nim_delete, &nid)
}

// icon_add installs (or replaces) the icon. The caller has filled uFlags and
// the fields it cares about; a 0 return is the shell's refusal.
fn icon_add(nid &NotifyIconData) int {
	return shell_notify(nim_add, nid)
}

// icon_set_version tells the shell which message protocol this icon speaks, and
// it only means anything after the icon exists, so it is a separate call on
// purpose. Version 4 is what buys the WAMY/WM_CONTEXTMENU path a tray menu
// needs; without it the shell would send a bare WM_RBUTTONUP that carries no way
// to say "this right click was for a menu".
//
// A refusal is not reported: NIM_SETVERSION fails when the icon is not present
// (a race with tray.destroy) or on a shell too old to have versions, and
// neither is a reason to fail the caller's command. The consequence of a
// refusal is only that a right click arrives as WM_RBUTTONUP, which the tray
// already handles as a click — so the service degrades to its old behaviour
// rather than breaking.
fn icon_set_version(hwnd voidptr, uid u32) {
	// u_timeout is NOTIFYICONDATA's uTimeout/uVersion union: the same four
	// bytes mean a timeout for NIM_MODIFY and a protocol version for
	// NIM_SETVERSION. The field is named for the use the tray never has (a
	// balloon timeout went away with ADR-0018), so reusing it here is free.
	nid := NotifyIconData{
		cb_size:   u32(sizeof(NotifyIconData))
		hwnd:      hwnd
		uid:       uid
		u_timeout: notifyicon_version_4
	}
	shell_notify(nim_setversion, &nid)
}

// load_icon resolves an icon for the tray: the frontend's file when it named
// one, the stock application icon when it did not. A path that will not load
// falls back to the stock icon rather than failing the command - a missing
// icon file is a cosmetic problem, and a tray that refuses to appear is a
// functional one. The fallback is why this function cannot fail.
fn load_icon(path string) voidptr {
	if path != '' {
		wide := path.to_wide()
		unsafe {
			h := C.LoadImageW(unsafe { nil }, wide, image_icon, 0, 0,
				lr_loadfromfile | lr_defaultsize)
			free(wide)
			if h != unsafe { nil } {
				return h
			}
		}
	}
	return unsafe { C.LoadIconW(unsafe { nil }, make_int_resource(idi_application)) }
}
