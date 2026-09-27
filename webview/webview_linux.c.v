// webview_linux.c.v — Linux backend: WebKitGTK via V C-interop.
// Compiled on Linux ONLY (V `_linux` suffix rule); skipped on Windows/macOS.
//
// Phase 1 job: verify these signatures against the installed headers
// (libgtk-3-dev, libwebkit2gtk-4.1-dev) with a real `v run` and record the
// working set in docs/ADR. Declarations below are the minimal GTK+WebKit
// surface; g_signal_connect is a C macro so we use g_signal_connect_data.
module webview

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

#pkgconfig gtk+-3.0
#pkgconfig webkit2gtk-4.1

fn C.gtk_init(argc &int, argv &&char)
fn C.gtk_main()
fn C.gtk_main_quit()
fn C.gtk_window_new(type_ int) voidptr
fn C.gtk_window_set_title(window voidptr, title &char)
fn C.gtk_window_set_default_size(window voidptr, width int, height int)
fn C.gtk_widget_show_all(widget voidptr)
fn C.gtk_container_add(container voidptr, widget voidptr)
fn C.webkit_web_view_new() voidptr
fn C.webkit_web_view_load_html(view voidptr, content &char, base_uri &char)
fn C.webkit_web_view_load_uri(view voidptr, uri &char)
fn C.g_signal_connect_data(instance voidptr, signal &char, handler voidptr, data voidptr, destroy_data voidptr, connect_flags int) u64
// --- Phase 2 transport (ADR-0004), wired after the Phase 1 window PoC ---
// V -> JS: evaluate a snippet built by bridge.resolve_js / events.to_js.
// 4.0/4.1-stable spelling; the newer evaluate_javascript (4.1-only) is NOT
// used so the code also builds against webkit2gtk-4.0 headers.
fn C.webkit_web_view_run_javascript(view voidptr, script &char, cancellable voidptr, callback voidptr, user_data voidptr)
// JS -> V: a "vails" script-message handler; the C callback forwards the
// body string to bridge.Router.handle_message. Receiving needs the
// script-message-received signal + WebKitJavascriptResult/JSC extraction,
// verified on real Linux in Phase 2 (see tests/e2e_linux/README.md).
fn C.webkit_web_view_get_user_content_manager(view voidptr) voidptr
// NOTE: gboolean is a 4-byte C int — never declare it as V bool.
fn C.webkit_user_content_manager_register_script_message_handler(manager voidptr, name &char) int

fn C.gtk_widget_get_visible(widget voidptr) int
// The GdkWindow of our top-level widget: services use it as the parent of
// their own native UI. NULL until the widget is realized, so it must be
// read after gtk_widget_show_all.
fn C.gdk_window_get_window(widget voidptr) voidptr
// V -> JS delivery: evaluates a snippet built by bridge.resolve_js /
// events.to_js. The callback is a no-op trampoline (the result is unused);
// WebKit requires a non-null function pointer here.
fn C.webkit_web_view_run_javascript(view voidptr, script &char, cancellable voidptr, callback voidptr, user_data voidptr)

// destroy_cb runs on window close and stops the GTK main loop.
// Plain top-level fn (no captures) so it can cross the C boundary.
fn destroy_cb() {
	C.gtk_main_quit()
}

// js_trampoline is the WebKitJavaScriptFinishedCallback. It runs on the
// main loop after the snippet was evaluated; nothing to do there, but C
// requires a non-null function pointer.
fn js_trampoline(_res voidptr, _data voidptr) {}

fn run_linux(cfg Config) ! {
	argc := 0
	C.gtk_init(&argc, unsafe { nil })
	// GTK_WINDOW_TOPLEVEL == 0
	window := C.gtk_window_new(0)
	if window == unsafe { nil } {
		return error('vails: gtk_window_new failed')
	}
	C.gtk_window_set_title(window, cfg.title.str)
	C.gtk_window_set_default_size(window, cfg.width, cfg.height)
	view := C.webkit_web_view_new()
	if view == unsafe { nil } {
		return error('vails: webkit_web_view_new failed')
	}
	C.gtk_container_add(window, view)
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
	unsafe {
		C.g_signal_connect_data(window, c'destroy', voidptr(destroy_cb), nil, nil, 0)
	}
	C.gtk_widget_show_all(window)
	// Services (Phase 5) get the eval path + the GdkWindow as parent.
	// Runs after show_all: gdk_window_get_window returns NULL until the
	// widget is realized, and before gtk_main takes over the loop.
	if on_ready := cfg.on_ready {
		on_ready(Ctx{
			label:   cfg.label
			eval_fn: fn [view] (js string) ! {
				unsafe {
					C.webkit_web_view_run_javascript(view, js.str, nil,
						voidptr(js_trampoline), nil)
				}
			}
			parent:  C.gdk_window_get_window(window)
		})
	}
	C.gtk_main()
}
