module bridge

fn echo_fn(params string) !string {
	return params
}

fn boom_fn(_ string) !string {
	return error('boom')
}

fn test_request_roundtrip() {
	raw := encode_request('1', 'greet', '{"name":"v"}')
	req := decode_request(raw)!
	assert req.id == '1'
	assert req.method == 'greet'
	assert req.params == '{"name":"v"}'
}

fn test_decode_invalid_fails() {
	mut failed := false
	decode_request('not json') or { failed = true }
	assert failed
}

fn test_router_call_ok() {
	mut r := new_router()
	r.register('echo', echo_fn)!
	resp := r.call('1', 'echo', 'hi')
	assert resp.id == '1'
	assert resp.err == ''
	assert resp.result == 'hi'
	assert encode_response(resp).contains('"result":"hi"')
}

fn test_router_unknown_method() {
	r := new_router()
	resp := r.call('2', 'nope', '')
	assert resp.err.contains('unknown method')
}

fn test_router_handler_error() {
	mut r := new_router()
	r.register('boom', boom_fn)!
	resp := r.call('3', 'boom', '')
	assert resp.err == 'boom'
	assert resp.result == ''
}

fn test_router_duplicate_fails() {
	mut r := new_router()
	r.register('echo', echo_fn)!
	mut failed := false
	r.register('echo', echo_fn) or { failed = true }
	assert failed
}
