// secure.v — secure frontend defaults (T7, cf. Tauri CSP).
// Every Vails window injects a default Content-Security-Policy so an
// app that forgets its own meta tag still runs locked down. Apps can
// override by shipping their own `Content-Security-Policy` meta tag:
// inject_csp leaves any document that already has one untouched.
// Pure-V, OS-agnostic, no C.
module webview

// default_csp is the policy shipped in hello and injected by inject_csp.
// Inline scripts AND styles stay allowed (`'unsafe-inline'`): hello keeps
// its UI in one file, so a strict `script-src 'self'` would break it.
// Hardening path (documented, not default): move JS to an external file
// and drop `'unsafe-inline'` from `script-src`. `getDisplayMedia`
// (ADR-0009) is not governed by CSP, but `media-src 'self' blob:` keeps
// the resulting streams playable.
pub fn default_csp() string {
	return "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; media-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'"
}

// csp_meta renders the policy as an injectable meta tag.
pub fn csp_meta() string {
	return '<meta http-equiv="Content-Security-Policy" content="' + default_csp() +
		'" />'
}

// inject_csp inserts the default policy meta tag into html. Documents
// that already carry a `Content-Security-Policy` marker keep theirs
// (app override wins). Insertion point: right after `<head>`, else after
// the `<html…>` tag, else prepended.
pub fn inject_csp(html string) string {
	if html.contains('Content-Security-Policy') {
		return html
	}
	tag := csp_meta()
	head_idx := html.index('<head>') or { -1 }
	if head_idx >= 0 {
		at := head_idx + '<head>'.len
		return html[..at] + '\n' + tag + html[at..]
	}
	html_idx := html.index('<html') or { -1 }
	if html_idx >= 0 {
		end := html.index_after('>', html_idx) or { -1 }
		if end >= 0 {
			return html[..end + 1] + '\n' + tag + html[end + 1..]
		}
	}
	return tag + '\n' + html
}
