// menu_linux.c.v - Linux backend of the menu service: a GtkMenu shown with
// gtk_menu_popup_at_rect. Compiled on Linux ONLY (V `_linux` suffix rule).
//
// The C->V direction is per-object here, which is the asymmetry ADR-0017
// records: there is no window procedure to hook on Linux, because the GTK
// object that produced the click is the one that signals it. So the menu's
// own items carry the answer - one "activate" connection per item, in
// build_menu, where the item widget exists - and one "deactivate" connection
// on the menu turns a dismissal into menu:canceled.
//
// Two things in ADR-0017's version of this file were wrong about GTK3 and had
// to be corrected before any of it worked; the details are in
// tests/e2e_linux/README.md, but the shape of both is worth knowing here:
//
//   - "item-activated" is a GTK2 signal. GtkMenu in 3.24 has NO signals of its
//     own; "activate" belongs to GtkMenuItem. Connecting to the former logs
//     "signal 'item-activated' is invalid for instance ... of type 'GtkMenu'"
//     and the menu never reports a choice.
//   - gtk_menu_popdown does NOT emit "deactivate". The teardown therefore
//     cannot live in that handler alone, or `menu.close` silently does nothing
//     and leaks; it is the shared teardown() that both callers use.
//
// Ordering inside GTK is the remaining trap: activating an item emits
// "activate" *and then* "deactivate", so a "chosen" flag is what tells the two
// apart.
module services

#include <gtk/gtk.h>
#pkgconfig gtk+-3.0

// The GTK and GLib functions below are all declared by <gtk/gtk.h>, which is
// included above, so V finds their prototypes on its own and no @[c_extern] is
// needed. Marking one of them @[c_extern] anyway is not harmless: V then emits
// its own prototype ahead of the header's, and the two disagree on const
// (gobject.h spells the key `const gchar *`), which is a "conflicting types
// for 'g_object_set_data'" error, not a fix.
//
// GTK3 is also why there is no `gtk_menu_item_set_sensitive` here (sensitivity
// is a GtkWidget property now, set through `gtk_widget_set_sensitive`) and no
// `g_object_set_int`/`g_object_get_int` (the GObject typed accessors were
// macros, and a macro is not a symbol, so it can be neither declared nor
// linked - `nm -D` on libgobject-2.0 finds no such symbol).
fn C.gtk_menu_new() voidptr
fn C.gtk_menu_bar_new() voidptr
// gtk_bin_get_child, not gtk_box_get: a GtkWindow is a GtkBin, and there is no
// gtk_box_get — the window is not a box and never was in GTK3. The backend's
// layout (webview_linux.c.v) puts a GtkBox in the window, so the bin's child IS
// that box.
fn C.gtk_bin_get_child(bin voidptr) voidptr
fn C.gtk_box_pack_start(box voidptr, child voidptr, expand bool, fill bool, padding int)
fn C.gtk_box_reorder_child(box voidptr, child voidptr, position int)
fn C.gtk_menu_item_new_with_label(label &char) voidptr
fn C.gtk_separator_menu_item_new() voidptr
fn C.gtk_menu_item_set_submenu(item voidptr, submenu voidptr)
fn C.gtk_menu_shell_append(shell voidptr, child voidptr)
fn C.gtk_menu_popup_at_rect(menu voidptr, rect_window voidptr, rect voidptr, rect_anchor int, menu_anchor int, trigger_event voidptr)

fn C.gtk_menu_popdown(shell voidptr)
fn C.gtk_widget_set_sensitive(widget voidptr, sensitive int)
fn C.gtk_widget_show_all(widget voidptr)
fn C.gtk_widget_destroy(widget voidptr)

// GCallback mirrors glib's GCallback: a plain C function pointer taking the
// three arguments every GObject signal passes. It is declared here because V
// has no callback type of its own and `g_signal_connect_data`'s third parameter
// is one. Declaring the parameter as `voidptr` instead "works" only because V's
// default C flags include -w, which hides gcc's "incompatible pointer type"
// error — and it stops being hidden the moment the fallback compiler runs
// without -w, which is exactly how this surfaced.
type GCallback = fn (a voidptr, b voidptr, c voidptr)

fn C.g_signal_connect_data(instance voidptr, signal &char, handler GCallback, data voidptr, destroy_data voidptr, connect_flags int) u64

