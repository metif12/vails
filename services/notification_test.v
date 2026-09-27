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
	// a balloon does not block the main thread: the shell owns the UI
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

// The validated byte bound is deliberately wider than the shell's fixed
// fields (256 UTF-16 units for the body, 64 for the title): a long
// notification is shown with a clipped tail instead of being refused, which
// is what notification APIs do everywhere. This pins the relationship so a
// future bound change is a deliberate decision.
fn test_shell_field_is_narrower_than_the_validated_bound() {
	assert max_notify_body > 255
	assert max_notify_title > 63
}

fn test_is_supported_is_true_only_where_a_backend_exists() {
	// The point of the command: an honest answer, so a frontend can ask
	// instead of firing a notification that quietly does nothing.
	$if windows {
		assert is_supported()
	} $else {
		assert !is_supported()
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
	notify(ctx, too_long) or {
		failed = true
		assert err.msg().starts_with('bad params:')
	}
	assert failed
}

fn test_install_binds_both_commands() {
	mut router := bridge.new_router()
	install_notification(mut router, webview.Ctx{
		label: 'main'
	})!
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
	})!
	res := router.call_json('main', '1', 'notification.notify', '{"body":"hi"}',
		notify_grant(['notification.is_supported']))
	assert res.err.starts_with('forbidden:')
	assert res.err.contains('notification.notify')
}
