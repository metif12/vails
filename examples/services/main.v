// examples/services - seven services in one window, and the E2E proof vehicle
// for Phase 5 S1 (ADR-0014/0015/0017): clipboard, dialog, opener, notification,
// menu, os_info and tray.
//
// What is new here compared to examples/dialog is not the wiring - that is
// the same two-phase pattern (grants in vails.json, services installed from
// Config.on_ready where the window handle exists) - but the *proof*:
//
//   - clipboard needs no human. The page writes a known string and reads it
//     back, so one screenshot shows the whole round trip going through the
//     real user32/GTK clipboard. Nothing else in the catalog can be proven
//     without a person answering something.
//   - tray is the second such service (ADR-0017): a click is an OS-initiated
//     message, so the example manufactures it (services.simulate_click) and
//     the page waits for the `tray:clicked` event. That proves the whole
//     C -> V -> event -> JS path - the window host seam included - with no
//     mouse and no human.
//   - menu is half-machine: the popup is a real native menu, so a screenshot
//     shows it, and the choice/cancel arrives as an event the page reports.
//     Which item the user picks is the one part a probe cannot fake, so the
//     page closes the menu itself after a fixed hold and reports the
//     dismissal.
//   - opener and notification report what the OS returned, so their status
//     lines are the evidence too.
//
// VAILS_SERVICES_PROBE=clipboard|opener|notification|menu|tray|post|none makes the
// page run that flow on load, the same example-only hook examples/dialog uses
// (VAILS_DIALOG_PROBE). A synthetic mouse click does not reach WebView2
// content reliably, and the probe travels the exact production path anyway:
// page -> vails.call -> Router.call_json -> handler -> native -> result.
//
// On Linux the clipboard and opener backends are real and menu/tray compile
// against the installed GTK 3.24 (see tests/e2e_linux/README.md for the state
// of the Linux run); notification is an explicit stub and is_supported
// answers false, which is what the page shows.
//
// notification's identity is bundle.identifier in vails.json, because on
// Windows an unpackaged app cannot raise a toast without an AppUserModelID
// (ADR-0018). vails init scaffolds one; vails doctor names it if it is
// missing while notification is granted.
module main

import bridge
import config
import os
import services
import time
import webview