// GdkRectangle is the plain struct gtk_menu_popup_at_rect takes a pointer to.
// Declared here rather than pulled from gdk/gdk.h for the same reason
// opener_linux.c.v redeclares GError: one four-int struct is not worth a header
// chain that every test file in this module would recompile. The declaration is
// placed after the function that uses it so the prototype list above stays one
// block.
struct GdkRectangle {
	x      int
	y      int
	width  int
	height int
}

// The pointer, for a popup that lands where the user is pointing. GDK can
// report that without V constructing a GdkEvent, which is the one thing V
// cannot do; without this the menu would open in the corner of the window
// instead of under the cursor. Windows gets the same placement for free from
// GetCursorPos (menu_windows.c.v), so this is the parity path, not a nicety.
fn C.gdk_display_get_default() voidptr
fn C.gdk_display_get_default_seat(display voidptr) voidptr
fn C.gdk_seat_get_pointer(seat voidptr) voidptr
fn C.gdk_device_get_position(device voidptr, screen voidptr, x voidptr, y voidptr)
fn C.g_object_set_data(object voidptr, key &char, data voidptr)
fn C.g_object_get_data(object voidptr, key &char) voidptr

// index_key is the GObject data key under which each item widget carries its
// 1-based position in the flat id list. A pointer under a key, not an int, so
// nothing here has a lifetime to manage: GObject stores the pointer verbatim
// and g_object_get_data hands it straight back. GTK3 removed the typed
// g_object_set_int accessors, so this is the smallest thing that works.
const index_key = 'vails-menu-index'

// GdkGravity for the popup anchor, as literals (AGENTS.md §2). The GdkGravity
// enum is a plain int and NORTH_WEST is its first member, so the value is 1.
const gdk_gravity_north_west = 1

// MenuBuilder is what building a menu needs, independent of what the menu is
// FOR. Two callers share it — a popup (LinuxPopup) and the window bar
// (LinuxBar) — and they differ only in the callback they connect and the data
// it travels in, so those are fields rather than parameters.
//
// ids is the flat list in the same order the Windows backend assigns command
// ids, which is what lets one id contract serve both platforms (menu.v's
// flatten_items).
struct MenuBuilder {
mut:
	st  &MenuState
	ids []string
	// on_click is the GObject callback for an item's "activate" and data is the
	// pointer handed to it. Both are plain voidptrs on purpose:
	// g_signal_connect_data wants a C function pointer, so neither can be a V
	// closure and the state has to travel through the data pointer.
	on_click GCallback
	data     voidptr
}

// LinuxPopup is the state behind one open menu. Allocated per popup and freed
// exactly once by teardown, whichever path gets there first.
struct LinuxPopup {
mut:
	// b is embedded rather than sitting beside the struct so there is exactly
	// one id list per menu, whoever built it.
	b    MenuBuilder
	menu voidptr
	// chosen is set by the item's activate handler so the teardown that
	// follows can tell a selection from a dismissal.
	chosen bool
	// torn_down guards the teardown against running twice. It has to: a user
	// dismissal and an explicit `menu.close` can both reach teardown, and a
	// second free() on the same context is a double free, not a no-op.
	torn_down bool
}

// LinuxBar is the state behind the window's menu bar. Unlike a popup the
// platform never tears it down, so it lives as long as the bar does and is
// freed when the bar is replaced or removed.
struct LinuxBar {
mut:
	b   MenuBuilder
	bar voidptr
}

// build_menu appends items to shell, stamping each with its flat index. The
// index is 1-based because 0 means "no index" and every id must map back.
fn build_menu(mut b &MenuBuilder, shell voidptr, items []MenuItem) {
	for item in items {
		if item.separator {
			sep := unsafe { C.gtk_separator_menu_item_new() }
			unsafe {
				C.gtk_menu_shell_append(shell, sep)
			}
			continue
		}
		widget := unsafe { C.gtk_menu_item_new_with_label(item.label.str) }
		if !item.enabled {
			unsafe {
				C.gtk_widget_set_sensitive(widget, 0)
			}
		}
		b.ids << item.id
		unsafe {
			C.g_object_set_data(widget, index_key.str, voidptr(u64(b.ids.len)))
			// One connection PER ITEM, because "activate" is a GtkMenuItem
			// signal in GTK3 (see item_activated). A separator has no activate
			// and no id, so it is skipped - connecting to it would fail the same
			// way item-activated did.
			C.g_signal_connect_data(widget, c'activate', b.on_click, b.data,
				unsafe { nil }, 0)
		}
		if item.children.len > 0 {
			sub := unsafe { C.gtk_menu_new() }
			unsafe {
				C.gtk_menu_item_set_submenu(widget, sub)
			}
			build_menu(mut b, sub, item.children)
		}
		unsafe {
			C.gtk_menu_shell_append(shell, widget)
		}
	}
}

