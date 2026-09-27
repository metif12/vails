module services

import bridge
import capabilities
import webview

fn test_read_text_not_implemented() {
	mut failed := false
	read_text() or { failed = true }
	assert failed
}

fn test_write_text_not_implemented() {
	mut failed := false
	write_text('x') or { failed = true }
	assert failed
}

fn test_manifest_shape() {
	m := clipboard_manifest()
	assert m.name == 'clipboard'
	assert m.command_names() == ['clipboard.read_text', 'clipboard.write_text']
	assert m.commands[0].params == no_params
	// the payload is a JSON string, not an object
	assert m.commands[1].params == 'string'
}

fn test_manifest_is_not_installed_by_default() {
	// clipboard is not in the catalog yet: it ships as a seam until its
	// native half lands (Phase 5 S1 wave 2).
	assert find('clipboard') == none
}

fn test_install_binds_both_commands_but_the_backend_is_pending() {
	mut router := bridge.new_router()
	install_clipboard(mut router, webview.Ctx{
		label: 'main'
	})!
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		commands: ['clipboard.read_text', 'clipboard.write_text']
	})
	// A grant must not look like an unknown method: the error comes from
	// the backend, naming the pending wave.
	res := router.call_json('main', '1', 'clipboard.read_text', '', reg)
	assert !res.err.starts_with('unknown method')
	assert !res.err.starts_with('forbidden')
	assert res.err.contains('not implemented')
}

fn test_write_text_decodes_a_json_string_payload() {
	mut router := bridge.new_router()
	install_clipboard(mut router, webview.Ctx{
		label: 'main'
	})!
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		commands: ['clipboard.write_text']
	})
	mut res := router.call_json('main', '1', 'clipboard.write_text', '"hello"', reg)
	assert res.err.contains('not implemented')
	// a non-JSON payload is a params problem, not a backend error
	res = router.call_json('main', '2', 'clipboard.write_text', '{oops', reg)
	assert res.err.contains('expected a JSON string')
}
