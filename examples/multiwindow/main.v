// examples/multiwindow - two windows, one document, and the routing between
// them (F0).
//
// This is the E2E proof vehicle for the half of F0 that a unit test cannot
// reach. `webview/window_test.v` proves the routing RULES with two fake eval
// sinks - an event addressed to one window never reaches the other's sink, an
// unknown label is refused, a window that is not ready is refused. What no unit
// test can prove is that those rules survive a real backend, a real WebView2
// instance per window, a real message loop per window, and one HTML document
// loaded into both. That is what this example is for, and the screenshot is the
// proof: two windows, each with its own inbox, each showing what it received.
//
// The three things it deliberately exercises, in the order they break:
//
//  1. CROSS-WINDOW PING. Window "main" emits to window "settings" BY LABEL. The
//     bug this is built to catch is silent in the sender and total in the
//     receiver: the ping would arrive at the wrong page, or nowhere, and the
//     sender's status line would still say "sent". So the sender's line says
//     only "sent" and the RECEIVER's inbox is the evidence.
//  2. BROADCAST. The opposite direction of the same mistake - if routing
//     collapsed to "everything goes to one window", broadcast is what notices.
//  3. THE LABEL. Both windows load the SAME index.html, so the page cannot know
//     which window it is from its own source. `window.vails.label` is injected
//     by the backend, and the page's badge showing the right label in the right
//     window is the proof that the per-window runtime injection works.
//
// VAILS_MULTIWINDOW_PROBE=pings|broadcast|none drives the round trip on load,
// the same example-only hook examples/services uses. It is V-side initiated on
// purpose: the proof involves two windows and a label lookup, not a button.
module main

import bridge
import config
import json2
import os
import sync
import time
import webview

// Reg is the app's window registry: the SAME WindowRegistry type the backend
// routes through, filled from `Config.on_window`. Each of the two windows is
// registered on its own thread, so this needs a lock — two threads writing one
// slice is exactly the case a `!` or a bare append would get wrong, and the
// symptom (a registry that is sometimes missing a window, only under load) is
// the kind of bug this repo refuses to ship.
@[heap]
struct Reg {
mut:
	registry webview.WindowRegistry
	mu       &sync.Mutex
}

// add registers one window. `unsafe` on the write for the same reason as
// webview_windows.c.v's WindowJob: V 0.5.2 loses mutability through a reference
// (AGENTS.md §2c), and the pointee is `#[heap]` so the write is well-founded.
fn (r &Reg) add(w &webview.Window) {
	r.mu.lock()
	unsafe {
		r.registry.add(w) or {
			eprintln('multiwindow: could not register a window: ' + err.msg())
			r.mu.unlock()
			return
		}
	}
	r.mu.unlock()
}

// count is how many windows exist so far.
fn (r &Reg) count() int {
	r.mu.lock()
	n := r.registry.count()
	r.mu.unlock()
	return n
}

// emit_to routes by label. This is the public F0 surface: a caller names a
// window and never holds a Ctx it could use by mistake.
fn (r &Reg) emit_to(label string, event string, data string) ! {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	unsafe {
		r.registry.emit_to(label, event, data)!
	}
}

// emit_all is the broadcast case.
fn (r &Reg) emit_all(event string, data string) ! {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	unsafe {
		r.registry.emit_all(event, data)!
	}
}

fn load_app_config() !config.VailsConfig {
	// Same candidate list as the other examples, so this runs from the repo
	// root, from its own directory, or next to the built binary.
	candidates := [
		'vails.json',
		os.join_path('examples', 'multiwindow', 'vails.json'),
		os.join_path(os.dir(os.executable()), 'vails.json'),
		os.join_path(os.dir(os.executable()), '..', 'examples', 'multiwindow', 'vails.json'),
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
		os.join_path('examples', 'multiwindow', asset_root, 'index.html'),
		os.join_path(os.dir(os.executable()), asset_root, 'index.html'),
	]
	for c in candidates {
		if os.exists(c) {
			return os.read_file(c)!
		}
	}
	return error('index.html not found (tried: ' + candidates.join(', ') + ')')
}

