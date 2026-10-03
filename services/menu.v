// services/menu.v - the native menu service (Phase 5 S1 wave 3, ADR-0017;
// window menu bar in wave 4, ADR-0023).
//
// Two shapes of native menu, one vocabulary:
//
//   - `menu.popup` is a *popup*: what a right-click opens, and what a tray
//     icon's right-click opens. It is modal on Windows and immediate on Linux.
//   - `menu.set_menu` is the window *menu bar*: attached to the window, no
//     result, and the user chooses from it whenever they like.
//
// ADR-0017 drew the line at "a menu bar is SetMenu plus WM_COMMAND routing
// plus menu-state tracking, a service of its own", and that was right at the
// time: the seam did not yet have what the routing needs. It does now — the
// window host seam takes a second subclass on the same window (ADR-0023) — so
// the bar arrives as the same `menu.` prefix and shares the item model, the id
// rules and above all the event. A frontend handles one `menu:clicked` and does
// not care which of the two shapes the user clicked.
//
// The choice comes back as an *event*, never as the command's result, and that
// is what makes one contract serve three very different natives:
// `TrackPopupMenuEx(TPM_RETURNCMD)` is a nested message loop on the handler's
// thread, so on Windows `menu.popup` blocks exactly like `dialog.open` does
// (the ADR-0014 modal exception); on Linux the GTK popup returns immediately and
// the answer arrives on the item's `activate` signal; and a bar's answer arrives
// as a WM_COMMAND through the host seam, minutes after the call that installed
// it returned. A frontend that waited for the result on one and for an event on
// the others would have to know the platform, so it does not: `menu:clicked`
// with the item id, or `menu:canceled`, always.
//
// Pure-V half: the item model, its bounds, the event payloads, the manifest and
// bar_click (the WM_COMMAND classifier). The OS halves are menu_windows.c.v
// (HMENU + TrackPopupMenuEx, and CreateMenu + SetMenu for the bar) and
// menu_linux.c.v (GtkMenu, and GtkMenuBar for the bar).
module services

import bridge
import json2
import webview

// Bounds. A menu is a set of short labels, not a document: the item list is
// capped so a frontend cannot build a menu the OS will silently truncate, and
// every string that reaches a native menu handle has a length the handle can
// hold (the Windows menu text buffer is bounded by the system, not by us).
const max_menu_items = 64
const max_menu_id = 64
const max_menu_label = 128
const max_menu_depth = 4

// The two events a popup produces. Names are the frontend's contract, so they
// live next to the payloads that fill them.
pub const event_menu_clicked = 'menu:clicked'
pub const event_menu_canceled = 'menu:canceled'

// wm_command is the window message a menu bar delivers a choice through
// (0x0111). It is a Windows message id, and it lives in the shared file rather
// than only in menu_windows.c.v because bar_click — the pure-V classifier that
// decides whether a message is ours — has to compare against it, and that
// function is tested on every platform. Same arrangement as host_message: the
// value is a fact about the platform, and the filter is unit-tested.
//
// A menu *popup* never sends it. That is what TPM_RETURNCMD buys: the chosen id
// comes back from the call and no message is involved at all, which is why the
// popup needs no hook (ADR-0017). A menu *bar* has no such call to return
// through — it is attached to the window and the user chooses from it minutes
// later — so WM_COMMAND is the only way its answer arrives.
pub const wm_command = u32(0x0111)

// MenuItem is one entry of a popup, or of a submenu.
//
// `separator` is a structural item: it has no id and no label, and a frontend
// spells it {"separator": true}. `children` is a submenu; its parent keeps its
// own id, so `menu:clicked` can name the submenu as well as a leaf - a
// frontend that wants "the File menu was opened" is not obliged to invent a
// convention for it.
pub struct MenuItem {
pub mut:
	id        string
	label     string
	enabled   bool = true
	separator bool
	children  []MenuItem
}

// MenuPopup is the params payload of menu.popup.
pub struct MenuPopup {
pub mut:
	items []MenuItem
}

