module assets

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
