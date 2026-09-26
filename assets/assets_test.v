module assets

import os

// testdata_dir is absolute (derived from @FILE) so the tests do not
// depend on the runner's working directory.
const testdata_dir = os.join_path(os.dir(@FILE), 'testdata')

fn test_content_types() {
	assert content_type('index.html') == 'text/html'
	assert content_type('APP.JS') == 'text/javascript'
	assert content_type('style.css') == 'text/css'
	assert content_type('data.json') == 'application/json'
	assert content_type('icon.svg') == 'image/svg+xml'
	assert content_type('logo.png') == 'image/png'
	assert content_type('blob.bin') == 'application/octet-stream'
}

fn test_read_missing() {
	s := Server{
		root: '.'
	}
	mut failed := false
	s.read('__vails_no_such_file__.html') or { failed = true }
	assert failed
}

fn test_read_rejects_traversal() {
	s := Server{
		root: '.'
	}
	mut failed := false
	s.read('../v.mod') or { failed = true }
	assert failed
}

fn test_read_empty_allowlist_serves_root() {
	s := Server{
		root: testdata_dir
	}
	content := s.read('hello.txt') or { '' }
	assert content == 'hello assets'
}

fn test_read_denies_outside_allowlist() {
	s := Server{
		root:          os.dir(@FILE)
		allowed_roots: ['testdata']
	}
	// assets.v exists but sits outside the allowlist: the denial must
	// come from the scope check, not from a missing file.
	mut denied := false
	s.read('assets.v') or { denied = err.msg().contains('allowed roots') }
	assert denied
	content := s.read('testdata/hello.txt') or { '' }
	assert content == 'hello assets'
}

fn test_read_still_rejects_traversal_with_allowlist() {
	s := Server{
		root:          os.dir(@FILE)
		allowed_roots: ['testdata']
	}
	mut failed := false
	s.read('../v.mod') or { failed = true }
	assert failed
}
