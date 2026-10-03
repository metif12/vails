// services/tray.v - the system tray service (Phase 5 S1 wave 3, ADR-0017).
//
// The first service in this codebase that is driven by the OS rather than by
// the page: a tray icon is a NOTIFYICONDATA whose uCallbackMsg is WM_APP+1,
// and when the user clicks it the shell sends a message to the window the
// *webview library* owns. Somebody has to be listening, which is what
// webview/host.v is for - the comctl32 subclass that lets a native message
// reach V (ADR-0017).
//
// A click is an event, like a menu choice and for the same reason: the two
// platforms answer in completely different ways (a window procedure on
// Windows, a GObject signal on Linux) and a frontend that had to know which
// would be a frontend that could not be written once.
//
// The service reports a click; it does not interpret one. Deciding that a left
// click opens a window is the app's job, and keeping it there is what makes this
// service reusable.
//
// `tray.set_menu` is the one place that is no longer true, and the reason is
// worth stating: a menu attached to the icon *is* the right click, on both
// platforms, so the service has to know it. It does not decide what the menu
// *does* — the items, their ids and the event they answer on all still belong to
// the menu service and to the app. It only declines to report a right click
// that its own menu has already consumed; see tray_menu_click.
//
// `simulate_click` exists because the click path has no pure-V test: it starts
// at a native message. It manufactures that message, so the whole
// C -> V -> event -> JS loop can be proven without a human moving a mouse -
// which is the same reason examples/* have *_PROBE hooks. It is also the
// shortest way for an app to test its own tray UI. It is not a command and not
// capability-gated, so a frontend cannot call it.
module services

import bridge
import json2
import webview

// Bounds. The tooltip is the shell's own fixed field (128 UTF-16 units, which
// is what the validated 128-byte bound has to fit inside), and the icon is a
// path, so both are bounded before they reach a native call.
const max_tray_tooltip = 128
const max_tray_icon_path = 1024

// The one event this service emits.
pub const event_tray_clicked = 'tray:clicked'

// The buttons the shell reports. `left` is a click, `right` is a click too:
// the shell sends a double click as a separate message, and this service
// reports both as the same button rather than inventing a "double_click" that
// a frontend would then have to handle twice.
pub const button_left = 'left'
pub const button_right = 'right'

// The shell's notification-area messages, which arrive in lParam alongside
// WM_APP+1 (NOT in wParam - the ADR-0017 note that cost an afternoon).
const wm_lbuttonup = 0x0202
const wm_lbuttondblclk = 0x0203
const wm_rbuttonup = 0x0205
const wm_rbuttondblclk = 0x0206
const wm_contextmenu = 0x007B

// TrayOptions is the params payload of tray.set. Both fields are optional: an
// empty icon is the stock application icon, and an empty tooltip is a tray
// icon that says nothing until the app sets one.
pub struct TrayOptions {
pub mut:
	icon    string
	tooltip string
}

// TrayClick is one classified click.
pub struct TrayClick {
pub mut:
	button string
}

// TrayState is the per-window tray state: the window host seam on Windows, the
// AppIndicator on Linux, and enough of a flag to tell `tray.destroy` from
// "nothing was ever installed". One per window, created by tray_backend and
// captured by both handlers, so the hook installed by `tray.set` outlives the
// call that installed it.
pub struct TrayState {
mut:
	ctx webview.Ctx
	// hook is the window host seam, installed on the first tray.set and
	// removed on destroy. Nil until then, which is why an app that never shows
	// a tray icon gets no subclass on its window at all.
	hook &webview.HostCtx = unsafe { nil }
	// indicator is the Linux AppIndicator (a GObject the tray owns, and one
	// that has to be unreffed rather than forgotten - ADR-0017). Nil on
	// Windows, where the shell holds the icon instead.
	indicator voidptr = unsafe { nil }
	// set reports whether an icon is on screen.
	set bool
	// menu reports whether a menu is attached, and menu_ids is that menu's flat
	// id table in the order the backend assigned command ids. Both are the
	// tray.set_menu contract in two parts: `menu` decides whether a right click
	// is still a click (tray_menu_click), and `menu_ids` decodes the id that
	// comes back so it can be reported as `menu:clicked`.
	//
	// Windows builds an HMENU and the choice arrives as a WM_COMMAND; Linux
	// hands a GtkMenu to the AppIndicator and the host opens it, so the id
	// never becomes a message there (see tray_linux.c.v).
	menu     bool
	menu_ids []string
	// menu_handle is the native menu (HMENU / GtkMenu), kept so a replaced menu
	// can be freed and `tray.destroy` can take it down with the icon.
	menu_handle voidptr = unsafe { nil }
	// menu_context is the Linux backend's per-menu struct (a *LinuxTrayMenu),
	// kept alive because the menu's item callbacks travel in its address.
	menu_context voidptr = unsafe { nil }
}