// MenuState is the per-window state the two commands share: the Ctx events
// are pushed with, and the popup that is currently on screen so `menu.close`
// can end it. One per window, created by menu_backend and captured by both
// handlers - no globals, which is the rule every other cross-command state in
// this codebase follows.
pub struct MenuState {
pub mut:
	ctx webview.Ctx
	// handle is the open popup's native handle (HMENU / GtkMenu), nil while
	// nothing is open.
	handle voidptr = unsafe { nil }
	// open tracks whether a popup is on screen. Kept next to the handle
	// because the two can disagree during teardown (a dismissal frees the
	// handle from the platform's own callback), and `close` on a closed menu
	// has to be a no-op rather than a use-after-free.
	open bool
	// context is the backend's own per-popup state, nil while nothing is open.
	// `menu.close` needs it to tear a popup down, and on Linux the platform's
	// dismiss callback is not guaranteed to run when the app closes the menu
	// itself (gtk_menu_popdown does not emit "deactivate"), so the close path
	// cannot rely on reaching the popup through the OS. A voidptr because this
	// struct is shared by both backends and the LinuxPopup type exists only in
	// menu_linux.c.v.
	context voidptr = unsafe { nil }
	// bar_handle is the installed window menu bar (HMENU / GtkMenuBar), nil
	// while none is set. It outlives the popup above: a bar is permanent for
	// the window until it is replaced, which is why it gets its own field
	// rather than sharing `handle`.
	bar_handle voidptr = unsafe { nil }
	// bar_ids is the flat id list of the bar, in the order the native backend
	// assigned command ids to its items. This is what turns the id in a
	// WM_COMMAND back into the string the frontend sent, and it is why the bar
	// can have its own id space without colliding with an open popup's: the
	// popup never routes through a message (it uses TPM_RETURNCMD), so the two
	// lists are never consulted for the same message.
	bar_ids []string
	// bar_context is the Linux backend's own per-bar struct (a *LinuxBar), kept
	// alive here because the bar's item callbacks travel in its address. Windows
	// needs nothing equivalent: its bar is an HMENU with no callback, the
	// answers arrive as WM_COMMAND, and the ids are the whole state.
	bar_context voidptr = unsafe { nil }
	// bar_hook is the window host seam installed for the bar, nil while no bar
	// is set. Kept so a replaced bar can drop the old one, and so a backend can
	// detach it.
	bar_hook &webview.HostCtx = unsafe { nil }
}

// menu_manifest is the service manifest (T5).
//
// `popup` is marked blocking: on Windows the native call spins a nested
// message loop on the webview thread until the user answers, which is the
// documented ADR-0014 exception. On Linux it does not block, and the flag is
// then describing the strictest platform - a flag is a promise, not a
// measurement, and the frontend sees the same contract either way (the choice
// arrives as an event).
pub fn menu_manifest() Service {
	return Service{
		name:     'menu'
		version:  '0.1.0'
		summary:  'native popup menus'
		commands: [
			Command{
				name:     'menu.popup'
				params:   'MenuPopup'
				result:   'string'
				blocking: true
				summary:  'opens a native popup menu; the choice arrives as an event'
			},
			Command{
				name:    'menu.close'
				result:  'string'
				summary: 'closes the open popup menu, if any'
			},
			Command{
				name:    'menu.set_menu'
				params:  'MenuPopup'
				result:  'string'
				summary: 'installs (or replaces) the window menu bar; a chosen ' +
					'item arrives as menu:clicked'
			},
		]
		ts_types: [
			// MenuItem/MenuPopup are the command's params, so they are the ones
			// the generated .d.ts refers to. MenuClicked/MenuCanceled are not:
			// they describe the payloads of the two *events* a popup emits,
			// which no command signature mentions. They live here so a frontend
			// that listens for them has the shapes in the same generated file
			// instead of in a comment. snake_case throughout, because a V struct
			// field name IS the wire name (ADR-0015).
			'\texport interface MenuItem { id?: string; label?: string; enabled?: boolean; separator?: boolean; children?: MenuItem[]; }',
			'\texport interface MenuPopup { items: MenuItem[]; }',
			'\texport interface MenuClicked { id: string; }',
			'\texport interface MenuCanceled { canceled: true; }',
		]
	}
}

