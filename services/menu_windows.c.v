// menu_windows.c.v - Windows backend of the menu service: a real HMENU shown
// with TrackPopupMenuEx. Compiled on Windows ONLY (V `_windows` suffix rule).
//
// Flat user32 calls, no shim: the same reason dialog's MessageBoxW half needed
// only user32 and clipboard needed only user32 (ADR-0015). A menu is a menu
// here, not a wrapped COM object.
//
// The one decision worth reading: TPM_RETURNCMD. Without it the chosen
// command id arrives as a WM_COMMAND message on the window - and the window is
// the webview library's, with no menu handler installed, because a popup needs
// no window procedure (ADR-0017). With it, the id comes back from the call and
// no message is involved at all. TPM_NONOTIFY is set for the same reason: we
// do not want a WM_COMMAND either.
//
// The window menu bar is the opposite case and cannot use any of that. A bar is
// attached to the window with SetMenu and has no call to return a value from,
// so WM_COMMAND is the only way its answer arrives — which is why the bar needs
// the host seam that the popup does not (ADR-0023).
module services

import webview

#flag windows -luser32

fn C.CreatePopupMenu() voidptr
fn C.CreateMenu() voidptr
fn C.DestroyMenu(menu voidptr) int
fn C.SetMenu(window voidptr, menu voidptr) voidptr
fn C.DrawMenuBar(window voidptr) int
fn C.AppendMenuW(menu voidptr, flags u32, id_or_submenu voidptr, text &u16) int
fn C.TrackPopupMenuEx(menu voidptr, flags u32, x int, y int, hwnd voidptr, rect voidptr) int
fn C.GetCursorPos(pt voidptr) int

// Menu flags, redeclared as literals (AGENTS.md §2) so a wrong flag set is a
// visible diff. MF_STRING is 0, which is why the other three are the only ones
// that change an item's meaning.
const mf_string = u32(0x0000)
const mf_gray = u32(0x0001)
const mf_popup = u32(0x0010)
const mf_separator = u32(0x0800)

// TrackPopupMenuEx flags. TPM_RETURNCMD is the load-bearing one; TPM_RIGHTALIGN
// is what makes it behave like a context menu (items grow to the left of the
// point), and TPM_NONOTIFY suppresses the WM_COMMAND we do not handle.
const tpm_rightalign = u32(0x0008)
const tpm_nonotify = u32(0x0080)
const tpm_returncmd = u32(0x0100)

// WM_CANCELMODE is the only way out of a modal menu loop: posting it to the
// owner dismisses the menu, and TrackPopupMenuEx's nested loop processes it.
// This is what `menu.close` does, and it is why close is a post rather than a
// call (the thread is inside the menu).
const wm_cancelmode = u32(0x001F)

// Point is a Win32 POINT, for GetCursorPos. Declared here rather than included
// because a V struct is a V struct: two fields, no headers needed.
struct Point {
mut:
	x i32
	y i32
}

// MenuBuilder carries the flat id list next to the menu being built. The
// command id of an item IS its 1-based position in that list, so the mapping
// back from TrackPopupMenuEx's return value is an index and nothing else -
// no hash map, no lookup by string, no per-item handle to keep alive.
//
// Passed by pointer: a `mut MenuBuilder` parameter is a *copy* in V, so
// appending to its slice field would grow the callee's list and leave the
// caller's empty (the first version of this file had exactly that bug).
struct MenuBuilder {
mut:
	ids []string
}

// build_menu turns the item tree into an HMENU, appending into parent and
// recording ids in order. Depth is not passed on purpose: validate_items has
// already rejected anything deeper than max_menu_depth, so the recursion here
// is bounded by the data that was checked.
fn build_menu(mut b &MenuBuilder, parent voidptr, items []MenuItem) {
	for item in items {
		if item.separator {
			// id 0 with MF_SEPARATOR is the documented way to write a
			// separator; MF_SEPARATOR alone would make AppendMenuW read the
			// null text pointer.
			unsafe {
				C.AppendMenuW(parent, mf_separator, unsafe { nil }, unsafe { nil })
			}
			continue
		}
		b.ids << item.id
		if item.children.len > 0 {
			// A submenu is a nested popup whose "command id" is the nested
			// HMENU. The parent keeps its own id in the list, so menu:clicked
			// can name the submenu as well as a leaf.
			sub := unsafe { C.CreatePopupMenu() }
			build_menu(mut b, sub, item.children)
			append_item(parent, mf_popup, sub, item.label)
			continue
		}
		mut flags := mf_string
		if !item.enabled {
			flags |= mf_gray
		}
		append_item(parent, flags, voidptr(u64(b.ids.len)), item.label)
	}
}

// append_item appends one item with its text, and frees the temporary UTF-16
// buffer afterwards. AppendMenuW copies the text into the menu, so the
// allocation is ours to release - string.to_wide() mallocs, and a menu that
// leaks a few hundred bytes per open would be the one native resource in this
// codebase nobody looks at (the balloon has the same shape, once a minute
// instead of once a click).
fn append_item(parent voidptr, flags u32, id_ptr voidptr, label string) {
	wide := label.to_wide()
	unsafe {
		C.AppendMenuW(parent, flags, id_ptr, wide)
		free(wide)
	}
}