// has_menu reports whether a menu is attached to the icon, which is what
// tray_menu_click needs to decide whether a right click is still a click.
pub fn (s &TrayState) has_menu() bool {
	return s.menu
}

// is_installed reports whether an icon is currently on screen. A frontend
// cannot ask - there is no command for it, and there should not be: the
// answer the frontend has is the `tray:clicked` event. The app that installed
// the icon can ask, and the E2E probe needs to, because a click that arrives
// before the icon exists has nothing to click and a fixed sleep loses that race
// on a slow first page load.
pub fn (s &TrayState) is_installed() bool {
	return s.set
}

// tray_manifest is the service manifest (T5). Neither command is blocking:
// installing an icon is a shell call that returns immediately, and the click
// arrives later as an event.
pub fn tray_manifest() Service {
	return Service{
		name:     'tray'
		version:  '0.1.0'
		summary:  'system tray icon'
		commands: [
			Command{
				name:    'tray.set'
				params:  'TrayOptions'
				result:  'string'
				summary: 'installs (or updates) the tray icon and its tooltip'
			},
			Command{
				name:    'tray.destroy'
				result:  'string'
				summary: 'removes the tray icon'
			},
			Command{
				name:    'tray.set_menu'
				params:  'MenuPopup'
				result:  'string'
				summary: 'attaches a menu to the tray icon; a chosen item ' +
					'arrives as menu:clicked'
			},
		]
		ts_types: [
			// TrayOptions is tray.set's params, so the generated .d.ts refers to
			// it. TrayClick is not: it describes the payload of the *event* a
			// click emits, which no command signature mentions - it is here so a
			// frontend that listens for tray:clicked finds the shape in the same
			// generated file. snake_case, because a V struct field name IS the
			// wire name (ADR-0015).
			'\texport interface TrayOptions { icon?: string; tooltip?: string; }',
			'\texport interface TrayClick { button: "left" | "right"; }',
		]
	}
}

// parse_tray_options decodes tray.set's params. A bare JSON string is accepted
// as the tooltip, which is what a minimal frontend sends; the bounds are
// checked by validate_tray_options, which wraps them in 'bad params: …' like
// opener does.
pub fn parse_tray_options(params string) !TrayOptions {
	if params == '' || params == 'null' {
		return error('tray: nothing to set (an icon, a tooltip, or both)')
	}
	opts := json2.decode[TrayOptions](params) or {
		tooltip := json2.decode[string](params) or {
			return error('tray: invalid options: ' + err.msg())
		}
		return TrayOptions{
			tooltip: tooltip
		}
	}
	validate_tray_options(opts)!
	return opts
}

// validate_tray_options enforces the bounds. Named for the service on purpose:
// the module namespace is flat, a bare `validate` collides with the `validate`
// parameter of bridge.Router.register_validated in V's C codegen (and gcc
// rejects the generated function pointer), and `validate_options` is
// dialog's. One flat namespace, so every name here carries its service.
pub fn validate_tray_options(opts TrayOptions) ! {
	if opts.tooltip.len > max_tray_tooltip {
		return error('tray: tooltip is longer than ' + max_tray_tooltip.str() +
			' characters')
	}
	if opts.icon.len > max_tray_icon_path {
		return error('tray: icon path is longer than ' + max_tray_icon_path.str() +
			' characters')
	}
	// Both land in a NUL-terminated fixed-width field, so an embedded NUL
	// would silently truncate them - a truncation the frontend did not ask for.
	if opts.tooltip.contains('\x00') {
		return error('tray: tooltip must not contain a NUL')
	}
	if opts.icon.contains('\x00') {
		return error('tray: icon path must not contain a NUL')
	}
}

// is_button reports whether a name is one of the two buttons this service
// reports. A frontend cannot send one; simulate_click can ask, and the answer
// is a one-line function rather than a two-branch match at the call site.
pub fn is_button(name string) bool {
	return name == button_left || name == button_right
}

