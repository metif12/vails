module assets

import capabilities
import os

const scope_testdata = os.join_path(os.dir(@FILE), 'testdata')

fn scope_registry() capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:          'frontend'
		windows:     ['main']
		commands:    ['ping']
		asset_roots: ['testdata']
	})
	return reg
}

fn test_server_resolve_for_allows_granted() {
	s := Server{
		root: os.dir(@FILE)
	}
	content := s.resolve_for('main', 'testdata/hello.txt', scope_registry())!
	assert content == 'hello assets'
}

fn test_server_resolve_for_denies_outside_grant() {
	s := Server{
		root: os.dir(@FILE)
	}
	mut denied := false
	s.resolve_for('main', 'assets.v', scope_registry()) or {
		denied = err.msg().contains('allowed roots')
	}
	assert denied
}

fn test_server_resolve_for_denies_ungranted_window() {
	s := Server{
		root: os.dir(@FILE)
	}
	mut denied := false
	s.resolve_for('other', 'testdata/hello.txt', scope_registry()) or {
		denied = err.msg().contains('no grant')
	}
	assert denied
}

fn test_server_resolve_for_still_rejects_traversal() {
	s := Server{
		root: os.dir(@FILE)
	}
	mut failed := false
	s.resolve_for('main', '../v.mod', scope_registry()) or { failed = true }
	assert failed
}

fn test_bundle_read_roundtrip() {
	b := Bundle{
		files:         {
			'frontend/index.html': '<h1>hi</h1>'
		}
		allowed_roots: ['frontend']
	}
	assert b.read('frontend/index.html')! == '<h1>hi</h1>'
	assert b.read('/frontend/index.html')! == '<h1>hi</h1>'
}

fn test_bundle_read_missing() {
	b := Bundle{
		files: map[string]string{}
	}
	mut failed := false
	b.read('frontend/nope.html') or { failed = true }
	assert failed
}

fn test_bundle_read_rejects_traversal() {
	b := Bundle{
		files: {
			'secret': 'x'
		}
	}
	mut failed := false
	b.read('../secret') or { failed = true }
	assert failed
}

fn test_bundle_resolve_for() {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:          'ui'
		windows:     ['main']
		commands:    ['ping']
		asset_roots: ['frontend']
	})
	b := Bundle{
		files: {
			'frontend/app.js': 'console.log(1)'
		}
	}
	assert b.resolve_for('main', 'frontend/app.js', reg)! == 'console.log(1)'
	mut denied := false
	b.resolve_for('other', 'frontend/app.js', reg) or { denied = true }
	assert denied
}

fn test_legacy_empty_allowlist_still_serves_root() {
	s := Server{
		root: scope_testdata
	}
	assert s.read('hello.txt')! == 'hello assets'
}
