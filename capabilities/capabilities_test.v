module capabilities

fn test_empty_registry_denies() {
	r := new_registry()
	assert r.is_allowed_on('main', 'ping', 'windows') == false
	assert r.is_allowed_on('main', 'ping', 'linux') == false
}

fn test_grant_allows_exact_window_and_command() {
	mut r := new_registry()
	r.grant(Capability{
		id:       'main-ping'
		windows:  ['main']
		commands: ['ping']
	})
	assert r.is_allowed_on('main', 'ping', 'linux') == true
	assert r.is_allowed_on('main', 'ping', 'windows') == true
	assert r.is_allowed_on('other', 'ping', 'linux') == false
	assert r.is_allowed_on('main', 'nope', 'linux') == false
}

fn test_empty_windows_means_all_windows() {
	mut r := new_registry()
	r.grant(Capability{
		id:       'broad'
		commands: ['ping']
	})
	assert r.is_allowed_on('main', 'ping', 'linux') == true
	assert r.is_allowed_on('settings', 'ping', 'linux') == true
	assert r.is_allowed_on('main', 'other', 'linux') == false
}

fn test_empty_commands_grants_nothing() {
	mut r := new_registry()
	r.grant(Capability{
		id:      'empty-cmds'
		windows: ['main']
	})
	assert r.is_allowed_on('main', 'ping', 'linux') == false
	assert r.is_allowed_on('main', '', 'linux') == false
}

fn test_platform_filtering() {
	mut r := new_registry()
	r.grant(Capability{
		id:        'win-only'
		windows:   ['main']
		commands:  ['ping']
		platforms: ['windows']
	})
	assert r.is_allowed_on('main', 'ping', 'windows') == true
	assert r.is_allowed_on('main', 'ping', 'linux') == false
}

fn test_platform_empty_means_all() {
	mut r := new_registry()
	r.grant(Capability{
		id:       'any-os'
		windows:  ['main']
		commands: ['ping']
	})
	assert r.is_allowed_on('main', 'ping', 'windows') == true
	assert r.is_allowed_on('main', 'ping', 'linux') == true
	assert r.is_allowed_on('main', 'ping', 'macos') == true
}

fn test_union_across_caps() {
	mut r := new_registry()
	r.grant(Capability{
		id:       'a'
		windows:  ['main']
		commands: ['ping']
	})
	r.grant(Capability{
		id:       'b'
		windows:  ['settings']
		commands: ['counter_inc']
	})
	assert r.is_allowed_on('main', 'ping', 'linux') == true
	assert r.is_allowed_on('settings', 'counter_inc', 'linux') == true
	assert r.is_allowed_on('main', 'counter_inc', 'linux') == false
	assert r.is_allowed_on('settings', 'ping', 'linux') == false
}

fn test_is_allowed_uses_current_os() {
	mut r := new_registry()
	r.grant(Capability{
		id:       'broad'
		commands: ['ping']
	})
	// No platform restriction, so the current OS must allow it.
	assert r.is_allowed('main', 'ping') == true
	assert r.is_allowed('main', 'nope') == false
}

fn test_asset_roots_of() {
	mut r := new_registry()
	r.grant(Capability{
		id:          'a'
		windows:     ['main']
		commands:    ['ping']
		asset_roots: ['frontend', 'static']
	})
	r.grant(Capability{
		id:          'b'
		windows:     ['settings']
		commands:    ['ping']
		asset_roots: ['static', 'other']
	})
	main_roots := r.asset_roots_of('main', 'linux')
	assert 'frontend' in main_roots
	assert 'static' in main_roots
	assert 'other' !in main_roots
	assert r.asset_roots_of('unknown', 'linux').len == 0
}
