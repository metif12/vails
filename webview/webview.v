// webview.v — OS-agnostic facade. The ONLY module allowed to call C,
// and only through its OS-gated siblings (webview_windows.c.v, …).
module webview

import bridge

pub struct Config {
pub mut:
	title  string = 'Vails App'
	width  int    = 1024
	height int    = 768
	// html is rendered directly (no server needed). url is for Phase 3 dev mode.
	html string
	url  string
	// router serves JS->V calls. Required on Windows (webview_bind arg);
	// on Linux it is accepted and reserved for the Phase 2 wiring.
	router &bridge.Router = unsafe { nil }
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
