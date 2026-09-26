// generator.v — TypeScript declaration emit for bound methods
// (guide: v2/internal/typescriptify, v3/internal/generator).
// Specs are hand-written in Phase 2; $for-based auto-derivation is Phase 7.
module generator

// MethodSpec describes one bound method: TS types for params and result.
pub struct MethodSpec {
pub:
	name   string
	params string
	result string
}

// generate_dts emits `export namespace <ns> { … }` with one Promise-based
// function per method, matching the bridge's JSON call convention.
pub fn generate_dts(namespace string, methods []MethodSpec) string {
	mut out := 'export namespace ' + namespace + ' {\n'
	for m in methods {
		out += '\texport function ' + m.name + '(params: ' + m.params + '): Promise<' +
			m.result + '>;\n'
	}
	out += '}\n'
	return out
}
