// bundle.v — the prod side of the Phase 3 assets split.
// Dev serves files from disk (`Server.read`); prod serves embedded bytes
// (`Bundle.read`, filled with `$embed_file` by the app). Both enforce the
// same traversal + allowlist checks so the security posture is identical.
// The `veb` dev server with livereload arrives later in Phase 3; this seam
// stays stable across all three.
module assets

import capabilities

// Bundle holds frontend files as in-memory bytes keyed by forward-slash
// relative path (e.g. `frontend/index.html`, matching the on-disk layout
// so dev and prod resolve the same paths).
pub struct Bundle {
pub:
	files map[string]string
	// allowed_roots scopes reads like Server.allowed_roots. Empty means
	// legacy serve-all; prefer resolve_for (registry-driven, deny by
	// default) on the real serving path.
	allowed_roots []string
}

// read returns the embedded bytes for path.
pub fn (b Bundle) read(path string) !string {
	clean := check_path(path, b.allowed_roots)!
	return b.files[clean] or { return error('asset not found: ' + path) }
}

// resolve_for is the registry-driven entry point (same contract as
// Server.resolve_for): roots granted to window_label scope the read, no
// grant means deny.
pub fn (b Bundle) resolve_for(window_label string, path string, reg capabilities.Registry) !string {
	roots := granted_roots(window_label, reg)!
	clean := check_path(path, roots)!
	return b.files[clean] or { return error('asset not found: ' + path) }
}
