module webview

fn test_config_defaults() {
	cfg := Config{}
	assert cfg.label == 'main'
	assert cfg.title == 'Vails App'
	assert cfg.width == 1024
	assert cfg.height == 768
	assert cfg.html == ''
	assert cfg.url == ''
}

fn test_config_label_is_security_identity() {
	cfg := Config{
		label: 'settings'
		title: 'Settings'
	}
	assert cfg.label != cfg.title
	assert cfg.label == 'settings'
}

fn test_validate_ok() {
	Config{}.validate()!
}

fn test_validate_rejects() {
	mut bad_title := 0
	Config{
		title: ''
	}.validate() or { bad_title = 1 }
	assert bad_title == 1
	mut bad_size := 0
	Config{
		width: 0
	}.validate() or { bad_size = 1 }
	assert bad_size == 1
}

fn test_run_requires_router_on_windows() {
	$if windows {
		run(Config{}) or {
			assert err.msg().contains('router')
			return
		}
		assert false
	} $else {
		assert true
	}
}

fn test_run_unsupported_off_win_linux() {
	$if !windows && !linux {
		run(Config{}) or {
			assert err.msg().contains('windows and linux')
			return
		}
		assert false
	} $else {
		// Windows (with router) and Linux open a real window;
		// covered manually — see tests/e2e_linux/README.md.
		assert true
	}
}
