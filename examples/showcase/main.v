// examples/showcase - one panel per capability, each with a button, a status line
// and a verdict a screenshot can check (ROADMAP track R3).
//
// ## Why this app exists when examples/services already exists
//
// `examples/services` grew a second job. It started as "call a service and print
// what came back" and became five probe modes behind `VAILS_SERVICES_PROBE`,
// with an OS-specific auto-answer shim for the dialog so a screenshot could be
// taken without a human. Every one of those was the right call *for that job* —
// and together they are why `services.png` and `notification.png` once came out
// byte-identical: two vehicles, each proving one thing, neither showing the whole.
//
// This one has a single job, and it is the one R3 states: **be the reference**.
// Every capability gets a panel; every panel says one of three things — it
// worked, it needs a human, or it failed — and a summary strip at the top counts
// them, so one screenshot is a verdict on the whole framework rather than on one
// service.
//
// So there are deliberately NO probe modes here, no auto-answer shim, and no
// `VAILS_SHOWCASE_PROBE`. A panel that needs a human says NEEDS YOU and does not
// pretend; that is ADR-0018's discipline applied to the demo instead of to a
// backend, and it is why the dialog panel can block this window without a
// screenshot ever looking green.
//
// ## It is a reference, not a template
//
// `vails init` keeps scaffolding the small `hello` app. Copying this file to
// start a project would be starting from 11 panels you did not ask for. What is
// worth copying is the *shape*: one `on_ready` that installs services against the
// window, a manifest that grants them, and a page that calls them.
//
// ## What is here on purpose and what is not
//
// Three app commands (`demo.ping`, `demo.post`) exist so the page can prove the
// two things no service can: that a JS -> V -> JS round trip resolves, and that
// `webview.post_to_main` gets a worker's result back onto the window thread
// (ADR-0019). Everything else is a service the page calls by its own name.
//
// Multi-window is NOT a panel. It is `examples/multiwindow`, it needs two
// windows to mean anything, and a panel in a one-window window would be a lie by
// omission (ADR-0035).
module main

import bridge
import config
import os
import services
import webview

// CtxHolder is the app's handle on its window. Services are installed in
// `on_ready` because they need the window handle, which does not exist until the
// native window is up, so something has to carry the Ctx from there to the code
// that needs it afterwards — and the tray's state, because the icon outlives the
// install call that created it.
//
// One heap-allocated holder rather than a `mut` captured local: V 0.5.2 copies a
// captured value, and the ctx the services were installed against must be the
// ctx the page's events come back on (AGENTS.md §2c).
@[heap]
struct CtxHolder {
mut:
	ctx webview.Ctx
	// tray is nil until install_tray has run (it needs the window handle), and it
	// stays nil if the install failed — the panel then says so instead of
	// offering a Remove button for an icon that is not there.
	tray &services.TrayState
}

fn load_app_config() !config.VailsConfig {
	// Same candidate list as the other examples, so this runs from the repo root,
	// from its own directory, or next to the built binary.
	candidates := [
		'vails.json',
		os.join_path('examples', 'showcase', 'vails.json'),
		os.join_path(os.dir(os.executable()), 'vails.json'),
		os.join_path(os.dir(os.executable()), '..', 'examples', 'showcase', 'vails.json'),
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
		os.join_path('examples', 'showcase', asset_root, 'index.html'),
		os.join_path(os.dir(os.executable()), asset_root, 'index.html'),
	]
	for c in candidates {
		if os.exists(c) {
			return os.read_file(c)!
		}
	}
	return error('index.html not found (tried: ' + candidates.join(', ') + ')')
}

// app_identity builds the notification service's identity from the manifest, so
// the toast carries this app's name and id rather than a default (ADR-0018).
// Falling back to the identifier keeps an app with an unset bundle.name from
// producing an empty name — copied from examples/services rather than reinvented,
// because it is the same rule and two copies of one rule is how they drift.
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

// ping returns a fixed string, so the page can assert on the *value* coming back
// rather than merely on "a promise resolved". A round trip that resolves with
// nothing cannot be distinguished from a round trip that resolved with garbage,
// which is the difference between a proof and a smoke test.
fn ping_pong(token string) string {
	return 'pong:' + token
}