// button_lparam is the shell message for a button: what simulate_click posts
// on Windows, and what classify_click recognizes on both.
pub fn button_lparam(button string) i64 {
	if button == button_right {
		return i64(wm_rbuttonup)
	}
	return i64(wm_lbuttonup)
}

// tray_click classifies a message the window host seam intercepted.
//
// Only the seam's own message is considered, and only the five notification
// area messages; anything else is `none`, which the caller drops. A double
// click reports the same button as a single click on purpose (see button_left).
//
// `has_menu` is the tray.set_menu contract: a right click with a menu attached
// belongs to the *menu*, and the native side shows the menu itself, so there is
// no click left to report. See tray_menu_click for why that is a rule and not a
// special case.
pub fn tray_click(e webview.HostEvent, has_menu bool) ?TrayClick {
	if e.msg != webview.host_message {
		return none
	}
	button := classify_click(e.lparam) or { return none }
	if has_menu && button == button_right {
		return none
	}
	return TrayClick{
		button: button
	}
}

// TrayAction is what the host handler should do about one window message.
// Three answers, because two answers is what went wrong here.
pub enum TrayAction {
	pass_on
	emit_clicked
	show_menu
}

// decide is the whole of the tray's host-message policy, in one pure function.
//
// It exists because the policy has three outcomes and a `bool` cannot carry
// them. An earlier version asked `tray_menu_click` (is this a click the frontend
// should hear about?) and branched on `!result` meaning "the menu owns this" —
// but that `false` also covers "this message is not the tray's at all", so a
// foreign message was answered by opening the tray menu and being consumed. In
// practice that meant an installed tray icon swallowed the menu bar's
// `WM_COMMAND` on the same window, which is exactly the seam contract ADR-0023
// added a second hook to protect.
//
// The fix is not a better predicate; it is refusing to overload one. Classify
// first, so "not ours" is settled before "whose click is it" is asked, and
// return all three outcomes so the handler cannot infer a fourth.
pub fn decide(e webview.HostEvent, has_menu bool) TrayAction {
	// `tray_click(e, false)` rather than `tray_click(e, has_menu)`: the
	// has_menu rule is the *second* question, and asking it here would erase the
	// evidence needed to answer the first.
	click := tray_click(e, false) or { return .pass_on }
	if has_menu && click.button == button_right {
		return .show_menu
	}
	return .emit_clicked
}

// The decision (2026-09-29, recorded because it changes the meaning of an event
// that already shipped): **with a menu attached, the menu wins a right click**.
// `tray.set_menu` opens that menu and emits nothing.
//
// The alternative — open the menu AND still emit `tray:clicked {right}` — was
// rejected because it makes one physical click deliver two independent signals,
// and a frontend that wants the menu still has to decide whether to also act on
// the click. The chosen rule has a property the other lacks: an app that never
// calls tray.set_menu sees no behaviour change at all, on either platform. Only
// the presence of the new command changes what a right click does.
//
// A left click is never taken. The menu is a *context* menu; eating the click
// that opens whatever the app wants a left click for would be the more damaging
// half of a wrong rule here.
pub fn tray_menu_click(e webview.HostEvent, has_menu bool) bool {
	if e.msg != webview.host_message {
		return false
	}
	button := classify_click(e.lparam) or { return false }
	return !(has_menu && button == button_right)
}

// classify_click maps the shell's packed lParam to a button name. The message
// ids overlap with unrelated window messages (0x0202 is also a keyboard
// message, for one), which is fine: the host seam only ever forwards
// WM_APP+1, so this table is only ever asked about notification-area clicks.
pub fn classify_click(lparam i64) ?string {
	match lparam {
		i64(wm_lbuttonup) {
			return button_left
		}
		i64(wm_lbuttondblclk) {
			return button_left
		}
		i64(wm_rbuttonup) {
			return button_right
		}
		i64(wm_rbuttondblclk) {
			return button_right
		}
		i64(wm_contextmenu) {
			return button_right
		}
		else {
			return none
		}
	}
}

// tray_clicked_data is the payload of tray:clicked. Named for the service
// because the module namespace is flat and the menu service builds a payload
// of the same shape. The button is a closed set of two names, so the payload is
// built from a validated string rather than encoded from a struct that could
// carry anything.
pub fn tray_clicked_data(c TrayClick) string {
	return '{"button":' + json2.encode(c.button) + '}'
}

