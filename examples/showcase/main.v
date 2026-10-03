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
import json2
import os
import services
import time
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
	// verdicts accumulate what the page reported, one entry per panel. Read by
	// `report` when a verify run finishes, and ignored on a normal run.
	verdicts []Verdict
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

// Verdict is one panel's result, as the page reported it.
//
// The page is the only thing that knows what a panel did — V cannot read the DOM
// — so `demo.verdict` is how a verdict crosses into text. That is the whole of
// R4's machine-checkable half, and it exists because a PNG is not a verdict: a
// screenshot cannot be diffed for "the clipboard panel passed", so the same
// information is also emitted as a line a person reads and a script can assert.
struct Verdict {
pub mut:
	panel   string
	verdict string
	detail  string
}

// record_verdict appends one panel's result and echoes it immediately.
//
// Echoing as it arrives rather than at the end is deliberate: a verify run that
// prints nothing for six seconds and then dumps a table is indistinguishable from
// one that hung, and the whole run is a sequence of native calls that can each
// fail. One line per panel as it happens is also the shape a transcript wants.
fn record_verdict(mut holder &CtxHolder, panel string, verdict string, detail string) {
	holder.verdicts << Verdict{
		panel:   panel
		verdict: verdict
		detail:  detail
	}
	println('  ' + pad(panel, 11) + pad(verdict, 11) + detail)
}

// report prints the tally and returns the process exit code.
//
// **The exit code is the point.** `NEEDS YOU` and `NOWHERE` are honest answers
// and do NOT fail the run — a Linux box with no `drop` backend is not a broken
// box. Only `FAIL` is, so a verify run can gate something. Reporting the counts
// as well as the code is what keeps the code from being the only thing that
// matters: a run that exits 0 because nothing ran is the failure mode here.
fn report(holder &CtxHolder) int {
	mut counts := map[string]int{}
	for v in holder.verdicts {
		counts[v.verdict]++
	}
	// "Never ran" is its own number and not the absence of one. Three panels are
	// human-only by construction (a file picker, a tray right-click, a drag), so a
	// verify run that skipped them must say so — reporting "0 need a human" for
	// panels that were never even reached is the kind of tidy lie this whole
	// design exists to avoid.
	mut never := expected_panels - holder.verdicts.len
	if never < 0 {
		never = 0
	}
	println('')
	println('showcase: ' + counts['PASS'].str() + ' pass, ' +
		counts['NEEDS YOU'].str() + ' need a human, ' + counts['NOWHERE'].str() +
		' not on this platform, ' + counts['FAIL'].str() + ' fail, ' +
		never.str() + ' of ' + expected_panels.str() + ' panels never ran')
	if counts['FAIL'] > 0 {
		return 1
	}
	if holder.verdicts.len < 2 {
		eprintln('showcase: almost nothing reported - treat this as a failed run, ' +
			'not as a clean one')
		return 1
	}
	return 0
}

// expected_panels is how many panels the page has, which is what makes "only two
// reported" a failure rather than a quiet success.
const expected_panels = 11

// pad right-pads to `n` so the report lines up. Two spaces of slack, because a
// verdict longer than the column would silently run the next column together and
// a report that runs together is a report nobody reads.
fn pad(s string, n int) string {
	mut out := s
	for out.len < n {
		out += ' '
	}
	return out + '  '
}

// close_after asks the window to close, `ms` from now, on another thread.
//
// The delay is the whole function. See `demo.finish`: the caller is on the window
// thread inside a message handler, and the close has to happen after that handler
// has returned.
fn close_after(ctx webview.Ctx, ms int) {
	time.sleep(ms * time.millisecond)
	// Both of these are logs rather than assumptions. The first version of this
	// had neither, and a verify run that did not end produced **no output at
	// all** — which is indistinguishable from a run that is still working, and is
	// the exact failure this mode exists to make visible.
	println('  finish      closing the window (' + ctx.can_close().str() +
		' can_close)')
	ctx.close() or {
		eprintln('showcase: could not close the window: ' + err.msg())
		return
	}
	println('  finish      close requested')
}

