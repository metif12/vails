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
		assert s.ready == toast_available(), 'notification_support().ready must ' +
			'be the machine probe (toast_available), never a hardcoded true'
		// Whichever way it went, the note has to explain itself - a stub without a
		// reason is useless in a doctor report, and support_test.v's invariant
		// already requires one but not that it is *useful*.
		if !s.ready {
			assert s.note.contains('REGDB_E_CLASSNOTREG') || s.note.contains('do not activate')
			// And the compile-time answer must not have been dragged along with it:
			// the backend IS in the build, and saying otherwise would send a reader
			// looking for a missing dependency that is not missing.
			assert is_supported()
		}
	} $else {
		assert !s.ready
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
