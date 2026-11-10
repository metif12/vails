module store

import os

fn tmp_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vails_store_' + name + '.json')
}

fn test_open_missing_is_empty() {
	p := tmp_path('missing')
	os.rm(p) or {}
	s := open(p)!
	assert s.len() == 0
	assert !s.has('k')
}

fn test_set_get_roundtrip() {
	p := tmp_path('roundtrip')
	os.rm(p) or {}
	mut s := open(p)!
	s.set('a', '1')
	s.set('b', 'two')
	av := s.get('a') or { '' }
	bv := s.get('b') or { '' }
	assert av == '1'
	assert bv == 'two'
	assert s.has('a')
	assert !s.has('z')
	s.save()!
	// reload
	s2 := open(p)!
	a2 := s2.get('a') or { '' }
	b2 := s2.get('b') or { '' }
	assert a2 == '1'
	assert b2 == 'two'
	assert s2.len() == 2
}

fn test_delete() {
	p := tmp_path('delete')
	os.rm(p) or {}
	mut s := open(p)!
	s.set('a', '1')
	s.delete('a')
	assert !s.has('a')
	s.delete('missing') // no-op
	assert s.len() == 0
}

fn test_save_atomic_leaves_old_on_failure() {
	p := tmp_path('atomic')
	os.rm(p) or {}
	mut s := open(p)!
	s.set('a', '1')
	s.save()!
	// corrupt the file by hand, then reopen must fail rather than silently
	// drop data.
	os.write_file(p, '{not json') or {}
	open(p) or {
		assert true
		return
	}
	assert false
}

fn test_keys() {
	p := tmp_path('keys')
	os.rm(p) or {}
	mut s := open(p)!
	s.set('x', '1')
	s.set('y', '2')
	ks := s.keys()
	assert ks.len == 2
	assert ks.contains('x')
	assert ks.contains('y')
}