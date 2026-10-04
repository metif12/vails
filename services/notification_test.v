module services

import bridge
import capabilities
import webview

fn notify_grant(commands []string) capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		commands: commands
	})
	return reg
}

fn test_manifest_shape() {
	m := notification_manifest()
	assert m.name == 'notification'
	assert m.command_names() == ['notification.notify', 'notification.is_supported']
	assert m.commands[0].params == 'NotificationOptions'
	// is_supported takes no params, so the install path wires validate_empty
	assert m.commands[1].params == no_params
	// a toast does not block the main thread: the shell owns the UI
	assert !m.commands[0].blocking
}

fn test_manifest_is_in_the_catalog() {
	assert find('notification') != none
	assert service_of('notification.notify') != none
	if s, c := lookup('is_supported') {
		assert s.name == 'notification'
		assert c.name == 'notification.is_supported'
	} else {
		assert false, 'is_supported must resolve to notification.is_supported'
	}
}

fn test_parse_notify_options_accepts_an_object_or_a_bare_string() {
	// snake_case keys, because a V field name is the wire name (json2 does
	// not map camelCase onto snake_case)
	opts := parse_notify_options('{"title":"Vails","body":"hello","timeout_ms":2000}')!
	assert opts.title == 'Vails'
	assert opts.body == 'hello'
	assert opts.timeout_ms == 2000
	// a minimal frontend can send just the body
	assert parse_notify_options('"hello"')!.body == 'hello'
	// and the timeout defaults instead of being zero
	assert parse_notify_options('{"body":"hello"}')!.timeout_ms == default_timeout
}

fn test_parse_notify_options_requires_a_body() {
	for bad in ['', 'null', '{}', '{"title":"Vails"}', '"   "', '{oops'] {
		mut failed := false
		parse_notify_options(bad) or { failed = true }
		assert failed, 'must reject "' + bad + '"'
	}
}

fn test_validate_enforces_the_string_bounds() {
	validate_notification(NotificationOptions{
		title: 'a'.repeat(max_notify_title)
		body:  'b'.repeat(max_notify_body)
	})!
	mut failed := false
	validate_notification(NotificationOptions{
		title: 'a'.repeat(max_notify_title + 1)
		body:  'b'
	}) or { failed = true }
	assert failed
	failed = false
	validate_notification(NotificationOptions{
		title: 'a'
		body:  'b'.repeat(max_notify_body + 1)
	}) or { failed = true }
	assert failed
	// the timeout is a hint, so validate never looks at it
	validate_notification(NotificationOptions{
		body:       'b'
		timeout_ms: -5
	})!
	// a NUL would truncate the string inside the C call, and a truncation
	// the frontend did not ask for is worse than a rejection
	failed = false
	validate_notification(NotificationOptions{
		title: 'a\x00b'
		body:  'b'
	}) or { failed = true }
	assert failed
	failed = false
	validate_notification(NotificationOptions{
		title: 'a'
		body:  'b\x00c'
	}) or { failed = true }
	assert failed
}

fn test_clamp_timeout() {
	assert clamp_timeout(0) == min_timeout
	assert clamp_timeout(-1000) == min_timeout
	assert clamp_timeout(min_timeout) == min_timeout
	assert clamp_timeout(4000) == 4000
	assert clamp_timeout(max_timeout) == max_timeout
	assert clamp_timeout(max_timeout * 10) == max_timeout
}

// A body longer than the shell's 256-unit field is truncated by the backend,
// not rejected: the pure-V bound (512 bytes) is what the frontend can count
// on, and this documents that the two are deliberately different numbers.
fn test_with_clamped_timeout_returns_a_clamped_copy() {
	// A copy, so the caller's value is untouched - which is what makes this
	// a pure function worth testing.
	opts := NotificationOptions{
		title:      'Vails'
		body:       'hello'
		timeout_ms: 0
	}
	clamped := with_clamped_timeout(opts)
	assert clamped.timeout_ms == min_timeout
	assert clamped.title == 'Vails' && clamped.body == 'hello'
	assert opts.timeout_ms == 0
	assert with_clamped_timeout(NotificationOptions{
		body:       'b'
		timeout_ms: 9000
	}).timeout_ms == 9000
	assert with_clamped_timeout(NotificationOptions{
		body:       'b'
		timeout_ms: max_timeout * 2
	}).timeout_ms == max_timeout
}

