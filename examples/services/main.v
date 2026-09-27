// examples/services - four services in one window, and the E2E proof vehicle
// for Phase 5 S1 wave 2 (ADR-0015): clipboard, opener, notification and
// os_info.
//
// What is new here compared to examples/dialog is not the wiring - that is
// the same two-phase pattern (grants in vails.json, services installed from
// Config.on_ready where the window handle exists) - but the *proof*:
//
//   - clipboard needs no human. The page writes a known string and reads it
//     back, so one screenshot shows the whole round trip going through the
//     real user32/GTK clipboard. Nothing else in the catalog can be proven
//     without a person answering something.
//   - opener and notification report what the OS returned, so their status
//     lines are the evidence too.
//
// VAILS_SERVICES_PROBE=clipboard|opener|notification|none makes the page run
// that flow on load, the same example-only hook examples/dialog uses
// (VAILS_DIALOG_PROBE). A synthetic mouse click does not reach WebView2
// content reliably, and the probe travels the exact production path anyway:
// page -> vails.call -> Router.call_json -> handler -> native -> result.
//
// On Linux the clipboard and opener backends are real; notification is an
// explicit stub, and is_supported answers false, which is what the page
// shows.
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
	// Same probe list as examples/dialog so the example runs from the repo
	// root, from its own dir, or next to the binary.
	candidates := [
		'vails.json',
		os.join_path('examples', 'services', 'vails.json'),
		os.join_path(os.dir(os.executable()), 'vails.json'),
		os.join_path(os.dir(os.executable()), '..', 'examples', 'services', 'vails.json'),
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
		os.join_path('examples', 'services', asset_root, 'index.html'),
		os.join_path(os.dir(os.executable()), asset_root, 'index.html'),
	]
	for c in candidates {
		if os.exists(c) {
			return os.read_file(c)!
		}
	}
	return error('index.html not found (tried: ' + candidates.join(', ') + ')')
}

// probe_text is the string the clipboard probe writes and reads back. It is
// fixed (not a timestamp) so a screenshot is comparable between runs, and it
// carries non-ASCII on purpose: the Windows path is UTF-8 -> UTF-16 ->
// clipboard -> UTF-16 -> UTF-8, and an ASCII-only proof would not exercise it.
const proof_text = 'vails clipboard proof — héllo 🌱'

// probe_script returns a <script> block appended to the document when
// VAILS_SERVICES_PROBE is set.
//
//   clipboard   : write proof_text, then read it back; both land in the page
//                 (no human, no flakiness - the whole point of this example)
//   opener      : open a URL, report what the OS said
//   notification: ask is_supported, then notify only if the answer is yes
//
// The snippet runs in the page, which keeps the ADR-0010 threading rule
// intact: only the handler touches native UI, and it does so on the webview
// main thread.
fn probe_script() string {
	probe := os.getenv('VAILS_SERVICES_PROBE')
	if probe == '' || probe == 'none' {
		return ''
	}
	call := match probe {
		'clipboard' {
			'window.vails.clipboard.write_text(JSON.stringify(' + json_str(proof_text) +
				')).then(function () { return window.vails.clipboard.read_text(); })' +
				'.then(function (t) { return { written: ' + json_str(proof_text) +
				', read_back: t }; })'
		}
		'opener' {
			'window.vails.opener.open_url({ url: "https://vails.invalid/probe" })' +
				'.then(function () { return "the OS accepted the URL"; })'
		}
		'notification' {
			'window.vails.notification.is_supported().then(function (r) {' +
				' return JSON.parse(r); }).then(function (ok) {' +
				' if (!ok) { return "not supported here - the service says so ' +
				'instead of doing nothing"; }' +
				' return window.vails.notification.notify({ title: "Vails probe", ' +
				'body: "Notification from the page (probe)." }).then(function () {' +
				' return "shown"; }); })'
		}
		else {
			'Promise.resolve("unknown probe: ' + probe + '")'
		}
	}
	return '  // VAILS_SERVICES_PROBE=' + probe + '\n' + '  ' + call +
		'.then(function (r) { window.vails.__emit("probe:done", ' +
		'JSON.stringify({ probe: "' + probe + '", ok: true, detail: r })); })\n' +
		'    .catch(function (e) { window.vails.__emit("probe:done", ' +
		'JSON.stringify({ probe: "' + probe + '", ok: false, detail: String(e) })); });\n'
}

// json_str renders a V string as a JS string literal for the probe snippet.
// Hand-rolled (the page is assembled from V strings, so no backticks) and
// only ever fed the fixed proof text.
//
// The accumulator is a []u8, not a string: `s[i]` gives a u8 whose .str() is
// its *decimal* value (u8(118).str() == "118"), so appending byte.str() would
// turn "vails" into "118971051081...". Building the bytes and calling
// bytestr() keeps the proof text's multi-byte characters intact - which is the
// whole point of putting non-ASCII in it.
fn json_str(s string) string {
	mut out := []u8{}
	out << u8(`"`)
	for i in 0 .. s.len {
		b := s[i]
		if b == u8(`"`) {
			out << u8(`\\`)
			out << u8(`"`)
		} else if b == u8(`\\`) {
			out << u8(`\\`)
			out << u8(`\\`)
		} else if b < 0x20 {
			// A control character has no JS string literal spelling; the proof
			// text has none, so a space keeps the document valid if it ever did.
			out << u8(` `)
		} else {
			out << b
		}
	}
	out << u8(`"`)
	return out.bytestr()
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
		services.install_clipboard(mut router, ctx) or {
			eprintln('clipboard: ' + err.msg())
		}
		services.install_opener(mut router, ctx) or {
			eprintln('opener: ' + err.msg())
		}
		services.install_notification(mut router, ctx) or {
			eprintln('notification: ' + err.msg())
		}
		services.install_os_info(mut router) or {
			eprintln('os_info: ' + err.msg())
		}
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
