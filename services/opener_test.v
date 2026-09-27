module services

import bridge
import capabilities
import webview

fn opener_grant(commands []string) capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		commands: commands
	})
	return reg
}

fn test_manifest_shape() {
	m := opener_manifest()
	assert m.name == 'opener'
	assert m.command_names() == ['opener.open_url', 'opener.open_path']
	// both commands take an options object, and neither waits on a human
	// (the handler is another process), so neither is blocking
	assert m.commands[0].params == 'OpenerUrlOptions'
	assert m.commands[1].params == 'OpenerPathOptions'
	assert !m.commands[0].blocking
	assert !m.commands[1].blocking
}

fn test_manifest_is_in_the_catalog() {
	assert find('opener') != none
	assert service_of('opener.open_url') != none
	if s, c := lookup('open_path') {
		assert s.name == 'opener'
		assert c.name == 'opener.open_path'
	} else {
		assert false, 'open_path must resolve to opener.open_path'
	}
}

fn test_url_scheme_parsing() {
	assert url_scheme('https://example.test/x') == 'https'
	assert url_scheme('HTTP://example.test') == 'http'
	assert url_scheme('mailto:someone@example.test') == 'mailto'
	// no colon, or a colon too early, is not a scheme
	assert url_scheme('example.test/x') == ''
	assert url_scheme('a:b') == ''
	assert url_scheme('') == ''
	// a Windows drive letter is a drive, not a scheme - the single most
	// important case here, because C:\notes.txt would otherwise look like
	// the scheme "c" and be rejected as a URL
	assert url_scheme('C:\\notes.txt') == ''
	assert url_scheme('c:/notes.txt') == ''
	// a scheme must be made of scheme characters only
	assert url_scheme('ht tp://x') == ''
	assert url_scheme('java\tscript:x') == ''
}

fn test_validate_url_allows_only_the_allowlist() {
	validate_url('https://example.test/path?a=b')!
	validate_url('http://localhost:8421/')!
	validate_url('mailto:someone@example.test')!
	validate_url('tel:+123456789')!
}

fn test_validate_url_rejects_everything_else() {
	// the schemes that turn a granted capability into an attack: local file
	// reads, UNC shares, and the ms-msdt family
	for bad in ['file:///c:/windows/win.ini', 'smb://host/share', 'ms-msdt:/id', 'javascript:alert(1)',
		'data:text/html,<b>x</b>', 'ftp://example.test', '\\\\host\\share', 'httpsx://example.test',
		'https://'] {
		mut failed := false
		validate_url(bad) or { failed = true }
		assert failed, 'must reject ' + bad
	}
	// a bare host is a typo, not something to guess https:// for
	mut failed := false
	validate_url('example.test') or { failed = true }
	assert failed
	// and the length bound
	failed = false
	validate_url('https://example.test/' + 'a'.repeat(max_url_len)) or {
		failed = true
	}
	assert failed
}

fn test_validate_path_accepts_local_paths() {
	validate_path('C:\\Users\\me\\notes.txt')!
	validate_path('/home/me/notes.txt')!
	validate_path('notes.txt')!
	validate_path('C:\\Program Files\\app\\data.bin')!
}

fn test_validate_path_rejects_urls_and_junk() {
	// open_path is not a second way to launch a URL: that would bypass the
	// scheme allowlist open_url enforces
	for bad in ['https://example.test', 'file:///etc/passwd', 'mailto:a@b.test', '   ', ''] {
		mut failed := false
		validate_path(bad) or { failed = true }
		assert failed, 'must reject "' + bad + '"'
	}
	mut failed := false
	validate_path('a\x00b') or { failed = true }
	assert failed
	failed = false
	validate_path('a'.repeat(max_path_len + 1)) or { failed = true }
	assert failed
}

fn test_parse_url_options_accepts_an_object_or_a_bare_string() {
	assert parse_url_options('{"url":"https://example.test"}')!.url == 'https://example.test'
	// a minimal frontend can send the URL as a plain JSON string
	assert parse_url_options('"https://example.test"')!.url == 'https://example.test'
}

fn test_parse_path_options_accepts_an_object_or_a_bare_string() {
	assert parse_path_options('{"path":"notes.txt"}')!.path == 'notes.txt'
	assert parse_path_options('"notes.txt"')!.path == 'notes.txt'
	// `with` rides along
	opts := parse_path_options('{"path":"notes.txt","with":"notepad.exe"}')!
	assert opts.with == 'notepad.exe'
	// and defaults to the default handler
	assert parse_path_options('{"path":"notes.txt"}')!.with == ''
}

fn test_parse_options_reject_a_payload_without_the_target() {
	for bad in ['', 'null', '{}', '{"with":"notepad.exe"}', '{oops', '[]'] {
		mut failed := false
		parse_url_options(bad) or { failed = true }
		assert failed, 'open_url must reject "' + bad + '"'
		failed = false
		parse_path_options(bad) or { failed = true }
		assert failed, 'open_path must reject "' + bad + '"'
	}
}

fn test_install_denies_an_ungranted_command() {
	mut router := bridge.new_router()
	install_opener(mut router, webview.Ctx{
		label: 'main'
	})!
	res := router.call_json('main', '1', 'opener.open_url', '"https://example.test"',
		opener_grant(['opener.open_path']))
	assert res.err.starts_with('forbidden:')
	assert res.err.contains('opener.open_url')
}

fn test_rejections_carry_the_bad_params_prefix_even_without_the_router() {
	// The wire contract must not depend on how the command was reached, so
	// the prefix is applied by the service itself, not only by the handler.
	mut failed := false
	open_url('file:///c:/windows/win.ini') or {
		failed = true
		assert err.msg().starts_with('bad params:')
	}
	assert failed
	failed = false
	open_path('https://example.test', '') or {
		failed = true
		assert err.msg().starts_with('bad params:')
	}
	assert failed
	failed = false
	open_path('notes.txt', 'a'.repeat(max_path_len + 1)) or {
		failed = true
		assert err.msg().starts_with('bad params:')
	}
	assert failed
}

fn test_install_reports_bad_params_before_any_launch() {
	mut router := bridge.new_router()
	install_opener(mut router, webview.Ctx{
		label: 'main'
	})!
	reg := opener_grant(['opener.open_url', 'opener.open_path'])
	// a scheme outside the allowlist is a params problem, with the standard
	// prefix - and nothing was launched
	mut res := router.call_json('main', '1', 'opener.open_url', '{"url":"file:///c:/win.ini"}', reg)
	assert res.err.starts_with('bad params:')
	assert res.err.contains('not allowed')
	// a URL sent to open_path is the mirror image of the same rule
	res = router.call_json('main', '2', 'opener.open_path', '{"path":"https://example.test"}', reg)
	assert res.err.starts_with('bad params:')
	assert res.err.contains('not a URL')
	// and a payload without a target never reaches the shell
	res = router.call_json('main', '3', 'opener.open_url', '{}', reg)
	assert res.err.starts_with('bad params:')
	assert res.err.contains('url is required')
}