// The bounds are byte counts on the *validated* value. Unlike the balloon
// this replaced, a WinRT toast has no fixed-width shell field to clip
// against, so the bound is the only limit the frontend can count on - which
// is why it is tested here rather than left implicit.
fn test_the_bound_is_the_only_limit_on_a_toast() {
	assert max_notify_body > 0
	assert max_notify_title > 0
	assert max_notify_title < max_notify_body
}

fn test_escape_xml_escapes_the_five_entities() {
	// '&' and '<' are the two that actually break the document
	assert escape_xml('a & b') == 'a &amp; b'
	assert escape_xml('<b>') == '&lt;b&gt;'
	assert escape_xml('"q"') == '&quot;q&quot;'
	assert escape_xml("it's") == 'it&apos;s'
	// all of them at once, in input order. The real invariant is that the
	// '&' we *emit* is never itself escaped - a single-pass matcher
	// guarantees that, and this is the assertion that would catch a
	// two-pass implementation producing '&amp;amp;'.
	assert escape_xml('<&">') == '&lt;&amp;&quot;&gt;'
	assert !escape_xml('&').contains('&amp;amp;')
}

fn test_escape_xml_leaves_ordinary_text_alone() {
	// The document is UTF-8 end to end, so non-ASCII is not escaped -
	// escaping it would be both wrong and unreadable.
	for s in ['hello', 'Vails', 'héllo wörld', 'done 🌱', 'line1\nline2', '100% ok'] {
		assert escape_xml(s) == s
	}
	// and the empty string is a fixed point
	assert escape_xml('') == ''
}

fn test_toast_duration_maps_the_clamped_timeout() {
	assert toast_duration(min_timeout) == 'short'
	assert toast_duration(default_timeout) == 'short'
	assert toast_duration(long_duration_timeout - 1) == 'short'
	assert toast_duration(long_duration_timeout) == 'long'
	assert toast_duration(max_timeout) == 'long'
	// out-of-range values still land on one of the two, because
	// toast_xml clamps before calling this
	assert toast_duration(0) == 'short'
	assert toast_duration(max_timeout * 10) == 'long'
}

fn test_toast_xml_emits_the_generic_template_with_both_texts() {
	xml := toast_xml(NotificationOptions{
		title: 'Vails probe'
		body:  'Notification from the page.'
	})
	assert xml.starts_with('<toast duration="short">')
	assert xml.contains('template="ToastGeneric"')
	// title first, body second: that is the order the template renders
	assert xml.index('Vails probe') or { -1 } < xml.index('Notification from the page.') or {
		-1
	}
	assert xml.ends_with('</toast>')
	assert xml.contains('<text>Vails probe</text>')
}

fn test_toast_xml_omits_an_empty_title() {
	// A blank first line is how ToastGeneric says "no heading", so
	// emitting an empty <text> anyway is what puts a mysterious gap above
	// a body-only notification.
	xml := toast_xml(NotificationOptions{
		body: 'just a body'
	})
	assert !xml.contains('<text></text>')
	assert xml.contains('<text>just a body</text>')
	// exactly one text node, not two
	assert xml.count('<text>') == 1
}

fn test_toast_xml_escapes_both_strings() {
	// The whole point of building the document in pure V: an unescaped
	// '<' from a frontend produces a document the shell refuses, and the
	// symptom (nothing appears) points nowhere near the cause.
	xml := toast_xml(NotificationOptions{
		title: '5 < 6 & rising'
		body:  'if a < b then "yes"'
	})
	assert !xml.contains('<b>')
	assert xml.contains('5 &lt; 6 &amp; rising')
	assert xml.contains('if a &lt; b then &quot;yes&quot;')
	// and the result is still a document with a plausible shape
	assert xml.starts_with('<toast ')
	assert xml.ends_with('</toast>')
}