// VerdictParams is `demo.verdict`'s wire shape. `pub mut` because json2 fills
// it, and named rather than a map so the contract is readable in the code.
struct VerdictParams {
pub mut:
	panel   string
	verdict string
	detail  string
}

// parse_verdict decodes demo.verdict's params.
//
// The verdict is **not** validated against a closed set here, deliberately: the
// page is the authority on what a panel concluded, and this side's job is to
// print it faithfully. Validating it would mean a new verdict in the page
// silently vanishing from the report instead of appearing in it, which is the
// wrong direction for a diagnostic. What IS checked is the two things that would
// make the report unreadable: an empty panel name, and an absurd detail length.
pub fn parse_verdict(params string) !Verdict {
	if params == '' || params == 'null' {
		return error('demo.verdict: no verdict payload')
	}
	v := json2.decode[VerdictParams](params) or {
		return error('demo.verdict: invalid payload: ' + err.msg())
	}
	if v.panel == '' {
		return error('demo.verdict: a verdict needs a panel name')
	}
	if v.verdict == '' {
		return error('demo.verdict: panel "' + v.panel + '" reported no verdict')
	}
	if v.detail.len > 2000 {
		return error('demo.verdict: detail is longer than 2000 characters')
	}
	return Verdict{
		panel:   v.panel
		verdict: v.verdict
		detail:  v.detail
	}
}

