module services

import bridge
import capabilities
import json2
import os

fn test_manifest_shape() {
	m := os_info_manifest()
	assert m.name == 'os_info'
	assert m.command_names() == ['os_info.get']
	// no-arg command: the install path must wire validate_empty
	assert m.commands[0].params == no_params
	// the reference service has no native call at all
	assert !m.commands[0].blocking
}

fn test_manifest_is_in_the_catalog() {
	assert find('os_info') != none
	assert (service_of('os_info.get') or { panic('missing') }).name == 'os_info'
	// a bare 'get' is ambiguous across services, so the wire name is the
	// documented form
	assert (service_of('os_info.get') or { panic('missing') }).name == 'os_info'
}

fn test_collect_reports_the_current_os() {
	info := collect()
	assert info.os == os.user_os()
	assert info.arch == host_arch()
	assert info.cwd == os.getwd()
	assert info.exe_path == os.executable()
}

fn test_collect_json_shape() {
	raw := json2.encode(collect(), escape_unicode: true)
	decoded := json2.decode[Info](raw) or { panic(err.msg()) }
	assert decoded.os == os.user_os()
	assert decoded.hostname != ''
	assert decoded.cpus > 0
}

fn test_command_is_capability_gated() {
	mut router := bridge.new_router()
	install_os_info(mut router)!
	res := router.call_json('main', '1', 'os_info.get', '',
		capabilities.new_registry())
	assert res.err.starts_with('forbidden:')
}

fn test_command_returns_json() {
	mut router := bridge.new_router()
	install_os_info(mut router)!
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		windows:  ['main']
		commands: ['os_info.get']
	})
	res := router.call_json('main', '1', 'os_info.get', '', reg)
	assert res.err == ''
	info := json2.decode[Info](res.result) or { panic(err.msg()) }
	assert info.os == os.user_os()
}

fn test_command_rejects_params() {
	mut router := bridge.new_router()
	install_os_info(mut router)!
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		commands: ['os_info.get']
	})
	res := router.call_json('main', '1', 'os_info.get', '{"nope":1}', reg)
	assert res.err.starts_with('bad params:')
}
