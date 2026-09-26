// bridge.v — JSON-RPC-style dispatch from JS to V (guide: v2/internal/binding).
// No reflection: methods are registered explicitly. params/result stay raw
// JSON strings so this module needs no codegen and no reflect package.
module bridge

import capabilities
import json2

pub struct Request {
pub mut:
	id     string
	method string
	params string
}

pub struct Response {
pub mut:
	id     string
	result string
	err    string
}

pub type MethodHandler = fn (params string) !string

pub struct Router {
mut:
	methods map[string]MethodHandler
}

pub fn new_router() Router {
	return Router{
		methods: map[string]MethodHandler{}
	}
}

pub fn (mut r Router) register(name string, h MethodHandler) ! {
	if name in r.methods {
		return error('method already registered: ' + name)
	}
	r.methods[name] = h
}

// call_from is the capability-checked dispatch (T1). The window_label is
// the webview.Config.label of the calling window. Denied calls return
// 'forbidden: …' (never 'unknown method') so ungranted method names do
// not leak. call() stays as the unchecked compat path.
pub fn (r Router) call_from(window_label string, id string, method string, params string, reg capabilities.Registry) Response {
	if !reg.is_allowed(window_label, method) {
		return Response{
			id:  id
			err: 'forbidden: ' + method + ' is not allowed for window "' + window_label + '"'
		}
	}
	return r.call(id, method, params)
}

// call dispatches one request and never propagates errors: failures land in
// Response.err so the JS side always gets a well-formed reply.
pub fn (r Router) call(id string, method string, params string) Response {
	h := r.methods[method] or {
		return Response{
			id:  id
			err: 'unknown method: ' + method
		}
	}
	res := h(params) or {
		return Response{
			id:  id
			err: err.msg()
		}
	}
	return Response{
		id:     id
		result: res
	}
}

pub fn encode_request(id string, method string, params string) string {
	return json2.encode(Request{
		id:     id
		method: method
		params: params
	},
		escape_unicode: true
	)
}

pub fn decode_request(raw string) !Request {
	return json2.decode[Request](raw)!
}

pub fn encode_response(res Response) string {
	return json2.encode(res, escape_unicode: true)
}
