// tray_linux.c.v - Linux backend of the tray service: one StatusNotifierItem
// through libayatana-appindicator. Compiled on Linux ONLY (V `_linux` suffix
// rule).
//
// Why libayatana-appindicator and not GtkStatusIcon: GtkStatusIcon was
// deprecated in GTK 3.14 and implements the XEmbed tray protocol, which no
// current desktop provides. The AppIndicator protocol is what GNOME's
// extension, KDE's plasma and every current desktop actually speak - the same
// choice v3/pkg/services makes. It costs a new build dependency, so it is a
// `vails doctor` line and a README prereq rather than a surprise.
//
// What this backend cannot do, stated plainly: **there is no click event.**
// This version of the library has no "activate" signal (only new-icon,
// new-status, new-label, connection-changed and scroll-event), because on
// Linux the SNI *host* owns the click: pressing the item opens the menu the
// app attached to it. So tray:clicked is a Windows event, and a Linux app
// reacts to menu:clicked from the item's menu instead - which is why
// `tray.set_menu` (the tray handing the menu service's items to the indicator)
// is a Phase 5 S2 item, and why simulate_click refuses here with that reason
// instead of faking a gesture. The OS->V direction itself is not unproven on
// Linux: the bridge's script-message-received (ADR-0015) and the menu's
// item-activated (this wave) are both GObject signals reaching a V handler.
//
// The item also needs a D-Bus *session* bus to register on. Under
// `dbus-run-session` it registers; without one, GLib cannot autolaunch and the
// item is created but never appears. That is why the Linux E2E wraps the run
// in dbus-run-session and why a headless screenshot can only ever show the
// status line, never the icon (there is no StatusNotifierHost under Xvfb
// either). See the note in tests/e2e_linux/README.md.
module services

// The AppIndicator API is declared by hand rather than included, for the same
// reason opener_linux.c.v redeclares GError: the header drags in the
// dbusmenu/glib/indicator/ido headers with it, and this module's C is
// recompiled by every one of its test files - a header chain that costs a
// minute per test file is a real tax, paid for six functions whose signatures
// are stable. The pkgconfig line is still needed: it is what supplies the
// -layatana-appindicator3 link flag.
//
// The @[c_extern] attributes are load-bearing, and they are the whole reason
// this file failed to compile on Linux until 2026-09-28. V 0.5.2 emits a C
// prototype for `fn C.f` only when the declaring header is #include'd *or* the
// declaration is marked @[c_extern]. No AppIndicator header is included here
// (see above), so without the attribute V emitted nothing at all and gcc
// reported "implicit declaration of function 'app_indicator_new'" and friends.
// The GTK/GLib functions in this file are declared by the <gtk/gtk.h> below
// and so need no attribute.
#include <gtk/gtk.h>
#pkgconfig ayatana-appindicator3-0.1 gtk+-3.0

@[c_extern]
fn C.app_indicator_new(id &char, icon_name &char, category int) voidptr

@[c_extern]
fn C.app_indicator_set_status(self voidptr, status int)

@[c_extern]
fn C.app_indicator_set_label(self voidptr, label &char, guide &char)

@[c_extern]
fn C.app_indicator_set_title(self voidptr, title &char)

@[c_extern]
fn C.app_indicator_set_icon_full(self voidptr, icon_name &char, icon_desc &char)

fn C.g_object_unref(object voidptr)

// APP_INDICATOR_STATUS_ACTIVE (0) and APP_INDICATOR_CATEGORY_APPLICATION_STATUS
// (0), redeclared as literals (AGENTS.md §2). PASSIVE is the state a new
// indicator is born in, so a tray icon is invisible until the status is set -
// which is the single most common way to get "my tray icon does not show up".
const indicator_status_active = 0
const indicator_category_application_status = 0

// default_icon is a theme name, not a path: it is what the item shows when the
// frontend named no icon. Adwaita ships it, and a tray without an icon asset
// still has to have something to draw.
const default_icon = 'application-x-executable'

// item_id is the D-Bus object name for one window's item. It has to be unique
// per process, and the window label is the only per-window thing the service
// knows - which is also why two windows get two tray items rather than one
// fighting over the name.
fn item_id(st &TrayState) string {
	return 'vails-tray-' + st.ctx.label
}

