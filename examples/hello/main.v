// examples/hello - window + counter/ping bridge + ready event.
// Runs on Windows (Edge/WebView2 via webview lib) and Linux (WebKitGTK).
// Needs -gc none on Linux (Boehm GC vs WebKit subprocess fork, see ADR-0005).
// The UI is loaded from frontend/index.html (single source of truth).
module main

import application
import bridge
import config
import os
import webview

// load_app_config reads vails.json (single source of truth for window
// geometry/label plus capability grants). Missing file falls back to
// defaults so ad-hoc invocations keep working; an invalid file fails
// fast. The grants are enforced on the native dispatch path via
// Config.registry (T2); defaults deny everything.
fn load_app_config() config.VailsConfig {
	candidates := [
		'vails.json',
		os.join_path('examples', 'hello', 'vails.json'),
		os.join_path(os.dir(os.executable()), 'vails.json'),
		os.join_path(os.dir(os.executable()), '..', 'examples', 'hello', 'vails.json'),
	]
	for c in candidates {
		if os.exists(c) {
			return config.load(c) or {
				eprintln('invalid ' + c + ': ' + err.msg())
				exit(1)
			}
		}
	}
	return config.default_config('Hello Vails')
}

// load_frontend_html reads the hello UI from disk. It probes the likely
// working directories (example dir, repo root, exe dir) so both
// `v run ./examples/hello` and `v run ./hello` style invocations work.
fn load_frontend_html() !string {
	candidates := [
		os.join_path('frontend', 'index.html'),
		os.join_path('examples', 'hello', 'frontend', 'index.html'),
		os.join_path(os.dir(os.executable()), 'frontend', 'index.html'),
		os.join_path(os.dir(os.executable()), '..', 'examples', 'hello', 'frontend',
			'index.html'),
	]
	for c in candidates {
		if os.exists(c) {
			return os.read_file(c)!
		}
	}
	return error('frontend/index.html not found (tried: ' + candidates.join(', ') + ')')
}

struct Counter {
mut:
	value int
}

fn (c Counter) get() string {
	return c.value.str()
}

fn (mut c Counter) inc() string {
	c.value++
	return c.value.str()
}

fn (mut c Counter) dec() string {
	c.value--
	return c.value.str()
}

fn (mut c Counter) reset() string {
	c.value = 0
	return c.value.str()
}

fn ping_handler(_ string) !string {
	return 'pong'
}

// Handlers run on the webview main thread (T2 threading rule): they must
// stay fast and non-blocking. Heavy work goes through `spawn` with the
// result delivered back as an event (see events.to_js + ADR-0010).
fn main() {
	mut app := application.new(title: 'Hello Vails')
	app.register_service('clipboard') or { eprintln(err.msg()) }
	// Heap-allocated so every handler closure shares one address
	// (value captures would fork the state per closure).
	mut counter := &Counter{}
	mut router := bridge.new_router()
	// 'ping' takes no arguments: the T2 params validator rejects anything
	// else with a standard 'bad params: …' error (promise reject in JS).
	router.register_validated('ping', bridge.validate_empty, ping_handler) or {
		eprintln(err.msg())
	}
	router.register('counter_get', fn [counter] (_ string) !string {
		return counter.get()
	}) or { eprintln(err.msg()) }
	router.register('counter_inc', fn [counter] (_ string) !string {
		return counter.inc()
	}) or { eprintln(err.msg()) }
	router.register('counter_dec', fn [counter] (_ string) !string {
		return counter.dec()
	}) or { eprintln(err.msg()) }
	router.register('counter_reset', fn [counter] (_ string) !string {
		return counter.reset()
	}) or { eprintln(err.msg()) }
	html := load_frontend_html() or {
		eprintln(err.msg())
		exit(1)
	}
	app_cfg := load_app_config()
	w := app_cfg.window('main') or {
		eprintln(err.msg())
		exit(1)
	}
	// T2 enforcement: the stored capability grants gate every JS->V call
	// in the native backend (Windows bind_cb → handle_envelope_from).
	// An empty capabilities list denies everything by default.
	reg := app_cfg.to_registry()
	webview.run(
		label:    w.label
		title:    w.title
		width:    w.width
		height:   w.height
		router:   &router
		registry: reg
		html:     html
	) or {
		eprintln(err.msg())
		exit(1)
	}
}