// is_valid_id checks a menu id against a whitelist rather than a blacklist.
// An id is a wire name the frontend sends back in `menu:clicked`, and on
// Windows it also travels as the HMENU command id - so allowing arbitrary text
// would mean NUL-terminating whatever a frontend invented inside a native menu
// handle. The alphabet is what a command name needs and nothing more.
pub fn is_valid_id(id string) bool {
	if id == '' || id.len > max_menu_id {
		return false
	}
	for ch in id {
		c := u8(ch)
		alnum := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || (c >= `0` && c <= `9`)
		if !(alnum || c == `_` || c == `-` || c == `.` || c == `:` || c == `/`) {
			return false
		}
	}
	return true
}

// is_valid_label checks menu text. `&` is rejected on purpose: on Windows it
// is the mnemonic marker, so "Save & close" would render as "Save _ close"
// and a frontend would have to guess which label the user saw. Vails menus are
// not mnemonics; a frontend that wants one can put it in the label and accept
// the platform's rendering, which is a decision, not an accident.
pub fn is_valid_label(label string) bool {
	if label == '' || label.len > max_menu_label {
		return false
	}
	for ch in label {
		if ch == `&` || u8(ch) < 0x20 {
			return false
		}
	}
	return true
}

// parse_popup decodes and validates menu.popup's params. A bare JSON array of
// items is accepted as well as the object form, because a minimal frontend
// sends the array it already has.
pub fn parse_popup(params string) ![]MenuItem {
	if params == '' || params == 'null' {
		return error('menu: no items to show')
	}
	mut items := decode_items(params) or {
		return error('menu: invalid items: ' + err.msg())
	}
	validate_items(items)!
	return items
}

// decode_items accepts the object form ({items: [...]}) and the bare array.
fn decode_items(params string) ![]MenuItem {
	trimmed := params.trim_space()
	if trimmed.starts_with('[') {
		return json2.decode[[]MenuItem](params)
	}
	// `request`, not `popup`: a local named after the service's own command
	// function shadows it, and V notices.
	request := json2.decode[MenuPopup](params) or {
		return error(err.msg())
	}
	return request.items
}

// validate_items rejects anything a native menu cannot honor, before any
// native call happens, and collects the ids as it goes: the Windows backend
// needs a flat id list to map the returned command id back to an item, and a
// duplicate id would make that mapping ambiguous.
pub fn validate_items(items []MenuItem) ! {
	if items.len == 0 {
		return error('menu: a menu needs at least one item')
	}
	if items.len > max_menu_items {
		return error('menu: at most ' + max_menu_items.str() + ' items')
	}
	mut seen := []string{}
	validate_level(items, 1, mut seen)!
}

// validate_level checks one nesting level and recurses. depth counts from 1,
// and a submenu deeper than max_menu_depth is rejected rather than flattened:
// a 4-deep menu is a design choice, a 40-deep one is a loop in a generator.
fn validate_level(items []MenuItem, depth int, mut seen []string) ! {
	for item in items {
		if item.separator {
			if item.id != '' || item.label != '' || item.children.len > 0 {
				return error('menu: a separator carries no id, label or submenu')
			}
			continue
		}
		if !is_valid_id(item.id) {
			return error('menu: "' + item.id + '" is not a valid menu id (1-' +
				max_menu_id.str() + ' characters of A-Z a-z 0-9 _ - . : /)')
		}
		if item.id in seen {
			return error('menu: duplicate menu id "' + item.id + '"')
		}
		seen << item.id
		if !is_valid_label(item.label) {
			return error('menu: "' + item.id + '" needs a label of 1-' +
				max_menu_label.str() + ' printable characters, without "&"')
		}
		if item.children.len > max_menu_items {
			return error('menu: submenu "' + item.id + '" has more than ' +
				max_menu_items.str() + ' items')
		}
		if item.children.len > 0 {
			if depth >= max_menu_depth {
				return error('menu: menus nest at most ' + max_menu_depth.str() +
					' levels deep')
			}
			validate_level(item.children, depth + 1, mut seen)!
		}
	}
}

