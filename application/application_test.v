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