// CtxHolder holds what the services need. Heap-allocated because every handler
// closure shares one address (V closures capture by value), and it now also
// holds the tray state, which is what services.simulate_click needs
// (ADR-0017: the Linux half keeps the AppIndicator in there).
struct CtxHolder {
mut:
	ctx webview.Ctx
	// tray is nil until install_tray has run (it needs the window handle),
	// which is why the worker below is spawned from on_ready and not earlier.
	tray &services.TrayState = unsafe { nil }
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
//   tray        : install the icon, then wait for the click the V side
//                 manufactures (ADR-0017)
//   post        : spawn a worker, post a job back to the main thread, and
//                 report what the window thread did (U0, ADR-0019)
//   menu        : open a real popup, let the page close it, and report the
//                 dismissal
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
				'body: "Notification from the page (probe)." }).then(function (m) {' +
				' return "shown via: " + m; }); })'
		}
		'tray' {
			// The click arrives as an event, not as this promise's result, so
			// the probe parks on a promise the page's tray:clicked handler
			// resolves (see index.html). The V side posts the message.
			'window.vails.tray.set({ tooltip: "Vails Services Demo" })' +
				'.then(function () {' +
				' return new Promise(function (resolve) { window.__vailsResolve = resolve; }); })' +
				'.then(function (payload) { return "clicked: " + payload; })'
		}
		'menu' {
			// The hold timer is armed BEFORE the call on purpose: on Windows
			// `menu.popup` is a modal native loop, so a timer armed after the
			// await would only start once the menu was already gone. The hold is
			// configurable (VAILS_SERVICES_PROBE_HOLD_MS) because an E2E run
			// needs the menu up long enough to photograph it, and a fixed 2.5 s
			// is a race against whoever is driving the machine.
			'setTimeout(function () { window.vails.menu.close(); }, ' +
				probe_hold_ms().str() + ');' +
				'window.vails.menu.popup({ items: ' + menu_probe_items_json() + ' })' +
				'.then(function () {' +
				' return new Promise(function (resolve) { window.__vailsResolve = resolve; }); })' +
				'.then(function (payload) { return "dismissed: " + payload; })'
		}
		'menubar' {
			// A window menu bar is not modal, so there is nothing to hold open
			// and nothing to close: the command installs the bar, resolves with
			// '', and the user picks from it whenever they like. The probe then
			// parks on the `menu:clicked` event, exactly like the popup probe
			// parks on its own answer, because that is the only thing worth
			// photographing.
			'window.vails.menu.set_menu({ items: ' + menubar_probe_items_json() + ' })' +
				'.then(function () {' +
				' return new Promise(function (resolve) { window.__vailsResolve = resolve; }); })' +
				'.then(function (payload) { return "bar chose: " + payload; })'
		}
		'dialog' {
			// The hard part of this probe is the ORDER. dialog.message blocks the
			// main thread inside gtk_dialog_run, so a dialog that nobody answers
			// would hang the page forever. The auto-answer timer therefore has to
			// be armed before the call - which means before the page's script
			// runs, which is what the V side does at startup. This script only
			// has to ask and report.
			//
			// GTK_RESPONSE_OK (the -5) is what the timer presses, so a proof that
			// says "button: ok" is showing the real response id travelling
			// through the real nested loop and the real mapping, not a stub.
			'window.vails.dialog.message({ title: "Vails probe", ' +
				'message: "Answered by the E2E probe, not a human.", ' +
				'buttons: "okcancel" })' +
				'.then(function (r) { var v = JSON.parse(r); ' +
				'return "button: " + v.button + ", canceled: " + v.canceled; })'
		}
		'traymenu' {
			// Attach a menu to the tray icon. Unlike the other tray probe there is
			// no answer to wait for on Linux at all: the StatusNotifier *host*
			// owns the click and opens this menu itself, so nothing arrives back
			// through the bridge. The honest proof is therefore what the page can
			// check — the command resolved — plus, on Windows, the menu really
			// appearing on a right click.
			'window.vails.tray.set({ tooltip: "Vails Services Demo" })' +
				'.then(function () { return window.vails.tray.set_menu({ items: ' +
				tray_menu_items_json() + ' }); })' +
				'.then(function () { return "menu attached to the tray icon"; })'
		}
		'post' {
			// The V side initiates this probe: a worker is spawned, it sleeps,
			// then posts a job back to the main thread, and the job's own
			// report_probe emits the only probe:done there is (U0, ADR-0019).
			//
			// A promise that never settles, deliberately. The generic wrapper
			// below turns the snippet's result into a probe:done, so an
			// already-resolved value here would report success the moment the
			// page loaded — a green line that proves nothing about the post seam
			// and, worse, one that races the real answer to the same panel. The
			// status line in the panel stays on the button's "waiting..." text
			// until the worker actually gets back.
			'new Promise(function () {})'
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

// The default and the ceiling for probe_hold_ms (VAILS_SERVICES_PROBE_HOLD_MS:
// how long the menu probe leaves the popup up before closing it).
const default_hold_ms = 2500
const max_hold_ms = 60000

// probe_hold_ms is example-only, like the probe itself: the service has no such
// knob, and a service would be the wrong place for "how long is this
// screenshot window". Clamped so a typo cannot hang a run for an hour.
fn probe_hold_ms() int {
	raw := os.getenv('VAILS_SERVICES_PROBE_HOLD_MS')
	if raw == '' {
		return default_hold_ms
	}
	ms := raw.int()
	if ms <= 0 {
		return default_hold_ms
	}
	return if ms > max_hold_ms { max_hold_ms } else { ms }
}

// menu_probe_items_json is the popup the menu probe shows, as a JS literal: a
// leaf, a disabled leaf, a separator, a submenu with two leaves, and a second
// separator - enough shape to prove the builder, the flags and the id mapping
// in one screenshot.
//
// It is a build-time string rather than a wire payload because the probe
// snippet is assembled from V strings and the ids and labels here are fixed.
// A real frontend sends the same shape as JSON (that is what `parse_popup`
// decodes); the V struct it mirrors is services.MenuItem.
fn menu_probe_items_json() string {
	return '[{"id":"open","label":"Open file..."},' +
		'{"id":"save","label":"Save as...","enabled":false},' +
		'{"separator":true},' +
		'{"id":"file","label":"File","children":[' +
		'{"id":"file/new","label":"New"},{"id":"file/quit","label":"Quit"}]},' +
		'{"separator":true},' +
		'{"id":"about","label":"About Vails"}]'
}

// menu_bar_probe_items_json is the window menu bar's fixture. It is a
// top-level bar of drop-downs rather than the popup's flat list, because that
// is the shape a bar is for and it exercises the part the popup cannot: a
// GtkMenuBar / a SetMenu root whose children each own a submenu.
fn menubar_probe_items_json() string {
	return '[{"id":"file","label":"File","children":[' +
		'{"id":"file/new","label":"New"},{"id":"file/open","label":"Open..."},' +
		'{"separator":true},{"id":"file/quit","label":"Quit"}]},' +
		'{"id":"edit","label":"Edit","children":[' +
		'{"id":"edit/copy","label":"Copy"},{"id":"edit/paste","label":"Paste"}]},' +
		'{"id":"help","label":"Help"}]'
}

// tray_menu_items_json is the tray icon's menu fixture. It is a short flat
// list rather than the window bar's drop-downs because a tray menu is a
// context menu by convention — and because the flat case is the one where the
// id table is easiest to check by eye.
fn tray_menu_items_json() string {
	return '[{"id":"tray/open","label":"Open"},' +
		'{"id":"tray/settings","label":"Settings"},' +
		'{"separator":true},' +
		'{"id":"tray/quit","label":"Quit"}]'
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

// inject_before_body inserts a <script> block right before the end of the
// body, so the page's own script (which registers the probe:done listener) has
// already run. Appended at the end when the document has no body.
//
// The LAST closing body tag, never the first: a mention of one inside a
// comment or a string in the page's own script element (which is where this
// example's E2E prose lives) used to be found first, and injecting there closed
// the script element early - the rest of the page's source then rendered as
// visible text. `webview/ctx_test.v` guards the invariant from the other side.
fn inject_before_body(html string, js string) string {
	block := '<script>\n' + js + '</script>\n'
	if at := html.last_index('</body>') {
		return html[..at] + block + html[at..]
	}
	return html + block
}

// simulate_tray_click is the tray probe's native half: wait for the page to
// install the icon, then manufacture the message the shell would send on a
// click. It is example code on purpose - `services.simulate_click` is the
// library's half, and the *timing* belongs to the proof, not to the service.
//
// It polls instead of sleeping a fixed time, because a click that arrives
// before the icon exists has nothing to click and a first WebView2 page load
// is slower than a comfortable constant. Both failures are reported rather
// than swallowed: a run whose click never lands should say why - on the page,
// not only in the log, because a line of eprintln is not something a
// screenshot can carry and the tray panel is exactly where a reader looks.
//
// ctx is passed in rather than read off the TrayState because TrayState.ctx is
// private to the services module (the state belongs to the service, not to the
// example), and the example already holds the same Ctx from on_ready.
fn simulate_tray_click(ctx webview.Ctx, st &services.TrayState) {
	for _ in 0 .. 100 {
		if st.is_installed() {
			break
		}
		time.sleep(100 * time.millisecond)
	}
	if !st.is_installed() {
		eprintln('tray probe: the page never called tray.set (did the page load?)')
		report_probe(ctx, 'tray', false, 'the page never called tray.set (did the page load?)')
		return
	}
	// Slack for the page's tray:clicked listener. It is registered by the
	// page's own script, which runs before the probe, so this is belt and
	// braces rather than a dependency.
	time.sleep(300 * time.millisecond)
	services.simulate_click(st, services.button_left) or {
		eprintln('tray probe: could not simulate a click: ' + err.msg())
		// Linux always lands here, and that is the honest answer rather than a
		// failure: there is no click to simulate because the SNI host owns it
		// (ADR-0017). Sending it to the page is what turns "nothing happened"
		// into a documented platform difference.
		report_probe(ctx, 'tray', false, err.msg())
	}
}

// report_probe hands a probe outcome to the page as the same probe:done event
// the frontend's own promise chain emits, so one listener renders both. The
// detail is a plain string here, which the page's handler already stringifies
// for non-object details.
fn report_probe(ctx webview.Ctx, probe string, ok bool, detail string) {
	payload := '{"probe":' + json_str(probe) + ',"ok":' + (if ok { 'true' } else { 'false' }) +
		',"detail":' + json_str(detail) + '}'
	ctx.emit('probe:done', payload) or {
		eprintln(probe + ' probe: could not deliver the result to the page: ' + err.msg())
	}
}

// run_post_probe is the `post` probe's V half, and the first real user of the
// main-thread post seam (U0, ADR-0019): a worker is spawned, it sleeps so the
// page has loaded and registered its listener, then it hands a closure to the
// window thread. The closure emits probe:done, which the page renders.
//
// This is the proof that a worker can reach the page at all. Before U0 the
// worker computed its result and dropped it on the floor, because ctx.emit ends
// in webview_eval on a thread the webview object does not own.
//
// The sleep is not a hack but the ordering the proof needs: the page's
// probe:done listener is registered by the page's own script, which runs after
// on_ready returns, so a post that lands before it is registered is a post the
// page never sees.
//
// The value is deliberately generous (2 s) because a FIRST WebView2 page load
// on Windows routinely takes longer than half a second, and an emit that beats
// the listener registration is dropped by the webview with no error - the
// symptom is a panel that never fills in, not a log line. Other probes in this
// file hide a comparable race behind a fixed wait too; they just have a
// command result to show afterwards, whereas this one's only result IS the
// event.
const post_probe_settle_ms = 2000

fn run_post_probe(ctx webview.Ctx) {
	time.sleep(post_probe_settle_ms * time.millisecond)
	webview.post_to_main(ctx, fn [ctx] () {
		report_probe(ctx, 'post', true, 'worker posted back to the main thread')
	}) or {
		// The failure is reported to the page, not only to the log: a line of
		// eprintln is not something a screenshot can carry, and the probe panel
		// is exactly where a reader looks.
		report_probe(ctx, 'post', false, err.msg())
	}
}

// app_identity builds the identity the notification service attributes its
// toasts to. On Windows this is the AppUserModelID, and an unpackaged app
// cannot raise a toast without one (ADR-0018) - so it comes from
// vails.json's bundle.identifier, the same value `vails init` scaffolds and
// `vails doctor` checks.
//
// The display name is the app's own name, which is what the Action Center
// shows next to the notification. Falling back to the identifier keeps an
// app with an unset bundle.name from producing an empty name.
fn app_identity(cfg config.VailsConfig) services.AppIdentity {
	return services.AppIdentity{
		id:           cfg.bundle.identifier
		display_name: if cfg.bundle.name != '' {
			cfg.bundle.name
		} else {
			cfg.bundle.identifier
		}
	}
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
	identity := app_identity(app_cfg)
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
	on_ready := fn [mut holder, mut router, identity] (ctx webview.Ctx) {
		holder.ctx = ctx
		services.install_clipboard(mut router, ctx) or {
			eprintln('clipboard: ' + err.msg())
		}
		services.install_opener(mut router, ctx) or {
			eprintln('opener: ' + err.msg())
		}
		// The identity is read once, outside the closure: it is app config,
		// not window state, and the closure already captures the router and
		// the holder.
		services.install_notification(mut router, ctx, identity) or {
			eprintln('notification: ' + err.msg())
		}
		services.install_menu(mut router, ctx) or {
			eprintln('menu: ' + err.msg())
		}
		// dialog is a blocking service, so it is installed here like the rest -
		// the blocking part is documented (ADR-0014's gtk_dialog_run
		// exception), not a reason to install it somewhere else.
		services.install_dialog(mut router, ctx) or {
			eprintln('dialog: ' + err.msg())
		}
		// Armed before the page's script can ask, and that ordering is the
		// whole difficulty of the dialog probe: the call blocks the main thread
		// inside gtk_dialog_run, so a timer armed after the fact would only
		// start once a human who is not there had already answered. Returns
		// false on every platform that cannot answer its own dialog (Windows),
		// and that is a documented manual check rather than a silent skip.
		if arm_dialog_probe() {
			eprintln('dialog probe: armed an auto-answer for the next modal dialog')
		}
		services.install_os_info(mut router) or {
			eprintln('os_info: ' + err.msg())
		}
		// tray is the one service whose state the app keeps: simulate_click
		// needs it (ADR-0017), and that is what makes the click loop
		// machine-provable.
		holder.tray = services.install_tray(mut router, ctx) or {
			eprintln('tray: ' + err.msg())
			return
		}
		if os.getenv('VAILS_SERVICES_PROBE') == 'tray' {
			// The click is a native message, so the proof has to come from the
			// native side: a worker posts it after the page has had time to
			// install the icon and register its listener. spawn + sleep is the
			// ADR-0010 shape (the main thread must stay responsive), and the
			// post is asynchronous, so the click lands after this handler
			// returns.
			spawn simulate_tray_click(ctx, holder.tray)
		}
		if os.getenv('VAILS_SERVICES_PROBE') == 'post' {
			// The main-thread post seam (U0): a worker hands a closure to the
			// window thread, which runs it and emits to the page. Same
			// spawn + sleep shape as the tray probe, for the same reason.
			spawn run_post_probe(ctx)
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
