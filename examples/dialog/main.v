// examples/dialog - two services in one window: the native dialog service
// (file picker, save dialog, message box) and os-info.
//
// Everything platform-specific is already behind the service; this file
// only wires it up:
//   1. vails.json declares the grants (dialog.* + os_info.get);
//   2. on_ready receives the window's runtime handle (webview.Ctx) - the
//      parent window for the pickers;
//   3. services.install* binds the commands on the router.
// The frontend then calls window.vails.dialog.open(...) or uses the
// snippet `vails dts` generates.
//
// Windows runs the real pickers; Linux reports 'not implemented' from the
// dialog backend until Phase 5b (tests/e2e_linux/README.md).
module main

import bridge
import config
import os
import services
import webview

// ctx_ holds the window handle the services need. Heap-allocated because
// every handler closure shares one address (V closures capture by value).
struct CtxHolder {
mut:
	ctx webview.Ctx
}

fn load_app_config() !config.VailsConfig {
	// Same probe list as examples/hello so the example runs from the repo
	// root, from its own dir, or next to the binary.
	candidates := [
		'vails.json',
		os.join_path('examples', 'dialog', 'vails.json'),
		os.join_path(os.dir(os.executable()), 'vails.json'),
		os.join_path(os.dir(os.executable()), '..', 'examples', 'dialog', 'vails.json'),
	]
	for c in candidates {
		if os.exists(c) {
			return config.load(c)!
		}
	}
	return error('vails.json not found (tried: ' + candidates.join(', ') + ')')
}

fn load_frontend_html(asset_root string) !string {
	candidates := [
		os.join_path(asset_root, 'index.html'),
		os.join_path('examples', 'dialog', asset_root, 'index.html'),
		os.join_path(os.dir(os.executable()), asset_root, 'index.html'),
	]
	for c in candidates {
		if os.exists(c) {
			return os.read_file(c)!
		}
	}
	return error('index.html not found (tried: ' + candidates.join(', ') + ')')
}

// probe_script returns a <script> block appended to the document when
// VAILS_DIALOG_PROBE is set, which is how the E2E proof in
// tests/e2e_windows/README.md runs: a click cannot be synthesized
// reliably into the WebView2 content, so the call is made from the page
// itself - the exact production path (JS -> bridge -> handler -> native
// dialog -> result event).
//
// The snippet runs in the page, not from a V thread, which also keeps the
// ADR-0010 threading rule intact: only the handler touches native UI, and
// it does so on the webview main thread.
//
// VAILS_DIALOG_PROBE=open|multi|save|message|host|none
fn probe_script() string {
	probe := os.getenv('VAILS_DIALOG_PROBE')
	if probe == '' || probe == 'none' {
		return ''
	}
	call := match probe {
		'open' {
			'window.vails.dialog.open({ title: "Open a file (probe)", filters: [{ name: "Text", extensions: "txt,md" }] })'
		}
		'multi' {
			'window.vails.dialog.open({ title: "Open several files (probe)", multi: true })'
		}
		'save' {
			'window.vails.dialog.save({ title: "Save as (probe)", defaultName: "probe.txt" })'
		}
		'message' {
			'window.vails.dialog.message({ title: "Vails probe", message: "Message box from the page.", buttons: "yesnocancel" })'
		}
		'host' {
			'window.vails.os_info.get()'
		}
		'diag' {
			// writes what the page sees into the first status line, which a
			// screenshot can show (document.title does not reach the native
			// window caption: no title-changed callback is wired)
			'document.getElementById("open-status").textContent = !window.vails ? "NO RUNTIME" : ("call=" + typeof window.vails.call + " onEvent=" + typeof window.vails.onEvent + " dialog=" + typeof ((window.vails.dialog || {}).open));'
		}
		else {
			'Promise.resolve("unknown probe: ' + probe + '")'
		}
	}
	return '  // VAILS_DIALOG_PROBE=' + probe + '\n' + '  ' + call +
		'.then(function (r) { window.vails.__emit("probe:done", r); })\n' +
		'    .catch(function (e) { window.vails.__emit("probe:done", "error: " + e); });\n'
}

// inject_before_body inserts a <script> block right before </body>, so the
// page's own script (which registers the probe:done listener) has already
// run. Appends at the end when the document has no body.
fn inject_before_body(html string, js string) string {
	block := '<script>\n' + js + '</script>\n'
	if at := html.index('</body>') {
		return html[..at] + block + html[at..]
	}
	return html + block
}

fn main() {
	app_cfg := load_app_config() or {
		eprintln(err.msg())
		exit(1)
	}
	mut html := load_frontend_html(app_cfg.asset_root) or {
		eprintln(err.msg())
		exit(1)
	}
	// The E2E probe (if any) is part of the document: it then travels the
	// real JS -> V -> native path instead of a synthesized click. It goes
	// in before </body> - a <script> appended after </html> is not
	// executed by the webview's HTML parser.
	probe := probe_script()
	if probe != '' {
		html = inject_before_body(html, probe)
	}
	w := app_cfg.window('main') or {
		eprintln(err.msg())
		exit(1)
	}
	mut holder := &CtxHolder{}
	mut r := bridge.new_router()
	// Heap-allocated so the on_ready closure and webview.run share one
	// router: the services are installed once the window exists, and the
	// native dispatch path must see the very same registrations.
	mut router := &r
	// Services need the window handle, which only exists once the native
	// window is up - hence the two-phase wiring: the app's own commands go
	// in now, the services in on_ready below.
	on_ready := fn [mut holder, mut router] (ctx webview.Ctx) {
		holder.ctx = ctx
		services.install_dialog(mut router, ctx) or { eprintln('dialog: ' + err.msg()) }
		services.install_os_info(mut router) or { eprintln('os_info: ' + err.msg()) }
	}
	webview.run(
		label:    w.label
		title:    w.title
		width:    w.width
		height:   w.height
		router:   router
		registry: app_cfg.to_registry()
		html:     html
		on_ready: on_ready
	) or {
		eprintln(err.msg())
		exit(1)
	}
}
