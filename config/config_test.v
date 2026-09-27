module config

import os

// hello_config_path is absolute (derived from @FILE) so the test does
// not depend on the runner's working directory.
const hello_config_path = os.join_path(os.dir(@FILE), '..', 'examples', 'hello',
	'vails.json')

fn check_invalid(text string) {
	mut failed := false
	load_text(text) or { failed = true }
	assert failed
}

fn test_default_config_validates() {
	cfg := default_config('demo')
	cfg.validate()!
	assert cfg.asset_root == 'frontend'
	assert cfg.bundle.name == 'demo'
	assert cfg.bundle.windows_dll_side_by_side == true
	w := cfg.window('main')!
	assert w.title == 'demo'
	assert w.width == 1024
}

fn test_default_config_roundtrip() {
	orig := default_config('demo')
	cfg := load_text(orig.encode())!
	assert cfg.name == 'demo'
	assert cfg.version == '0.1.0'
	assert cfg.windows.len == 1
	assert cfg.window('main')!.title == 'demo'
}

fn test_load_text_applies_defaults() {
	cfg := load_text('{"name":"demo","windows":[{"label":"main","title":"Demo","width":800,"height":600}]}')!
	assert cfg.name == 'demo'
	assert cfg.asset_root == 'frontend'
	assert cfg.capabilities.len == 0
	assert cfg.bundle.windows_dll_side_by_side == true
	w := cfg.window('main')!
	assert w.width == 800
	assert w.height == 600
}

fn test_load_text_rejects_bad_json() {
	check_invalid('not json')
	check_invalid('{"name":')
}

fn test_validate_rejects() {
	check_invalid('{"name":"","windows":[{"label":"main","title":"T","width":800,"height":600}]}')
	check_invalid('{"name":"demo","windows":[]}')
	check_invalid('{"name":"demo","windows":[{"label":"","title":"T","width":800,"height":600}]}')
	check_invalid('{"name":"demo","windows":[{"label":"main","title":"","width":800,"height":600}]}')
	check_invalid('{"name":"demo","windows":[{"label":"main","title":"T","width":0,"height":600}]}')
	check_invalid('{"name":"demo","asset_root":"","windows":[{"label":"main","title":"T","width":800,"height":600}]}')
	check_invalid('{"name":"demo","windows":[{"label":"main","title":"T","width":800,"height":600},{"label":"main","title":"U","width":800,"height":600}]}')
	check_invalid('{"name":"demo","windows":[{"label":"main","title":"T","width":800,"height":600}],"capabilities":[{"id":"","commands":["ping"]}]}')
	check_invalid('{"name":"demo","windows":[{"label":"main","title":"T","width":800,"height":600}],"capabilities":[{"id":"noop","commands":[]}]}')
}

fn test_window_unknown_label_fails() {
	cfg := default_config('demo')
	mut failed := false
	cfg.window('settings') or { failed = true }
	assert failed
}

fn test_to_registry_gates_dispatch() {
	cfg := load_text('{"name":"demo","windows":[{"label":"main","title":"Demo","width":800,"height":600}],"capabilities":[{"id":"main-app","windows":["main"],"commands":["ping"],"asset_roots":["frontend"],"platforms":["linux"]}]}')!
	reg := cfg.to_registry()
	assert reg.is_allowed_on('main', 'ping', 'linux') == true
	assert reg.is_allowed_on('main', 'ping', 'windows') == false
	assert reg.is_allowed_on('other', 'ping', 'linux') == false
	assert reg.is_allowed_on('main', 'secret', 'linux') == false
	assert reg.asset_roots_of('main', 'linux') == ['frontend']
	assert reg.asset_roots_of('other', 'linux').len == 0
}

fn test_to_registry_empty_denies() {
	cfg := default_config('demo')
	reg := cfg.to_registry()
	assert reg.is_allowed_on('main', 'ping', 'linux') == false
}

fn test_hello_config_parses() {
	cfg := load(hello_config_path)!
	w := cfg.window('main')!
	assert w.title == 'Hello Vails'
	assert w.width == 1024
	assert w.height == 768
	reg := cfg.to_registry()
	assert reg.is_allowed_on('main', 'ping', 'linux') == true
	assert reg.is_allowed_on('main', 'counter_inc', 'windows') == true
	assert reg.is_allowed_on('main', 'unknown', 'linux') == false
}

fn test_load_missing_file_fails() {
	mut failed := false
	load(os.join_path(os.dir(@FILE), '__vails_no_such_config__.json')) or { failed = true }
	assert failed
}