// set_tray_native installs the item, replacing one this window installed
// earlier. Replacing rather than stacking matters: a leaked AppIndicator keeps
// its place in the panel forever, so a second tray.set on a loop would grow a
// column of dead icons - the same failure mode ADR-0015 recorded for the
// balloon, inverted, because here the resource outlives the process.
fn set_tray_native(mut st &TrayState, opts TrayOptions) ! {
	require_parent(st.ctx, 'tray.set')!
	if st.indicator != unsafe { nil } {
		unsafe {
			C.g_object_unref(st.indicator)
		}
		st.indicator = unsafe { nil }
		st.set = false
	}
	id := item_id(st)
	indicator := unsafe {
		C.app_indicator_new(id.str, default_icon.str, indicator_category_application_status)
	}
	if indicator == unsafe { nil } {
		return error('tray: the AppIndicator could not be created')
	}
	unsafe {
		C.app_indicator_set_status(indicator, indicator_status_active)
		// The label is the visible text next to the icon and the title is the
		// accessible name; the "-" guide is GTK's spelling of "no guide", and
		// it matters because a truncated label with a guide is a link.
		C.app_indicator_set_label(indicator, opts.tooltip.str, c'-')
		C.app_indicator_set_title(indicator, c'Vails')
		if opts.icon != '' {
			// A full path is accepted here, which is what makes the same
			// frontend field work on both platforms (.ico on Windows, .png here).
			C.app_indicator_set_icon_full(indicator, opts.icon.str, c'Vails')
		}
	}
	st.indicator = indicator
	st.set = true
}

// destroy_tray_native unrefs the item. Unreffed, not merely forgotten: the
// last reference is what removes it from the panel, so a tray that is
// "removed" without it leaves the icon behind for the rest of the session.
//
// The menu goes first and is detached from the indicator, because the host
// holds its own reference to it and would open a destroyed window if the icon
// outlived the menu.
fn destroy_tray_native(mut st &TrayState) ! {
	if !st.set {
		free_tray_menu(mut st)
		return
	}
	free_tray_menu(mut st)
	indicator := st.indicator
	st.indicator = unsafe { nil }
	st.set = false
	if indicator != unsafe { nil } {
		unsafe {
			C.g_object_unref(indicator)
		}
	}
}

// simulate_click_native refuses, with the reason. There is no click to
// manufacture on this platform (see the header): the SNI host opens the item's
// menu instead, so a simulated click would prove a path that does not exist.
// A refusal that names the real alternative is worth more here than a green
// line that means nothing.
fn simulate_click_native(_st &TrayState, button string) ! {
	return error('tray: there is no click to simulate on linux (the tray host ' +
		"opens the item's menu, which is menu's job - see ADR-0017); '" + button +
		"' is a Windows-only proof")
}

// --- tray.set_menu (the Linux shape) ---
//
// On Linux this is the *whole* interactive half of a tray icon, and it is not
// a Windows-shaped port. The StatusNotifier *host* owns the click: there is no
// click event on this platform at all (no "activate" signal in this version of
// libayatana-appindicator), and pressing the item makes the host open whatever
// menu the app attached with app_indicator_set_menu. So:
//
//   - the menu is handed to the indicator once, here, and the host does the
//     rest - which is why there is no show_tray_menu_native for Linux and the
//     shared show_tray_menu is a no-op there;
//   - the choice comes back as the GtkMenuItem's own "activate" signal, not as
//     a window message, so it never passes through the host seam at all;
//   - and tray:clicked stays Windows-only, which is why tray_menu_click is not
//     reached for a Linux icon in the first place.
//
// ADR-0017 predicted this and got the reasoning right; what it could not know
// is that `item-activated` (the signal it planned to use) is a GTK2 leftover,
// which is why the per-item "activate" connection below is the whole mechanism.

// GCallback mirrors glib's and is declared in menu_linux.c.v, which this file
// uses: the two menus are built from one item model, so they are declared once.

@[c_extern]
fn C.app_indicator_set_menu(self voidptr, menu voidptr)

// GCallback, gtk_menu_new, gtk_menu_item_new_with_label,
// gtk_separator_menu_item_new, gtk_menu_item_set_submenu,
// gtk_menu_shell_append, gtk_widget_destroy, g_object_set_data,
// g_object_get_data and g_signal_connect_data are deliberately NOT redeclared
// here. Every .c.v of a module compiles into one translation unit and one
// namespace (ADR-0018 Notes), so a second copy is a hard error, not a shadow.
// menu_linux.c.v already declares all of them, and using its copies is the
// point: the tray menu and the popup are built by one item model, so they
// should be built against one set of declarations.

