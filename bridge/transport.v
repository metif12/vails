// transport.v — the pure-V half of the JS<->V wire (guide: v3/internal/runtime).
// The Linux C side (webview_linux.c.v, ADR-0004) only moves strings:
//   JS -> V : message body -> Router.handle_message(body) -> response JSON
//   V -> JS : bridge.resolve_js / events.to_js snippets via run_javascript.
// Everything here is OS-agnostic and unit-tested on any platform.
module bridge

import capabilities
import jsesc
import json2

// handle_message is the single entry point for the WebKit script-message
// handler. It always returns a well-formed Response JSON string, never an
// error — even a malformed request gets a Response{err: ...} (id is empty
// then, since no id could be parsed).
pub fn (r Router) handle_message(raw string) string {
	// The webview library wraps bound-call arguments in a JSON array
	// (vails_call(body) arrives as ["<body>"]); the raw WebKitGTK message
	// handler delivers the body directly. Accept both shapes.
	req := decode_request(unwrap_args(raw)) or {
		return encode_response(Response{
			err: err_bad_request(err.msg())
		})
	}
	return encode_response(r.call(req.id, req.method, req.params))
}

// handle_message_from is the capability-checked entry point (T1).
// The native side passes the calling window's Config.label. Since T2 it
// runs the full call_json path (capability gate + params validation).
// Denied or malformed requests still return well-formed Response JSON,
// never error.
pub fn (r Router) handle_message_from(raw string, window_label string, reg capabilities.Registry) string {
	req := decode_request(unwrap_args(raw)) or {
		return encode_response(Response{
			err: err_bad_request(err.msg())
		})
	}
	return encode_response(r.call_from(window_label, req.id, req.method, req.params, reg))
}

// NotifyAck is the transport-level acknowledgement for the one-way path.
// It is NOT a command reply: the JS emit() helper ignores it. It exists
// only because the native callback must return a string; success carries
// ok:true, failures carry the standard err value for logs/debugging.
pub struct NotifyAck {
pub mut:
	ok  bool
	err string
}

pub fn encode_notify_ack_ok() string {
	return json2.encode(NotifyAck{
		ok: true
	},
		escape_unicode: true
	)
}

pub fn encode_notify_ack_err(msg string) string {
	return json2.encode(NotifyAck{
		err: msg
	},
		escape_unicode: true
	)
}

// handle_notify_from is the one-way JS->V entry point (T2). The native
// side passes the calling window's Config.label. Always returns Ack JSON,
// never errors. On success the app forwards the gated payload to its own
// events.Bus (see Router.notify).
pub fn (r Router) handle_notify_from(raw string, window_label string, reg capabilities.Registry) string {
	n := decode_notify(unwrap_args(raw)) or {
		return encode_notify_ack_err(err_bad_request(err.msg()))
	}
	r.notify(window_label, n.event, n.data, reg) or {
		return encode_notify_ack_err(err.msg())
	}
	return encode_notify_ack_ok()
}

// Envelope is the sniffing shape for the single native entry point: a
// body with `method` set is a command, with `event` set is a one-way
// event. Method wins when both are set (a malformed sender); neither set
// is a bad request.
pub struct Envelope {
pub mut:
	id     string
	method string
	params string
	event  string
	data   string
}

pub fn decode_envelope(raw string) !Envelope {
	return json2.decode[Envelope](raw)!
}

// handle_envelope_from is what the native backends call (T2): it routes
// one incoming body to the command path (call_json → Response JSON, fed
// to __resolve) or the event path (notify → Ack JSON, ignored by emit()).
// The window_label is the calling window's Config.label.
pub fn (r Router) handle_envelope_from(raw string, window_label string, reg capabilities.Registry) string {
	body := unwrap_args(raw)
	env := decode_envelope(body) or {
		return encode_response(Response{
			err: err_bad_request(err.msg())
		})
	}
	if env.method != '' {
		return encode_response(r.call_json(window_label, env.id, env.method, env.params, reg))
	}
	if env.event != '' {
		return r.handle_notify_from(body, window_label, reg)
	}
	return encode_response(Response{
		id:  env.id
		err: err_bad_request('neither method nor event set')
	})
}

