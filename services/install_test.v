module services

import bridge
import capabilities

// demo is a local two-command service: every V test file compiles as its
// own module, so test helpers cannot be shared between _test.v files.
fn demo() Service {
	return Service{
		name:     'demo'
		version:  '0.1.0'
		summary:  'install test service'
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

// handler set used by the install tests: every command answers 'ok'.
// Built by assignment because V cannot parse a map literal whose value is
// a fn literal.
fn demo_backend() Backend {
	mut backend := Backend{}
	backend['demo.run'] = fn (_ string) !string {
		return 'ok'
	}
	backend['demo.stop'] = fn (_ string) !string {
		return 'ok'
	}
	return backend
}

// full_registry grants both demo commands for the window 'main'.
fn full_registry() capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'demo-all'
		windows:  ['main']
		commands: ['demo.run', 'demo.stop']
	})
	return reg
}

fn test_install_binds_every_manifest_command() {
	mut router := bridge.new_router()
	install(mut router, demo(), demo_backend())!
	res := router.call_json('main', '1', 'demo.run', '{"value":1}', full_registry())
	assert res.err == ''
	assert res.result == 'ok'
}

fn test_install_uses_the_capability_gate() {
	mut router := bridge.new_router()
	install(mut router, demo(), demo_backend())!
	// No grants at all: the command is registered, so an empty registry
	// denies it without leaking that the method exists (ADR-0007).
	res := router.call_json('main', '1', 'demo.run', '{"value":1}',
		capabilities.new_registry())
	assert res.err.starts_with('forbidden:')
	assert !res.err.contains('unknown method')
}

fn test_install_rejects_ungranted_window() {
	mut router := bridge.new_router()
	install(mut router, demo(), demo_backend())!
	res := router.call_json('other', '1', 'demo.stop', '', full_registry())
	assert res.err.contains('window "other"')
}

fn test_installed_no_arg_command_rejects_payloads() {
	mut router := bridge.new_router()
	install(mut router, demo(), demo_backend())!
	// demo.stop declares no params: the manifest drives validate_empty.
	assert router.call_json('main', '1', 'demo.stop', '', full_registry()).err == ''
	res := router.call_json('main', '2', 'demo.stop', '{"value":1}', full_registry())
	assert res.err.starts_with('bad params:')
}

fn test_install_arg_command_accepts_payloads() {
	mut router := bridge.new_router()
	install(mut router, demo(), demo_backend())!
	res := router.call_json('main', '1', 'demo.run', '{"value":7}', full_registry())
	assert res.err == ''
}

fn test_install_rejects_missing_handler() {
	mut router := bridge.new_router()
	mut backend := demo_backend()
	backend.delete('demo.stop')
	mut failed := ''
	install(mut router, demo(), backend) or { failed = err.msg() }
	assert failed.contains('no handler for command "demo.stop"')
}

fn test_install_rejects_undeclared_backend_entry() {
	mut router := bridge.new_router()
	mut backend := demo_backend()
	backend['dialog.open'] = fn (_ string) !string {
		return 'nope'
	}
	mut failed := ''
	install(mut router, demo(), backend) or { failed = err.msg() }
	assert failed.contains('handler for undeclared command "dialog.open"')
}

fn test_install_rejects_foreign_namespace() {
	mut router := bridge.new_router()
	sneaky := Service{
		name:     'demo'
		version:  '0.1.0'
		commands: [Command{ name: 'dialog.open' }]
	}
	mut backend := Backend{}
	backend['dialog.open'] = fn (_ string) !string {
		return 'nope'
	}
	mut failed := ''
	install(mut router, sneaky, backend) or { failed = err.msg() }
	assert failed.contains('outside the "demo." namespace')
}

fn test_install_rejects_duplicate_registration() {
	mut router := bridge.new_router()
	install(mut router, demo(), demo_backend())!
	mut failed := ''
	install(mut router, demo(), demo_backend()) or { failed = err.msg() }
	assert failed.contains('method already registered')
}

fn test_install_all_binds_several_services() {
	second := Service{
		name:     'other'
		version:  '0.1.0'
		commands: [Command{ name: 'other.run' }]
	}
	mut router := bridge.new_router()
	mut other_backend := Backend{}
	other_backend['other.run'] = fn (_ string) !string {
		return 'other'
	}
	mut backends := map[string]Backend{}
	backends['demo'] = demo_backend()
	backends['other'] = other_backend
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'all'
		commands: ['demo.run', 'other.run']
	})
	install_all(mut router, [demo(), second], backends)!
	assert router.call_json('main', '1', 'demo.run', '', reg).result == 'ok'
	assert router.call_json('main', '2', 'other.run', '', reg).result == 'other'
}

fn test_install_all_requires_a_backend_per_service() {
	mut router := bridge.new_router()
	mut backends := map[string]Backend{}
	backends['demo'] = demo_backend()
	second := Service{
		name:     'other'
		version:  '0.1.0'
		commands: [Command{ name: 'other.run' }]
	}
	mut failed := ''
	install_all(mut router, [demo(), second], backends) or { failed = err.msg() }
	assert failed.contains('no backend for service other')
}
