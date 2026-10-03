// webview_linux.c.v — Linux backend: WebKitGTK via V C-interop.
// Compiled on Linux ONLY (V `_linux` suffix rule); skipped on Windows/macOS.
//
// Phase 1 job: verify these signatures against the installed headers
// (libgtk-3-dev, libwebkit2gtk-4.1-dev) with a real `v run` and record the
// working set in docs/ADR. Declarations below are the minimal GTK+WebKit
// surface; g_signal_connect is a C macro so we use g_signal_connect_data.
//
// The parts that need a C type V cannot express (WebKit's two callback
// signatures, the JSC value extraction, the runtime user script) live in
// webview_linux_shim.h, the same division of labour as webview_shim.h on
// Windows. Everything here is the V-side glue.
module webview

import bridge
import capabilities

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#insert "@VMODROOT/webview/webview_linux_shim.h"

#pkgconfig gtk+-3.0
#pkgconfig webkit2gtk-4.1

fn C.vails_js_set_target(js_fn voidptr)
fn C.vails_run_javascript(view voidptr, script &char)
fn C.vails_message_set_target(message_fn voidptr)
fn C.vails_message_connect(manager voidptr, name &char, data voidptr) int
fn C.vails_message_body(result voidptr) &char
fn C.vails_add_runtime(manager voidptr, js &char)
fn C.g_free(mem voidptr)

fn C.gtk_init(argc &int, argv &&char)
fn C.gtk_main()
fn C.gtk_main_quit()
fn C.gtk_window_new(type_ int) voidptr
fn C.gtk_window_set_title(window voidptr, title &char)
fn C.gtk_window_set_default_size(window voidptr, width int, height int)
fn C.gtk_widget_show_all(widget voidptr)
fn C.gtk_container_add(container voidptr, widget voidptr)
fn C.gtk_box_new(orientation int, spacing int) voidptr
fn C.gtk_box_pack_start(box voidptr, child voidptr, expand bool, fill bool, padding int)
fn C.webkit_web_view_new() voidptr
fn C.webkit_web_view_load_html(view voidptr, content &char, base_uri &char)
fn C.webkit_web_view_load_uri(view voidptr, uri &char)
fn C.g_signal_connect_data(instance voidptr, signal &char, handler voidptr, data voidptr, destroy_data voidptr, connect_flags int) u64
// --- Phase 2 transport (ADR-0004), wired after the Phase 1 window PoC ---
// V -> JS: bridge.resolve_js / events.to_js snippets go through
// vails_run_javascript (webview_linux_shim.h), which owns WebKit's
// callback-typed parameter. The 4.0/4.1-stable spelling; the newer
// evaluate_javascript (4.1-only) is not used so this also builds against
// webkit2gtk-4.0 headers.
fn C.vails_run_javascript(view voidptr, script &char)
// JS -> V: a "vails" script-message handler; the C callback forwards the
// body string to bridge.Router.handle_message. Receiving needs the
// script-message-received signal + WebKitJavascriptResult/JSC extraction,
// verified on real Linux in Phase 2 (see tests/e2e_linux/README.md).
fn C.webkit_web_view_get_user_content_manager(view voidptr) voidptr
// NOTE: gboolean is a 4-byte C int — never declare it as V bool.
fn C.webkit_user_content_manager_register_script_message_handler(manager voidptr, name &char) int

fn C.gtk_widget_get_visible(widget voidptr) int
// The GdkWindow of our top-level widget: services use it as the parent of
// their own native UI. gtk_widget_get_window is the GTK spelling of the same
// window gdk_window_get_window returns, and it needs no gdk header of our
// own (which is where the Linux build picked up an implicit declaration
// before - ADR-0015). NULL until the widget is realized, so it must be read
// after gtk_widget_show_all.
fn C.gtk_widget_get_window(widget voidptr) voidptr

// GTK_ORIENTATION_VERTICAL (1) and GDK_WINDOW_TYPE_HINT (0) as literals
// (AGENTS.md §2). gtk_window_new is called with 0, which is GTK_WINDOW_TOPLEVEL.
const gtk_orientation_vertical = 1
const gtk_window_toplevel = 0

// destroy_cb runs on window close and stops the GTK main loop.
// Plain top-level fn (no captures) so it can cross the C boundary.
// destroy_cb runs on window close. It hands over to the shim's counter, which
// quits the GTK main loop only when the LAST window closed (F0) — the single
// window version called gtk_main_quit unconditionally, which was correct with
// one window and is "closing the settings window quits the app" with two.
//
// Plain top-level fn (no captures) so it can cross the C boundary.
fn destroy_cb() {
	C.vails_window_closed()
}

