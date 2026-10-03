// webview.v — OS-agnostic facade. The ONLY module allowed to call C,
// and only through its OS-gated siblings (webview_windows.c.v, …).
module webview

import bridge
import capabilities

pub struct Config {
pub mut:
	// label identifies the window for capability checks (Tauri-style).
	// Distinct from title: title is shown, label is the security identity.
	label  string = 'main'
	title  string = 'Vails App'
	width  int    = 1024
	height int    = 768
	// html is rendered directly (no server needed). url is for Phase 3 dev mode.
	html string
	url  string
	// router serves JS->V calls. Required on Windows (webview_bind arg);
	// on Linux it is accepted and reserved for the Phase 2 wiring.
	router &bridge.Router = unsafe { nil }
	// registry gates JS->V dispatch (T2): the native backend passes label
	// with every incoming body into Router.handle_envelope_from. Empty
	// denies everything (secure by default); build it from vails.json via
	// config.VailsConfig.to_registry(). Linux enforcement lands with its
	// transport wiring (ADR-0004); until then this field is Windows-only.
	registry capabilities.Registry
	// on_ready hands the window's runtime handle (Ctx) to the app once the
	// native window exists, before the event loop starts. Phase 5 services
	// need it: they push events to the frontend and parent native UI to
	// this window. Optional: without it a window still runs, it just has
	// no services wired to it.
	on_ready ?fn (ctx Ctx)
	// on_window hands the app the backend's OWN &Window, once per window, at
	// the same moment `on_ready` fires. It exists because F0 makes windows a
	// set and an app has to be able to *address* them, and the only object that
	// carries the address is this one: `Ctx` knows its label but not its
	// `Window`, and building the app's own parallel `&Window`s would mean two
	// registries that can disagree about which window is which.
	//
	// An app that wants to emit to a window by label keeps its own
	// `WindowRegistry`, adds each window here, and calls `emit_to` — which is
	// the routing API `window_test.v` pins with two sinks.
	//
	// It fires BEFORE `on_ready` for the same window, so an app that installs
	// services in on_ready has its registry entry already in place. It does
	// NOT mean the other windows exist: with three windows, window 1's
	// `on_window` runs before window 3 is registered, so anything that emits
	// across windows has to wait for the count it needs. That is the
	// `created`/`ready` lifecycle being honest rather than surprising.
	on_window ?fn (w &Window)
}

// document returns the HTML to load, with the default CSP injected
// (T7/ADR-0012). Empty in URL mode (dev server owns the document) and
// empty when no HTML was given — the backends fall back to a placeholder.
// Pure-V so the injection is unit-tested without opening a window.
pub fn (cfg Config) document() string {
	if cfg.url != '' {
		return ''
	}
	if cfg.html == '' {
		return ''
	}
	return inject_csp(cfg.html)
}

// validate rejects nonsense configs before any native call so mistakes
// surface identically on every OS (unit-testable on Windows too).
pub fn (cfg Config) validate() ! {
	if cfg.title == '' {
		return error('vails: window title must not be empty')
	}
	if cfg.width <= 0 || cfg.height <= 0 {
		return error('vails: window size must be positive')
	}
}

// run blocks until the window closes. Backends live behind $if so every
// platform compiles only its own C file (Phase 6 adds macOS).
//
// This is the one-window case of run_many, kept as its own name because every
// existing example calls it and because "one window, one call" is the shape
// almost every app has. An app that wants a second window calls run_many with
// both configs; there is no `open()` on a running app, and there is not going
// to be one — a window opened after the loop is running has to be built on a
// thread that does not exist yet, which is a different and much larger feature
// than F0.
pub fn run(cfg Config) ! {
	cfg.validate()!
	$if windows {
		return run_windows([cfg])
	} $else $if linux {
		return run_linux([cfg])
	} $else {
		return error('vails webview supports windows and linux only')
	}
}