// item_activated is a popup item's "activate": (item, user_data).
// A GObject signal handler always receives the emitting instance first
// (ADR-0015 Notes - the same trap as script-message-received), and that is
// fortunate here: the item widget is exactly the object carrying the index.
//
// Plain top-level fn, no captures, because g_signal_connect_data wants a C
// function pointer; the LinuxPopup travels in the data pointer and C never
// dereferences it.
//
// "activate" is per ITEM in GTK3, not per menu. ADR-0017 assumed one
// "item-activated" connection on the GtkMenu, and that signal is a GTK2 leftover:
// `g_signal_list_ids` on GtkMenu returns zero signals in 3.24, and connecting to
// it yields "signal 'item-activated' is invalid for instance ... of type
// 'GtkMenu'" at runtime. GtkMenuItem is the type that has "activate", so that is
// what is connected, once per item, in build_menu. The index stamp on the
// widget is what keeps the mapping honest.
fn item_activated(item voidptr, data voidptr) {
	mut pop := unsafe { &LinuxPopup(data) }
	pop.chosen = true
	// A 0 readback means the stamp is absent, not that the item is first: a
	// GTK-internal item has no stamp at all, and treating that as index 0 would
	// report a choice the app never offered.
	raw := unsafe { C.g_object_get_data(item, index_key.str) }
	idx := int(u64(raw))
	if idx <= 0 || idx > pop.b.ids.len {
		// A stamp we did not write: a GTK-internal item. Ignoring it is right,
		// and a wrong id would be worse than none.
		return
	}
	// An emit that fails has no second channel to report itself on, and the
	// menu is torn down either way. The frontend notices as a menu that never
	// answers, which is the honest shape of "the answer could not be pushed".
	emit_clicked(pop.b.st, pop.b.ids[idx - 1]) or { return }
}

// teardown is the single owner of the popup's lifetime: it emits the final
// event, destroys the menu, clears the state and frees the context.
//
// It has to be shared, because ADR-0017 assumed `gtk_menu_popdown` ends the
// grab by making GTK emit "deactivate" and left the teardown to that handler.
// It does not. Verified on GTK 3.24: popdown hides the menu and the deactivate
// handler never runs (deactivated == 0), so with the teardown living only in
// the handler a `menu.close` emitted no event, left st.open true and leaked the
// context. Now both callers - the handler and menu.close - come here.
//
// Destroying the menu before freeing the context is what makes the double-entry
// safe: gtk_widget_destroy disconnects every handler this file connected, so no
// GTK callback can reach a freed LinuxPopup afterwards.
fn teardown(mut pop &LinuxPopup, canceled bool) {
	if pop.torn_down {
		return
	}
	pop.torn_down = true
	if canceled {
		// An emit that fails has no second channel: the frontend sees a menu
		// that never answers, which is the honest shape of a dropped answer.
		emit_canceled(pop.b.st) or {}
	}
	unsafe {
		C.gtk_widget_destroy(pop.menu)
	}
	pop.b.st.handle = unsafe { nil }
	pop.b.st.open = false
	pop.b.st.context = unsafe { nil }
	unsafe {
		free(pop)
	}
}

// menu_deactivated is GtkMenuShell's "deactivate" signal, which is what GTK
// emits when a grab ends without a choice (Escape, a click elsewhere). It runs
// after an activation too, so `chosen` decides between the two answers.
fn menu_deactivated(_shell voidptr, data voidptr) {
	mut pop := unsafe { &LinuxPopup(data) }
	teardown(mut pop, !pop.chosen)
}

