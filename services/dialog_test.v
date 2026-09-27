module services

import bridge
import capabilities
import webview

// sample_ctx is a headless window context: no native handle, a no-op eval
// sink. Enough to exercise the pure-V half of the service (option
// validation, result encoding, capability gating) on any OS; the native
// picker itself is proven by hand (see tests/e2e_windows/README.md).
fn sample_ctx() webview.Ctx {
	return webview.Ctx{
		label:   'main'
		eval_fn: fn (_ string) ! {}
	}
}

fn grant(names []string) capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		windows:  ['main']
		commands: names
	})
	return reg
}

fn test_manifest_shape() {
	m := dialog_manifest()
	assert m.name == 'dialog'
	assert m.command_names() == ['dialog.open', 'dialog.save', 'dialog.message']
	for c in m.commands {
		assert m.own_command(c.name)
		// every dialog command is a modal native call
		assert c.blocking
	}
}

fn test_manifest_is_in_the_catalog() {
	assert find('dialog') != none
	assert (service_of('dialog.open') or { panic('missing') }).name == 'dialog'
	// bare grant names resolve too
	assert (service_of('message') or { panic('missing') }).name == 'dialog'
}

fn test_parse_options_from_object() {
	opts := parse_options(kind_open, '{"title":"Pick","multi":true}') or {
		panic(err.msg())
	}
	assert opts.title == 'Pick'
	assert opts.multi
}

fn test_parse_options_from_bare_string() {
	// "Open a file" is the minimal payload a frontend can send.
	opts := parse_options(kind_save, '"Save as"') or { panic(err.msg()) }
	assert opts.title == 'Save as'
}

// Every multi-word field the .d.ts promises has to be spelled exactly as the
// V struct field, because json2 drops keys it does not recognize. This test
// is the guard for that: the camelCase spellings decode to nothing, the
// snake_case ones decode, and the ts_types block promises the latter.
fn test_promised_wire_names_are_the_struct_field_names() {
	opts := parse_options(kind_save,
		'{"title":"Save","default_path":"C:\\\\tmp\\\\","default_name":"notes.txt"}') or {
		panic(err.msg())
	}
	assert opts.default_path == 'C:\\tmp\\'
	assert opts.default_name == 'notes.txt'
	// the camelCase spelling the .d.ts used to promise: accepted as valid
	// JSON, ignored by the decoder - which is exactly the silent failure
	// this test exists to prevent
	camel := parse_options(kind_save, '{"defaultName":"notes.txt"}') or {
		panic(err.msg())
	}
	assert camel.default_name == ''
	// and the ts_types block agrees with the struct
	ts := dialog_ts_types().join(' ')
	assert ts.contains('default_path?: string')
	assert ts.contains('default_name?: string')
	assert !ts.contains('defaultPath')
}

fn test_parse_options_rejects_garbage() {
	mut failed := ''
	parse_options(kind_open, 'not json') or { failed = err.msg() }
	assert failed.contains('invalid options')
}

fn test_parse_options_rejects_empty_payload() {
	mut failed := ''
	parse_options(kind_open, '') or { failed = err.msg() }
	assert failed.contains('no options')
}

fn test_kind_must_match_the_command() {
	// A granted dialog.open must not be usable to run a save or a box.
	mut failed := ''
	parse_options(kind_open, '{"kind":"save"}') or { failed = err.msg() }
	assert failed.contains('does not accept kind "save"')
}

fn test_kind_defaults_to_the_command() {
	// `{}` means "the dialog this command is": the frontend does not have
	// to repeat the kind, and cannot smuggle another one in.
	mut opts := parse_options(kind_save, '{}') or { panic(err.msg()) }
	assert opts.kind == kind_save
	opts = parse_options(kind_open, '{"title":"x"}') or { panic(err.msg()) }
	assert opts.kind == kind_open
}

fn test_message_requires_text() {
	mut failed := ''
	parse_options(kind_message, '{"title":"hi"}') or { failed = err.msg() }
	assert failed.contains('message is required')
}

fn test_message_accepts_buttons() {
	opts := parse_options(kind_message, '{"message":"ok?","buttons":"yesnocancel"}') or {
		panic(err.msg())
	}
	assert opts.buttons == buttons_yes_no_cancel
}

