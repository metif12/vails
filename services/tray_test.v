module services

import webview

fn test_tray_manifest_declares_two_commands() {
	m := tray_manifest()
	assert m.name == 'tray'
	assert m.command_names() == ['tray.set', 'tray.destroy', 'tray.set_menu']
	set := m.command('tray.set') or { panic('tray.set must be declared') }
	assert set.params == 'TrayOptions'
	assert set.result == 'string'
	// Neither command is blocking: installing an icon is a shell call that
	// returns at once, and the click arrives later as an event.
	assert !set.blocking
	destroy := m.command('tray.destroy') or { panic('tray.destroy must be declared') }
	// No params, so install wires bridge.validate_empty: a stray payload must
	// not reach the handler.
	assert destroy.params == no_params
	assert !destroy.blocking
}

fn test_parse_tray_options_accepts_the_object_and_the_bare_string() {
	from_object := parse_tray_options('{"icon":"/tmp/x.png","tooltip":"Vails"}') or {
		panic(err.msg())
	}
	assert from_object.icon == '/tmp/x.png'
	assert from_object.tooltip == 'Vails'
	// A minimal frontend has one string and sends it as the tooltip.
	from_string := parse_tray_options('"hello"') or { panic(err.msg()) }
	assert from_string.tooltip == 'hello'
	assert from_string.icon == ''
	// Both fields are optional, and neither field is required to be a string.
	empty := parse_tray_options('{}') or { panic(err.msg()) }
	assert empty.tooltip == ''
}

fn test_parse_tray_options_rejects_nothing_to_set() {
	for params in ['', 'null'] {
		mut failed := ''
		parse_tray_options(params) or { failed = err.msg() }
		assert failed.contains('nothing to set'), params
	}
	mut broken := ''
	parse_tray_options('7') or { broken = err.msg() }
	assert broken.contains('invalid options')
}

fn test_validate_tray_options_bounds_the_strings() {
	// The tooltip lands in the shell's fixed 128-unit wide field, so the
	// validated bound is the field: a longer tooltip is refused rather than
	// silently clipped, because this one is short enough to read in full.
	mut long := ''
	validate_tray_options(TrayOptions{
		tooltip: 'x'.repeat(max_tray_tooltip + 1)
	}) or { long = err.msg() }
	assert long.contains('tooltip is longer than ' + max_tray_tooltip.str())
	mut long_path := ''
	validate_tray_options(TrayOptions{
		icon: 'x'.repeat(max_tray_icon_path + 1)
	}) or { long_path = err.msg() }
	assert long_path.contains('icon path is longer than ' +
		max_tray_icon_path.str())
	// Exactly at the bound is legal: 128 characters fit the field.
	validate_tray_options(TrayOptions{
		tooltip: 'x'.repeat(max_tray_tooltip)
	}) or { panic(err.msg()) }
}

fn test_validate_tray_options_rejects_an_embedded_nul() {
	// A NUL would truncate the field at the shell's writer, and the frontend
	// would see a different string than the one it sent.
	for field in ['tooltip', 'icon'] {
		mut opts := TrayOptions{}
		unsafe {
			mut ptr := &opts
			if field == 'tooltip' {
				ptr.tooltip = 'a\x00b'
			} else {
				ptr.icon = 'a\x00b'
			}
		}
		mut failed := ''
		validate_tray_options(opts) or { failed = err.msg() }
		assert failed.contains('must not contain a NUL'), field
	}
}

fn test_only_the_seams_own_message_is_considered() {
	// A message the seam did not intercept is not a tray click, even if its
	// lParam happens to be one of the shell's button messages. This is the
	// check that keeps a WebView2 message with lParam 0x0202 from becoming a
	// tray click.
	assert tray_click(webview.HostEvent{
		msg:    0x0202 // WM_KEYDOWN, the same lParam the shell uses
		lparam: i64(wm_lbuttonup)
	}, false) == none
	assert tray_click(webview.HostEvent{
		msg: webview.host_message
	}, false) == none
}

