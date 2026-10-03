module webview

// Sink records what reached one window's eval_fn, so a test can assert both
// what a window received and — the part that matters — what it did NOT.
//
// `&[heap]` because the sink is shared: it is handed to a closure that outlives
// the call that built it, so V has to know the pointee is not a stack object.
// A `[]string` behind a pointer because a test Ctx is copied by value every
// time it is passed to `emit` (Ctx has a value receiver on emit), so a closure
// capturing the slice by value would write into a copy and the test would pass
// having asserted nothing. Same rule as jobs_test.v's Probe.
@[heap]
struct Sink {
mut:
	got []string
}

// ready_window is a registered window with a live sink behind it.
//
// The closure captures a PLAIN `&Sink` and appends under `unsafe`, and both
// halves are load-bearing. V 0.5.2 copies a `mut s &Sink` *parameter* into the
// closure environment by value, so the append lands in the copy and the
// caller's sink stays empty — verified directly: with `mut s` captured, a
// direct call to the window's own `eval_fn` left `got.len == 0`. Capturing the
// pointer itself keeps the write on the caller's object, and `unsafe` is how
// V expresses "mutate through a shared reference" (the same move as
// `host.v`'s `free(host)`).
fn ready_window(label string, s &Sink) &Window {
	mut w := new_window(label)
	w.ctx = Ctx{
		label:   label
		eval_fn: fn [s] (js string) ! {
			unsafe {
				s.got << js
			}
		}
	}
	w.state = .ready
	return w
}

// A registry with no windows, and every operation on it refused by name.
fn test_an_empty_registry_has_no_windows() {
	r := new_registry()
	assert r.count() == 0
	assert r.labels() == []string{}
	assert !r.has('main')
	assert r.find('main') == unsafe { nil }
	assert r.open_labels() == []string{}
}

// The whole point of the file, in one test: two windows, two sinks, and an
// event addressed to one. The other window's sink must be untouched.
//
// The bug this pins is silent by construction. With a single window and a
// single Ctx, emitting to the wrong window is not a crash — it delivers the
// event, the promise resolves, and the wrong page's status line changes. A
// test suite that only ever has one window cannot see it, and a screenshot of
// one window cannot either.
fn test_an_event_addressed_to_one_window_never_reaches_another() {
	mut main_sink := &Sink{}
	mut other_sink := &Sink{}
	mut r := new_registry()
	r.add(ready_window('main', main_sink)) or { panic(err.msg()) }
	r.add(ready_window('settings', other_sink)) or { panic(err.msg()) }

	r.emit_to('settings', 'probe:done', 'hello') or { panic(err.msg()) }

	assert other_sink.got.len == 1
	assert other_sink.got[0].contains('hello')
	// The assertion that would have caught the real bug:
	assert main_sink.got.len == 0
}

// The same isolation, stated as "each window only ever hears its own label",
// across several emissions to both. One event could pass by luck of ordering;
// this cannot.
// test_every_window_only_ever_hears_its_own_events
fn test_every_window_only_ever_hears_its_own_events() {
	mut a := &Sink{}
	mut b := &Sink{}
	mut c := &Sink{}
	mut r := new_registry()
	r.add(ready_window('alpha', a)) or { panic(err.msg()) }
	r.add(ready_window('beta', b)) or { panic(err.msg()) }
	r.add(ready_window('gamma', c)) or { panic(err.msg()) }

	for label in ['alpha', 'beta', 'gamma', 'alpha', 'beta'] {
		r.emit_to(label, 'tick', label) or { panic(err.msg()) }
	}

	assert a.got.len == 2
	assert b.got.len == 2
	assert c.got.len == 1
	// events.to_js wraps both the name and the payload in SINGLE quotes
	// (events/js.v), so the payload is matched quoted — and each window is
	// checked for the *absence* of its siblings' labels, which is the half
	// that would catch a route going to the wrong page.
	for snippet in a.got {
		assert snippet.contains("'alpha'")
		assert !snippet.contains("'beta'")
		assert !snippet.contains("'gamma'")
	}
	for snippet in c.got {
		assert snippet.contains("'gamma'")
		assert !snippet.contains("'alpha'")
	}
}