// flatten_items appends every id in the order the menu is built, which is the
// order the Windows backend assigns command ids (1-based, so 0 can stay "no
// selection"). The same order is what the Linux backend stores on each item
// widget, so one list serves both platforms.
pub fn flatten_items(items []MenuItem) []string {
	mut out := []string{}
	flatten_into(items, mut out)
	return out
}

fn flatten_into(items []MenuItem, mut out []string) {
	for item in items {
		if item.separator {
			continue
		}
		out << item.id
		flatten_into(item.children, mut out)
	}
}

// menu_clicked_data is the payload of menu:clicked. Named for the service
// because the module namespace is flat and the tray service builds a payload
// with the same shape for the same reason (ADR-0015's naming lesson, applied
// to payloads as well as to validators).
pub fn menu_clicked_data(id string) string {
	return '{"id":' + json2.encode(id) + '}'
}

// bar_click is the pure-V half of a window menu bar: it turns one intercepted
// window message into the id the frontend sent, or nothing.
//
// This is where the whole of `menu.set_menu` is testable without a window. The
// native side owns exactly one fact - a WM_COMMAND's LOWORD is the command id
// the backend assigned, which is the item's 1-based position in the bar's flat
// list - and this function owns what that means.
//
// Three cases are rejected rather than guessed, because each would otherwise
// report a choice the user never made:
//   - a message that is not WM_COMMAND. The hook is asked about every message
//     on the window (that is how a subclass chain works, ADR-0023), so the
//     window's own WM_COMMAND for a control, an accelerator or a system menu
//     command arrives here too. Those are not ours.
//   - id 0. Windows uses 0 for "no command" and it is also what a menu sends
//     for a separator, and the id list is 1-based precisely so 0 can mean that.
//   - an id past the end of the list. It means the window's menu changed
//     without us being told, and the honest answer is "not one of ours" rather
//     than a read past the end of a slice.
pub fn bar_click(e webview.HostEvent, ids []string) ?string {
	if e.msg != wm_command {
		return none
	}
	// LOWORD(wParam) is the menu command id. HIWORD is the notification code
	// and is 0 for a plain menu command; a non-zero one is a control
	// notification that happens to share the message.
	if (e.wparam >> 16) != 0 {
		return none
	}
	id := int(e.wparam & 0xFFFF)
	if id <= 0 || id > ids.len {
		return none
	}
	return ids[id - 1]
}

// canceled_data is the payload of menu:canceled. A dismissal is an event, not
// an error: the frontend asked for a menu, the user closed it, and nothing
// failed (the same rule as dialog's `{canceled: true}`).
pub fn canceled_data() string {
	return '{"canceled":true}'
}

// emit_clicked pushes one chosen id to the frontend. Wrapped so both platform
// halves report a failure the same way: a menu whose event cannot be pushed is
// a broken menu, and swallowing it would leave the frontend waiting forever.
fn emit_clicked(st &MenuState, id string) ! {
	st.ctx.emit(event_menu_clicked, menu_clicked_data(id))!
}

// emit_menu_clicked is emit_clicked for a menu that is not the popup's. The
// window bar (menu.set_menu) and the tray icon's menu (tray.set_menu) both hold
// their own state rather than a MenuState, and both answer on the same event
// with the same payload — which is the point: a frontend registers one
// `menu:clicked` listener and does not care which of the three menus the user
// clicked.
//
// It lives here, in the service that owns the event, rather than being
// re-implemented in each caller: a second copy of "how a menu reports a choice"
// is exactly how two menus end up disagreeing about the payload shape.
pub fn emit_menu_clicked(ctx webview.Ctx, id string) ! {
	ctx.emit(event_menu_clicked, menu_clicked_data(id))!
}

