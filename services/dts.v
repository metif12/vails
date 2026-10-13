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
// shared shape the .d.ts emitter already understands. Kept so a service
// (or a tool) can hand its commands to generator.generate_dts directly.
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
// the manifest's TypeScript declarations first, then the promise-returning
// function per command. The names are the short ones the per-service JS
// snippet installs on window.vails, so a frontend type-checks the same
// shape it calls at runtime.
//
// **A blocking command carries a JSDoc marker above its declaration**, and
// that is the whole point of the `blocking` field reaching this function at
// all. ADR-0014 says the flag exists "so the constraint is visible in the
// service description, not only in prose" — and until now it was in neither:
// `dts` emitted a bare signature, so the generated `.d.ts` a frontend
// type-checks against was byte-identical whether a command froze the UI or
// not. A frontend author had to go and read ADR-0014 to learn that
// `dialog.open` blocks until the user answers, and nothing in their editor
// would have told them.
//
// A JSDoc comment rather than a change to the signature, because the flag is
// documentation and not part of the type: `dialog.open` takes the same
// arguments and returns the same `Promise` whether it blocks or not, and
// inventing a wrapper type to encode "blocks the UI" would be a lie about the
// runtime shape.
pub fn dts(svcs []Service) string {
	mut out := ''
	for s in svcs {
		out += 'export namespace ' + s.name + ' {\n'
		for t in s.ts_types {
			out += t + '\n'
		}
		out += '\texport const service: string;\n'
		out += '\texport const version: string;\n'
		for c in s.commands {
			if c.blocking {
				out += '\t/** ' + blocking_note(c) + ' */\n'
			}
			out += '\texport function ' + c.short_name() + '(params: ' +
				params_type(c) + '): Promise<' + c.result + '>;\n'
		}
		out += '}\n'
	}
	return out
}

// blocking_note is the one-line warning a frontend author reads at the call
// site. It says what the call does and what the constraint is, because "this
// blocks" alone reads as a performance note rather than as "do not put this on
// a path that must stay responsive".
fn blocking_note(c Command) string {
	return c.short_name() + ' blocks the UI until it is answered (a native ' +
		'modal). Do not call it from a loop or a startup path; it is the ' +
		'documented exception to the "handlers must be fast" threading rule ' +
		'(ADR-0014).'
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