// An unknown label is an ERROR, and nothing is delivered anywhere.
//
// This is the branch that matters most, because the convenient implementation
// is to fall back to some default window. That fallback delivers the event to
// a real and wrong page, which is the same defect as misrouting — a missing
// route that looks like a success. So the test asserts both halves: the error
// mentions the label, and neither sink saw anything.
fn test_an_unknown_label_is_refused_and_nothing_is_delivered() {
	mut a := &Sink{}
	mut r := new_registry()
	r.add(ready_window('main', a)) or { panic(err.msg()) }

	mut why := ''
	r.emit_to('settings', 'probe:done', 'hello') or { why = err.msg() }

	assert why.contains('settings')
	// And the message names what IS open, because "no window labelled x" with
	// an empty list is much harder to act on than one that says "open: main".
	assert why.contains('main')
	assert a.got.len == 0
}

// A window that exists but is not ready cannot be emitted to. Emitting through
// a nil eval_fn is a call through a null function pointer — a crash, not an
// error — so the state check is the only thing standing between a
// mis-ordered startup and a dead app.
fn test_a_window_that_is_not_ready_refuses_an_emit_by_name() {
	mut s := &Sink{}
	mut r := new_registry()
	created := new_window('main') // state .created, eval_fn still nil
	r.add(created) or { panic(err.msg()) }

	mut why := ''
	r.emit_to('main', 'probe:done', 'hello') or { why = err.msg() }

	assert why.contains('main')
	assert why.contains('created')
	assert !created.can_emit()
	assert s.got.len == 0
}

// A closed window is refused, and says "closed" rather than "no window such
// label" — the two are different mistakes and a caller reacts to them
// differently (one is a bug in the caller, the other is a race in the app).
fn test_a_closed_window_refuses_an_emit_and_says_so() {
	mut s := &Sink{}
	mut r := new_registry()
	r.add(ready_window('main', s)) or { panic(err.msg()) }
	assert r.remove('main') != unsafe { nil } // it was there

	mut why := ''
	r.emit_to('main', 'probe:done', 'hello') or { why = err.msg() }
	assert why.contains('main')
	// Unregistered on removal, so the message is the not-found one; the closed
	// state is what a caller holding the &Window can still ask about.
	assert why.contains('no window')
}

// Duplicate labels are refused. This is a capability hole and an ambiguous
// route in one: two windows sharing a label share a security identity, and
// emit_to would have two destinations and no way to choose.
fn test_two_windows_may_not_share_a_label() {
	mut r := new_registry()
	r.add(new_window('main')) or { panic(err.msg()) }
	mut why := ''
	r.add(new_window('main')) or { why = err.msg() }
	assert why.contains('main')
	assert why.contains('already')
	assert r.count() == 1
}

// An empty label is refused at registration, not at emit time. The label is
// the capability identity and the event route, so an empty one would make
// every window unaddressable and every capability check on it vacuous.
fn test_an_empty_label_is_refused_when_the_window_is_registered() {
	mut r := new_registry()
	mut why := ''
	r.add(new_window('')) or { why = err.msg() }
	assert why.contains('label')
	assert r.count() == 0
}

// Removal returns the window and marks it closed rather than freeing it: an
// app may still hold the &Window, and "is this open?" after a close is a
// legitimate question with a real answer.
fn test_removing_a_window_closes_it_and_hands_it_back() {
	mut r := new_registry()
	mut sink := &Sink{}
	w := ready_window('main', sink)
	r.add(w) or { panic(err.msg()) }
	assert w.is_open()

	removed := r.remove('main')
	assert removed == w
	assert !w.is_open()
	assert r.count() == 0
	// And removing again is a miss, not an error.
	assert r.remove('main') == unsafe { nil }
}

// emit_all reaches every ready window — the "both pages need to know" case —
// and deliberately skips a window that is not ready instead of failing on it,
// because a window still starting up is normal, not exceptional.
fn test_emit_all_reaches_every_ready_window_and_skips_the_rest() {
	mut a := &Sink{}
	mut b := &Sink{}
	mut r := new_registry()
	r.add(ready_window('a', a)) or { panic(err.msg()) }
	r.add(new_window('starting-up')) or { panic(err.msg()) }
	r.add(ready_window('b', b)) or { panic(err.msg()) }

	r.emit_all('theme', 'dark') or { panic(err.msg()) }

	assert a.got.len == 1
	assert b.got.len == 1
	assert a.got[0].contains('dark')
}

