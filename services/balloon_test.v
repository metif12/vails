// services/balloon_test.v - the balloon service's pure half (ADR-0039).
//
// What is testable here is the policy, not the shell: the bounds, the timeout
// clamp, and above all the icon-lifetime rules. `Shell_NotifyIconW` needs a
// notification area and a human, so the native path is proven by hand - see
// tests/e2e_windows/README.md.
//
// The dead-icon hazard is the part worth spending tests on. ADR-0018 removed the
// balloon from `notification` partly because "a single stray worker would have
// left a row of dead icons", and the fix is a per-call icon id rather than a
// cleverer worker. That fix is arithmetic, so it is asserted as arithmetic.

module services

import bridge
import capabilities
import json2

// balloon_grant is dialog_test.v's `grant` under a different name, and the
// name is the point: every `*_test.v` in this module is compiled together, so
// two helpers called `grant` would be a redefinition - which is why
// clipboard_test.v spells its equivalent `granted`.
fn balloon_grant(names []string) capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		windows:  ['main']
		commands: names
	})
	return reg
}

fn test_manifest_names_the_service_and_its_commands() {
	m := balloon_manifest()
	assert m.name == 'balloon'
	assert m.summary.contains('secondary')
	names := m.commands.map(it.name)
	assert names == ['balloon.show', 'balloon.is_supported']
	// The manifest has to say what a balloon is not, because a frontend reading
	// only the catalog cannot otherwise tell it apart from notification.
	assert m.summary.contains('NOT a Windows toast') || m.commands[0].summary.contains('balloon')
	assert m.ts_types.len > 0
	assert m.ts_types[0].contains('timeout_ms?: number')
}

fn test_parse_balloon_options_from_an_object() {
	opts := parse_balloon_options('{"title":"Vails","body":"built","timeout_ms":3000}') or {
		panic(err.msg())
	}
	assert opts.title == 'Vails'
	assert opts.body == 'built'
	assert opts.timeout_ms == 3000
}

// The minimal frontend should be able to say something in one call, exactly as
// notification.notify accepts a bare string.
fn test_parse_balloon_options_from_a_bare_string() {
	opts := parse_balloon_options('"just a body"') or { panic(err.msg()) }
	assert opts.title == ''
	assert opts.body == 'just a body'
	assert opts.timeout_ms == default_balloon_timeout
}

fn test_parse_balloon_options_rejects_an_empty_body() {
	mut failed := ''
	parse_balloon_options('') or { failed = err.msg() }
	assert failed.contains('no body'), 'empty payload gave: [' + failed + ']'
	// A bare JSON string that is only whitespace.
	failed = ''
	parse_balloon_options('"   "') or { failed = err.msg() }
	assert failed.contains('body is required'), 'whitespace body gave: [' + failed + ']'
	// And the object form: a title with no body is not a balloon.
	failed = ''
	parse_balloon_options('{"title":"only a title"}') or { failed = err.msg() }
	assert failed.contains('body is required'), 'title-only gave: [' + failed + ']'
}

fn test_validate_balloon_enforces_the_shell_field_widths() {
	// The bounds are the shell's own field widths, so a caller that fits can
	// always be displayed in full.
	ok := BalloonOptions{
		title: 'x'.repeat(max_balloon_title)
		body:  'y'.repeat(max_balloon_body)
	}
	validate_balloon(ok)!
	over := BalloonOptions{
		title: 'x'.repeat(max_balloon_title + 1)
		body:  'b'
	}
	// The house pattern for a void `!` function, and not a style choice: on this
	// compiler `validate_balloon(x) or { panic(..) }` inside a test_ function is
	// parsed as something other than what it looks like, and the assertion silently
	// passes (AGENTS.md §2b). Capturing the message is also what proves *why* it was
	// rejected rather than merely that it was.
	mut failed := ''
	validate_balloon(over) or { failed = err.msg() }
	assert failed.contains('title is longer'), 'title len=' + over.title.len.str() +
		' max=' + max_balloon_title.str() + ' said: [' + failed + ']'
	// The body bound is the same rule on the other field, and it is a separate
	// branch in the source - so it needs its own case.
	long_body := BalloonOptions{
		title: 't'
		body:  'y'.repeat(max_balloon_body + 1)
	}
	failed = ''
	validate_balloon(long_body) or { failed = err.msg() }
	assert failed.contains('body is longer'), 'body len=' + long_body.body.len.str() +
		' max=' + max_balloon_body.str() + ' said: [' + failed + ']'
}

fn test_validate_balloon_rejects_a_nul() {
	// A NUL would truncate inside the shell's wide field - a truncation the
	// caller did not ask for.
	for opts in [BalloonOptions{ title: 'a\x00b', body: 'b' },
		BalloonOptions{ title: 'a', body: 'a\x00b' }] {
		mut failed := ''
		validate_balloon(opts) or { failed = err.msg() }
		assert failed.contains('NUL')
	}
}

fn test_clamp_balloon_timeout() {
	assert clamp_balloon_timeout(0) == min_balloon_timeout
	assert clamp_balloon_timeout(min_balloon_timeout - 1) == min_balloon_timeout
	assert clamp_balloon_timeout(default_balloon_timeout) == default_balloon_timeout
	assert clamp_balloon_timeout(max_balloon_timeout) == max_balloon_timeout
	assert clamp_balloon_timeout(max_balloon_timeout + 1) == max_balloon_timeout
	// A caller asking for a very long balloon is clamped, not refused: the
	// timeout is a hint and 10 minutes is not a reason to fail a command.
	assert clamp_balloon_timeout(600000) == max_balloon_timeout
}

