module services

fn test_read_text_not_implemented() {
	mut failed := false
	read_text() or { failed = true }
	assert failed
}