fn test_toast_xml_carries_the_clamped_duration() {
	// The timeout's one surviving effect: the toast asks the shell for the
	// longer of the two on-screen durations it offers.
	long_xml := toast_xml(NotificationOptions{
		body:       'b'
		timeout_ms: max_timeout * 10
	})
	assert long_xml.contains('duration="long"')
	// out-of-range low values clamp up rather than producing a third state
	short_xml := toast_xml(NotificationOptions{
		body:       'b'
		timeout_ms: -1
	})
	assert short_xml.contains('duration="short"')
}

fn test_is_supported_is_true_only_where_a_backend_exists() {
	// The point of the command: an honest answer, so a frontend can ask
	// instead of firing a notification that quietly does nothing.
	//
	// **This is the COMPILE-TIME question**, deliberately separate from
	// `notification_support()`: "is the backend built in" is true on every Windows
	// machine, while "can this session show one" is not. Both are real questions
	// and conflating them is what made `doctor` lie - see the next test.
	$if windows {
		assert is_supported()
	} $else {
		assert !is_supported()
	}
}

// `doctor` must not claim a notification works where one cannot be shown.
//
// The bug this pins, found by the showcase's verify run on 2026-10-03: `doctor`
// printed `ok notification` and the showcase's support table said ready, so the
// panel called `notification.notify` and got
// `RoGetActivationFactory` -> `hr=0x80040154` (REGDB_E_CLASSNOTREG). A doctor
// line that says ok for something that does not work *here* is the over-read
// AGENTS.md 5 exists to prevent, and it was only reachable because
// `notification_support()` hardcoded `ready: true` instead of probing.
fn test_support_agrees_with_what_the_machine_can_actually_do() {
	s := notification_support()
	assert s.name == 'notification'
	$if windows {
		// The invariant, expressed in terms of the reason rather than a bool:
		// `ready` must mean "the probe found nothing wrong". Stated as
		// `toast_available()` it also held, but that let a second probe of the
		// same fact exist and drift; ADR-0039 replaced the bool with the
		// reason code precisely so this line has something to say.
		assert s.ready == (toast_failure_reason() == toast_reason_ok), 'notification_support().ready must be the machine probe ' +
			'(toast_failure_reason), never a hardcoded true'
		// Whichever way it went, the note has to explain itself - a stub without a
		// reason is useless in a doctor report, and support_test.v's invariant
		// already requires one but not that it is *useful*.
		if !s.ready {
			// And the useful part is specifically that it carries the *cause*:
			// the note is the mapped sentence for this machine's reason code,
			// verbatim. That is the invariant that stops `doctor` from naming
			// the wrong repair - it failed before by naming the AUMID on a
			// machine whose Windows had no WinRT at all.
			assert s.note.contains(toast_failure_note(toast_failure_reason()))
			// And the compile-time answer must not have been dragged along with it:
			// the backend IS in the build, and saying otherwise would send a reader
			// looking for a missing dependency that is not missing.
			assert is_supported()
			assert s.note.contains('built in')
		}
	} $else {
		// No WinRT here, so no toast - and the note has to say so for the same
		// reason the Windows branch demands a cause: `doctor` is read on Linux
		// too, and "no backend on this platform" with no reason is the stub
		// this whole service was written to avoid.
		assert !s.ready
		assert s.note.contains(toast_failure_note(toast_reason_other_platform))
	}
}

fn test_notify_rejects_a_bad_payload_with_the_standard_prefix() {
	// Called directly, not through the router: the contract must not depend
	// on the route.
	ctx := webview.Ctx{
		label: 'main'
	}
	mut failed := false
	too_long := NotificationOptions{
		body: 'b'.repeat(max_notify_body + 1)
	}
	notify(ctx, probe_identity(), too_long) or {
		failed = true
		assert err.msg().starts_with('bad params:')
	}
	assert failed
}

// The identity a test uses: a well-formed AUMID, so a failure can only come
// from the notification itself and not from a missing bundle.identifier.
// Not named test_* : V would parse it as a test function and reject its
// return type (same trap ADR-0015 records about per-file test helpers).
fn probe_identity() AppIdentity {
	return AppIdentity{
		id:           'com.vails.test'
		display_name: 'Vails Test'
	}
}

