// install.v — the one path every service registers through (T5).
//
// A service hands in its manifest and a backend (wire name -> handler)
// and gets its commands bound on the router. Doing it here instead of in
// each service keeps three guarantees in one place:
//
//   - a command is only ever registered under its own service namespace
//     (Service.own_command), so services cannot hijack each other;
//   - every command declared in the manifest must have a handler and
//     vice versa, so a manifest can never drift from the code;
//   - no-argument commands get bridge.validate_empty, so the frontend
//     cannot smuggle a payload past the T2 params check.
//
// The capability gate itself stays where it is: install only binds, and
// dispatch gating is bridge.Router.call_json with the app's registry
// (ADR-0007/0010). Handlers still run on the webview main thread, except
// for the manifest commands marked blocking (see ADR-0014).
module services

import bridge

// Backend maps a command's wire name to its handler. A handler receives
// the raw params JSON and returns raw result JSON.
pub type Handler = fn (params string) !string

pub type Backend = map[string]Handler

// install binds every command of the manifest on router. Fails fast: an
// unknown command name, a missing handler, a command outside the service
// namespace, a duplicate registration, or a backend entry the manifest
// does not declare.
pub fn install(mut router bridge.Router, s Service, backend Backend) ! {
	for name, _ in backend {
		if !s.has_command(name) {
			return error('service ' + s.name + ': handler for undeclared command "' + name +
				'"')
		}
	}
	for c in s.commands {
		if !s.own_command(c.name) {
			return error('service ' + s.name + ': command "' + c.name +
				'" is outside the "' + s.prefix() + '" namespace')
		}
		handler := backend[c.name] or {
			return error('service ' + s.name + ': no handler for command "' + c.name + '"')
		}
		validator := if c.params == no_params { bridge.validate_empty } else { bridge.validate_any }
		router.register_validated(c.name, validator, handler)!
	}
}

// install_all binds several services, aborting on the first failure.
// Each service gets its own handler set (keyed by service name) so a
// handler can never leak into another service's namespace.
pub fn install_all(mut router bridge.Router, svcs []Service, backends map[string]Backend) ! {
	for s in svcs {
		if s.name !in backends {
			return error('no backend for service ' + s.name)
		}
		install(mut router, s, backends[s.name])!
	}
}
