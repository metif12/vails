// serve.v — thin stdlib HTTP wrapper over the pure dev core (Phase 3).
// Deliberately NOT veb: veb pulls fasthttp's C files on Windows, which
// would force every `v test .` run through gcc and break this repo's
// no-gcc Windows CI rule (AGENTS.md §1). net.http is pure V, so this
// module stays testable everywhere. No logic lives here; behavior is
// covered in dev_test.v without sockets.
module dev

import net
import net.http

struct DevHandler {
	server DevServer
}

fn (mut h DevHandler) handle(req http.Request) http.Response {
	res := h.server.resolve_request(req.url) or {
		return http.new_response(
			status: status_for_err(err)
			body:   err.msg()
		)
	}
	mut header := http.new_header()
	header.add(.content_type, res.content_type)
	return http.new_response(
		status: .ok
		header: header
		body:   res.body
	)
}

// run blocks serving on 127.0.0.1:port (loopback only — dev traffic never
// leaves the machine). Callers (vails run) spawn it and open the webview
// at dev_url(). A busy port returns a clean error (no panic) so the CLI
// can suggest --port or a doctor hint.
pub fn (s DevServer) run() ! {
	// Probe first: a successful dial means something already answers
	// there, so fail with a hint instead of panicking inside the server.
	if mut busy := net.dial_tcp('127.0.0.1:${s.port}') {
		busy.close() or {}
		return error('vails dev: port ${s.port} is busy (another `vails run`? try --port N)')
	}
	mut server := &http.Server{
		addr:                 '127.0.0.1:${s.port}'
		handler:              DevHandler{
			server: &s
		}
		show_startup_message: false
	}
	server.listen_and_serve()
}
