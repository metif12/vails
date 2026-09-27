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
pub fn run(cfg Config) ! {
	cfg.validate()!
	$if windows {
		return run_windows(cfg)
	} $else $if linux {
		return run_linux(cfg)
	} $else {
		return error('vails webview supports windows and linux only')
	}
}
