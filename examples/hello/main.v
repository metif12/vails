// examples/hello - window + counter/ping bridge + ready event.
// Runs on Windows (Edge/WebView2 via webview lib) and Linux (WebKitGTK).
// Needs -gc none on Linux (Boehm GC vs WebKit subprocess fork, see ADR-0005).
// The UI is loaded from frontend/index.html (single source of truth).
module main

import application
import bridge
import os
import webview

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

fn main() {
	mut app := application.new(title: 'Hello Vails')
	app.register_service('clipboard') or { eprintln(err.msg()) }
	// Heap-allocated so every handler closure shares one address
	// (value captures would fork the state per closure).
	mut counter := &Counter{}
	mut router := bridge.new_router()
	router.register('ping', ping_handler) or { eprintln(err.msg()) }
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
	webview.run(
		label:  'main'
		title:  app.options.title
		width:  app.options.width
		router: &router
		html:   html
	) or {
		eprintln(err.msg())
		exit(1)
	}
}