// post_from_a_worker is the U0 proof (ADR-0019) and the shape ADR-0010 asks slow
// work to take: the command hands off to a spawned worker, and the worker hands
// a closure back to the window thread to emit from.
//
// The middle step is the whole point. A worker that called `ctx.emit` directly
// would be calling `webview_eval` off the thread that owns the webview, which is
// undefined behaviour for WebView2 — so the arrival of `demo:posted` IS the
// result, not a side effect of it.
fn post_from_a_worker(ctx webview.Ctx, label string) {
	// A plain reference and a plain value, never a `mut` one: `spawn` with a
	// `mut ... &T` parameter crashes or hangs in this V (AGENTS.md §2c).
	spawn post_worker(ctx, label)
}

// post_worker is the spawned half. It runs off the window thread, so the only
// thing it may do with the page is ask the window thread to do it.
fn post_worker(ctx webview.Ctx, label string) {
	webview.post_to_main(ctx, fn [ctx, label] () {
		ctx.emit('demo:posted', json_str(label)) or {
			eprintln('showcase: the posted closure could not emit: ' + err.msg())
		}
	}) or {
		eprintln('showcase: post_to_main refused: ' + err.msg())
	}
}

// json_str renders a V string as a JSON string literal. Hand-rolled for the same
// reason examples/multiwindow hand-rolls it: these examples carry no build step,
// and it is fed only strings this app itself produced.
fn json_str(s string) string {
	mut out := []u8{}
	out << u8(`"`)
	for i in 0 .. s.len {
		b := s[i]
		if b == u8(`"`) || b == u8(`\\`) {
			out << u8(`\\`)
		} else if b < 0x20 {
			out << u8(` `)
		} else {
			out << b
		}
	}
	out << u8(`"`)
	return out.bytestr()
}

// support_json renders services.supports() — the same table `vails doctor`
// prints — for the page.
//
// This exists so the showcase does NOT decide "is this platform missing it" by
// matching error strings. A panel that greps for "not implemented" is a panel
// that breaks when the wording changes, and one that reports a working feature as
// broken is worse than one that reports nothing: both are the over-read
// ADR-0018's discipline is about. The framework already knows the answer and
// already has a type for it, so the page is handed the answer.
//
// Shape: {"drop": {"ready": false, "note": "..."}, ...} — one entry per catalog
// service, keyed by name, because that is the key the page's panels are written
// against and a second mapping layer would be a second thing to keep in sync.
fn support_json() string {
	mut parts := []string{}
	for s in services.supports() {
		parts << json_str(s.name) + ':{' + '"ready":' + bool_json(s.ready) + ',"note":' +
			json_str(s.note) + '}'
	}
	return '{' + parts.join(',') + '}'
}

// bool_json renders a V bool as JSON. Two lines rather than a dependency on an
// encoder for one value, and `ready` is the only non-string scalar in the table.
fn bool_json(b bool) string {
	return if b { 'true' } else { 'false' }
}

// inject_before_body puts a script at the end of the document.
//
// Before `</body>`, not appended after `</html>`: a `<script>` past the closing
// html tag is not executed by the webview's HTML parser, which is the same trap
// examples/services documents for its probe script.
fn inject_before_body(html string, js string) string {
	marker := '</body>'
	idx := html.last_index(marker) or { return html + '\n' + js + '\n' }
	return html[..idx] + '<script>\n' + js + '\n</script>\n' + html[idx..]
}

