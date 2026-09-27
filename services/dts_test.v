module services

// demo is a local two-command service: every V test file compiles as its
// own module, so test helpers cannot be shared between _test.v files.
fn demo() Service {
	return Service{
		name:     'demo'
		version:  '0.1.0'
		summary:  'test service'
		commands: [
			Command{
				name:   'demo.run'
				params: '{ value: number }'
				result: 'string'
			},
			Command{ name: 'demo.stop', result: 'void' },
		]
	}
}

fn test_specs_use_short_names() {
	specs := demo().specs()
	assert specs.len == 2
	assert specs[0].name == 'run'
	assert specs[0].params == '{ value: number }'
	assert specs[0].result == 'string'
}

fn test_specs_mark_no_arg_commands_undefined() {
	specs := demo().specs()
	assert specs[1].name == 'stop'
	assert specs[1].params == 'undefined'
}

fn test_dts_emits_namespace_per_service() {
	out := dts([demo()])
	assert out.contains('export namespace demo {')
	assert out.contains('export function run(params: { value: number }): Promise<string>;')
	assert out.contains('export function stop(params: undefined): Promise<void>;')
}

fn test_dts_declares_the_runtime_shape() {
	out := dts([demo()])
	assert out.contains('export const service: string;')
	assert out.contains('export const version: string;')
	// one namespace per service, not one per service+runtime
	assert out.split('export namespace').len == 2
}

fn test_dts_includes_manifest_types_first() {
	typed := Service{
		name:     'typed'
		version:  '0.1.0'
		commands: [Command{ name: 'typed.get', result: 'Typed' }]
		ts_types: ['\texport interface Typed { value: string; }']
	}
	out := dts([typed])
	assert out.contains('export interface Typed { value: string; }')
	// the interface must come before the function that returns it
	assert (out.index('interface Typed') or { -1 }) < (out.index('Promise<Typed>') or { -1 })
}

fn test_dts_of_nothing_is_empty() {
	assert dts([]) == ''
}

fn test_snippets_are_prefixed_per_service() {
	out := snippets([demo()])
	assert out.starts_with('// service: demo 0.1.0 - test service')
	assert out.contains('v.demo = v.demo || {}')
}

fn test_snippets_of_nothing_is_empty() {
	assert snippets([]) == ''
}
