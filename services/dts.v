// dts.v — frontend codegen from manifests (T5): TypeScript declarations
// per service, plus the JS snippets that make `window.vails.dialog.*`
// exist in the browser.
//
// Generation is driven by the capability grants in vails.json, so a
// frontend can only type-check against the services it was actually
// granted. Pure-V: no filesystem, no config parsing — the CLI does that
// and writes what these functions return (see cli `vails dts`).
module services

import generator

// specs converts the manifest's commands into generator.MethodSpec, the
// shared shape the .d.ts emitter already understands.
pub fn (s Service) specs() []generator.MethodSpec {
	mut out := []generator.MethodSpec{}
	for c in s.commands {
		params := if c.params == no_params { 'undefined' } else { c.params }
		out << generator.MethodSpec{
			name:   c.short_name()
			params: params
			result: c.result
		}
	}
	return out
}

// dts renders one `export namespace <service> { … }` block per service:
// the manifest's TypeScript declarations, then the promise-returning
// function per command. The runtime part declares the window.vails shape
// the JS snippet installs, so `window.vails.dialog.open` type-checks.
pub fn dts(svcs []Service) string {
	mut out := ''
	for s in svcs {
		out += generator.generate_dts(s.name, s.specs())
		out += 'export namespace ' + s.name + '_runtime {\n'
		out += '\texport const service: string;\n'
		out += '\texport const version: string;\n'
		for c in s.commands {
			out += '\texport function ' + c.short_name() + '(params: ' +
				params_type(c) + '): Promise<' + c.result + '>;\n'
		}
		out += '}\n'
	}
	return out
}

// params_type is the .d.ts parameter type of one command: `undefined`
// for a no-argument command, the declared type otherwise.
fn params_type(c Command) string {
	return if c.params == no_params { 'undefined' } else { c.params }
}

// snippets concatenates the per-service JS glue. Each snippet is
// independent and idempotent (`ns.x = ns.x || {}` style guards), so a
// frontend can load them in any order and twice without harm.
pub fn snippets(svcs []Service) string {
	mut out := ''
	for s in svcs {
		out += '// service: ' + s.name + ' ' + s.version + ' - ' + s.summary + '\n'
		out += s.js_snippet() + '\n'
	}
	return out
}

// granted_commands flattens the granted command names out of capability
// specs, preserving order and dropping duplicates. Kept here (not in the
// CLI) so the grant -> manifest mapping is unit-testable.
pub fn granted_commands(commands []string) []string {
	mut out := []string{}
	for c in commands {
		if c !in out {
			out << c
		}
	}
	return out
}