fn test_tray_click_classifies_the_shells_buttons() {
	// Five messages, two buttons. A double click reports the same button as a
	// single click on purpose: a frontend should not have to handle "the same
	// thing, twice as fast".
	left := tray_click(webview.HostEvent{
		msg:    webview.host_message
		lparam: i64(wm_lbuttonup)
	}, false) or { panic('a left click must classify') }
	assert left.button == button_left
	for lparam in [i64(wm_lbuttondblclk)] {
		c := tray_click(webview.HostEvent{
			msg:    webview.host_message
			lparam: lparam
		}, false) or { panic('a left double click must classify') }
		assert c.button == button_left
	}
	for lparam in [i64(wm_rbuttonup), i64(wm_rbuttondblclk), i64(wm_contextmenu)] {
		c := tray_click(webview.HostEvent{
			msg:    webview.host_message
			lparam: lparam
		}, false) or { panic('a right click must classify') }
		assert c.button == button_right
	}
}

fn test_an_unknown_lparam_is_not_a_click() {
	// WM_LBUTTONDOWN (a press, not a release) and a nonsense value both fall
	// through: the service reports clicks, not the whole mouse grammar.
	for lparam in [i64(0x0201), i64(0), i64(-1), i64(0x7FFF_FFFF)] {
		assert classify_click(lparam) == none, lparam.str()
	}
}

// --- tray.set_menu: the right-click contract (ADR-0026) ---

// The decision, in one test: with a menu attached the menu owns a right click,
// and without one nothing changes. The second half matters as much as the first
// - an app that never calls tray.set_menu must not see a different event stream
// than it did before the command existed.
fn test_a_right_click_belongs_to_the_menu_when_one_is_attached() {
	right := webview.HostEvent{
		msg:    webview.host_message
		lparam: i64(wm_rbuttonup)
	}
	assert tray_menu_click(right, false)
	assert tray_menu_click(right, true) == false
	// and the same message is no longer reported as a click
	assert tray_click(right, true) == none
}

fn test_a_left_click_is_never_taken_by_the_menu() {
	// The menu is a *context* menu: it answers a right click and must not eat
	// the click that opens whatever the app wants a left click for. This is the
	// case that would be silently wrong if the rule were "menu attached -> no
	// clicks at all".
	left := webview.HostEvent{
		msg:    webview.host_message
		lparam: i64(wm_lbuttonup)
	}
	assert tray_menu_click(left, true)
	c := tray_click(left, true) or { panic('a left click must survive a menu') }
	assert c.button == button_left
}

fn test_the_menu_claims_every_right_click_shape() {
	// Windows sends WM_RBUTTONUP, WM_RBUTTONDBLCLK and WM_CONTEXTMENU (the
	// last one is what a version-4 icon with a menu actually gets). All three
	// are the same user intent, so all three have to be claimed - or the menu
	// opens on some right clicks and not others, which is worse than not
	// having it.
	for lparam in [i64(wm_rbuttonup), i64(wm_rbuttondblclk), i64(wm_contextmenu)] {
		e := webview.HostEvent{
			msg:    webview.host_message
			lparam: lparam
		}
		assert tray_menu_click(e, true) == false, lparam.str()
		assert tray_click(e, true) == none, lparam.str()
	}
}

fn test_a_foreign_message_is_never_a_tray_click_with_or_without_a_menu() {
	// The seam is asked about every message on the window, so the "is this
	// mine" question has to be asked before the menu question - otherwise a
	// WebView2 message that happens to carry 0x0205 in its lParam would open
	// the tray menu.
	foreign := webview.HostEvent{
		msg:    0x0205
		lparam: i64(wm_rbuttonup)
	}
	assert tray_menu_click(foreign, false) == false
	assert tray_menu_click(foreign, true) == false
}

fn test_an_ungranted_lparam_is_neither_a_click_nor_a_menu() {
	// A press without a release is not a click, and must not be mistaken for
	// "the menu claimed it". The distinction matters: claiming it would consume
	// the message and do nothing at all, and passing it on lets the webview
	// library - which sent nothing, but may care - see it. Neither outcome is
	// what the other one is, which is the point.
	e := webview.HostEvent{
		msg:    webview.host_message
		lparam: i64(0x0204) // WM_RBUTTONDOWN
	}
	assert tray_menu_click(e, true) == false
	assert tray_click(e, true) == none
}

