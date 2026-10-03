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
	// the scaffold carries a usable AppUserModelID, not an empty one
	assert cfg.bundle.identifier == 'demo'
	validate_identifier(cfg.bundle.identifier)!
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

// The identifier is the Windows AppUserModelID (ADR-0018), so these are
// the shell's rules rather than ours. Tested here, in pure V, because the
// failure they prevent - a toast that never appears - is otherwise only
// visible by eye on a machine with the notification area open.
fn test_validate_identifier_accepts_real_aumids() {
	for ok in ['vails.app', 'com.example.MyApp', 'a', 'my-app_1.2', '9'] {
		validate_identifier(ok)!
	}
	// empty is legal: nothing but notification needs an identity
	validate_identifier('')!
}

fn test_validate_identifier_rejects() {
	// a space is the classic AUMID bug: the shell matches exactly
	check_invalid_identifier('my app')
	// separators the shell does not accept
	check_invalid_identifier('my/app')
	check_invalid_identifier('my\\app')
	check_invalid_identifier('my:app')
	// non-ASCII: the AUMID is compared as a byte string
	check_invalid_identifier('café')
	// leading / trailing period
	check_invalid_identifier('.leading')
	check_invalid_identifier('trailing.')
	check_invalid_identifier('.')
	// over the documented 128-character ceiling
	check_invalid_identifier('a'.repeat(max_identifier + 1))
	// ...and exactly at it is still fine
	validate_identifier('a'.repeat(max_identifier))!
}

fn check_invalid_identifier(id string) {
	mut failed := false
	validate_identifier(id) or { failed = true }
	assert failed, 'must reject "' + id + '"'
}

fn test_default_identifier_sanitizes_an_app_name() {
	// the shape an author actually types
	assert default_identifier('Vails Services Demo') == 'vailsservicesdemo'
	// punctuation and spaces are dropped rather than encoded
	assert default_identifier('My App!') == 'myapp'
	// dots survive, so a reverse-DNS name is passed through intact
	assert default_identifier('com.example.App') == 'com.example.app'
	// and it never produces something validate_identifier would reject
	for name in ['Hello Vails', 'My App!', '...', '   ', '!!!', 'A-B_C.1', 'x'.repeat(200)] {
		validate_identifier(default_identifier(name))!
	}
}

fn test_default_identifier_falls_back_when_nothing_is_usable() {
	// an all-rejected name would otherwise produce an empty - and so
	// invalid - AUMID
	assert default_identifier('!!!') == 'vails.app'
	assert default_identifier('   ') == 'vails.app'
	assert default_identifier('') == 'vails.app'
}

fn test_default_identifier_strips_edge_periods_and_bounds_length() {
	// validate_identifier rejects a leading/trailing '.', so the builder
	// has to remove them
	assert default_identifier('.hidden.') == 'hidden'
	// and the result can never exceed the ceiling
	assert default_identifier('x'.repeat(500)).len <= max_identifier
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
