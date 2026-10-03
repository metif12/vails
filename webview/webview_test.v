module webview

fn test_config_defaults() {
	cfg := Config{}
	assert cfg.label == 'main'
	assert cfg.title == 'Vails App'
	assert cfg.width == 1024
	assert cfg.height == 768
	assert cfg.html == ''
	assert cfg.url == ''
}

fn test_config_label_is_security_identity() {
	cfg := Config{
		label: 'settings'
		title: 'Settings'
	}
	assert cfg.label != cfg.title
	assert cfg.label == 'settings'
}

fn test_validate_ok() {
	Config{}.validate()!
}

fn test_validate_rejects() {
	mut bad_title := 0
	Config{
		title: ''
	}.validate() or { bad_title = 1 }
	assert bad_title == 1
	mut bad_size := 0
	Config{
		width: 0
	}.validate() or { bad_size = 1 }
	assert bad_size == 1
}

fn test_run_requires_router_on_windows() {
	$if windows {
		run(Config{}) or {
			assert err.msg().contains('router')
			return
		}
		assert false
	} $else {
		assert true
	}
}

fn test_run_unsupported_off_win_linux() {
	$if !windows && !linux {
		run(Config{}) or {
			assert err.msg().contains('windows and linux')
			return
		}
		assert false
	} $else {
		// Windows (with router) and Linux open a real window;
		// covered manually — see tests/e2e_linux/README.md.
		assert true
	}
}

fn test_run_many_needs_at_least_one_window() {
	mut why := ''
	run_many([]Config{}) or { why = err.msg() }
	assert why.contains('at least one window')
}

// The rules that make a misconfiguration impossible rather than half-built. Both
// are refused BEFORE any window appears, which is the property worth pinning:
// "the app opened one window and then printed an error" is a worse failure than
// "the app printed an error".
fn test_run_many_refuses_two_windows_with_the_same_label() {
	mut why := ''
	run_many([Config{ label: 'main' }, Config{ label: 'main' }]) or { why = err.msg() }
	assert why.contains('share the label')
	assert why.contains('main')
}

fn test_run_many_refuses_an_invalid_config() {
	mut why := ''
	run_many([Config{ title: '' }]) or { why = err.msg() }
	assert why.contains('title')
}

// F0's second window is no longer gated, so what is left to pin here is that
// nothing ELSE got gated with it — and that the rules that used to be buried
// inside `run_many` still say the same thing through their new front door.
//
// The test that lived here before asserted the refusal ("one window, and the
// blocker is named"). It was deleted with the refusal, and the reason it was
// worth having is worth keeping in mind: the failure it was protecting against
// is a window that appears, refuses a dispatch, and takes the process down with
// it. `com_enter` in webview_windows.c.v is what now stands between that and a
// crash, and it is native code — so the tests that CAN run without a WebView2
// window are the ones that had better all be green.
fn test_two_windows_get_past_every_rule_checkable_without_a_native_window() {
	// Two well-formed, distinctly-labelled windows must clear `check_windows`.
	// This is the assertion that the ">1 window" gate is really gone, and it is
	// deliberately the PURE function rather than `run_many`: calling `run_many`
	// here would open two real WebView2 windows inside a unit test.
	check_windows([Config{ label: 'main' }, Config{ label: 'settings' }]) or {
		panic('two distinct, valid windows must pass check_windows: ' + err.msg())
	}
	// And a single window is still the shape `run` uses — no rule is about a
	// count above one.
	check_windows([Config{}]) or { panic('one window must pass: ' + err.msg()) }
}

fn test_run_many_on_windows_runs_the_ordinary_path_for_one_window() {
	$if windows {
		// One window with no router is refused by the backend for the missing
		// router and for nothing else — in particular NOT for being a single
		// window, which is the gate F0 removed. This is the regression test for
		// that gate: if a future change re-adds a count check with a different
		// message, this still passes, and the removal stays visible in the ADR.
		mut single := ''
		run_many([Config{}]) or { single = err.msg() }
		assert single.contains('router')
		assert !single.contains('window label')
	} $else {
		assert true
	}
}