// automation_script is the whole of the showcase's automation seam, and it is
// three lines of generated JavaScript.
//
// ## Why there is a seam at all
//
// R4 needs one screenshot per panel (ROADMAP: "a panel that cannot produce a
// screenshot is not a panel yet"), and that means one panel per app launch. The
// document is delivered with `webview_set_html`, so there is no URL to read an
// instruction from and nothing for the page to poll. The alternatives were
// worse: a V-side probe mode — which is the `VAILS_SERVICES_PROBE` design ADR-0037
// rejected, and which has grown to seven values there — or a page that guesses.
//
// So the seam is one injected call into the page's OWN `run`, and it waits on
// the page's own `ready` promise. Both exist so that a capture can never run a
// panel before the support table has landed, which would report a missing backend
// as FAIL rather than NOWHERE.
//
// ## The action name is validated against the page's own list, not trusted
//
// `showcase.actions` is checked in JavaScript rather than in V, because the page
// is the only thing that knows its own runner keys — and an unknown key would
// otherwise be a silently empty screenshot, which is the failure mode this whole
// design exists to avoid. A typo names itself in the page's status line instead.
//
// Note that an ACTION is not a PANEL: `menu` is a panel, `menubar` is the action
// that fills it, and R4's capture script holds that mapping because it is the
// thing most likely to drift. The page therefore exposes both lists.
//
// ## What a normal run gets
//
// Nothing. With `VAILS_SHOWCASE_PANEL` unset, this returns the empty string, no
// script is injected, and the page has no idea automation exists.
fn automation_script(panel string) string {
	if panel == '' {
		return ''
	}
	return 'window.showcase.ready.then(function () {' + '\n' +
		'  var key = ' + json_str(panel) + ';' + '\n' +
		'  if (window.showcase.actions.indexOf(key) < 0) {' + '\n' +
		'    document.getElementById("tally").textContent = ' +
		'"no such action: " + key + " (have: " + window.showcase.actions.join(", ") + ")";' +
		'\n' +
		'    return;' + '\n' +
		'  }' + '\n' +
		'  window.showcase.run(key);' + '\n' +
		'});'
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
	// The automation seam, and only when somebody asked for one: R4's capture
	// script sets this to isolate a panel per screenshot. It travels with the
	// document so the page runs it through the real JS path rather than a
	// synthesised click, exactly as the services probe does.
	automation := automation_script(os.getenv('VAILS_SHOWCASE_PANEL'))
	if automation != '' {
		html = inject_before_body(html, automation)
	}
	w := app_cfg.window('main') or {
		eprintln(err.msg())
		exit(1)
	}
	identity := app_identity(app_cfg)
	mut holder := &CtxHolder{
		// V requires a reference field to be initialised explicitly, and nil is
		// the honest value here: install_tray has not run yet, and the panel is
		// written to treat nil as "not installed" rather than to guess.
		tray: unsafe { nil }
	}
	mut r := bridge.new_router()
	// Heap-allocated so the on_ready closure and webview.run share one router:
	// the commands are registered before the window exists and the services are
	// installed after, and both halves must land in the same table.
	mut router := &r
	// The app's own commands go in before the window: they need nothing from it.
	router.register('demo.ping', fn (_ string) !string {
		return ping_pong('vails')
	}) or {
		eprintln('demo.ping: ' + err.msg())
		exit(1)
	}
	router.register('demo.post', fn [mut holder] (_ string) !string {
		post_from_a_worker(holder.ctx, 'from a worker thread')
		return ''
	}) or {
		eprintln('demo.post: ' + err.msg())
		exit(1)
	}
	// Read once, outside the closure: the support table is a property of the
	// build and the platform, not of the window, and it cannot change while the
	// app runs.
	support := support_json()
	router.register('demo.support', fn [support] (_ string) !string {
		return support
	}) or {
		eprintln('demo.support: ' + err.msg())
		exit(1)
	}
	// Services need the window handle, which only exists once the native window
	// is up — hence the two-phase wiring: the app's commands go in now, the
	// services in on_ready below. Every install is reported by name rather than
	// swallowed: a showcase whose panel silently does nothing is worse than a
	// showcase that says which service is missing.
	on_ready := fn [mut holder, mut router, identity] (ctx webview.Ctx) {
		holder.ctx = ctx
		services.install_clipboard(mut router, ctx) or {
			eprintln('showcase: clipboard: ' + err.msg())
		}
		services.install_opener(mut router, ctx) or {
			eprintln('showcase: opener: ' + err.msg())
		}
		services.install_notification(mut router, ctx, identity) or {
			eprintln('showcase: notification: ' + err.msg())
		}
		services.install_menu(mut router, ctx) or {
			eprintln('showcase: menu: ' + err.msg())
		}
		// dialog BLOCKS the window thread inside the platform's modal call while
		// it is open. That is documented (ADR-0014) rather than hidden, and the
		// panel says NEEDS YOU instead of pretending otherwise.
		services.install_dialog(mut router, ctx) or {
			eprintln('showcase: dialog: ' + err.msg())
		}
		services.install_os_info(mut router) or {
			eprintln('showcase: os_info: ' + err.msg())
		}
		// tray: the state is kept because the icon outlives this call, and a
		// tray panel that could not remove its own icon would be a trap.
		holder.tray = services.install_tray(mut router, ctx) or {
			eprintln('showcase: tray: ' + err.msg())
			unsafe { nil }
		}
		// drop (ADR-0036): installed like the rest. On Linux `drop.enable`
		// refuses by name, and the panel shows that refusal rather than claiming
		// a feature this platform does not have.
		services.install_drop(mut router, ctx) or {
			eprintln('showcase: drop: ' + err.msg())
		}
	}
	webview.run(webview.Config{
		label:    w.label
		title:    w.title
		width:    w.width
		height:   w.height
		html:     html
		router:   router
		registry: app_cfg.to_registry()
		on_ready: on_ready
	}) or {
		eprintln('showcase: ' + err.msg())
		exit(1)
	}
}