// run_probe drives the cross-window round trip once BOTH windows exist.
//
// Waiting for the count rather than sleeping a fixed time is the honest version:
// window 1's `on_window` fires before window 2 has been built, so a probe that
// emitted immediately would hit `created` state on window 2 and be refused —
// which would be the registry working correctly and the example failing for the
// wrong reason. Polling is bounded, and a timeout is reported rather than
// silently skipped, because a probe that never runs is a green screenshot of
// an empty page.
fn run_probe(reg &Reg, probe string) {
	for _ in 0 .. 100 {
		if reg.count() >= 2 {
			break
		}
		time.sleep(100 * time.millisecond)
	}
	if reg.count() < 2 {
		eprintln('multiwindow probe: only ' + reg.count().str() +
			' window(s) came up (did the second window fail to build?)')
		return
	}
	// Slack for both pages to have registered their demo:pinged listeners.
	// The listeners are registered by the page's own script, which runs after
	// on_window, so an emit that beats them is dropped by the webview with no
	// error — the same race the services example documents for its probes.
	time.sleep(700 * time.millisecond)
	match probe {
		'pings' {
			// The proof: main addresses settings, and settings' page is the
			// only thing that changes.
			reg.emit_to('settings', 'demo:pinged', '{"from":"main"}') or {
				eprintln('multiwindow probe: ping failed: ' + err.msg())
				return
			}
			time.sleep(400 * time.millisecond)
			// And the reverse direction, so neither window can be the one that
			// simply never receives.
			reg.emit_to('main', 'demo:pinged', '{"from":"settings"}') or {
				eprintln('multiwindow probe: reverse ping failed: ' + err.msg())
				return
			}
			time.sleep(300 * time.millisecond)
			reg.emit_all('demo:broadcast', '{"text":"both windows should list this"}') or {
				eprintln('multiwindow probe: broadcast failed: ' + err.msg())
				return
			}
		}
		'broadcast' {
			reg.emit_all('demo:broadcast', '{"text":"broadcast probe"}') or {
				eprintln('multiwindow probe: broadcast failed: ' + err.msg())
			}
		}
		else {}
	}
}

// PingParams is demo.ping's wire shape. A named struct rather than a map so
// json2 fills it and the capability contract is readable in the code (ADR-0010:
// params are raw JSON, and the struct is where the shape is pinned).
struct PingParams {
pub mut:
	from string
	to   string
}

struct FromParams {
pub mut:
	from string
}

fn main() {
	app_cfg := load_app_config() or {
		eprintln(err.msg())
		exit(1)
	}
	html := load_frontend_html(app_cfg.asset_root) or {
		eprintln(err.msg())
		exit(1)
	}
	reg := &Reg{
		mu: sync.new_mutex()
	}
	mut r := bridge.new_router()
	router := &r
	// The commands are the smallest useful set for the proof, and both are
	// granted to BOTH windows in vails.json — the point is routing, not
	// capability gating.
	router.register('demo.ping', fn [reg] (params string) !string {
		p := PingParams{}
		json2.decode[PingParams](params)!
		if p.to == '' {
			return error('ping needs a target window label')
		}
		reg.emit_to(p.to, 'demo:pinged', '{"from":' + json_str(p.from) + '}')!
		return '{"ok":true}'
	}) or {
		eprintln('demo.ping: ' + err.msg())
		exit(1)
	}
	router.register('demo.broadcast', fn [reg] (params string) !string {
		p := FromParams{}
		json2.decode[FromParams](params)!
		reg.emit_all('demo:broadcast', '{"text":' + json_str('from ' + p.from) + '}')!
		return '{"ok":true}'
	}) or {
		eprintln('demo.broadcast: ' + err.msg())
		exit(1)
	}
	probe := os.getenv('VAILS_MULTIWINDOW_PROBE')
	// One webview.Config per window in vails.json. This is the whole of F0's
	// config surface: the manifest already had a LIST, it just had exactly one
	// entry per app until now.
	mut cfgs := []webview.Config{}
	for w in app_cfg.windows {
		wcfg := w
		cfgs << webview.Config{
			label:     wcfg.label
			title:     wcfg.title
			width:     wcfg.width
			height:    wcfg.height
			html:      html
			router:    router
			registry:  app_cfg.to_registry()
			// F0's app-facing hook: the backend hands over its OWN &Window,
			// so the app's registry routes through the same objects the
			// backend does rather than a parallel copy that could disagree.
			on_window: fn [reg] (win &webview.Window) {
				reg.add(win)
			}
		}
	}
	// The probe is spawned rather than run inline because it waits for the
	// second window, and inline it would block the first window's loop forever.
	// A PLAIN reference, because `spawn` with a `mut ... &T` parameter crashes
	// or hangs in this V (AGENTS.md §2c).
	if probe != '' && probe != 'none' {
		spawn probe_worker(reg, probe)
	}
	webview.run_many(cfgs) or {
		eprintln(err.msg())
		exit(1)
	}
}

fn probe_worker(reg &Reg, probe string) {
	run_probe(reg, probe)
}

// json_str renders a V string as a JSON string literal. Hand-rolled because
// this example carries no build step and json2 has no one-call encoder here;
// it is fed only the `from` label the page itself sent, which is already a
// window label and therefore already validated by the registry.
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
