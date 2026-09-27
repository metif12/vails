// dev.v — veb-based dev server core (Phase 3).
// Pure-V and OS-agnostic: all request logic (path mapping, capability
// scoping, livereload injection, versioning) lives here and is unit
// tested on Windows. The thin veb wrapper is in serve.v; `vails run`
// (Phase 4) spawns it in dev mode.
//
// Security posture matches prod: reads go through
// assets.Server.resolve_for, so the vails.json grants scope every file
// (no grant for the window = deny). Server.root is the project dir
// (where vails.json lives); granted roots are relative to it, e.g.
// asset_root 'frontend' + grant ['frontend'] serves 'frontend/index.html'
// for '/'.
module dev

import assets
import capabilities
import net.http
import os
import time

// default_port is the first port `vails run` tries in dev mode.
pub const default_port = 8413

// version_path serves the 'build_id:frontend_version' marker the
// injected livereload script polls.
pub const version_path = '/__vails_dev_version'

const livereload_marker = '__vails_dev_version'

pub struct DevServer {
pub:
	// root is the project dir (vails.json dir). Registry asset roots
	// are relative to it.
	root string
	// asset_root prefixes every served path (from vails.json).
	asset_root string = 'frontend'
	port       int
	build_id   string
	registry   capabilities.Registry
	// label is the window whose grants scope reads.
	label string = 'main'
}

pub struct ServeResult {
pub:
	body         string
	content_type string
}

pub fn new_dev_server(root string, asset_root string, port int, reg capabilities.Registry, label string) DevServer {
	return DevServer{
		root:       root
		asset_root: asset_root
		port:       port
		build_id:   time.ticks().str()
		registry:   reg
		label:      label
	}
}

// dev_url is the address the dev server binds (loopback only).
pub fn (s DevServer) dev_url() string {
	return 'http://127.0.0.1:${s.port}'
}

// resolve_request maps one request path to a response body. '/' and
// trailing-slash paths serve index.html; HTML responses carry the
// livereload script (dev only — prod serves embedded bytes untouched).
pub fn (s DevServer) resolve_request(raw_path string) !ServeResult {
	path := raw_path.all_before('?')
	if path == version_path {
		return ServeResult{
			body:         s.current_version()
			content_type: 'text/plain'
		}
	}
	rel := s.asset_rel(path)
	body := s.read_asset(rel)!
	ct := assets.content_type(rel)
	if ct == 'text/html' {
		return ServeResult{
			body:         inject_livereload(body, s.port)
			content_type: ct
		}
	}
	return ServeResult{
		body:         body
		content_type: ct
	}
}

// asset_rel maps a URL path to the project-relative asset path:
// '/' → '<asset_root>/index.html', '/app.js' → '<asset_root>/app.js'.
fn (s DevServer) asset_rel(url_path string) string {
	mut rel := url_path.trim_left('/')
	if rel == '' || rel.ends_with('/') {
		rel += 'index.html'
	}
	prefix := s.asset_root.trim('/')
	if prefix == '' {
		return rel
	}
	return prefix + '/' + rel
}

// read_asset is the single serving path: registry grants scope the read,
// no grant for the window means deny (same rule as bridge dispatch).
fn (s DevServer) read_asset(rel string) !string {
	srv := assets.Server{
		root: s.root
	}
	return srv.resolve_for(s.label, rel, s.registry)!
}

// current_version is the livereload marker: it changes when the server
// restarts (new build_id) or any frontend file changes.
pub fn (s DevServer) current_version() string {
	return '${s.build_id}:${s.frontend_version()}'
}

// frontend_version fingerprints the served tree (path:size:mtime per
// file, sorted). Second-resolution mtimes mean sub-second edits surface
// on the next poll tick — fine for dev.
pub fn (s DevServer) frontend_version() string {
	prefix := s.asset_root.trim('/')
	base := if prefix == '' { s.root } else { os.join_path(s.root, prefix) }
	mut parts := []string{}
	collect_versions(base, '', prefix, mut parts)
	parts.sort()
	return parts.join(';')
}

fn collect_versions(dir string, rel string, prefix string, mut parts []string) {
	cur := if rel == '' { dir } else { os.join_path(dir, rel) }
	entries := os.ls(cur) or { return }
	for e in entries {
		sub := if rel == '' { e } else { rel + '/' + e }
		full := os.join_path(dir, sub)
		if os.is_dir(full) {
			collect_versions(dir, sub, prefix, mut parts)
			continue
		}
		st := os.stat(full) or { continue }
		name := if prefix == '' { sub } else { prefix + '/' + sub }
		parts << '${name}:${st.size}:${st.mtime}'
	}
}

// status_for_err maps serving errors to HTTP status: missing file →
// 404, everything else (traversal, outside grants, no grant) → 403 so
// denied paths never leak existence.
pub fn status_for_err(err IError) http.Status {
	if err.msg().contains('asset not found') {
		return .not_found
	}
	return .forbidden
}

// inject_livereload inserts the reload poller before </body> (appended
// when there is no body tag). Idempotent: pages already carrying the
// marker are returned untouched.
pub fn inject_livereload(html string, port int) string {
	if html.contains(livereload_marker) {
		return html
	}
	snippet := livereload_snippet(port)
	idx := html.to_lower().index('</body>') or { -1 }
	if idx >= 0 {
		return html[..idx] + snippet + html[idx..]
	}
	return html + snippet
}

// livereload_snippet polls version_path and reloads when the marker
// moves (frontend edit or server restart). Failures are swallowed so a
// restarting server does not spam the console.
pub fn livereload_snippet(port int) string {
	return '<script>\n"use strict";\n(function(){var u="http://127.0.0.1:${port}${version_path}";var last=null;setInterval(function(){fetch(u,{cache:"no-cache"}).then(function(r){return r.text();}).then(function(v){if(last===null){last=v;return;}if(v!==last){window.location.reload();}}).catch(function(){/* dev server restarting */});},500);})();\n</script>'
}
