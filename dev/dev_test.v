module dev

import capabilities
import os

const dev_testdata = os.join_path(os.dir(@FILE), 'testdata')

fn dev_registry() capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:          'frontend'
		windows:     ['main']
		commands:    ['ping']
		asset_roots: ['frontend']
	})
	return reg
}

fn dev_server() DevServer {
	return new_dev_server(dev_testdata, 'frontend', default_port, dev_registry(), 'main')
}

fn test_dev_url_is_loopback() {
	s := dev_server()
	assert s.dev_url() == 'http://127.0.0.1:${default_port}'
}

fn test_resolve_root_serves_index_with_livereload() {
	s := dev_server()
	res := s.resolve_request('/')!
	assert res.content_type == 'text/html'
	assert res.body.contains('<h1>dev fixture</h1>')
	assert res.body.contains('__vails_dev_version')
	assert res.body.index('</body>') or { -1 } > res.body.index('__vails_dev_version') or { -1 }
}

fn test_resolve_js_content_type_without_injection() {
	s := dev_server()
	res := s.resolve_request('/app.js')!
	assert res.content_type == 'text/javascript'
	assert res.body.contains('dev fixture')
	assert !res.body.contains('__vails_dev_version')
}

fn test_resolve_query_string_is_ignored() {
	s := dev_server()
	res := s.resolve_request('/app.js?v=2')!
	assert res.content_type == 'text/javascript'
}

fn test_resolve_missing_maps_to_404() {
	s := dev_server()
	s.resolve_request('/nope.js') or {
		assert status_for_err(err) == .not_found
		return
	}
	assert false, 'expected missing asset error'
}

fn test_resolve_traversal_maps_to_403() {
	s := dev_server()
	s.resolve_request('/../dev.v') or {
		assert status_for_err(err) == .forbidden
		return
	}
	assert false, 'expected traversal error'
}

fn test_resolve_denies_ungranted_window() {
	s := new_dev_server(dev_testdata, 'frontend', default_port, dev_registry(), 'other')
	s.resolve_request('/') or {
		assert status_for_err(err) == .forbidden
		assert err.msg().contains('no grant')
		return
	}
	assert false, 'expected no-grant error'
}

fn test_version_path_serves_marker() {
	s := dev_server()
	res := s.resolve_request(version_path)!
	assert res.content_type == 'text/plain'
	assert res.body == s.current_version()
	assert res.body.contains('frontend/index.html')
}

fn test_frontend_version_changes_with_edits() {
	s := dev_server()
	path := os.join_path(dev_testdata, 'frontend', 'app.js')
	orig := os.read_file(path)!
	before := s.frontend_version()
	os.write_file(path, orig + '\n// touch')!
	middle := s.frontend_version()
	assert middle != before
	os.write_file(path, orig)!
	after := s.frontend_version()
	// Sizes differ between touched and restored states, so the markers
	// differ even at one-second mtime resolution.
	assert after != middle
	assert os.read_file(path)! == orig
}

fn test_inject_is_idempotent() {
	once := inject_livereload('<html><body><p>hi</p></body></html>', 8413)
	twice := inject_livereload(once, 8413)
	assert once == twice
	assert once.count('__vails_dev_version') == 1
}

fn test_inject_appends_without_body_tag() {
	out := inject_livereload('<p>bare</p>', 8413)
	assert out.starts_with('<p>bare</p><script>')
	assert out.contains('__vails_dev_version')
}