// unwrap_args extracts the single string element when raw is a one-element
// JSON string array; anything else passes through untouched.
fn unwrap_args(raw string) string {
	args := json2.decode[[]string](raw) or { return raw }
	if args.len == 1 {
		return args[0]
	}
	return raw
}

// resolve_js builds the snippet the native side evaluates to deliver a
// method response to the pending Promise in runtime_js.
pub fn resolve_js(res Response) string {
	return "window.vails.__resolve('" + jsesc.escape(encode_response(res)) + "');"
}

// runtime_js is injected at document start. Exposes:
//   window.vails.call(method, params) -> Promise<string>  — command
//     (rejects with the standard err value on failure, T2)
//   window.vails.emit(name, data)      — one-way JS->V event, no reply (T2)
//   window.vails.onEvent(name, cb)     — frontend event subscription
// Transport out uses window.webkit.messageHandlers.vails.postMessage
// (raw WebKitGTK path, Linux); transport in arrives via __resolve (call
// results) and __emit (events).
// Note: no `$` or backticks anywhere — V string interpolation must not
// touch this source.
pub fn runtime_js() string {
	return runtime_js_with_sender('window.webkit.messageHandlers.vails.postMessage(body);',
		'window.webkit.messageHandlers.vails.postMessage(body);')
}

// runtime_js_bound is the same runtime for the webview-library backend
// (Windows): the bound function returns a promise, so the call result is
// chained back into __resolve and the rest (pending map, __emit) is shared.
// NOTE: the library resolves with the PARSED JSON value (object), not the
// raw string — hence the typeof normalization before __resolve.
// emit() is fire-and-forget: the Ack JSON the V side returns resolves the
// binding promise and is ignored by design.
pub fn runtime_js_bound(binding string) string {
	return runtime_js_with_sender(binding +
		'(body).then(function (raw) { window.vails.__resolve(typeof raw === "string" ? raw : JSON.stringify(raw)); });',
		binding + '(body);')
}

fn runtime_js_with_sender(call_sender_js string, emit_sender_js string) string {
	lines := [
		'(function () {',
		'  if (window.vails) { return; }',
		'  var seq = 0;',
		'  var pending = {};',
		'  var listeners = {};',
		'  function nextId() { seq += 1; return "v" + seq; }',
		'  window.vails = {',
		'    call: function (method, params) {',
		'      var id = nextId();',
		'      var body = JSON.stringify({ id: id, method: method, params: params || "" });',
		'      return new Promise(function (resolve, reject) {',
		'        pending[id] = { resolve: resolve, reject: reject };',
		'        ' + call_sender_js,
		'      });',
		'    },',
		'    emit: function (name, data) {',
		'      var body = JSON.stringify({ event: name, data: data || "" });',
		'      ' + emit_sender_js,
		'    },',
		'    onEvent: function (name, cb) {',
		'      if (!listeners[name]) { listeners[name] = []; }',
		'      listeners[name].push(cb);',
		'    },',
		'    __resolve: function (raw) {',
		'      var msg;',
		'      try { msg = JSON.parse(raw); } catch (e) { return; }',
		'      var p = pending[msg.id];',
		'      if (!p) { return; }',
		'      delete pending[msg.id];',
		'      if (msg.err) { p.reject(new Error(msg.err)); } else { p.resolve(msg.result); }',
		'    },',
		'    __emit: function (name, data) {',
		'      var cbs = listeners[name] || [];',
		'      for (var i = 0; i < cbs.length; i++) {',
		'        try { cbs[i](data); } catch (e) {}',
		'      }',
		'    }',
		'  };',
		'})();',
	]
	return lines.join('\n')
}