// on_host_message is the handler the window seam calls. A plain function (not
// a closure) so the install site reads the same on every platform.
//
// It answers "did I consume this?" and only consumes a message it recognises as
// the tray's own: a WM_APP+1 that classify_click maps to a button, and that
// tray_menu_click says is still a click (so a right click with a menu attached
// is declined, because the menu owns it). Everything else is false, so it
// reaches the next subclass in the chain and then the webview library — the
// menu bar installs its own hook on the same window and depends on this one
// staying out of its way (ADR-0023).
//
// A click the frontend never receives is a broken tray, so a failed emit fails
// the handler, which the host treats as consumed: there is nothing to do with a
// recognised tray click but drop it.
// It does nothing but carry out `decide`, which is where the policy and its
// tests live. What it must not do is infer an outcome of its own: the three
// cases are not interchangeable, and `show_menu` in particular must be
// unreachable for a message the tray does not own.
fn on_host_message(st &TrayState, e webview.HostEvent) !bool {
	match decide(e, st.has_menu()) {
		.pass_on {
			// Not the tray's. It continues down the subclass chain to the
			// window menu bar's own hook and on to the webview library
			// (ADR-0023). This is the branch that must never be folded into
			// either of the other two.
			return false
		}
		.show_menu {
			show_tray_menu(st, e)!
			return true
		}
		.emit_clicked {
			// Safe to unwrap: decide returns emit_clicked only for a message
			// tray_click accepts.
			click := tray_click(e, st.has_menu()) or { return false }
			st.ctx.emit(event_tray_clicked, tray_clicked_data(click))!
			return true
		}
	}
}

// show_tray_menu displays the icon's menu for a click the menu owns, and reports
// the chosen item. It is the platform's half of the tray.set_menu contract; the
// decision to call it is pure V (tray_menu_click), and the item -> id mapping is
// the menu service's (flatten_items via build_menu).
//
// A no-op when no menu is attached, which makes the caller free to ask without
// checking first: on a platform with no menu this is simply never reached.
fn show_tray_menu(st &TrayState, e webview.HostEvent) ! {
	if !st.has_menu() {
		return
	}
	$if windows {
		show_tray_menu_native(st, e)!
	} $else $if linux {
		// Linux has no equivalent call. The StatusNotifier *host* owns the click
		// on this platform: it opens the menu the app attached with
		// app_indicator_set_menu, and the choice comes back as the GtkMenuItem's
		// own "activate" rather than as a window message. So there is nothing for
		// this to do, and pretending otherwise would be a no-op that looked like
		// it worked. See tray_linux.c.v.
		_ = e
	} $else {
		_ = e
	}
}

// set_tray installs (or replaces) the icon. Needs a window: a tray icon
// belongs to a window on both platforms (a NOTIFYICONDATA has an hWnd; an
// AppIndicator needs the D-Bus connection the GTK runtime owns), and the rule
// lives in pure V so a hand-built Ctx cannot reach the native call.
pub fn set_tray(mut st &TrayState, opts TrayOptions) ! {
	$if windows {
		return set_tray_native(mut st, opts)
	} $else $if linux {
		return set_tray_native(mut st, opts)
	} $else {
		_ = opts
		return error('tray.set: not implemented on this platform yet (Phase 6, ' +
			'macOS)')
	}
}

// set_tray_menu attaches (or replaces, or with an empty list removes) the menu
// the tray icon opens. Not blocking: the choice arrives later as
// `menu:clicked`, the same event the menu service already uses.
//
// The items are the menu service's own `MenuItem` shape, parsed by the menu
// service's own `parse_popup`, so both menus in Vails share one item model, one
// id whitelist and one set of bounds. That is why the params type is MenuPopup
// and not something parallel.
pub fn set_tray_menu(mut st &TrayState, items []MenuItem) ! {
	$if windows {
		return set_tray_menu_native(mut st, items)
	} $else $if linux {
		return set_tray_menu_native(mut st, items)
	} $else {
		_ = items
		return error('tray.set_menu: not implemented on this platform yet (Phase 6, ' +
			'macOS)')
	}
}

