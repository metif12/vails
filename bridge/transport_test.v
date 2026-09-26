module bridge

fn transport_echo(params string) !string {
	return params
}

fn transport_boom(_ string) !string {
	return error('boom')
}

fn test_handle_message_ok() {
	mut r := new_router()
	r.register('echo', transport_echo)!
	raw := encode_request('7', 'echo', 'ping')
	resp_raw := r.handle_message(raw)
	assert resp_raw.contains('"id":"7"')
	assert resp_raw.contains('"result":"ping"')
}

fn test_handle_message_array_wrapped() {
	// webview library shape: bound-call args arrive wrapped in an array.
	mut r := new_router()
	r.register('echo', transport_echo)!
	inner := encode_request('7', 'echo', 'ping')
	wrapped := '["' + inner.replace('"', '\\"') + '"]'
	resp_raw := r.handle_message(wrapped)
	assert resp_raw.contains('"id":"7"')
	assert resp_raw.contains('"result":"ping"')
}

fn test_unwrap_args_passthrough() {
	assert unwrap_args('not json') == 'not json'
	assert unwrap_args('{"id":"1"}') == '{"id":"1"}'
	assert unwrap_args('[]') == '[]'
	assert unwrap_args('["a","b"]') == '["a","b"]'
	assert unwrap_args('["x"]') == 'x'
}

fn test_handle_message_bad_json() {
	r := new_router()
	resp_raw := r.handle_message('{oops')
	assert resp_raw.contains('"err":"bad request:')
}

fn test_handle_message_unknown_method() {
	r := new_router()
	resp_raw := r.handle_message(encode_request('9', 'nope', ''))
	assert resp_raw.contains('"id":"9"')
	assert resp_raw.contains('unknown method')
}

fn test_handle_message_handler_error() {
	mut r := new_router()
	r.register('boom', transport_boom)!
	resp_raw := r.handle_message(encode_request('3', 'boom', ''))
	assert resp_raw.contains('"err":"boom"')
}

fn test_resolve_js_shape() {
	snippet := resolve_js(Response{
		id:     '1'
		result: 'pong'
	})
	assert snippet.starts_with('window.vails.__resolve(')
	assert snippet.ends_with(';')
	assert snippet.contains('pong')
}

fn test_resolve_js_escapes_quote() {
	snippet := resolve_js(Response{
		id:     '1'
		result: "it's"
	})
	// raw single quote must not leak into the JS string literal
	assert !snippet.contains("it's")
	assert snippet.contains("\\'")
}

fn test_runtime_js_markers() {
	js := runtime_js()
	assert js.contains('window.vails = {')
	assert js.contains('window.webkit.messageHandlers.vails.postMessage')
	assert js.contains('__resolve')
	assert js.contains('__emit')
	assert js.contains('onEvent')
}

fn test_runtime_js_bound_markers() {
	js := runtime_js_bound('vails_call')
	assert js.contains('window.vails = {')
	assert js.contains('vails_call(body).then')
	assert js.contains('__resolve')
	assert js.contains('__emit')
	assert js.contains('typeof raw === "string"')
	assert !js.contains('messageHandlers')
}