// pointer_pos is where the popup opens. It walks display -> seat -> pointer
// device because that is the only chain GDK offers that ends in coordinates, and
// each link can legitimately be nil (no display under a headless session, no
// seat on an old GDK), so every step is checked rather than assumed. The
// fallback is (0, 0): a menu in the corner is a usable menu, and refusing to
// open one would be worse.
fn pointer_pos() GdkRectangle {
	mut x := 0
	mut y := 0
	unsafe {
		display := C.gdk_display_get_default()
		if display != unsafe { nil } {
			seat := C.gdk_display_get_default_seat(display)
			if seat != unsafe { nil } {
				device := C.gdk_seat_get_pointer(seat)
				if device != unsafe { nil } {
					mut sx := 0
					mut sy := 0
					C.gdk_device_get_position(device, unsafe { nil }, voidptr(&sx),
						voidptr(&sy))
					x = sx
					y = sy
				}
			}
		}
	}
	return GdkRectangle{
		x:      x
		y:      y
		width:  1
		height: 1
	}
}

// popdown hides the open popup and tears it down. An explicit close IS a
// dismissal - the same answer Windows gives, where menu.close posts WM_CANCELMODE
// and TrackPopupMenuEx returns 0 - so it reports menu:canceled and then goes
// through the shared teardown.
fn popdown(st &MenuState) {
	handle := st.handle
	if handle == unsafe { nil } {
		return
	}
	unsafe {
		C.gtk_menu_popdown(handle)
	}
	if st.context != unsafe { nil } {
		mut pop := unsafe { &LinuxPopup(st.context) }
		teardown(mut pop, true)
	}
}

// popup_native shows the menu. Everything the answer needs is allocated here
// and released by the deactivate handler; the V function returns as soon as
// the menu is on screen, which is why `menu.popup` is not a blocking command
// on Linux even though the manifest marks it (the flag describes the strictest
// platform - see menu_manifest).
fn popup_native(mut st &MenuState, items []MenuItem) ! {
	require_parent(st.ctx, 'menu.popup')!
	if st.open {
		// Two popups at once would leave the first context to be freed by the
		// second's teardown, so the old one goes first. Same rule as a modal
		// dialog: one at a time.
		popdown(st)
	}
	menu := unsafe { C.gtk_menu_new() }
	if menu == unsafe { nil } {
		return error('menu: gtk_menu_new failed')
	}
	// Allocated, then wired: the items' "activate" callback travels in the data
	// pointer, and that pointer is the address of this struct — which is not
	// known until the allocation has happened. `st` is a reference field, so V
	// requires it in the literal rather than assigned after.
	mut pop := &LinuxPopup{
		b:    MenuBuilder{
			st:       st
			on_click: unsafe { GCallback(item_activated) }
		}
		menu: menu
	}
	pop.b.data = voidptr(pop)
	mut b := &pop.b
	build_menu(mut b, menu, items)
	unsafe {
		// Only the teardown signal is connected on the menu itself; the
		// per-item "activate" connections were made in build_menu, because
		// that is where the GtkMenuItem widget exists.
		C.g_signal_connect_data(menu, c'deactivate', GCallback(menu_deactivated),
			voidptr(pop), unsafe { nil }, 0)
		C.gtk_widget_show_all(menu)
		// at_rect against the window's own GdkWindow, NOT at_pointer. ADR-0017
		// used at_pointer with a NULL event and called it "the whole Linux
		// answer"; it is not. With no event GTK has no trigger window, and it
		// logs "no trigger event for menu popup" followed by "gtk_menu_popup_at_
		// rect: assertion 'GDK_IS_WINDOW (rect_window)' failed" and then shows
		// nothing - the menu is created, never mapped, and the frontend waits
		// forever. at_pointer is only usable from inside a real event handler,
		// which a service command is not.
		//
		// at_rect takes the GdkWindow to anchor in, and Ctx.parent already is
		// exactly that (webview_linux.c.v fills it with
		// gtk_widget_get_window). V cannot construct a GdkEvent - hence a rect,
		// not a point - and the rect is placed at the pointer, which is the same
		// placement Windows gets from GetCursorPos. Falls back to the window's
		// own origin when the pointer cannot be read, so a headless session
		// still gets a menu instead of nothing.
		rect := pointer_pos()
		C.gtk_menu_popup_at_rect(menu, st.ctx.parent, voidptr(&rect),
			gdk_gravity_north_west, gdk_gravity_north_west, unsafe { nil })
	}
	st.handle = menu
	st.open = true
	st.context = voidptr(pop)
}