fn emit_canceled(st &MenuState) ! {
	st.ctx.emit(event_menu_canceled, canceled_data())!
}

// popup shows the menu. Blocking on Windows (see menu_manifest), immediate on
// Linux; either way the answer arrives as an event.
pub fn popup(mut st &MenuState, items []MenuItem) ! {
	$if windows {
		popup_native(mut st, items)!
	} $else $if linux {
		popup_native(mut st, items)!
	} $else {
		_ = items
		return error('menu.popup: not implemented on this platform yet (Phase 6, ' +
			'macOS)')
	}
}

// close ends the open popup, if any. A no-op when nothing is open, because a
// frontend that closes defensively is doing the right thing and must not get
// an error for it.
pub fn close(mut st &MenuState) ! {
	$if windows {
		close_native(mut st)!
	} $else $if linux {
		close_native(mut st)!
	} $else {
		return error('menu.close: not implemented on this platform yet (Phase 6, ' +
			'macOS)')
	}
}

// set_menu installs the window's menu bar, replacing any bar already there.
// Not blocking and not modal: it hands the items to the window and returns,
// and the user chooses from them whenever they like. The choice is a
// `menu:clicked` event like any other, which is what lets one frontend handler
// serve both shapes.
pub fn set_menu(mut st &MenuState, items []MenuItem) ! {
	$if windows {
		set_menu_native(mut st, items)!
	} $else $if linux {
		set_menu_native(mut st, items)!
	} $else {
		_ = items
		return error('menu.set_menu: not implemented on this platform yet (Phase 6, ' +
			'macOS)')
	}
}

// menu_backend builds the handler set for one window. The state is heap
// allocated and captured by every handler, so `menu.close` sees the popup
// `menu.popup` opened and the bar's hook sees the ids `menu.set_menu` installed.
pub fn menu_backend(ctx webview.Ctx) Backend {
	mut st := &MenuState{
		ctx: ctx
	}
	mut backend := Backend{}
	backend['menu.popup'] = fn [mut st] (params string) !string {
		items := parse_popup(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		popup(mut st, items) or {
			return error(err.msg())
		}
		// Always '': the choice is an event (see the module header).
		return ''
	}
	backend['menu.close'] = fn [mut st] (_ string) !string {
		close(mut st) or {
			return error(err.msg())
		}
		return ''
	}
	backend['menu.set_menu'] = fn [mut st] (params string) !string {
		// An empty list is the way to remove the bar, and it is accepted rather
		// than rejected: a frontend that shows and hides its own chrome should
		// not have to special-case "pass {}" to mean "no menu".
		items := parse_popup(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		set_menu(mut st, items) or {
			return error(err.msg())
		}
		return ''
	}
	return backend
}

// install_menu binds the menu service on router for one window.
pub fn install_menu(mut router bridge.Router, ctx webview.Ctx) ! {
	install(mut router, menu_manifest(), menu_backend(ctx))!
}

// menu_support answers "can this platform show a native popup menu?" (see
// support.v). The `$if` is the same one popup/close dispatch on, so the answer
// and the implementation cannot drift.
pub fn menu_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'menu'
			ready: true
			note:  'HMENU + TrackPopupMenuEx (modal) and SetMenu for the window ' +
				'bar; the choice arrives as menu:clicked either way'
		}
	} $else $if linux {
		return ServiceStatus{
			name:  'menu'
			ready: true
			// The popup's signal is GtkMenu's "deactivate" plus each item's
			// "activate" (GTK3 has no "item-activated" — see menu_linux.c.v).
			// The bar needs no hook at all: its items are ordinary widgets whose
			// "activate" the backend connects itself.
			note:  'GtkMenu popup + GtkMenuBar for the window bar; the choice ' +
				'arrives as menu:clicked either way'
		}
	} $else {
		return ServiceStatus{
			name:  'menu'
			ready: false
			note:  'no backend on this platform yet (Phase 6, macOS)'
		}
	}
}