// popup_native shows the menu and pushes the answer as an event.
//
// The whole call is inside the nested loop TrackPopupMenuEx runs, so the emit
// happens *before* the command's promise resolves on Windows, and after it on
// Linux. Nothing in the contract depends on that order (the frontend reacts to
// two independent signals), but it is the kind of thing worth writing down.
fn popup_native(mut st &MenuState, items []MenuItem) ! {
	require_parent(st.ctx, 'menu.popup')!
	root := unsafe { C.CreatePopupMenu() }
	if root == unsafe { nil } {
		return error('menu: CreatePopupMenu failed')
	}
	mut b := &MenuBuilder{}
	build_menu(mut b, root, items)
	// A popup needs the owner window or the user cannot dismiss it by clicking
	// away, and it has no position of its own: the cursor is what a right-click
	// context menu means.
	mut pt := Point{}
	unsafe {
		C.GetCursorPos(voidptr(&pt))
	}
	// st.open is set before the blocking call and cleared after it, so a
	// `menu.close` that arrives *during* the loop has something to read: the
	// nested loop does dispatch the bridge, so a frontend can call it.
	st.open = true
	rc := unsafe {
		C.TrackPopupMenuEx(root, tpm_returncmd | tpm_nonotify | tpm_rightalign,
			pt.x, pt.y, st.ctx.parent, unsafe { nil })
	}
	st.open = false
	unsafe {
		C.DestroyMenu(root)
	}
	if rc <= 0 || rc > b.ids.len {
		// 0 is a dismissal, which is a result and not a failure; anything
		// outside the id range means the menu was not ours.
		emit_canceled(st) or {
			return error('menu: the menu was dismissed but the event failed: ' +
				err.msg())
		}
		return
	}
	emit_clicked(st, b.ids[rc - 1]) or {
		return error('menu: the menu was answered but the event failed: ' + err.msg())
	}
}

// close_native ends the modal menu by posting WM_CANCELMODE to the owner. A
// post, not a call: while a menu is up, this thread is inside the menu's own
// loop, and the only thing that can dismiss it from outside is a message.
fn close_native(mut st &MenuState) ! {
	if !st.open {
		return
	}
	require_parent(st.ctx, 'menu.close')!
	webview.post_message(st.ctx, wm_cancelmode, 0, 0)!
}

// set_menu_native attaches a menu bar to the window.
//
// The bar replaces any previous one, and the old HMENU is destroyed here rather
// than left to the garbage collector: SetMenu hands the window a pointer and
// keeps using it, so a bar that is still attached when we free it would leave
// the window drawing freed memory. SetMenu returns the PREVIOUS menu, which is
// the only way to get at the one being replaced — GetMenu would tell us what is
// attached but not what was there before this call.
fn set_menu_native(mut st &MenuState, items []MenuItem) ! {
	require_parent(st.ctx, 'menu.set_menu')!
	// An empty list removes the bar. CreateMenu always succeeds, so the branch
	// is on the items and not on a NULL handle.
	if items.len == 0 {
		if st.bar_handle != unsafe { nil } {
			old := C.SetMenu(st.ctx.parent, unsafe { nil })
			C.DrawMenuBar(st.ctx.parent)
			if old != unsafe { nil } {
				C.DestroyMenu(old)
			}
			st.bar_handle = unsafe { nil }
			st.bar_ids = []
			drop_bar_hook(mut st)
		}
		return
	}
	root := unsafe { C.CreateMenu() }
	if root == unsafe { nil } {
		return error('menu.set_menu: CreateMenu failed')
	}
	mut b := &MenuBuilder{}
	build_menu(mut b, root, items)
	// The flat list is the id table: build_menu assigned each command id as
	// this item's 1-based position in it, and bar_click inverts exactly that.
	// Set BEFORE the bar goes on the window, so a WM_COMMAND cannot arrive
	// before the table that decodes it exists.
	st.bar_ids = b.ids
	previous := unsafe { C.SetMenu(st.ctx.parent, root) }
	if previous != unsafe { nil } {
		unsafe {
			C.DestroyMenu(previous)
		}
	}
	// Without this the bar does not appear until the next repaint, which on a
	// window that is already up looks like the command silently did nothing.
	unsafe {
		C.DrawMenuBar(st.ctx.parent)
	}
	st.bar_handle = root
	attach_bar_hook(mut st)
}

// drop_bar_hook removes the seam installed for the bar. Called when the bar
// goes away, because a hook with nothing to decode ids for would classify every
// WM_COMMAND as "not ours" forever — harmless but no longer the reason it exists.
fn drop_bar_hook(mut st &MenuState) {
	if st.bar_hook == unsafe { nil } {
		return
	}
	webview.detach(mut st.bar_hook)
	st.bar_hook = unsafe { nil }
}

// attach_bar_hook installs the window seam for the bar's WM_COMMAND, unless it
// is already installed (replacing the bar's items must not stack hooks).
//
// `owner` rather than `st` in the capture: V 0.5.2 types a closure capture of a
// `mut` pointer *parameter* as a pointer to the pointer and the generated C
// assignment is rejected by gcc. Same workaround as tray_backend, same reason.
fn attach_bar_hook(mut st &MenuState) {
	if st.bar_hook != unsafe { nil } {
		return
	}
	owner := st
	hook := webview.attach(st.ctx, fn [owner] (e webview.HostEvent) !bool {
		return on_bar_command(owner, e)!
	}) or {
		// A bar with no hook is a bar the user can click and nothing will
		// happen, which is worse than no bar at all, so the whole command
		// fails: the caller learns, and the frontend can fall back.
		eprintln('menu.set_menu: could not hook the window for menu commands: ' +
			err.msg())
		return
	}
	st.bar_hook = hook
}

// on_bar_command is the handler for the bar's seam. It consumes a WM_COMMAND
// only when bar_click recognises the id as one of ours; everything else returns
// false so the message reaches the next subclass in the chain and then the
// webview library, which must keep seeing the window's own WM_COMMANDs.
fn on_bar_command(st &MenuState, e webview.HostEvent) !bool {
	id := bar_click(e, st.bar_ids) or {
		return false
	}
	emit_clicked(st, id)!
	return true
}
