module bridge

import capabilities

// contract_test.v — T2 stricter IPC contract (see ADR-0010):
// command (call_json: gated + validated) vs event (notify: gated, no reply).

fn contract_echo(params string) !string {
	return params
}

// Each _test.v file compiles standalone, so this file defines its own
// registry helper (mirrors allow_echo_registry in bridge_test.v).
fn contract_registry() capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'main-echo'
		windows:  ['main']
		commands: ['echo']
	})
	return reg
}

fn contract_require_object(params string) !void {
	t := params.trim_space()
	if t.starts_with('{') && t.ends_with('}') {
		return
	}
	return error('params must be a JSON object')
}

fn test_validate_empty() {
	validate_empty('')!
	validate_empty('null')!
	validate_empty('""')!
	mut failed := 0
	validate_empty('hi') or { failed++ }
	validate_empty('{"a":1}') or { failed++ }
	assert failed == 2
}

fn test_register_validated_duplicate_fails() {
	mut r := new_router()
	r.register_validated('m', validate_empty, contract_echo)!
	mut failed := false
	r.register_validated('m', validate_empty, contract_echo) or { failed = true }
	assert failed
}

fn test_call_validated_ok_and_bad_params() {
	mut r := new_router()
	r.register_validated('obj', contract_require_object, contract_echo)!
	ok := r.call_validated('1', 'obj', '{"a":1}')
	assert ok.err == ''
	assert ok.result == '{"a":1}'
	bad := r.call_validated('2', 'obj', 'hi')
	assert bad.id == '2'
	assert bad.err.contains('bad params:')
	assert bad.err.contains('JSON object')
	assert bad.result == ''
}

fn test_call_validated_unvalidated_method_skips_check() {
	mut r := new_router()
	r.register('echo', contract_echo)!
	resp := r.call_validated('1', 'echo', 'anything goes')
	assert resp.err == ''
	assert resp.result == 'anything goes'
}

fn test_call_json_gates_then_validates() {
	mut r := new_router()
	r.register_validated('obj', contract_require_object, contract_echo)!
	reg := contract_registry()
	// 'obj' is not granted: deny must not leak whether it exists.
	denied := r.call_json('main', '1', 'obj', '{}', reg)
	assert denied.err.contains('forbidden:')
	assert !denied.err.contains('unknown method')
	assert !denied.err.contains('bad params:')
}

// contract_registry grants 'echo' on 'main'; T2 shares the same allowlist
// for event names, so it gates notify too.
fn test_call_json_empty_registry_denies_without_leak() {
	mut r := new_router()
	r.register('echo', contract_echo)!
	resp := r.call_json('main', '9', 'echo', '', capabilities.new_registry())
	assert resp.err.contains('forbidden:')
	assert !resp.err.contains('unknown method')
}

fn test_call_json_granted_valid_and_invalid() {
	mut r := new_router()
	r.register_validated('echo', contract_require_object, contract_echo)!
	reg := contract_registry()
	ok := r.call_json('main', '1', 'echo', '{}', reg)
	assert ok.err == ''
	assert ok.result == '{}'
	bad := r.call_json('main', '2', 'echo', 'hi', reg)
	assert bad.err.contains('bad params:')
}

fn test_notify_allows_granted() {
	r := new_router()
	r.notify('main', 'echo', 'hello', contract_registry())!
}

fn test_notify_denies_wrong_window() {
	r := new_router()
	mut msg := ''
	r.notify('other', 'echo', 'hi', contract_registry()) or { msg = err.msg() }
	assert msg.contains('forbidden:')
	assert msg.contains('echo')
	assert !msg.contains('unknown method')
}

fn test_notify_rejects_empty_event() {
	r := new_router()
	mut msg := ''
	r.notify('main', '', 'hi', contract_registry()) or { msg = err.msg() }
	assert msg.contains('bad event:')
}

fn test_notify_roundtrip_helpers() {
	n := decode_notify(encode_notify('ready', 'hello'))!
	assert n.event == 'ready'
	assert n.data == 'hello'
	assert encode_notify_ack_ok().contains('"ok":true')
	assert encode_notify_ack_err('forbidden: x').contains('forbidden: x')
}

fn test_handle_notify_from_allows_granted() {
	r := new_router()
	ack := r.handle_notify_from(encode_notify('echo', 'hi'), 'main', contract_registry())
	assert ack.contains('"ok":true')
}

fn test_handle_notify_from_denies() {
	r := new_router()
	ack := r.handle_notify_from(encode_notify('echo', 'hi'), 'other', contract_registry())
	assert ack.contains('forbidden:')
	assert !ack.contains('"ok":true')
}

fn test_handle_notify_from_bad_json() {
	r := new_router()
	ack := r.handle_notify_from('{oops', 'main', contract_registry())
	assert ack.contains('bad request:')
}

fn test_handle_message_from_runs_validator() {
	mut r := new_router()
	r.register_validated('obj', contract_require_object, contract_echo)!
	raw := encode_request('5', 'obj', 'hi')
	resp_raw := r.handle_message_from(raw, 'main', contract_registry())
	// 'obj' is ungranted so the gate fires first (no leak of the validator).
	assert resp_raw.contains('forbidden:')
}

fn test_handle_envelope_routes_command() {
	mut r := new_router()
	r.register('echo', contract_echo)!
	inner := encode_request('21', 'echo', 'ping')
	wrapped := '["' + inner.replace('"', '\\"') + '"]'
	resp_raw := r.handle_envelope_from(wrapped, 'main', contract_registry())
	assert resp_raw.contains('"id":"21"')
	assert resp_raw.contains('"result":"ping"')
}

fn test_handle_envelope_routes_event() {
	r := new_router()
	ack := r.handle_envelope_from(encode_notify('echo', 'hi'), 'main', contract_registry())
	assert ack.contains('"ok":true')
	denied := r.handle_envelope_from(encode_notify('echo', 'hi'), 'other', contract_registry())
	assert denied.contains('forbidden:')
}

fn test_handle_envelope_rejects_neither() {
	r := new_router()
	resp_raw := r.handle_envelope_from('{"id":"30"}', 'main', contract_registry())
	assert resp_raw.contains('"id":"30"')
	assert resp_raw.contains('bad request:')
	assert resp_raw.contains('neither method nor event')
}

fn test_handle_envelope_rejects_garbage() {
	r := new_router()
	resp_raw := r.handle_envelope_from('{oops', 'main', contract_registry())
	assert resp_raw.contains('bad request:')
}

fn test_runtime_js_emit_markers() {
	js := runtime_js()
	assert js.contains('emit: function')
	assert js.contains('JSON.stringify({ event: name')
	assert js.contains('window.webkit.messageHandlers.vails.postMessage')
	assert js.contains('__resolve')
	assert js.contains('__emit')
	assert js.contains('onEvent')
}

fn test_runtime_js_bound_emit_markers() {
	js := runtime_js_bound('vails_call')
	assert js.contains('emit: function')
	assert js.contains('vails_call(body);')
	assert js.contains('vails_call(body).then')
	assert js.contains('typeof raw === "string"')
	assert js.contains('__resolve')
	assert js.contains('__emit')
	assert !js.contains('messageHandlers')
}