// destroy_tray removes the icon again and unhooks the window seam. A no-op
// when none is installed, because an app that cleans up defensively must not
// get an error for it.
pub fn destroy_tray(mut st &TrayState) ! {
	$if windows {
		return destroy_tray_native(mut st)
	} $else $if linux {
		return destroy_tray_native(mut st)
	} $else {
		return error('tray.destroy: not implemented on this platform yet ' +
			'(Phase 6, macOS)')
	}
}

// simulate_click manufactures the message the OS would send, so the whole
// click path can be exercised (and screenshotted) with no human and no mouse.
pub fn simulate_click(st &TrayState, button string) ! {
	if !is_button(button) {
		return error('tray: "' + button + '" is not a tray button (' + button_left +
			' or ' + button_right + ')')
	}
	$if windows {
		return simulate_click_native(st, button)
	} $else $if linux {
		return simulate_click_native(st, button)
	} $else {
		_ = button
		return error('tray: simulate_click is not available on this platform yet ' +
			'(Phase 6, macOS)')
	}
}

// tray_backend builds the handler set for one window. The state is heap
// allocated and captured by both handlers, so the hook installed by `tray.set`
// outlives the call that installed it.
//
// The captured name is a local copy of the pointer, not the parameter itself:
// V 0.5.2 types a `mut` closure capture of a `mut` *parameter* as a pointer to
// the pointer (the generated C assigns `TrayState**` into a `TrayState*`
// field and gcc rejects it), while a `mut` local captures correctly. Same
// lesson as the ADR-0015 codegen notes, one layer up: the workaround is a
// local, and the reason is written down next to it.
pub fn tray_backend(mut st &TrayState) Backend {
	mut state := st
	mut backend := Backend{}
	backend['tray.set'] = fn [mut state] (params string) !string {
		opts := parse_tray_options(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		set_tray(mut state, opts) or {
			return error(err.msg())
		}
		return ''
	}
	backend['tray.destroy'] = fn [mut state] (_ string) !string {
		destroy_tray(mut state) or {
			return error(err.msg())
		}
		return ''
	}
	backend['tray.set_menu'] = fn [mut state] (params string) !string {
		// The menu service parses and validates these, so the tray menu cannot
		// drift from the popup's item rules. An empty list removes the menu,
		// which is why a defensive clear needs no special payload.
		items := parse_popup(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		set_tray_menu(mut state, items) or {
			return error(err.msg())
		}
		return ''
	}
	return backend
}

// install_tray binds the tray service on router for one window and returns the
// state it created.
//
// The state is what simulate_click needs (the Linux half holds the
// AppIndicator in it), so a caller that wants to exercise the click path
// without a human - examples/services does - has to be able to reach it.
// Returning it costs nothing to the callers that ignore it, and a registry of
// states keyed by window would be a global (AGENTS.md §2).
pub fn install_tray(mut router bridge.Router, ctx webview.Ctx) !&TrayState {
	mut st := &TrayState{
		ctx: ctx
	}
	install(mut router, tray_manifest(), tray_backend(mut st))!
	return st
}

// tray_support answers "can this platform put an icon in the tray?" (see
// support.v). The Linux note is deliberately specific: the item is created and
// registered, but drawing it needs a StatusNotifierHost, which a headless
// session does not have. That is a different statement from "not supported",
// and doctor is the place it belongs.
pub fn tray_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'tray'
			ready: true
			note:  'Shell_NotifyIconW (WM_APP+1 click -> tray:clicked, ADR-0017); ' +
				'tray.set_menu attaches an HMENU and the choice comes back as ' +
				'menu:clicked'
		}
	} $else $if linux {
		return ServiceStatus{
			name:  'tray'
			ready: true
			// No tray:clicked on Linux, and the note must not imply otherwise:
			// the StatusNotifier *host* owns the click and opens the menu the app
			// attached to the item, so a Linux app reacts to menu:clicked from
			// that menu instead (ADR-0017). tray.set_menu is what gives that menu
			// items. A StatusNotifierHost must also be running for the item to be
			// visible at all.
			note:  'libayatana-appindicator (no click event: the SNI host owns it ' +
				'and opens the menu from tray.set_menu - a StatusNotifierHost must ' +
				'be running to see the icon)'
		}
	} $else {
		return ServiceStatus{
			name:  'tray'
			ready: false
			note:  'no backend on this platform yet (Phase 6, macOS)'
		}
	}
}
