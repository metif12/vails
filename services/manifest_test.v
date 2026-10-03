module services

// demo is a two-command service used to test the manifest, install and
// codegen paths without depending on a native backend.
fn demo() Service {
	return Service{
		name:     'demo'
		version:  '0.1.0'
		summary:  'test service'
		commands: [
			Command{
				name:    'demo.run'
				params:  '{ value: number }'
				result:  'string'
				summary: 'runs the demo'
			},
			Command{
				name:    'demo.stop'
				result:  'void'
				summary: 'stops the demo'
			},
		]
	}
}

fn test_prefix_and_own_command() {
	s := demo()
	assert s.prefix() == 'demo.'
	assert s.own_command('demo.run')
	assert !s.own_command('dialog.open')
	assert !s.own_command('run')
}

fn test_command_lookup() {
	s := demo()
	assert s.has_command('demo.run')
	assert !s.has_command('demo.missing')
	assert s.command('demo.stop') != none
	assert (s.command('demo.stop') or { panic('missing') }).params == no_params
	assert s.command_names() == ['demo.run', 'demo.stop']
}

fn test_short_name_and_matches() {
	c := demo().command('demo.run') or { panic('missing') }
	assert c.short_name() == 'run'
	assert c.matches('demo.run')
	assert c.matches('run')
	assert !c.matches('dialog.run')
}

fn test_js_snippet_shape() {
	js := demo().js_snippet()
	assert js.contains('var ns = v.demo = v.demo || {};')
	assert js.contains('ns.run = function (params) { return v.call("demo.run", params || ""); };')
	assert js.contains('ns.stop = function (params) { return v.call("demo.stop", params || ""); };')
	assert js.trim_space().ends_with('}());')
}

fn test_js_snippet_has_no_interpolation_traps() {
	// The runtime source is assembled from V strings: a `$` or a backtick
	// would break interpolation or the JS literal (same rule as
	// bridge.runtime_js).
	js := demo().js_snippet()
	assert !js.contains('$')
	assert !js.contains('`')
}

fn test_find_in_resolves_by_name() {
	assert (find_in([demo()], 'demo') or { panic('missing') }).name == 'demo'
	assert find_in([demo()], 'nope') == none
}

fn test_service_in_prefers_exact_wire_names() {
	list := [demo(), Service{
		name:     'other'
		version:  '0.1.0'
		commands: [Command{ name: 'other.run' }]
	}]
	// 'run' is ambiguous in bare form; the first manifest wins.
	assert (service_in(list, 'run') or { panic('missing') }).name == 'demo'
	// The exact wire name always wins.
	assert (service_in(list, 'other.run') or { panic('missing') }).name == 'other'
	assert service_in(list, 'nope') == none
}

fn test_lookup_in_resolves_service_and_command() {
	s, c := lookup_in([demo()], 'stop') or { panic('missing') }
	assert s.name == 'demo'
	assert c.name == 'demo.stop'
	assert lookup_in([demo()], 'ping') == none
}

fn test_select_in_reports_unknown_names() {
	svcs, unknown := select_in([demo()], ['demo.run', 'ping', 'nope'])
	assert svcs.len == 1
	assert svcs[0].name == 'demo'
	assert unknown == ['ping', 'nope']
}

fn test_select_in_dedupes_services() {
	svcs, unknown := select_in([demo()], ['demo.run', 'stop', 'demo.stop'])
	assert svcs.len == 1
	assert unknown == []string{}
}

fn test_granted_commands_dedupes() {
	assert granted_commands(['ping', 'ping', 'dialog.open', 'ping']) ==
		['ping', 'dialog.open']
}

// The catalog wrappers are the seam the CLI and the services build on;
// Phase 5 S1 wave 1 put dialog and os_info in it, wave 2 added
// notification, menu, tray, clipboard and opener, and F1 added drop. The count
// is asserted exactly: a service that is added to the catalog without a
// manifest test here is a service nobody looked at.
fn test_catalog_wrappers_see_the_built_in_services() {
	assert manifests().len == 8
	assert (find('dialog') or { panic('missing') }).name == 'dialog'
	assert (find('os_info') or { panic('missing') }).name == 'os_info'
	assert (find('clipboard') or { panic('missing') }).name == 'clipboard'
	assert (find('opener') or { panic('missing') }).name == 'opener'
	assert (find('notification') or { panic('missing') }).name == 'notification'
	assert (find('menu') or { panic('missing') }).name == 'menu'
	assert (find('tray') or { panic('missing') }).name == 'tray'
	assert (find('drop') or { panic('missing') }).name == 'drop'
	assert service_of('dialog.open') != none
	assert service_of('os_info.get') != none
	assert service_of('clipboard.read_text') != none
	assert service_of('opener.open_url') != none
	assert service_of('notification.notify') != none
	assert service_of('menu.popup') != none
	assert service_of('tray.set') != none
	assert service_of('drop.enable') != none
	// a name nothing provides is reported, not silently ignored
	svcs, unknown := select_for(['dialog.open', 'ping'])
	assert svcs.len == 1
	assert unknown == ['ping']
}

fn test_lookup_in_resolves_through_the_catalog() {
	s, c := lookup('dialog.save') or { panic('missing') }
	assert s.name == 'dialog'
	assert c.name == 'dialog.save'
}
