module webview

import os

// Recorder is a fake Ctx.eval_fn: it keeps the snippets so tests can assert
// what a service would have pushed into the window. Heap-allocated because V
// closures capture locals by value (same reason hello uses &Counter).
struct Recorder {
mut:
	snippets []string
	fail     bool
}

fn (mut r Recorder) sink(js string) ! {
	if r.fail {
		return error('eval failed')
	}
	r.snippets << js
}

fn test_ctx_without_backend_is_not_ready() {
	c := Ctx{
		label: 'main'
	}
	assert !c.is_ready()
	assert !c.has_parent()
}

fn test_emit_reaches_the_sink() {
	rec := &Recorder{}
	c := Ctx{
		label:   'main'
		eval_fn: fn [rec] (js string) ! {
			rec.sink(js)!
		}
	}
	assert c.is_ready()
	c.emit('dialog:done', '{"path":"a.txt"}') or { panic(err.msg()) }
	assert rec.snippets.len == 1
	assert rec.snippets[0].contains('__emit')
	assert rec.snippets[0].contains('dialog:done')
}

fn test_emit_rejects_empty_name() {
	rec := &Recorder{}
	c := Ctx{
		label:   'main'
		eval_fn: fn [rec] (js string) ! {
			rec.sink(js)!
		}
	}
	mut failed := false
	c.emit('', 'x') or { failed = true }
	assert failed
	assert rec.snippets.len == 0
}

fn test_emit_propagates_backend_failure() {
	rec := &Recorder{
		fail: true
	}
	c := Ctx{
		label:   'main'
		eval_fn: fn [rec] (js string) ! {
			rec.sink(js)!
		}
	}
	mut failed := false
	c.emit('x', 'y') or { failed = true }
	assert failed
}

fn test_emit_without_backend_fails_explicitly() {
	mut failed := ''
	Ctx{
		label: 'settings'
	}.emit('x', 'y') or { failed = err.msg() }
	assert failed.contains('no window attached')
	assert failed.contains('settings')
}

fn test_run_js_passes_through_untouched() {
	rec := &Recorder{}
	c := Ctx{
		label:   'main'
		eval_fn: fn [rec] (js string) ! {
			rec.sink(js)!
		}
	}
	c.run_js('document.title = 1;') or { panic(err.msg()) }
	assert rec.snippets[0] == 'document.title = 1;'
}

fn test_parent_handle_is_reported() {
	assert (Ctx{
		label:  'main'
		parent: voidptr(0x1234)
	}).has_parent()
}

fn test_document_injects_default_csp() {
	out := Config{
		html: '<html><head></head><body>hi</body></html>'
	}.document()
	assert out.contains(default_csp())
}

fn test_document_keeps_app_override() {
	html := '<head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'" /></head>'
	assert Config{
		html: html
	}.document() == html
}

fn test_document_is_empty_in_url_mode() {
	assert Config{
		url: 'http://127.0.0.1:8421/'
	}.document() == ''
}

fn test_document_is_empty_without_html() {
	assert Config{}.document() == ''
}

// every example ships the default policy verbatim, so the preview fallback
// (opened outside a Vails window) runs under the same secure mode as the
// window. Keeps new examples in line automatically.
fn test_examples_ship_default_csp() {
	root := os.dir(os.dir(@FILE))
	examples := os.join_path(root, 'examples')
	for name in os.ls(examples)! {
		page := os.join_path(examples, name, 'frontend', 'index.html')
		if !os.exists(page) {
			continue
		}
		html := os.read_file(page) or { panic('cannot read ' + page + ': ' + err.msg()) }
		assert html.contains('Content-Security-Policy'), name
		assert html.contains(default_csp()), name
	}
}

// No example page may spell a closing body or script tag inside a <script>
// element. The examples that carry an E2E probe inject one with
// `inject_before_body`, and a mention of such a tag in a comment or a string
// inside the page's own script element makes the injection land *inside* that
// element: the script closes early and the rest of the source renders as
// visible text. It happened, it looked like a broken page, and the fix in the
// example (search for the last tag, not the first) is a mitigation - this is
// the invariant itself.
fn test_example_pages_have_no_stray_closing_tags_inside_scripts() {
	root := os.dir(os.dir(@FILE))
	examples := os.join_path(root, 'examples')
	for name in os.ls(examples)! {
		page := os.join_path(examples, name, 'frontend', 'index.html')
		if !os.exists(page) {
			continue
		}
		html := os.read_file(page) or { panic('cannot read ' + page + ': ' + err.msg()) }
		// The one opening tag and the one closing tag are the boundary; what
		// must not appear between them is another closing tag.
		open_at := html.index('<script>') or { continue }
		rest := html[open_at + '<script>'.len..]
		close_at := rest.index('</script>') or { continue }
		body := rest[..close_at]
		for tag in ['</body>', '</script>'] {
			assert !body.contains(tag), name + ': "' + tag +
				'" inside a <script> element breaks the E2E probe injection'
		}
	}
}
