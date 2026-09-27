module application

fn test_new_defaults() {
	app := new(AppOptions{})
	assert app.options.title == 'Vails App'
	assert app.options.width == 1024
	assert app.options.height == 768
	assert app.is_running() == false
}

fn test_new_custom_title() {
	app := new(title: 'Demo')
	assert app.options.title == 'Demo'
}

fn test_register_service() {
	mut app := new(AppOptions{})
	app.register_service('clipboard')!
	assert app.has_service('clipboard')
	assert !app.has_service('dialog')
}

fn test_register_duplicate_fails() {
	mut app := new(AppOptions{})
	app.register_service('clipboard')!
	mut failed := false
	app.register_service('clipboard') or { failed = true }
	assert failed
	assert app.services.len == 1
}

fn test_managed_state_roundtrip() {
	mut app := new(AppOptions{})
	assert !app.has_state('theme')
	app.set_state('theme', '"dark"')!
	assert app.has_state('theme')
	assert app.get_state('theme')! == '"dark"'
}

fn test_managed_state_missing_fails() {
	app := new(AppOptions{})
	mut failed := false
	app.get_state('nope') or { failed = true }
	assert failed
}

fn test_managed_state_rejects_empty_key() {
	mut app := new(AppOptions{})
	mut failed := false
	app.set_state('', '{}') or { failed = true }
	assert failed
}
