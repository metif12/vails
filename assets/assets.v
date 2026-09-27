// assets.v — read-only frontend file provider (guide: v3/internal/assetserver).
// Prod embedding ($embed_file) and the veb dev server arrive in Phase 3;
// this seam (read + content_type) stays stable across both.
module assets

import capabilities
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
	clean := check_path(path, s.allowed_roots)!
	full := os.join_path(s.root, clean)
	if !os.exists(full) {
		return error('asset not found: ' + path)
	}
	return os.read_file(full)!
}

// resolve_for is the Phase 3 capability wiring: the registry (built from
// vails.json) decides which roots window_label may read, and the server
// root stays as configured. No grant for the window means deny (secure
// by default, same rule as an empty bridge Registry).
pub fn (s Server) resolve_for(window_label string, path string, reg capabilities.Registry) !string {
	roots := granted_roots(window_label, reg)!
	scoped := Server{
		root:          s.root
		allowed_roots: roots
	}
	return scoped.read(path)!
}

// granted_roots returns the asset roots the registry grants to a window.
// Empty means deny: callers must not fall back to legacy serve-all.
fn granted_roots(window_label string, reg capabilities.Registry) ![]string {
	roots := reg.asset_roots_of(window_label, os.user_os())
	if roots.len == 0 {
		return error('asset outside allowed roots: no grant for window "' + window_label + '"')
	}
	return roots
}

// check_path validates path against the allowlist and returns the clean
// relative path. Empty allowed_roots means legacy behavior: everything
// under root is servable (only `..` is rejected).
fn check_path(path string, allowed_roots []string) !string {
	clean := path.trim_left('/')
	if clean.contains('..') {
		return error('asset path escapes root: ' + path)
	}
	if allowed_roots.len > 0 && !is_subpath_allowed(clean, allowed_roots) {
		return error('asset outside allowed roots: ' + path)
	}
	return clean
}

// is_subpath_allowed reports whether clean sits under one of allowed_roots.
// Comparison uses a separator boundary so 'testdata2/x' does not match
// root 'testdata'.
fn is_subpath_allowed(clean string, allowed_roots []string) bool {
	norm := clean.replace('\\', '/')
	for r in allowed_roots {
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