fn test_message_rejects_unknown_buttons() {
	mut failed := ''
	parse_options(kind_message, '{"message":"x","buttons":"maybe"}') or {
		failed = err.msg()
	}
	assert failed.contains('buttons must be')
}

fn test_open_accepts_multi() {
	opts := parse_options(kind_open, '{"multi":true}') or { panic(err.msg()) }
	assert opts.multi
}

fn test_multi_is_rejected_for_save() {
	mut failed := ''
	parse_options(kind_save, '{"multi":true}') or { failed = err.msg() }
	assert failed.contains('multi is only valid for kind "open"')
}

fn test_default_name_is_rejected_for_open() {
	mut failed := ''
	parse_options(kind_open, '{"default_name":"a.txt"}') or { failed = err.msg() }
	assert failed.contains('default_name is only valid for kind "save"')
}

fn test_length_limits() {
	mut long_title := '{"title":"'
	long_title += 'x'.repeat(max_title + 1) + '"}'
	mut failed := ''
	parse_options(kind_open, long_title) or { failed = err.msg() }
	assert failed.contains('title is longer')
}

fn test_filter_validation() {
	validate_filter(Filter{
		name:       'Images'
		extensions: 'png,jpg'
	}) or { panic(err.msg()) }
	validate_filter(Filter{
		name:       'All'
		extensions: '.PNG'
	}) or { panic(err.msg()) }
	mut failed := ''
	validate_filter(Filter{
		name:       'Bad'
		extensions: 'png;j'
	}) or { failed = err.msg() }
	assert failed.contains('invalid extension')
}

fn test_filter_rejects_empty_name_and_extension() {
	mut no_name := ''
	validate_filter(Filter{
		name:       '  '
		extensions: 'png'
	}) or { no_name = err.msg() }
	assert no_name.contains('name must not be empty')

	mut no_ext := ''
	validate_filter(Filter{
		name:       'Images'
		extensions: 'png,'
	}) or { no_ext = err.msg() }
	assert no_ext.contains('empty extension')

	mut sep := ''
	validate_filter(Filter{
		name:       'Images|Text'
		extensions: 'png'
	}) or { sep = err.msg() }
	assert sep.contains('must not contain')
}

fn test_too_many_filters() {
	mut filters := []Filter{}
	for i in 0 .. max_filters + 1 {
		filters << Filter{
			name:       'f' + i.str()
			extensions: 'txt'
		}
	}
	mut failed := ''
	parse_options(kind_open, json_of(filters)) or { failed = err.msg() }
	assert failed.contains('at most ' + max_filters.str() + ' filters')
}

// json_of renders a filter list as the params payload (keeps the test free
// of hand-written JSON escaping).
fn json_of(filters []Filter) string {
	mut parts := []string{}
	for f in filters {
		parts << '{"name":"' + f.name + '","extensions":"' + f.extensions + '"}'
	}
	return '{"filters":[' + parts.join(',') + ']}'
}

fn test_native_filter_string_format() {
	assert native_filter_string([Filter{ name: 'Images', extensions: 'png,jpg' }, Filter{
		name:       'Text'
		extensions: 'txt'
	}]) == 'Images (*.png;*.jpg)|Text (*.txt)'
}

fn test_native_filter_string_normalizes() {
	assert native_filter_string([Filter{
		name:       'All'
		extensions: ' .PNG , jpg '
	}]) == 'All (*.png;*.jpg)'
}

fn test_native_filter_string_of_nothing_is_empty() {
	assert native_filter_string([]) == ''
}

fn test_parse_paths_splits_on_nul() {
	assert parse_paths('C:\\a.txt\x00D:\\b.txt\x00') == ['C:\\a.txt', 'D:\\b.txt']
	assert parse_paths('') == []string{}
	assert parse_paths('\x00') == []string{}
}

fn test_encode_result_shape() {
	out := encode_result(Result{
		canceled: true
	})
	assert out.contains('"canceled":true')
	assert out.contains('"paths":[]')
	assert !out.contains('null')
}

fn test_encode_result_carries_paths() {
	out := encode_result(Result{
		paths:  ['C:\\a.txt']
		button: 'ok'
	})
	assert out.contains('"canceled":false')
	assert out.contains('C:\\\\a.txt')
	assert out.contains('"button":"ok"')
}

