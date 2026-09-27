module services

import bridge
import capabilities
import webview

// live_ctx is a Ctx carrying a window handle, like a real window gets from
// Config.on_ready. The handle is a stand-in: only its presence is ever
// inspected, and no test path reaches a native call (ADR-0015 - `v test`
// never opens the user's clipboard), so it is never dereferenced.
fn live_ctx() webview.Ctx {
	return webview.Ctx{
		label:  'main'
		parent: unsafe { voidptr(1) }
	}
}

fn granted(commands []string) capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		commands: commands
	})
	return reg
}

// json_string_literal wraps an ASCII-only string in quotes — the payload
// shape decode_text expects. Hand-rolled (no json2.encode) so the test does
// not lean on the encoder whose output it is checking; the tests only ever
// pass plain ASCII, which the guard below asserts.
fn json_string(s string) string {
	for ch in s {
		assert ch >= ` ` && ch <= `~` && ch != `"` && ch != `\\`, 'the test helper is ASCII-only'
	}
	return '"' + s + '"'
}

fn test_manifest_shape() {
	m := clipboard_manifest()
	assert m.name == 'clipboard'
	assert m.command_names() == ['clipboard.read_text', 'clipboard.write_text']
	assert m.commands[0].params == no_params
	// the payload is a JSON string, not an object
	assert m.commands[1].params == 'string'
	// neither command waits on a human, so neither is a blocking command
	assert !m.commands[0].blocking
	assert !m.commands[1].blocking
}

fn test_manifest_is_in_the_catalog() {
	// Wave 2 gave clipboard its native half, so it is a catalog service now:
	// `vails dts` and `vails doctor` see it (ADR-0015).
	assert find('clipboard') != none
	assert service_of('clipboard.read_text') != none
	if s, c := lookup('write_text') {
		assert s.name == 'clipboard'
		assert c.name == 'clipboard.write_text'
	} else {
		assert false, 'write_text must resolve to clipboard.write_text'
	}
}

fn test_decode_text_accepts_a_json_string() {
	assert decode_text('"hello"')! == 'hello'
	// the empty string is legal: it clears the clipboard
	assert decode_text('""')! == ''
}

fn test_decode_text_rejects_a_non_string_payload() {
	// an object, a number or broken JSON is a params problem, not a native
	// error - and it never reaches the backend
	for bad in ['{oops', '{}', '42', 'null', '', '   '] {
		mut failed := false
		decode_text(bad) or { failed = true }
		assert failed, 'must reject ' + bad
	}
}

fn test_decode_text_enforces_the_size_bound() {
	// just under the bound is fine. Built at runtime on purpose: a 1 MiB
	// string literal would live in the test binary.
	ok := 'a'.repeat(max_text_bytes)
	assert decode_text(json_string(ok))! == ok
	too_big := 'a'.repeat(max_text_bytes + 1)
	mut failed := false
	decode_text(json_string(too_big)) or { failed = true }
	assert failed
	failed = false
	validate_text(too_big) or { failed = true }
	assert failed
}

fn test_validate_text_counts_bytes_not_characters() {
	// 'é' is two UTF-8 bytes, so a string of max_text_bytes/2 characters is
	// over the bound. Bounding in bytes is what keeps the promise "1 MiB".
	ok := 'é'.repeat(max_text_bytes / 4)
	validate_text(ok)!
	mut failed := false
	validate_text('é'.repeat(max_text_bytes)) or { failed = true }
	assert failed
}

fn test_require_parent_rejects_a_ctx_without_a_window() {
	// The pure-V half of the Windows ownership rule: writing needs the HWND
	// that EmptyClipboard turns into the clipboard owner, so a hand-built Ctx
	// (or a window that never got a handle) is rejected before the native
	// call.
	ctx := webview.Ctx{
		label: 'main'
	}
	assert !ctx.has_parent()
	mut failed := false
	require_parent(ctx, 'write_text') or { failed = true }
	assert failed
	// and a wired one passes
	assert live_ctx().has_parent()
	require_parent(live_ctx(), 'write_text')!
}

fn test_install_denies_an_ungranted_command() {
	mut router := bridge.new_router()
	install_clipboard(mut router, live_ctx())!
	// read_text is installed but the capability grants only write_text
	mut res := router.call_json('main', '1', 'clipboard.read_text', '',
		granted(['clipboard.write_text']))
	assert res.err.starts_with('forbidden:')
	assert res.err.contains('clipboard.read_text')
	// and the other way round
	res = router.call_json('main', '2', 'clipboard.write_text', '"hi"',
		granted(['clipboard.read_text']))
	assert res.err.starts_with('forbidden:')
	assert res.err.contains('clipboard.write_text')
}

fn test_write_text_stops_before_any_native_call() {
	mut router := bridge.new_router()
	// no parent handle on purpose: the pure-V rule must reject it, which
	// proves the handler is bound and reachable without touching the real
	// clipboard from a unit test
	install_clipboard(mut router, webview.Ctx{
		label: 'main'
	})!
	reg := granted(['clipboard.write_text'])
	mut res := router.call_json('main', '1', 'clipboard.write_text', '"hello"', reg)
	assert !res.err.starts_with('unknown method')
	assert !res.err.starts_with('forbidden')
	assert res.err.contains('needs the window handle')
	// a non-JSON payload is a params problem, with the standard prefix
	res = router.call_json('main', '2', 'clipboard.write_text', '{oops', reg)
	assert res.err.starts_with('bad params:')
	assert res.err.contains('expected a JSON string')
	// an over-long payload never reaches the backend either
	res = router.call_json('main', '3', 'clipboard.write_text',
		json_string('a'.repeat(max_text_bytes + 1)), reg)
	assert res.err.starts_with('bad params:')
	assert res.err.contains('longer than')
}

fn test_read_text_rejects_params_it_does_not_take() {
	mut router := bridge.new_router()
	install_clipboard(mut router, live_ctx())!
	// read_text declares no params, so the install path wires validate_empty:
	// the payload is refused by the validator, before the handler - which is
	// also what keeps this test from opening the real clipboard
	res := router.call_json('main', '1', 'clipboard.read_text', '{"x":1}',
		granted(['clipboard.read_text']))
	assert res.err.starts_with('bad params:')
	assert res.err.contains('expected no params')
}
