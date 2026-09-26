module generator

fn test_generate_dts() {
	out := generate_dts('backend', [
		MethodSpec{
			name:   'greet'
			params: '{ name: string }'
			result: 'string'
		},
	])
	assert out.contains('export namespace backend')
	assert out.contains('export function greet(params: { name: string }): Promise<string>;')
}

fn test_generate_dts_empty() {
	assert generate_dts('backend', []) == 'export namespace backend {\n}\n'
}