// --- decide(): the composition, which is where the bug was ---
//
// The tests above exercise the predicates one at a time. That is not enough,
// and the reason is the bug this section was added for: the handler branched
// on `!tray_menu_click(...)`, and that false means both "the menu owns this"
// and "not the tray's message at all". Every predicate test passed and the
// handler was still wrong, because the mistake was in how the answers were
// combined, and nothing was combining them. These tests are about `decide`,
// which is the combination.

// A message that is not the tray's must be passed on — never answered by
// opening the menu. This is the regression that mattered: an installed tray
// icon used to swallow the window menu bar's WM_COMMAND on the same window,
// which is the seam contract ADR-0023 exists to keep.
fn test_decide_passes_on_every_message_that_is_not_a_tray_click() {
	// A foreign message carrying a right-click lParam, which is what a
	// WebView2 message looks like if the table were consulted too early.
	assert decide(webview.HostEvent{
		msg:    0x0205
		lparam: i64(wm_rbuttonup)
	}, true) == .pass_on
	assert decide(webview.HostEvent{
		msg:    0x0205
		lparam: i64(wm_rbuttonup)
	}, false) == .pass_on
	// WM_COMMAND is the menu bar's own message, and it is what got eaten.
	assert decide(webview.HostEvent{
		msg:    0x0111
		lparam: 1
	}, true) == .pass_on
	// A right-button press with no release is not a click.
	assert decide(webview.HostEvent{
		msg:    webview.host_message
		lparam: i64(0x0204)
	}, true) == .pass_on
	// The menu never opens unless the click is a right click *and* a menu is
	// attached, and never for a message the tray does not own.
	for lparam in [i64(wm_lbuttonup), i64(wm_lbuttondblclk), i64(0x0204), i64(0), 0x1234] {
		e := webview.HostEvent{
			msg:    webview.host_message
			lparam: lparam
		}
		assert decide(e, true) != .show_menu, lparam.str()
		assert decide(e, false) != .show_menu, lparam.str()
	}
}

fn test_decide_shows_the_menu_only_for_a_right_click_with_a_menu() {
	for lparam in [i64(wm_rbuttonup), i64(wm_rbuttondblclk), i64(wm_contextmenu)] {
		e := webview.HostEvent{
			msg:    webview.host_message
			lparam: lparam
		}
		assert decide(e, true) == .show_menu, lparam.str()
		// The same message with no menu is an ordinary click, unchanged.
		assert decide(e, false) == .emit_clicked, lparam.str()
	}
}

fn test_decide_never_loses_a_click_to_the_menu() {
	// The complement of the two tests above, stated as one invariant: a message
	// the tray owns is either emitted or shown, never dropped. A dropped click
	// is a broken tray, and this is the assertion that would have caught a
	// fourth, unhandled outcome being introduced later.
	for lparam in [i64(wm_lbuttonup), i64(wm_lbuttondblclk), i64(wm_rbuttonup), i64(wm_rbuttondblclk),
		i64(wm_contextmenu)] {
		e := webview.HostEvent{
			msg:    webview.host_message
			lparam: lparam
		}
		for has_menu in [true, false] {
			action := decide(e, has_menu)
			assert action == .emit_clicked || action == .show_menu, '${lparam} ${has_menu}'
		}
	}
}

fn test_button_lparam_round_trips_through_the_classifier() {
	// simulate_click posts button_lparam, and the classifier reads it back, so
	// the two ends have to agree - which is the one thing a test can check
	// about a path whose other half is a native message.
	for button in [button_left, button_right] {
		back := classify_click(button_lparam(button)) or { panic('must classify') }
		assert back == button
	}
}

fn test_buttons_are_a_closed_set() {
	assert is_button(button_left)
	assert is_button(button_right)
	for name in ['middle', 'Left', '', 'double_click', 'left '] {
		assert !is_button(name), name
	}
}