// No AppUserModelID is refused with a message that names the config field.
// A toast raised with no identity is the silent failure this service exists
// to avoid, so guessing an id is not an option.
fn test_notify_without_an_identity_fails_loudly() {
	$if windows {
		ctx := webview.Ctx{
			label: 'main'
		}
		mut failed := false
		notify(ctx, AppIdentity{}, NotificationOptions{
			body: 'hello'
		}) or {
			failed = true
			assert err.msg().contains('bundle.identifier')
		}
		assert failed, 'an empty AppUserModelID must be an error, not a guess'
	}
}

fn test_install_binds_both_commands() {
	mut router := bridge.new_router()
	install_notification(mut router, webview.Ctx{
		label: 'main'
	}, probe_identity())!
	reg := notify_grant(['notification.notify', 'notification.is_supported'])
	// is_supported answers without touching a native half, so this is a real
	// end-to-end check of the binding: a JSON boolean, ready for JSON.parse
	mut res := router.call_json('main', '1', 'notification.is_supported', '', reg)
	assert res.err == ''
	assert res.result == 'true' || res.result == 'false'
	// and notify refuses a payload with no body before any native call
	res = router.call_json('main', '2', 'notification.notify', '{"title":"Vails"}', reg)
	assert res.err.starts_with('bad params:')
	assert res.err.contains('body is required')
}

fn test_install_denies_an_ungranted_command() {
	mut router := bridge.new_router()
	install_notification(mut router, webview.Ctx{
		label: 'main'
	}, probe_identity())!
	res := router.call_json('main', '1', 'notification.notify', '{"body":"hi"}',
		notify_grant(['notification.is_supported']))
	assert res.err.starts_with('forbidden:')
	assert res.err.contains('notification.notify')
}

// ## toast_failure_note: the mapping is the testable half of the probe
//
// The registry probe itself is C and `v test` cannot reach it (ADR-0039). What
// can be tested - exhaustively - is that every reason code the C half can
// return produces a distinct, actionable sentence. A new code added on the C
// side without a V branch would otherwise show up as a bare "unrecognised code"
// string in `vails doctor`, which is exactly the unhelpful output this work
// set out to remove.

fn test_toast_failure_note_covers_every_reason_code() {
	// ok is not a failure: an empty note, so a caller can concatenate it
	// unconditionally.
	assert toast_failure_note(toast_reason_ok) == ''
	// Each real code must say something, and must not echo the raw code back -
	// the point is that a reader gets a sentence, not a token.
	codes := [
		toast_reason_no_class_store,
		toast_reason_not_registered,
		toast_reason_activate_failed,
		toast_reason_init_failed,
		toast_reason_other_platform,
	]
	mut seen := map[string]bool{}
	for code in codes {
		note := toast_failure_note(code)
		assert note.len > 40, 'code "${code}" produced a stub note: ${note}'
		assert !note.contains(code), 'note for "${code}" leaks the raw code'
		assert !(note in seen), 'two codes produced the same note'
		seen[note] = true
	}
}

fn test_toast_failure_note_names_the_missing_store_and_the_repair() {
	note := toast_failure_note(toast_reason_no_class_store)
	// The measured cause, stated exactly: not "the toast failed", but which
	// registry branch is gone.
	assert note.contains('ActivatableClasses')
	// The repair, because a diagnosis a reader cannot act on is half a note.
	assert note.contains('RestoreHealth')
	assert note.contains('sfc /scannow')
	// And the correction of the natural misdiagnosis: this is not an identity
	// problem, and telling a reader to check bundle.identifier here is what
	// this note exists to stop them doing.
	assert note.contains('not a Vails bug')
	assert note.contains('AppUserModelID')
}

fn test_toast_failure_note_distinguishes_a_wrong_identity() {
	// The two REGDB_E_CLASSNOTREG cases must not read alike: one is a broken
	// Windows image, the other is a partial install.
	debloated := toast_failure_note(toast_reason_no_class_store)
	partial := toast_failure_note(toast_reason_not_registered)
	assert debloated != partial
	assert partial.contains('RestoreHealth')
	// A missing AUMID does NOT produce the registration HRESULT, so this note
	// must not send the reader to bundle.identifier.
	assert !partial.contains('bundle.identifier')
}

