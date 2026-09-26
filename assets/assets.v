// assets.v — read-only frontend file provider (guide: v3/internal/assetserver).
// Prod embedding ($embed_file) and the veb dev server arrive in Phase 3;
// this seam (read + content_type) stays stable across both.
module assets

import os

pub struct Server {
pub:
	root string
}

// read returns the file bytes as string. Path traversal outside root is
// rejected so a hostile frontend cannot escape the assets dir.
pub fn (s Server) read(path string) !string {
	clean := path.trim_left('/')
	if clean.contains('..') {
		return error('asset path escapes root: ' + path)
	}
	full := os.join_path(s.root, clean)
	if !os.exists(full) {
		return error('asset not found: ' + path)
	}
	return os.read_file(full)!
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
