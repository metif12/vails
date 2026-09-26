module events

fn noop(_ string) {}

fn test_emit_unknown_is_noop() {
	b := new_bus()
	assert b.emit('nope', 'x') == 0
	assert b.handler_count('nope') == 0
}

fn test_on_emit_counts() {
	mut b := new_bus()
	b.on('tick', noop)
	b.on('tick', noop)
	assert b.handler_count('tick') == 2
	assert b.emit('tick', '1') == 2
	assert b.handler_count('other') == 0
}