fn test_toast_failure_note_reports_an_unknown_code_verbatim() {
	// A code the C half learned and this half did not: report it rather than
	// invent a diagnosis. Guessing here is how a wrong repair gets suggested.
	note := toast_failure_note('something-new')
	assert note.contains('something-new')
	assert note.contains('does not recognise')
}

// ## Toast action buttons: built, tested, not sent (ADR-0039)
//
// The decision under test is a negative one - the service must NOT put buttons
// on the wire - so the tests are shaped around the gate rather than around the
// builder. Both halves are pinned: the builder because it is the code that has
// to be right when the gate opens, and the gate because until it opens the
// builder is unreachable and therefore untested by anything else.

fn test_toast_xml_omits_actions_while_the_capability_is_false() {
	opts := NotificationOptions{
		title:   'Build finished'
		body:    '2 errors'
		actions: [
			NotificationAction{ id: 'open', content: 'Open' },
		]
	}
	xml := toast_xml(opts)
	// The gate is what makes this pass today.
	assert !toast_actions_available
	assert !xml.contains('<actions>')
	// And the rest of the document is intact - a gate must not quietly break the
	// toast it is gating.
	assert xml.contains('<text>Build finished</text>')
	assert xml.contains('<text>2 errors</text>')
	assert xml.starts_with('<toast ')
	assert xml.ends_with('</toast>')
}

fn test_actions_element_has_the_schema_nesting() {
	// <actions> is a child of <toast> and a SIBLING of <visual>, after it. Putting
	// it inside the binding, or before the visual, produces a document the shell
	// refuses to parse - and the symptom is that no notification appears at all,
	// which points nowhere near the cause.
	mut el := toast_actions_element([NotificationAction{
		id:        'open'
		content:   'Open'
		arguments: 'open:1'
	}])
	assert el.starts_with('<actions>')
	assert el.ends_with('</actions>')
	assert el.contains('content="Open"')
	assert el.contains('arguments="open:1"')
	// self-closing, which is how the schema wants a button with no children
	assert el.contains('/>')
	assert el.contains('placement="contextual"')
	// and no <visual> leaked in
	assert !el.contains('<visual')
}

// The placement vocabulary, including the default. `system` is accepted by the
// schema but not what a desktop app wants, so the default is what a caller gets
// without asking.
fn test_action_placement_defaults_and_vocabulary() {
	a := NotificationAction{ id: 'x', content: 'X' }
	assert a.placement == ''
	assert effective_placement(a) == action_placement_contextual
	mut el := toast_actions_element([a])
	assert el.contains('placement="contextual"')
	// Both spellings round-trip into the document.
	el = toast_actions_element([NotificationAction{
		id:        'x'
		content:   'X'
		placement: action_placement_system
	}])
	assert el.contains('placement="system"')
}

// Attribute values are escaped, which `<text>` content does not strictly need.
// An unescaped quote here ends the attribute and turns the rest of the document
// into markup - a failure that shows up as a vanished notification.
fn test_action_attributes_are_escaped() {
	mut el := toast_actions_element([NotificationAction{
		id:        'x'
		content:   'Say "hi"'
		arguments: 'a&b<c>'
	}])
	assert el.contains('&quot;')
	assert el.contains('&amp;')
	assert el.contains('&lt;')
	assert !el.contains('content="Say "hi""')
	// And the escape cannot be defeated by the label itself forging a tag.
	el = toast_actions_element([NotificationAction{ id: 'x', content: '<b>bold</b>' }])
	assert el.contains('&lt;b&gt;')
	assert !el.contains('<b>')
}

fn test_validate_notification_actions_bounds() {
	mut failed := ''
	validate_notification_actions([]) or { failed = err.msg() }
	assert failed == ''
	// too many
	failed = ''
	mut many := []NotificationAction{}
	for i in 0 .. (max_notification_actions + 1) {
		many << NotificationAction{ id: 'a' + i.str(), content: 'c' }
	}
	validate_notification_actions(many) or { failed = err.msg() }
	assert failed.contains('at most')
}