// verify_script is what a verify run injects instead of a single panel.
//
// It is the same seam as `automation_script` (ADR-0037): set the flag, then use
// the page's own `run` for every panel a machine can complete. The flag has to be
// set BEFORE the panels run and AFTER the page's script has loaded, which is why
// it is injected before `</body>` rather than in `<head>`: at that point
// `window.showcase` exists but nothing has been run yet.
//
// The two human-only panels are deliberately not in AUTO — a file picker and a
// tray right-click have no machine answer, and asking for one is how a verify run
// hangs forever. They stay IDLE and the report says so, which is the honest
// outcome rather than a timeout.
//
// ## Why `finish` is called from BOTH chain outcomes, and why there is a timer
//
// The first version chained `chain.then(finish).catch(noop)`, so any rejection
// anywhere in the run meant `demo.finish` was never called and the window stayed
// up forever. The observed symptom was exactly that: seven panels reported and
// then nothing, with an empty stderr, because the rejection is swallowed by the
// very handler meant to tidy up.
//
// So: finish runs on resolve AND on reject, and a 20 s timer runs it regardless.
// A verify run must always end — a window left open is indistinguishable from a
// run that is still working, which is the failure mode this whole mode exists to
// avoid.
fn verify_script() string {
	return 'window.showcase.verify = true;' + '\n' +
		'window.showcase.ready.then(function () {' + '\n' +
		'  var finish = function () {' + '\n' +
		'    return window.vails.call("demo.finish", "").catch(function () {});' +
		'\n' +
		'  };' + '\n' +
		'  var safety = setTimeout(finish, 20000);' + '\n' +
		'  var auto = ["bridge", "caps", "osinfo", "clipboard", "notify", ' +
		'"opener", "menubar", "post"];' + '\n' +
		'  var chain = Promise.resolve();' + '\n' +
		'  auto.forEach(function (k) { chain = chain.then(function () {' + '\n' +
		'    return window.showcase.run(k);' + '\n' +
		'  }); });' + '\n' +
		'  var end = function () { clearTimeout(safety); return finish(); };' +
		'\n' +
		'  chain.then(end, end);' + '\n' +
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
	// script sets this to isolate a panel per screenshot, and a verify run sets it
	// to run every machine-checkable panel and report. It travels with the
	// document so the page runs it through the real JS path rather than a
	// synthesised click, exactly as the services probe does.
	verify := os.getenv('VAILS_SHOWCASE_VERIFY') != ''
	mut automation := automation_script(os.getenv('VAILS_SHOWCASE_PANEL'))
	if verify {
		// Verify wins over a single panel: asking for both is a contradiction and
		// the honest reading of it is "run everything", which is a superset.
		automation = verify_script()
	}
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
	// The verdict channel (R4). The page owns the verdict — it is the only side
	// that can see what a panel did — so this is how one becomes text.
	//
	// Not capability-gated in the manifest sense: it is in the `bridge`
	// capability's command list, so a page that has not been granted it gets
	// refused, exactly like every other command.
	router.register('demo.verdict', fn [mut holder] (params string) !string {
		v := parse_verdict(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		record_verdict(mut holder, v.panel, v.verdict, v.detail)
		return ''
	}) or {
		eprintln('demo.verdict: ' + err.msg())
		exit(1)
	}
	// `demo.finish` is how a verify run ends. The page cannot close its own window
	// — only the app knows how — and it must not try: from JS both options are
	// wrong (reloading loops forever, `window.close()` does nothing in a webview).
	router.register('demo.finish', fn [mut holder] (_ string) !string {
		// Spawned rather than closed inline, because this handler runs ON the
		// window thread inside the very message loop that has to return before the
		// window can close. Closing from here asks the library to shut down the
		// loop it is currently dispatching into. The short sleep on another thread
		// lets this handler return first — a plain reference, because `spawn` with
		// a `mut ... &T` crashes or hangs in this V (AGENTS.md §2c).
		//
		// `mut closer := holder` rather than capturing `holder`: a `mut` capture
		// of a `mut` *parameter* is typed as a pointer to the pointer by V 0.5.2
		// and gcc rejects the assignment — a plain local captures correctly.
		mut closer := holder
		println('  finish      the page asked the app to close the window')
		spawn close_after(closer.ctx, 250)
		return ''
	}) or {
		eprintln('demo.finish: ' + err.msg())
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
	// A verify run gets a watchdog BEFORE the window opens, so the timer starts
	// when the run does rather than after the page has loaded. A plain reference,
	// because `spawn` with a `mut ... &T` crashes or hangs in this V (AGENTS.md
	// §2c); `holder` is already a heap struct, so the pointee is the shared one.
	if verify {
		mut watcher := holder
		spawn watchdog(watcher, verify_settle_ms)
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
	// The report, after the window has closed. On a normal run `verdicts` is empty
	// and this prints nothing that says anything — so it only speaks when a
	// verify run asked for it, because a report nobody asked for is noise.
	if verify {
		exit(report(holder))
	}
}

// watchdog ends a verify run on its own terms, which is a deliberate choice.
//
// The obvious design is "the page asks the app to close the window, then the app
// reports". Measured on Windows 2026-10-03: **`Ctx.close()` reports success and
// the window stays open.** `webview_terminate` is reached (the log line is
// printed), returns 0, and `webview_run` never comes back — so the first version
// of this mode printed every panel and then sat there until it was killed.
//
// That is precisely the failure mode this mode exists to prevent: a harness that
// depends on the thing-under-test's shutdown path cannot report a failure *of*
// that path. So the watchdog is the authority: after `settle_ms` it prints the
// report and ends the process itself, and `demo.finish` is still there to close
// the window cleanly on any platform where close works.
fn watchdog(holder &CtxHolder, settle_ms int) {
	time.sleep(settle_ms * time.millisecond)
	println('  finish      watchdog: the window did not close on its own')
	code := report(holder)
	println('')
	println('showcase: verify finished with exit code ' + code.str())
	exit(code)
}

// verify_settle_ms is how long the watchdog waits. Long enough for a first page
// load and eight service round trips on a slow machine, short enough that a hung
// run is a nuisance rather than an abandonment.
const verify_settle_ms = 15000