fn test_tray_clicked_data_is_the_wire_contract() {
	// The frontend switches on the payload, so it is pinned: two names, no
	// extras, no case to normalize.
	assert tray_clicked_data(TrayClick{
		button: button_left
	}) == '{"button":"left"}'
	assert tray_clicked_data(TrayClick{
		button: button_right
	}) == '{"button":"right"}'
}

fn test_tray_backend_binds_only_its_own_commands() {
	mut st := &TrayState{
		ctx: webview.Ctx{
			label: 'main'
		}
	}
	backend := tray_backend(mut st)
	mut keys := backend.keys()
	keys.sort()
	assert keys == ['tray.destroy', 'tray.set', 'tray.set_menu']
}

fn test_tray_backend_wraps_bad_params() {
	mut st := &TrayState{
		ctx: webview.Ctx{
			label: 'main'
		}
	}
	backend := tray_backend(mut st)
	set := backend['tray.set'] or { panic('tray.set must be bound') }
	mut failed := ''
	set('{"tooltip":7}') or { failed = err.msg() }
	assert failed.starts_with('bad params:')
}

fn test_a_state_without_a_window_never_reaches_the_native_call() {
	// The parent-window rule, kept in pure V so a hand-built Ctx is caught here
	// rather than by the shell: an AppIndicator needs the D-Bus connection the
	// GTK runtime owns, and a NOTIFYICONDATA has an hWnd.
	mut st := &TrayState{
		ctx: webview.Ctx{
			label: 'main'
		}
	}
	mut failed := ''
	set_tray(mut st, TrayOptions{
		tooltip: 'x'
	}) or { failed = err.msg() }
	assert failed.contains('window handle')
	// The state is unchanged: no icon, no hook.
	assert !st.set
	assert st.hook == unsafe { nil }
	assert st.indicator == unsafe { nil }
}

fn test_destroy_is_a_no_op_when_nothing_was_installed() {
	// An app that cleans up defensively must not get an error for it, and must
	// not reach the native call either (this Ctx has no window).
	mut st := &TrayState{
		ctx: webview.Ctx{
			label: 'main'
		}
	}
	destroy_tray(mut st) or { panic(err.msg()) }
	assert !st.set
}

fn test_simulate_click_needs_a_button_and_a_platform_answer() {
	mut st := &TrayState{
		ctx: webview.Ctx{
			label: 'main'
		}
	}
	mut failed := ''
	simulate_click(st, 'middle') or { failed = err.msg() }
	assert failed.contains('is not a tray button')
	assert failed.contains('left')
	// A valid button with no icon installed is refused before any native call:
	// there is nothing to click.
	mut no_icon := ''
	simulate_click(st, button_left) or { no_icon = err.msg() }
	$if windows {
		assert no_icon.contains('window handle')
	} $else $if linux {
		// Linux refuses for the real reason, and says what the real mechanism
		// is: the tray host opens the item's menu (ADR-0017).
		assert no_icon.contains('no click to simulate on linux')
		assert no_icon.contains('menu')
	}
}

fn test_simulate_click_needs_a_live_icon() {
	// The window is there, so the platform's own precondition is the one under
	// test: a tray with no icon has nothing to click.
	mut st := &TrayState{
		ctx: webview.Ctx{
			label:  'main'
			parent: voidptr(0x1234)
		}
	}
	mut failed := ''
	simulate_click(st, button_left) or { failed = err.msg() }
	$if windows {
		assert failed.contains('no icon is installed')
	} $else $if linux {
		assert failed.contains('no click to simulate on linux')
	}
}

fn test_tray_support_is_answered_per_platform() {
	// The `$if` in tray_support must match the one set_tray dispatches on, or
	// doctor and the implementation would disagree (ADR-0015).
	$if windows {
		assert tray_support().ready
		assert tray_support().note.contains('Shell_NotifyIconW')
	} $else $if linux {
		assert tray_support().ready
		// The Linux note has to say the part that is not proven here, or doctor
		// would be claiming a screenshot nobody can take.
		assert tray_support().note.contains('StatusNotifierHost')
	} $else {
		assert !tray_support().ready
	}
}