// js_trampoline is the V end of the V->JS completion callback. It runs on the
// main loop after the snippet was evaluated; nothing to do there, but the
// shim needs a real function to call. Plain top-level fn (no captures) and
// no parameters, because a V function pointer is not a
// GAsyncReadyCallback - the shim adapts it.
fn js_trampoline() {}

// DispatchCtx crosses into the script-message callback the way BindCtx does
// on Windows (webview_windows.c.v): the signal carries an opaque user_data,
// and C never dereferences it - it only ferries the pointer back to the
// callback. Heap-allocated, freed after gtk_main returns.
struct DispatchCtx {
	view    voidptr
	router  &bridge.Router
	label   string
	reg     capabilities.Registry
	runtime string
}

// message_cb is the single JS->V entry point on Linux. It runs on the GTK main
// loop (the same thread the handlers run on, ADR-0010) and dispatches the T2
// contract, exactly like bind_cb on Windows:
//
//	page -> vails.call -> postMessage -> here -> Router.handle_envelope_from
//	     -> __resolve (evaluated back into the page)
//
// The reply rides out through vails_run_javascript because WebKit's script
// message handler has no return value: Linux is the "raw WebKitGTK path" of
// ADR-0004, Windows is the bound-function path.
fn message_cb(result voidptr, data voidptr) {
	ctx := &DispatchCtx(data)
	body := unsafe { C.vails_message_body(result) }
	if body == unsafe { nil } {
		// Not a string payload: nothing to dispatch, and no reply the page
		// could read. The page's promise then never settles, which is the same
		// behaviour as a dropped native callback on Windows.
		return
	}
	// cstring_to_vstring COPIES. `vstring()` does not - it reuses the C block
	// (V's own comment: "the memory block pointed by cp is reused, not
	// copied"), so reading it after the g_free below would be a
	// use-after-free. That bug shipped for one debug run and produced the most
	// confusing error in this project ("Invalid json: unknown value kind" on a
	// body that had printed correctly one line earlier).
	raw := unsafe { cstring_to_vstring(body) }
	unsafe { C.g_free(voidptr(body)) }
	out := ctx.router.handle_envelope_from(raw, ctx.label, ctx.reg)
	unsafe {
		C.vails_run_javascript(ctx.view, bridge.resolve_json(out).str)
	}
}