// close_native ends the open popup. A no-op when nothing is open, because a
// frontend that closes defensively must not get an error for it.
fn close_native(mut st &MenuState) ! {
	if !st.open {
		return
	}
	popdown(st)
}

// set_menu_native attaches a menu bar to the window, replacing any bar already
// there.
//
// GTK3 has no gtk_window_set_menubar: that was a GTK2 function and it is gone
// (only gtk_application_set_menubar remains, and that is a GtkApplication API
// for the app menu, not a window one). The GTK3 spelling is a menu bar packed
// into the window's box — which is why run_linux always puts the webview in a
// vertical box rather than straight into the window (webview_linux.c.v): a
// GtkWindow holds exactly one child, and that child has to be a container with
// room for a row the bar can occupy.
//
// It also cannot go in the box's usual place: the box was filled with the
// webview already, so the bar is packed and then moved to the top with
// gtk_box_reorder_child, or it would appear under the page.
fn set_menu_native(mut st &MenuState, items []MenuItem) ! {
	if !st.ctx.has_toplevel() {
		return error('menu.set_menu: no window to attach a menu bar to (pass the ' +
			'Ctx from Config.on_ready)')
	}
	// Remove first: replacing frees the old bar and its context, and doing it
	// unconditionally means "empty list" and "replace" are the same code path.
	free_bar(mut st)
	if items.len == 0 {
		return
	}
	box := unsafe { C.gtk_bin_get_child(st.ctx.toplevel) }
	if box == unsafe { nil } {
		// Not a box: the window's child is whatever the backend put there. The
		// message says what is missing rather than faulting inside GTK.
		return error('menu.set_menu: this window is not the box layout the Linux ' +
			'backend uses, so a menu bar has nowhere to go')
	}
	bar := unsafe { C.gtk_menu_bar_new() }
	if bar == unsafe { nil } {
		return error('menu.set_menu: gtk_menu_bar_new failed')
	}
	// `st` is a reference field, so it goes in the literal; `data` cannot,
	// because it is this struct's own address.
	mut state := &LinuxBar{
		b:   MenuBuilder{
			st:       st
			on_click: unsafe { GCallback(bar_item_activated) }
		}
		bar: bar
	}
	state.b.data = voidptr(state)
	mut b := &state.b
	build_menu(mut b, bar, items)
	unsafe {
		// Show the bar BEFORE packing it: a widget packed while unrealized gets
		// no size request until the box lays out, and the bar ends up 1px tall.
		C.gtk_widget_show_all(bar)
		C.gtk_box_pack_start(box, bar, false, false, 0)
		C.gtk_box_reorder_child(box, bar, 0)
	}
	// The id list lives on the shared state so the answer can be decoded, and
	// the context pointer keeps the LinuxBar alive for as long as the bar is.
	st.bar_handle = bar
	st.context = unsafe { nil }
	st.bar_ids = state.b.ids
	st.bar_context = voidptr(state)
}

// free_bar removes the window's menu bar and releases its context. A no-op when
// there is none, so `set_menu` with an empty list is how a bar is removed.
fn free_bar(mut st &MenuState) {
	if st.bar_context != unsafe { nil } {
		state := unsafe { &LinuxBar(st.bar_context) }
		unsafe {
			C.gtk_widget_destroy(state.bar)
			free(state)
		}
		st.bar_context = unsafe { nil }
	}
	st.bar_handle = unsafe { nil }
	st.bar_ids = []
}

// bar_item_activated is a bar item's "activate": (item, user_data). Same GTK3
// per-item signal as the popup's, and for the same reason — there is no
// menu-wide signal to hang this on — but the answer is simpler: a bar has no
// modal lifetime and no dismissal, so activating one just reports the choice.
fn bar_item_activated(item voidptr, data voidptr) {
	state := unsafe { &LinuxBar(data) }
	raw := unsafe { C.g_object_get_data(item, index_key.str) }
	idx := int(u64(raw))
	if idx <= 0 || idx > state.b.ids.len {
		// A stamp we did not write (a GTK-internal item). No id is better than
		// a wrong one.
		return
	}
	emit_clicked(state.b.st, state.b.ids[idx - 1]) or {}
}