// The grace period is the whole reason this function exists. `uTimeout` removes
// the balloon's TEXT; nothing removes its ICON. Removing the icon at the timeout
// instead of after it shows the user a message with no icon beside it, which is
// the one artefact that makes a balloon look broken.
fn test_cleanup_always_outlasts_the_balloon() {
	for ms in [0, 1, 1500, 8000, 30000, 999999] {
		cleanup := balloon_cleanup_ms(ms)
		assert cleanup > clamp_balloon_timeout(ms)
		assert cleanup - clamp_balloon_timeout(ms) == balloon_icon_grace_ms
	}
	// And specifically: a clamped-up request still gets its grace.
	assert balloon_cleanup_ms(max_balloon_timeout + 5000) ==
		max_balloon_timeout + balloon_icon_grace_ms
}

// The dead-icon fix, asserted directly: consecutive calls must not share an id,
// or they overwrite each other and the first cleanup deletes the second's icon.
fn test_consecutive_balloons_get_different_icon_ids() {
	mut st := &BalloonState{}
	first := st.next_icon_id()
	second := st.next_icon_id()
	assert first != second
	assert st.seq == 2
}

fn test_icon_ids_stay_inside_their_span() {
	// Every id is base + [0, span), for any call number - including the ones
	// nobody will reach.
	for seq in [0, 1, balloon_uid_span - 1, balloon_uid_span, balloon_uid_span + 1, 1000000, -1,
		-1025] {
		id := balloon_icon_id(seq)
		offset := int(id) - int(balloon_icon_base)
		assert offset >= 0, 'seq ${seq} gave a negative offset'
		assert offset < balloon_uid_span, 'seq ${seq} left the span'
	}
}

// The wrap, stated as a design consequence rather than an accident: after
// balloon_uid_span calls the ids repeat. That is benign *because* the cleanup
// deletes by (hWnd, uId) and deleting an absent icon is a shell no-op, so a late
// worker can only remove an icon that is already gone. This test exists so that
// somebody tightening balloon_uid_span has to look at the reason.
fn test_icon_ids_wrap_and_the_wrap_is_contained() {
	assert balloon_icon_id(balloon_uid_span) == balloon_icon_id(0)
	assert balloon_icon_id(balloon_uid_span + 7) == balloon_icon_id(7)
	assert balloon_icon_id(-1) == balloon_icon_id(balloon_uid_span - 1)
}

// ## The independence assertions
//
// ADR-0039's decision is not "balloon is a notification backend that is off by
// default"; it is "balloon is a different service". These two tests are the only
// place that says so in a way a future edit has to break on purpose, because
// merging the two is the natural refactor and it would look harmless.
//
// `notification` resolving with 'toast' and `balloon` resolving with 'balloon'
// is not enough on its own: a later edit could add a fallback in notification and
// leave the mechanism constant alone.

fn test_notification_cannot_resolve_with_a_balloon() {
	assert notification_manifest().commands[0].result == 'string'
	// The mechanism vocabulary is a closed set, and balloon is not in it.
	assert backend_toast == 'toast'
	assert balloon_backend_balloon == 'balloon'
	// The commands that exist are the ones the manifests declare - no hidden
	// balloon path on the notification service.
	names := notification_manifest().commands.map(it.name)
	assert !names.contains('notification.balloon')
	assert names == ['notification.notify', 'notification.is_supported']
}

fn test_the_two_manifests_do_not_claim_each_other() {
	nm := notification_manifest()
	bm := balloon_manifest()
	// notification must not advertise the balloon...
	assert !nm.summary.contains('balloon')
	assert !nm.commands.map(it.summary).join(' ').contains('balloon')
	// ...and balloon must not call itself a toast.
	assert !bm.summary.contains('toast')
	assert !bm.commands.map(it.summary).join(' ').contains('toast')
}

fn test_install_balloon_binds_both_commands() {
	mut router := bridge.new_router()
	mut backend := Backend{}
	backend['balloon.show'] = fn (_ string) !string {
		return json2.encode(balloon_backend_balloon)
	}
	backend['balloon.is_supported'] = fn (_ string) !string {
		return json2.encode(true)
	}
	install(mut router, balloon_manifest(), backend)!
	mut res := router.call_json('main', '1', 'balloon.is_supported', '', balloon_grant(['balloon.is_supported']))
	assert res.err == ''
	assert res.result == 'true'
	// A command outside the grant is refused, so the capability system covers the
	// new service without being taught anything new.
	res = router.call_json('main', '2', 'balloon.show', '{"body":"hi"}',
		balloon_grant(['balloon.is_supported']))
	assert res.err.starts_with('forbidden:')
}

// The catalog and the support list must agree, or `doctor` prints a service the
// .d.ts does not have (or the reverse).
fn test_balloon_is_in_the_catalog_and_the_support_list() {
	names := manifests().map(it.name)
	assert names.contains('balloon')
	// Once each: a duplicate would install the service twice and shadow the
	// first registration.
	assert names.filter(it == 'balloon').len == 1
	statuses := status_names(supports())
	assert statuses.contains('balloon')
	assert statuses.filter(it == 'balloon').len == 1
}

// support.v's own invariant (a ready row must have a note) is checked for balloon
// by that suite; what is specific here is that the note states the limitation.
// A reader of `doctor` must be able to tell this is not a toast.
fn test_balloon_support_states_what_it_is_not() {
	s := balloon_support()
	assert s.name == 'balloon'
	assert s.note.contains('ADR-0039')
	$if windows {
		assert s.ready
		assert s.note.contains('NIF_INFO')
		// The two facts that make it secondary, named explicitly.
		assert s.note.contains('NOT a Windows toast')
		assert s.note.contains('.exe')
	} $else {
		assert !s.ready
		// Not "not implemented" alone - it must say why there will be no GTK
		// equivalent, or a Linux reader will file the gap as an oversight.
		assert s.note.contains('not a shell balloon')
	}
}
