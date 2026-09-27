// webview_linux_shim.h — const-correct adapters for two WebKitGTK calls.
//
// Same reason as webview_shim.h (the Windows adapter): V cannot express the
// C types these calls want, and gcc 14+ rejects the mismatch as an *error*
// rather than a warning. On Linux the mismatch that actually bit was
// `webkit_web_view_run_javascript`'s completion callback — a V function
// pointer is not a `WebKitJavaScriptFinishedCallback` — so the trampoline
// lives here, in C, with WebKit's exact signature.
//
// Two more facts this header encodes, both learned the hard way (ADR-0015):
//
//   - the V side registers its zero-argument trampoline once
//     (vails_js_set_target), because a V function's C symbol name is
//     module-mangled and C cannot call it by name;
//   - `gdk_window_get_window` is reached through `gtk_widget_get_window`
//     instead: the same GdkWindow, from a library we already link, with no
//     dependency on gdk's headers being pulled in by our own #include order.
//
// Included via `#insert "@VMODROOT/webview/webview_linux_shim.h"`, so no
// extra -I flag is needed. Include-guarded because a header that defines
// statics must not be inserted twice into one translation unit.
#ifndef VAILS_LINUX_SHIM_H
#define VAILS_LINUX_SHIM_H

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

// The V trampoline takes no arguments; WebKit's callback takes three. The C
// function below absorbs WebKit's arguments and calls the V one.
//
// The callback type is GAsyncReadyCallback, not the WebKit1-era
// WebKitJavaScriptFinishedCallback: webkit_web_view_run_javascript has taken
// a plain GAsyncReadyCallback since 2.40, and guessing the old name is what
// made this header fail to compile the first time (ADR-0015).
typedef void (*vails_js_fn)(void);
static vails_js_fn vails_js_target = NULL;

static void vails_js_finished(GObject *source, GAsyncResult *result, gpointer data) {
	(void)source;
	(void)result;
	(void)data;
	if (vails_js_target) {
		vails_js_target();
	}
}

static inline void vails_js_set_target(void *js_fn) {
	vails_js_target = (vails_js_fn)js_fn;
}

// vails_run_javascript is the V -> JS direction (Phase 5, ADR-0014): evaluate
// a snippet built by bridge.resolve_js / events.to_js and ignore the result.
// The 4.0/4.1-stable spelling; the newer evaluate_javascript is not used so
// this also builds against older webkit2gtk-4.0 headers. WebKit marks
// run_javascript deprecated in favour of it - a warning we accept for the
// wider header compatibility.
static inline void vails_run_javascript(WebKitWebView *view, const char *script) {
	webkit_web_view_run_javascript(view, script, NULL, vails_js_finished, NULL);
}

#endif // VAILS_LINUX_SHIM_H