// build_linux_window constructs one window and everything hanging off it, and
// fills in the registry's Window. Deliberately NOT a thread: GTK wants one
// main loop for the process, so N windows are N GtkWindows in one loop
// (webview_linux_shim.h, "N windows on ONE GTK main loop").
//
// Returns the DispatchCtx so run_linux can free it after the loop ends. That
// is one context per window, each carrying ITS OWN label, which is what makes
// a command called from the settings window gated against the settings
// window's capabilities (F0 makes that load-bearing).
fn build_linux_window(cfg Config, win &Window) &DispatchCtx {
	// GTK_WINDOW_TOPLEVEL == 0
	window := C.gtk_window_new(0)
	if window == unsafe { nil } {
		return unsafe { nil }
	}
	C.gtk_window_set_title(window, cfg.title.str)
	C.gtk_window_set_default_size(window, cfg.width, cfg.height)
	view := C.webkit_web_view_new()
	if view == unsafe { nil } {
		return unsafe { nil }
	}
	// The bridge: a heap context the signal callback ferries back to us, the
	// script-message channel, and the runtime injected as a user script (the
	// Linux answer to the webview library's webview_init). Without this the
	// page has no window.vails at all and every example renders in preview
	// mode - which is exactly how this was found.
	ctx := &DispatchCtx{
		view:   view
		router: cfg.router
		label:  cfg.label
		reg:    cfg.registry
	}
	unsafe {
		// The shim's trampoline needs the V function's address before any eval
		// can happen. Done per window rather than once per process: it is the
		// same address every time, and doing it here means a window built later
		// cannot be the one that forgot.
		C.vails_js_set_target(voidptr(js_trampoline))
		C.vails_message_set_target(voidptr(message_cb))
		manager := C.webkit_web_view_get_user_content_manager(view)
		if C.vails_message_connect(manager, c'vails', voidptr(ctx)) == 0 {
			free(ctx)
			return unsafe { nil }
		}
		C.vails_add_runtime(manager, label_js(bridge.runtime_js(), cfg.label))
		C.g_signal_connect_data(window, c'destroy', voidptr(destroy_cb), nil, nil, 0)
	}
	// The webview goes into a vertical box rather than straight into the
	// window. A GtkWindow holds exactly one child, so with the view as that
	// child a window menu bar (menu.set_menu) has nowhere to go and would have
	// to rebuild the window's whole child tree. The box makes the layout
	// explicit instead: row 0 is reserved for a menu bar and the view takes the
	// rest. With no bar ever set, the view still gets the full client area,
	// because the box has no other visible child (expand + fill, no padding).
	// GTK_ORIENTATION_VERTICAL is 1.
	box := C.gtk_box_new(gtk_orientation_vertical, 0)
	C.gtk_container_add(window, box)
	C.gtk_box_pack_start(box, view, true, true, 0)
	if cfg.url.len > 0 {
		C.webkit_web_view_load_uri(view, cfg.url.str)
	} else {
		// document() injects the default CSP (T7) into the served HTML.
		mut html := cfg.document()
		if html == '' {
			html = '<h1>Vails</h1>'
		}
		C.webkit_web_view_load_html(view, html.str, unsafe { nil })
	}
	// Services (Phase 5) get the eval path, the GdkWindow as `parent` and the
	// GtkWindow as `toplevel`. Runs before the loop starts: the GdkWindow is
	// NULL until the widget is realized.
	//
	// The job seam (U0) is created here too and carried on the same Ctx, and
	// the Ctx is built into a local first so this file reads the same way the
	// Windows one does. install_wakeup is a no-op on Linux today — the
	// g_idle_add half is unwritten, and post_to_main refuses by name — but the
	// call is already in the right place, so writing that half changes
	// install_wakeup and post_to_main only, not this backend.
	mt := new_main_thread()
	wctx := Ctx{
		label:    cfg.label
		eval_fn:  fn [view] (js string) ! {
			unsafe {
				C.vails_run_javascript(view, js.str)
			}
		}
		parent:   C.gtk_widget_get_window(window)
		toplevel: window
		main:     mt
	}
	mt.install_wakeup(wctx) or {
		eprintln('webview[' + cfg.label + ']: the main-thread job wakeup is ' +
			'unavailable: ' + err.msg())
	}
	win.ctx = wctx
	win.native = view
	win.state = .ready
	// on_window BEFORE on_ready, for the same reason as the Windows backend.
	if on_window := cfg.on_window {
		on_window(win)
	}
	if on_ready := cfg.on_ready {
		on_ready(wctx)
	}
	win.state = .running
	return ctx
}

// run_linux builds every window, then runs ONE GTK main loop for all of them.
//
// The loop ends when the last window closes, not the first — see destroy_cb and
// the shim's counter. The single-window case is this with a one-element list,
// which is why `run` and `run_many` share this backend.
fn run_linux(cfgs []Config) ! {
	argc := 0
	C.gtk_init(&argc, unsafe { nil })
	// The registry is built and validated before a single GtkWindow exists, so
	// a duplicate or empty label is refused without anything appearing on
	// screen. An app that asked for two windows called "main" should not get
	// one window up and then an error.
	reg := new_registry()
	for cfg in cfgs {
		cfg.validate()!
		reg.add(new_window(cfg.label)) or { return err }
	}
	// Build them all before the loop starts: on_ready for window 2 must not run
	// while window 1's loop is already spinning, and GTK wants every window
	// realized before the first iteration.
	contexts := []&DispatchCtx{}
	for cfg in cfgs {
		win := reg.find(cfg.label)
		C.vails_window_opened()
		ctx := build_linux_window(cfg, win)
		if ctx == unsafe { nil } {
			// Roll the counter back: a run that never reaches gtk_main must
			// not leave the process believing a window is still open.
			C.vails_window_closed()
			return error('vails: could not build the window "' + cfg.label + '"')
		}
		contexts << ctx
	}
	for cfg in cfgs {
		win := reg.find(cfg.label)
		unsafe {
			C.gtk_widget_show_all(win.native)
		}
	}
	C.gtk_main()
	// The loop has returned, so no window is left: mark them all closed and
	// free the per-window dispatch contexts. The eval closures died with their
	// views, so the registry's Windows are only labels now.
	for cfg in cfgs {
		reg.find(cfg.label).state = .closed
	}
	for c in contexts {
		unsafe {
			free(c)
		}
	}
}