// The gate is proven without ever calling the native picker: a granted
// call is covered by test_manifest_installs_against_a_fake_backend, and a
// real dialog must never run inside `v test` (it would block the suite on
// a modal window nobody can click - ADR-0014).
fn test_installed_dialog_command_is_capability_gated() {
	mut router := bridge.new_router()
	install_dialog(mut router, sample_ctx())!
	// no grant at all
	mut res := router.call_json('main', '1', 'dialog.open', '{}',
		capabilities.new_registry())
	assert res.err.starts_with('forbidden:')
	// the other window of the same app is not granted either
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'main-only'
		windows:  ['main']
		commands: ['dialog.open']
	})
	res = router.call_json('other', '2', 'dialog.open', '{}', reg)
	assert res.err.contains('window "other"')
}

fn test_installed_dialog_rejects_bad_options_with_bad_params() {
	mut router := bridge.new_router()
	install_dialog(mut router, sample_ctx())!
	mut res := router.call_json('main', '1', 'dialog.open', '{"kind":"nope"}',
		grant(['dialog.open']))
	assert res.err.starts_with('bad params:')
}

// A modal dialog must never run in a unit test: the native picker blocks
// the main thread until a human answers (ADR-0014), so the tests wire the
// real manifest against a fake backend instead. The real pickers are
// proven by hand - see tests/e2e_windows/README.md.
fn test_manifest_installs_against_a_fake_backend() {
	mut router := bridge.new_router()
	mut backend := Backend{}
	backend['dialog.open'] = fn (_ string) !string {
		return '{"canceled":true,"paths":[],"button":""}'
	}
	backend['dialog.save'] = fn (_ string) !string {
		return '{"canceled":false,"paths":["C:\\\\out.txt"],"button":""}'
	}
	backend['dialog.message'] = fn (_ string) !string {
		return '{"canceled":false,"paths":[],"button":"ok"}'
	}
	install(mut router, dialog_manifest(), backend)!
	mut res := router.call_json('main', '1', 'dialog.open', '{}',
		grant(['dialog.open']))
	assert res.err == ''
	assert res.result.contains('"canceled":true')
	res = router.call_json('main', '2', 'dialog.save', '{"title":"x"}',
		grant(['dialog.save']))
	assert res.result.contains('out.txt')
	res = router.call_json('main', '3', 'dialog.message', '{"message":"hi"}',
		grant(['dialog.message']))
	assert res.result.contains('"button":"ok"')
}

fn test_backend_is_pending_on_linux() {
	// On Linux the shim is an explicit stub: the error must say so instead
	// of resolving with a fake result. The call is safe there because no
	// native dialog exists to block on.
	$if linux {
		mut router := bridge.new_router()
		install_dialog(mut router, sample_ctx())!
		mut res := router.call_json('main', '1', 'dialog.message', '{"message":"hi"}',
			grant(['dialog.message']))
		assert res.err.contains('not implemented')
	} $else {
		// Windows has a real backend; dialog_rc/parse_paths are covered
		// directly, the native call stays manual.
		assert parse_paths('a\x00b\x00') == ['a', 'b']
	}
}

fn test_dialog_rc_maps_shim_codes() {
	// 0 = canceled, n>0 = n paths, <0 = shim error (the message comes from
	// the backend, so the mapping is what matters here). Pure V, so this
	// test runs on Linux too.
	mut res := dialog_rc(0, '', '') or { panic('canceled is not an error') }
	assert res.canceled
	res = dialog_rc(2, 'C:\\a.txt\x00C:\\b.txt\x00', '') or { panic(err.msg()) }
	assert !res.canceled
	assert res.paths.len == 2
	// a negative code is an error carrying the backend's message
	mut failed := false
	dialog_rc(-1, '', 'the shell refused') or { failed = true }
	assert failed
}

fn test_installed_dialog_does_not_leak_other_namespaces() {
	mut router := bridge.new_router()
	install_dialog(mut router, sample_ctx())!
	// dialog.* must not answer to os_info's name
	res := router.call_json('main', '1', 'os_info.get', '', grant(['os_info.get']))
	assert res.err.starts_with('unknown method:')
}
