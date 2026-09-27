// bridge.v — JSON-RPC-style dispatch from JS to V (guide: v2/internal/binding).
// No reflection: methods are registered explicitly. params/result stay raw
// JSON strings so this module needs no codegen and no reflect package.
//
// T2 contract (see ADR-0010):
//   - command: request/response (`call_json`, gated + validated, replies
//     into the JS promise via `__resolve`).
//   - event: one-way, no reply (`notify`, gated only; the app forwards the
//     payload to its own `events.Bus`). JS posts it via `vails.emit` and
//     never awaits a result.
// Threading rule: handlers run on the webview main thread, so they must
// stay fast and non-blocking. Heavy work goes through `spawn` with the
// result delivered back as an event (`events.to_js` snippet evaluated on
// the main thread).
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

// Notify is the one-way JS->V event shape. Unlike Request it carries no
// id because no reply is ever produced for it.
pub struct Notify {
pub mut:
	event string
	data  string
}

pub type MethodHandler = fn (params string) !string

// ParamsValidator checks the raw params string before the handler runs.
// Return an error to reject the call with a 'bad params: …' response.
pub type ParamsValidator = fn (params string) !void

pub struct Router {
mut:
	methods    map[string]MethodHandler
	validators map[string]ParamsValidator
}

pub fn new_router() Router {
	return Router{
		methods:    map[string]MethodHandler{}
		validators: map[string]ParamsValidator{}
	}
}

pub fn (mut r Router) register(name string, h MethodHandler) ! {
	if name in r.methods {
		return error('method already registered: ' + name)
	}
	r.methods[name] = h
}

// register_validated registers a command together with a params-shape
// validator. The validator runs after the capability check and before
// the handler; a rejection becomes a 'bad params: …' response.
pub fn (mut r Router) register_validated(name string, validate ParamsValidator, h MethodHandler) ! {
	if name in r.methods {
		return error('method already registered: ' + name)
	}
	r.methods[name] = h
	r.validators[name] = validate
}

// Standard error values (Tauri `Result` → promise reject). Prefixes are
// part of the wire contract: JS matches on them, so never reword a
// prefix without bumping the contract (see ADR-0010).
pub fn err_unknown(method string) string {
	return 'unknown method: ' + method
}

pub fn err_forbidden(method string, window_label string) string {
	return 'forbidden: ' + method + ' is not allowed for window "' + window_label + '"'
}

pub fn err_bad_request(detail string) string {
	return 'bad request: ' + detail
}

pub fn err_bad_params(detail string) string {
	return 'bad params: ' + detail
}

pub fn err_bad_event(detail string) string {
	return 'bad event: ' + detail
}

// validate_empty is a ready-made ParamsValidator for commands that take
// no arguments (the frontend sends `""` for those). It accepts the empty
// string as well as the JSON `null` / `""` literals.
pub fn validate_empty(params string) !void {
	if params == '' || params == 'null' || params == '""' {
		return
	}
	return error('expected no params')
}

// validate_any accepts any params payload. It is the default for commands
// that do declare arguments: the handler owns their shape check, and a
// wrong payload surfaces as the handler's own error (a service decodes
// its params with json2 and returns a readable message).
pub fn validate_any(params string) !void {
	_ = params
}

// call_from is the capability-checked dispatch (T1). The window_label is
// the webview.Config.label of the calling window. Denied calls return
// 'forbidden: …' (never 'unknown method') so ungranted method names do
// not leak. Since T2 it also runs the params validator when one was
// registered via register_validated (it delegates to call_json).
// call() stays as the unchecked, unvalidated compat path.
pub fn (r Router) call_from(window_label string, id string, method string, params string, reg capabilities.Registry) Response {
	return r.call_json(window_label, id, method, params, reg)
}

// call_json is the canonical T2 command path: capability check first
// (deny does not leak method names), then params-shape validation, then
// the handler. Failures land in Response.err so the JS promise rejects
// with a standard error value instead of hanging.
pub fn (r Router) call_json(window_label string, id string, method string, params string, reg capabilities.Registry) Response {
	if !reg.is_allowed(window_label, method) {
		return Response{
			id:  id
			err: err_forbidden(method, window_label)
		}
	}
	return r.call_validated(id, method, params)
}

// call dispatches one request and never propagates errors: failures land in
// Response.err so the JS side always gets a well-formed reply.
pub fn (r Router) call(id string, method string, params string) Response {
	h := r.methods[method] or {
		return Response{
			id:  id
			err: err_unknown(method)
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

// call_validated is call plus the params-shape check, without the
// capability gate. Prefer call_json on the real dispatch path; this is
// the testable core and the escape hatch for trusted in-process callers.
pub fn (r Router) call_validated(id string, method string, params string) Response {
	h := r.methods[method] or {
		return Response{
			id:  id
			err: err_unknown(method)
		}
	}
	if method in r.validators {
		validate := r.validators[method]
		validate(params) or {
			return Response{
				id:  id
				err: err_bad_params(err.msg())
			}
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

// notify is the T2 one-way path: a JS->V event with no reply. It only
// gates (empty event names rejected, then the capability check against
// the event name in the shared command allowlist) and returns nothing on
// success. Delivery to V-side subscribers is the app's job: it takes the
// already-gated payload and emits it on its own events.Bus.
pub fn (r Router) notify(window_label string, event string, data string, reg capabilities.Registry) !void {
	_ = data
	if event == '' {
		return error(err_bad_event('name must not be empty'))
	}
	if !reg.is_allowed(window_label, event) {
		return error(err_forbidden(event, window_label))
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

pub fn encode_notify(event string, data string) string {
	return json2.encode(Notify{
		event: event
		data:  data
	},
		escape_unicode: true
	)
}

pub fn decode_notify(raw string) !Notify {
	return json2.decode[Notify](raw)!
}

pub fn encode_response(res Response) string {
	return json2.encode(res, escape_unicode: true)
}