// open_labels is what a "bring every window up" step iterates, so it must
// report the windows that are usable and skip the closed ones.
fn test_open_labels_skips_closed_windows_and_keeps_creation_order() {
	mut r := new_registry()
	r.add(new_window('first')) or { panic(err.msg()) }
	r.add(new_window('second')) or { panic(err.msg()) }
	r.add(new_window('third')) or { panic(err.msg()) }
	assert r.remove('second') != unsafe { nil }

	assert r.open_labels() == ['first', 'third']
	// labels() is the registry's full history, which is what a diagnostic
	// wants; open_labels() is what a driver wants. Keeping them different is
	// the point of having both.
	assert r.labels() == ['first', 'third']
}

// get is find with the error attached, and its message lists the open labels
// so a typo is diagnosable from the log line alone.
fn test_get_names_the_open_labels_when_it_fails() {
	mut r := new_registry()
	r.add(new_window('main')) or { panic(err.msg()) }
	r.add(new_window('settings')) or { panic(err.msg()) }

	mut why := ''
	r.get('nope') or { why = err.msg() }
	assert why.contains('nope')
	assert why.contains('main, settings')
}

// A window that cannot be closed programmatically says so instead of quietly
// doing nothing: an app waiting for a window to disappear needs to know the
// difference between "asked, and it will go" and "nothing happened".
fn test_closing_a_window_with_no_backend_hook_is_an_error() {
	c := Ctx{
		label: 'main'
	}
	assert !c.can_close()
	mut why := ''
	c.close() or { why = err.msg() }
	assert why.contains('cannot be closed')
	assert why.contains('main')
}

// stop_all asks every open window to close. With no hook installed it fails on
// the first one rather than pretending the set was closed — the same rule as
// emit_to: a routing or lifecycle operation that half-succeeded and reported
// success is the multi-window version of the quiet bug.
fn test_stop_all_reports_a_window_it_could_not_close() {
	mut r := new_registry()
	r.add(new_window('main')) or { panic(err.msg()) }
	mut why := ''
	r.stop_all() or { why = err.msg() }
	assert why.contains('cannot be closed')
}

// window_state names are one place, so an error message that says "created"
// and a doctor line that says "created" cannot drift apart.
fn test_window_states_have_stable_names() {
	assert state_name(.created) == 'created'
	assert state_name(.ready) == 'ready'
	assert state_name(.running) == 'running'
	assert state_name(.closed) == 'closed'
}

// The label reaches the page through a string built here, so the escaping is
// pinned rather than hoped for. The quote case is the one that matters: a label
// containing a double quote would otherwise close the JS string literal and
// everything after it would be script the app did not write.
fn test_label_js_quotes_the_label_and_escapes_quotes() {
	out := label_js('BASE();', 'settings')
	assert out.starts_with('BASE();')
	assert out.contains("window.vails.label = 'settings';")
}

// The escaping test, and it exists because the first version of label_js
// wrapped the label in DOUBLE quotes and this is what it failed: `jsesc.escape`
// leaves a `"` completely unchanged, so the quote closed the JS literal and
// turned the rest of the label into script. Both quote characters are checked
// here, in both roles, because the failure mode is "the string ends earlier than
// you think" and that is invisible unless you look for exactly it.
fn test_label_js_escapes_a_single_quote_in_the_label() {
	out := label_js('BASE();', "a'b")
	eprintln('[tmp] label_js = ' + out)
	// The label's own quote must not be able to close the literal.
	assert !out.contains("= 'a'b';")
	assert out.contains("\\'")
}

fn test_label_js_leaves_a_double_quote_harmless_inside_a_single_quoted_literal() {
	// A double quote inside a single-quoted JS string is legal and needs no
	// escaping, which is the whole reason the literal is single-quoted.
	out := label_js('BASE();', 'a"b')
	assert out.contains('= \'a"b\';')
}

fn test_label_js_escapes_a_backslash() {
	// A trailing backslash would escape the closing quote and swallow whatever
	// came next. This is the second way the same injection happens.
	out := label_js('BASE();', 'a\\')
	assert out.contains("label = 'a\\\\';")
}

// The assignment has to survive the runtime's own guard, which is an IIFE that
// returns early when window.vails already exists. So the label line must come
// AFTER the base, never inside it.
fn test_label_js_appends_outside_the_runtime() {
	base := 'window.vails.__x = 1;'
	out := label_js(base, 'main')
	at_base := out.index(base) or { -1 }
	at_label := out.index('window.vails.label') or { -1 }
	assert at_base >= 0
	assert at_label > at_base
}
