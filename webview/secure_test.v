module webview

import os

fn test_default_csp_shape() {
	csp := default_csp()
	assert csp.contains("default-src 'self'")
	assert csp.contains("object-src 'none'")
	assert csp.contains("frame-ancestors 'none'")
	assert csp.contains("media-src 'self' blob:")
	assert !csp.contains('\n')
	assert !csp.contains('"')
}

fn test_csp_meta_shape() {
	meta := csp_meta()
	assert meta.starts_with('<meta http-equiv="Content-Security-Policy" content="')
	assert meta.ends_with('" />')
	assert meta.contains(default_csp())
}

fn test_inject_after_head() {
	out := inject_csp('<html><head><title>x</title></head></html>')
	assert out == '<html><head>\n' + csp_meta() + '<title>x</title></head></html>'
}

fn test_inject_respects_override() {
	html := '<head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'" /></head>'
	assert inject_csp(html) == html
}

fn test_inject_falls_back_to_html_tag() {
	out := inject_csp('<html lang="en"><body>hi</body></html>')
	assert out == '<html lang="en">\n' + csp_meta() + '<body>hi</body></html>'
}

fn test_inject_prepends_without_tags() {
	out := inject_csp('<p>fragment</p>')
	assert out == csp_meta() + '\n<p>fragment</p>'
}

fn test_inject_is_idempotent() {
	once := inject_csp('<html><head></head></html>')
	assert inject_csp(once) == once
}

// hello ships the default policy verbatim so the preview fallback
// (opened outside a Vails window) runs under the same policy. This test
// keeps the shipped meta tag and default_csp() in sync.
fn test_hello_ships_default_csp() {
	path := os.join_path(os.dir(@FILE), '..', 'examples', 'hello', 'frontend', 'index.html')
	html := os.read_file(path) or { panic('cannot read hello index.html: ' + err.msg()) }
	assert html.contains('Content-Security-Policy')
	assert html.contains(default_csp())
}
