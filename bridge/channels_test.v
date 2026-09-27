module bridge

fn test_hub_mints_unique_ids() {
	mut h := new_hub()
	a := h.open('progress')!
	b := h.open('progress')!
	assert a.id == 'ch_1'
	assert b.id == 'ch_2'
	assert a.id != b.id
	assert a.event == 'progress'
	assert !a.is_closed()
}

fn test_open_rejects_empty_event() {
	mut h := new_hub()
	mut failed := false
	h.open('') or { failed = true }
	assert failed
}

fn test_push_is_emit_compatible() {
	mut h := new_hub()
	c := h.open('download')!
	snippet := c.push_js('50%')!
	assert snippet == "window.vails.__emit('ch_1', '50%');"
	assert snippet.contains('__emit')
}

fn test_push_escapes() {
	mut h := new_hub()
	c := h.open('log')!
	snippet := c.push_js("it's\na</script>")!
	assert snippet == "window.vails.__emit('ch_1', 'it\\'s\\na\\x3c/script>');"
}

fn test_push_after_close_fails() {
	mut h := new_hub()
	mut c := h.open('tick')!
	_ := c.close_js()
	assert c.is_closed()
	mut failed := false
	c.push_js('late') or { failed = true }
	assert failed
}

fn test_close_is_idempotent() {
	mut h := new_hub()
	mut c := h.open('tick')!
	first := c.close_js()
	second := c.close_js()
	assert first == second
	assert first == "window.vails.__emit('ch_1:close', '');"
	assert c.is_closed()
}
