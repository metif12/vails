module state

fn test_set_get_roundtrip() {
	mut s := new_store()
	s.set('theme', '"dark"')!
	assert s.get('theme')! == '"dark"'
	assert s.has('theme')
	assert s.len() == 1
	assert s.keys() == ['theme']
}

fn test_get_unknown_fails() {
	s := new_store()
	mut msg := ''
	s.get('nope') or { msg = err.msg() }
	assert msg.contains('unknown key')
	assert msg.contains('nope')
}

fn test_set_rejects_empty_key() {
	mut s := new_store()
	mut failed := false
	s.set('', '{}') or { failed = true }
	assert failed
	assert s.len() == 0
}

fn test_set_overwrites() {
	mut s := new_store()
	s.set('n', '1')!
	s.set('n', '2')!
	assert s.get('n')! == '2'
	assert s.len() == 1
}

fn test_remove() {
	mut s := new_store()
	s.set('a', '1')!
	s.set('b', '2')!
	s.remove('a')
	assert !s.has('a')
	assert s.has('b')
	// Unknown keys are a no-op, never an error.
	s.remove('missing')
	assert s.len() == 1
}

fn test_string_helpers() {
	mut s := new_store()
	s.set_string('name', 'vails')!
	assert s.get_string('name')! == 'vails'
	// Stored form is JSON, so a raw read sees the quoted literal.
	assert s.get('name')! == '"vails"'
}

fn test_string_helper_missing() {
	s := new_store()
	mut failed := false
	s.get_string('nope') or { failed = true }
	assert failed
}
