// jsesc.v — minimal escaping for embedding V strings inside a
// single-quoted JavaScript string literal (used by bridge.resolve_js and
// events.to_js for evaluate/run_javascript snippets).
module jsesc

// escape rewrites s so it can sit between single quotes in JS source.
// `<` becomes `\x3c` to also neutralize a `</script>` breakout.
pub fn escape(s string) string {
	mut out := ''
	for ch in s {
		match ch {
			`\\` { out += '\\\\' }
			`'` { out += "\\'" }
			`\n` { out += '\\n' }
			`\r` { out += '\\r' }
			`<` { out += '\\x3c' }
			else { out += ch.ascii_str() }
		}
	}
	return out
}
