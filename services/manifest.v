// manifest.v — the service manifest (T5): what a service is, which
// commands it contributes and what the frontend gets for free.
//
// A manifest is data, not code: it is the single description a service
// registers from, generates its TypeScript declarations from, and prints
// in `vails doctor`. Capabilities stay flat strings (ADR-0007), so a
// service's commands ARE its capability names ('dialog.open'), which
// keeps vails.json grants and manifest entries from drifting apart.
//
// Pure-V and OS-agnostic: no C, no globals, nothing platform-specific, so
// every service on every OS is described the same way.
module services

// Command is one bound method of a service.
pub struct Command {
pub:
	name string
	// params/result are TypeScript type texts emitted into the .d.ts
	// (Tauri-style). params == no_params means the command takes no
	// arguments (the frontend sends ""), and the install path then wires
	// bridge.validate_empty so a stray payload is rejected.
	params string
	result string
	// blocking marks a command whose native call blocks the webview main
	// thread on purpose: a modal native dialog freezes the UI exactly like
	// a webview-native modal does (ADR-0014 records the exception to the
	// ADR-0010 threading rule).
	blocking bool
	summary  string
}

// no_params is the params text of a command without arguments.
pub const no_params = ''

// Service is one native capability group, e.g. 'dialog'.
pub struct Service {
pub:
	name     string
	version  string
	summary  string
	commands []Command
	// ts_types are raw TypeScript declarations (interfaces, type aliases)
	// the command signatures refer to. They live in the manifest so the
	// .d.ts is generated from one source, and they are emitted inside the
	// service's namespace (tab-indented already).
	ts_types []string
}

// prefix is the service's namespace fragment ('dialog' -> 'dialog.'),
// used to build wire names and the JS namespace.
pub fn (s Service) prefix() string {
	return s.name + '.'
}

// has_command reports whether the service contributes the given wire name.
pub fn (s Service) has_command(name string) bool {
	return s.command(name) != none
}

// command_names returns the wire names this service contributes, in
// manifest order.
pub fn (s Service) command_names() []string {
	mut out := []string{}
	for c in s.commands {
		out << c.name
	}
	return out
}

// command looks one command up by wire name.
pub fn (s Service) command(name string) ?Command {
	for c in s.commands {
		if c.name == name {
			return c
		}
	}
	return none
}

// own_command rejects a foreign wire name, so a service can never claim
// another service's namespace (e.g. dialog installing 'os_info.get').
pub fn (s Service) own_command(name string) bool {
	return name.starts_with(s.prefix())
}

// short_name is the JS-side method name: the wire name without the
// service prefix ('dialog.open' -> 'open').
pub fn (c Command) short_name() string {
	idx := c.name.last_index('.') or { return c.name }
	return c.name[idx + 1..]
}

// matches reports whether the command answers to the given name: the full
// wire name ('dialog.open') or the bare name ('open'), which is what apps
// write in vails.json so grants stay readable.
pub fn (c Command) matches(name string) bool {
	return c.name == name || c.short_name() == name
}

// js_snippet is the service's own frontend glue: a namespace on
// window.vails wrapping each command in vails.call. Per service on
// purpose (T5): no monolithic runtime, and a frontend only pays for the
// services its capabilities actually grant.
//
// Plain ES5 with no `$` or backticks, because it is assembled from V
// strings (same rule as bridge.runtime_js).
pub fn (s Service) js_snippet() string {
	mut lines := [
		'(function () {',
		'  var v = window.vails = window.vails || {};',
		'  var ns = v.' + s.name + ' = v.' + s.name + ' || {};',
	]
	for c in s.commands {
		lines << '  ns.' + c.short_name() + ' = function (params) { return v.call("' +
			c.name + '", params || ""); };'
	}
	lines << '}());'
	return lines.join('\n')
}

// find returns the built-in service with the given name.
pub fn find(name string) ?Service {
	return find_in(manifests(), name)
}

// find_in is the list-based core of find, so tests can resolve names
// without touching the (platform-independent, but growing) catalog.
pub fn find_in(list []Service, name string) ?Service {
	for s in list {
		if s.name == name {
			return s
		}
	}
	return none
}

// service_of resolves one granted command name to the service providing
// it. Exact wire names win over bare names, so a grant list is never
// ambiguous when both are present.
pub fn service_of(command string) ?Service {
	return service_in(manifests(), command)
}

// service_in is the list-based core of service_of.
pub fn service_in(list []Service, command string) ?Service {
	for s in list {
		if s.has_command(command) {
			return s
		}
	}
	for s in list {
		for c in s.commands {
			if c.matches(command) {
				return s
			}
		}
	}
	return none
}

// lookup resolves one granted command name to its service + command.
pub fn lookup(command string) ?(Service, Command) {
	return lookup_in(manifests(), command)
}

// lookup_in is the list-based core of lookup.
pub fn lookup_in(list []Service, command string) ?(Service, Command) {
	if s := service_in(list, command) {
		if c := s.command(command) {
			return s, c
		}
		for c in s.commands {
			if c.matches(command) {
				return s, c
			}
		}
	}
	return none
}

// select_for returns the services covering the given granted command
// names, plus the names no service provides so `vails dts`/`doctor` can
// warn instead of silently emitting nothing.
pub fn select_for(granted []string) ([]Service, []string) {
	return select_in(manifests(), granted)
}

// select_in is the list-based core of select_for.
pub fn select_in(list []Service, granted []string) ([]Service, []string) {
	mut picked := []Service{}
	mut unknown := []string{}
	for name in granted {
		if s := service_in(list, name) {
			picked = add_service(picked, s)
		} else {
			unknown << name
		}
	}
	return picked, unknown
}

// add_service appends svc unless it is already in the list; manifest
// order wins, so the output does not depend on grant order. Returns the
// list because a V slice header is a value.
fn add_service(list []Service, svc Service) []Service {
	for s in list {
		if s.name == svc.name {
			return list
		}
	}
	mut out := list.clone()
	out << svc
	return out
}