// check_windows refuses every misconfiguration that would otherwise become a
// half-built app, before any native window exists.
//
// It is a separate function rather than an inline block in `run_many` for one
// concrete reason: this is where the rules are testable. A unit test can call
// `check_windows` with two well-formed windows and get a verdict without opening
// either of them. `run_many` itself is not a thing a unit test may call with two
// windows — doing that puts two real WebView2 windows on the test machine, which
// is an E2E action (examples/multiwindow) wearing a unit test's clothes.
//
// Three rules, all "refuse before anything is built" rather than "clean up
// afterwards": at least one window; every config valid on its own; and no two
// windows sharing a label. The third is the non-obvious one — two windows with
// one label share a capability identity (T1), so a command granted to `main`
// would also be allowed from the second, and `emit_to("main")` would have two
// destinations and no way to choose.
pub fn check_windows(cfgs []Config) ! {
	if cfgs.len == 0 {
		return error('vails: run_many needs at least one window')
	}
	for cfg in cfgs {
		cfg.validate()!
	}
	// Duplicate detection here rather than in the backend: the registry would
	// catch it too, but only after the earlier windows had been built, and "the
	// app opened one window and then printed an error" is a worse failure than
	// "the app printed an error".
	for i in 0 .. cfgs.len {
		for j in 0 .. cfgs.len {
			if i != j && cfgs[i].label == cfgs[j].label {
				return error('vails: two windows share the label "' +
					cfgs[i].label + '" (labels are the capability identity and ' +
					'the event route, so they must be unique)')
			}
		}
	}
}

// run_many opens every window in cfgs and blocks until they have all closed.
//
// This is F0's entry point and the reason `VailsConfig.windows` being a *list*
// was never multi-window: a list of configs is all F0 needed from config, and
// everything else (the registry, the routing, the per-window Ctx) is here.
//
// ## What is proven, and what is written but unproven
//
// THE RULES ARE DONE AND PROVEN: `webview/window.v` has the registry, the
// per-label routing and the lifecycle, `webview/window_test.v` proves with two
// fake eval sinks that an event addressed to one window never reaches the
// other's, and both backends build N windows' worth of `Ctx`, `MainThread`,
// label and runtime injection.
//
// N WINDOWS ON WINDOWS IS UNBLOCKED, AND IT WAS A COM APARTMENT. WebView2 ties
// three things to the thread that called `webview_create` — the HWND, the COM
// apartment, and the message pump — and `webview_run` blocks in that pump, so N
// windows means N threads. A `spawn`ed thread has **no COM apartment at all**,
// and WebView2's failure in that state is silent right up to the first
// dispatch: the window is created, the page renders, the library then REFUSES a
// `webview_dispatch` to it, and the process dies. That was the measured failure
// behind the refusal this function used to carry.
//
// `com_enter` in `webview_windows.c.v` now gives every window's thread its own
// `COINIT_APARTMENTTHREADED` apartment before `webview_create` and gives it back
// after `webview_destroy`, so the refusal is gone.
//
// **AND IT IS STILL NOT PROVEN, WHICH IS THE HONEST PART.** The apartment is the
// documented requirement and the two-line answer to the measured failure, but
// nobody has watched two windows open on Windows: this machine's `webview` test
// module crashes the host, so the verification runs have not happened here. So
// the two-window path is **written and type-checked, not observed**. The run that
// settles it is `examples/multiwindow` with `VAILS_MULTIWINDOW_PROBE=pings`, and
// until someone does it and puts the screenshot in tests/e2e_windows, this
// paragraph is the claim and the screenshot would be the proof.
//
// Linux takes N windows today: GTK is one process-wide main loop with any
// number of GtkWindows in it, so `webview_linux_shim.h` counts open windows and
// quits when the last one closes. It is structurally correct and has not been
// run in a real session from this machine.
//
// Rules enforced before any window appears, so a misconfiguration is never a
// half-built app: at least one config, and every label non-empty and unique
// (window.v's registry refuses both, and a duplicate label is a capability hole
// as well as an ambiguous route).
pub fn run_many(cfgs []Config) ! {
	check_windows(cfgs)!
	$if windows {
		return run_windows(cfgs)
	} $else $if linux {
		return run_linux(cfgs)
	} $else {
		return error('vails webview supports windows and linux only')
	}
}
