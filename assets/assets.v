// assets.v — read-only frontend file provider (guide: v3/internal/assetserver).
// Prod embedding ($embed_file) and the veb dev server arrive in Phase 3;
// this seam (read + content_type) stays stable across both.
module assets

import os

pub struct Server {
pub:
	root string
	// allowed_roots is the Tauri asset-scope allowlist (T1): subpath
	// prefixes relative to root (e.g. ['frontend']). Empty means legacy
	// behavior: everything under root is servable. Non-empty scopes reads
	// to those subtrees; '..' is rejected before this check either way.
	allowed_roots []string
}

// read returns the file bytes as string. Path traversal outside root is
// rejected so a hostile frontend cannot escape the assets dir.
pub fn (s Server) read(path string) !string {
	clean := path.trim_left('/')
	if clean.contains('..') {
		return error('asset path escapes root: ' + path)
	}
	if s.allowed_roots.len > 0 && !s.is_subpath_allowed(clean) {
		return error('asset outside allowed roots: ' + path)
	}
	full := os.join_path(s.root, clean)
	if !os.exists(full) {
		return error('asset not found: ' + path)
	}
	return os.read_file(full)!
}

// is_subpath_allowed reports whether clean sits under one of allowed_roots.
// Comparison uses a separator boundary so 'testdata2/x' does not match
// root 'testdata'.
fn (s Server) is_subpath_allowed(clean string) bool {
	norm := clean.replace('\\', '/')
	for r in s.allowed_roots {
		base := r.replace('\\', '/').trim('/')
		if norm == base || norm.starts_with(base + '/') {
			return true
		}
	}
	return false
}

pub fn content_type(path string) string {
	return match os.file_ext(path).to_lower() {
		'.html' { 'text/html' }
		'.js', '.mjs' { 'text/javascript' }
		'.css' { 'text/css' }
		'.json' { 'application/json' }
		'.svg' { 'image/svg+xml' }
		'.png' { 'image/png' }
		'.ico' { 'image/x-icon' }
		'.woff2' { 'font/woff2' }
		else { 'application/octet-stream' }
	}
}