fn test_validate_notification_actions_requires_id_and_content() {
	mut failed := ''
	validate_notification_actions([NotificationAction{ id: '', content: 'Open' }]) or {
		failed = err.msg()
	}
	assert failed.contains('needs an id')
	failed = ''
	validate_notification_actions([NotificationAction{ id: 'open', content: '  ' }]) or {
		failed = err.msg()
	}
	assert failed.contains('content')
}

fn test_validate_notification_actions_refuses_duplicate_ids() {
	// The id is what a delivered click is matched against, so two buttons sharing
	// one makes the returned event ambiguous - which is precisely the delivery
	// this feature exists for.
	mut failed := ''
	validate_notification_actions([
		NotificationAction{ id: 'open', content: 'Open' },
		NotificationAction{ id: 'open', content: 'Reopen' },
	]) or { failed = err.msg() }
	assert failed.contains('share the id')
}

fn test_validate_notification_actions_refuses_a_bad_placement() {
	mut failed := ''
	validate_notification_actions([NotificationAction{
		id:        'a'
		content:   'A'
		placement: 'inline'
	}]) or { failed = err.msg() }
	assert failed.contains('placement')
}

fn test_actions_survive_the_clamped_copy() {
	// Today the gate stops them going out, so the only thing that can be wrong
	// here is the copy silently dropping them - which would be invisible until
	// the gate opened, i.e. exactly when it would matter.
	opts := NotificationOptions{
		title:      't'
		body:       'b'
		timeout_ms: 999999
		actions:    [NotificationAction{ id: 'open', content: 'Open' }]
	}
	c := with_clamped_timeout(opts)
	assert c.timeout_ms == max_timeout
	assert c.actions.len == 1
	assert c.actions[0].id == 'open'
}

fn test_actions_decode_from_json() {
	mut opts := parse_notify_options('{"body":"b","actions":[{"id":"open","content":"Open"}]}') or {
		panic(err.msg())
	}
	assert opts.actions.len == 1
	assert opts.actions[0].id == 'open'
	assert opts.actions[0].content == 'Open'
	// The field stays zero when the key is absent - which is exactly why the
	// default lives in effective_placement rather than in the struct.
	assert opts.actions[0].placement == ''
	assert effective_placement(opts.actions[0]) == action_placement_contextual
	assert opts.actions[0].arguments == ''
	// And an EXPLICIT placement survives decoding.
	opts = parse_notify_options('{"body":"b","actions":[{"id":"a","content":"A","placement":"system"}]}') or {
		panic(err.msg())
	}
	assert opts.actions[0].placement == 'system'
	assert effective_placement(opts.actions[0]) == 'system'
}

fn test_validate_notification_rejects_a_bad_action() {
	// The actions are validated as part of the whole notification, so there is no
	// route in that skips it.
	opts := NotificationOptions{
		title:   't'
		body:    'b'
		actions: [NotificationAction{ id: '', content: 'Open' }]
	}
	mut failed := ''
	validate_notification(opts) or { failed = err.msg() }
	assert failed.contains('needs an id')
}

// An unset placement means contextual, and that has to hold for a struct built in
// V as well as one decoded from JSON. It is a decision rather than a
// convenience: `placement=""` is not the schema's default to the shell, it is an
// invalid attribute value, and the validator and the XML builder have to agree on
// which one they mean - they did not, once, when the struct carried a field
// default that decoding could overwrite.
fn test_effective_placement_defaults_an_unset_value() {
	unset := NotificationAction{ id: 'a', content: 'A' }
	assert unset.placement == ''
	assert effective_placement(unset) == action_placement_contextual
	explicit := NotificationAction{
		id:        'b'
		content:   'B'
		placement: action_placement_system
	}
	assert effective_placement(explicit) == action_placement_system
	// And the XML carries the normalised value, not the empty one.
	el := toast_actions_element([unset])
	assert el.contains('placement="contextual"')
	assert !el.contains('placement=""')
	// An unset placement is also NOT rejected by the validator - otherwise the
	// default would be unreachable from the only path a frontend takes.
	mut failed := ''
	validate_notification_actions([unset]) or { failed = err.msg() }
	assert failed == ''
}