// tray_menu_index_key is the GObject data key under which each item widget
// carries its 1-based position in the flat id list, the same trick the popup
// uses (menu_linux.c.v) and for the same reason: the widget and the id list
// cannot then disagree.
const tray_menu_index_key = 'vails-tray-menu-index'

// LinuxTrayMenu is the per-menu context. It has to be heap and outlive the
// call, because every item's "activate" callback travels in its address.
struct LinuxTrayMenu {
mut:
	st   &TrayState
	ids  []string
	menu voidptr
}

// build_tray_menu fills shell with items, stamping and connecting each one.
// The id list order is the same flatten_items order the Windows tray menu gets
// from build_menu, so the two platforms report the same id for the same tree.
fn build_tray_menu(mut m &LinuxTrayMenu, shell voidptr, items []MenuItem) {
	for item in items {
		if item.separator {
			sep := unsafe { C.gtk_separator_menu_item_new() }
			unsafe {
				C.gtk_menu_shell_append(shell, sep)
			}
			continue
		}
		widget := unsafe { C.gtk_menu_item_new_with_label(item.label.str) }
		m.ids << item.id
		unsafe {
			C.g_object_set_data(widget, tray_menu_index_key.str, voidptr(u64(m.ids.len)))
			C.g_signal_connect_data(widget, c'activate', GCallback(tray_menu_activated),
				voidptr(m), unsafe { nil }, 0)
		}
		if item.children.len > 0 {
			sub := unsafe { C.gtk_menu_new() }
			unsafe {
				C.gtk_menu_item_set_submenu(widget, sub)
			}
			build_tray_menu(mut m, sub, item.children)
		}
		unsafe {
			C.gtk_menu_shell_append(shell, widget)
		}
	}
}

// tray_menu_activated is one item's "activate": (item, user_data). Reports the
// choice on the menu service's own event, so a frontend that listens for
// menu:clicked does not care which of the three menus was used.
fn tray_menu_activated(item voidptr, data voidptr) {
	m := unsafe { &LinuxTrayMenu(data) }
	raw := unsafe { C.g_object_get_data(item, tray_menu_index_key.str) }
	idx := int(u64(raw))
	if idx <= 0 || idx > m.ids.len {
		// A stamp we did not write. No id is better than a wrong one.
		return
	}
	emit_menu_clicked(m.st.ctx, m.ids[idx - 1]) or {}
}

// set_tray_menu_native attaches the menu the indicator's host will open.
// Replacing first means an empty list removes it through the same path.
fn set_tray_menu_native(mut st &TrayState, items []MenuItem) ! {
	require_parent(st.ctx, 'tray.set_menu')!
	free_tray_menu(mut st)
	if items.len == 0 {
		return
	}
	menu := unsafe { C.gtk_menu_new() }
	if menu == unsafe { nil } {
		return error('tray.set_menu: gtk_menu_new failed')
	}
	mut m := &LinuxTrayMenu{
		st:   st
		menu: menu
	}
	build_tray_menu(mut m, menu, items)
	unsafe {
		// show_all BEFORE handing it over: the host shows the menu itself, so
		// this is the only chance the widgets get a size request.
		C.gtk_widget_show_all(menu)
	}
	st.menu_ids = m.ids
	st.menu_handle = menu
	st.menu_context = voidptr(m)
	st.menu = true
	if st.indicator != unsafe { nil } {
		unsafe {
			C.app_indicator_set_menu(st.indicator, menu)
		}
	}
}

// free_tray_menu detaches the menu from the indicator and releases it. The
// detach matters as much as the free: an indicator still holding a destroyed
// menu would open a window into freed memory when the user clicked it.
fn free_tray_menu(mut st &TrayState) {
	if st.indicator != unsafe { nil } && st.menu_handle != unsafe { nil } {
		unsafe {
			C.app_indicator_set_menu(st.indicator, unsafe { nil })
		}
	}
	if st.menu_context != unsafe { nil } {
		unsafe {
			free(&LinuxTrayMenu(st.menu_context))
		}
	}
	if st.menu_handle != unsafe { nil } {
		unsafe {
			C.gtk_widget_destroy(st.menu_handle)
		}
	}
	st.menu_handle = unsafe { nil }
	st.menu_context = unsafe { nil }
	st.menu_ids = []
	st.menu = false
}
