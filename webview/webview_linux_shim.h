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

// --- JS -> V transport (the Phase 2 leftover, closed in ADR-0015) -----------
//
// Two facts about webkit2gtk 4.1 that the headers do not tell you and that
// cost time to discover (both verified against the installed 2.52 headers and
// its exported symbols):
//
//  1. `script-message-received` delivers a **WebKitJavascriptResult**, not the
//     WebKitScriptMessage the doc comment shows: WebKitScriptMessage and its
//     `webkit_script_message_get_body` are not exported at all in this
//     version. A GSignalQuery on the signal confirms
//     `param 0: WebKitJavascriptResult`.
//  2. WebKitJavascriptResult has no `get_context` either, and the JSC getter
//     in this JavaScriptCore takes only the value: `jsc_value_to_string`
//     derives the context itself. (WebKit's own header example still shows
//     the two-argument form from an older JSC, which is the second compile
//     error this shim hit.)
//
// So the extraction is two public calls, and it lives here because V has no
// JSC bindings at all.
static char *vails_message_body(WebKitJavascriptResult *result) {
	if (!result) {
		return NULL;
	}
	JSCValue *value = webkit_javascript_result_get_js_value(result);
	if (!value || !jsc_value_is_string(value)) {
		return NULL;
	}
	// Newly allocated: the caller frees it with g_free.
	return jsc_value_to_string(value);
}

// The signal handler needs WebKit's exact signature, and it must reach a V
// function: its C symbol name is module-mangled, so the address is registered
// once and the data pointer travels through untouched.
//
// The signature is three parameters, not two: a GObject handler receives the
// emitting instance first. Getting that wrong passes the WebKitUserContent-
// Manager where the result should be, and jsc_value_is_string() then asserts
// "JSC_IS_VALUE(value) failed" - which is exactly what happened here before a
// probe with a g_signal_query + a G_OBJECT_TYPE_NAME printout settled it.
typedef void (*vails_message_fn)(WebKitJavascriptResult *result, void *data);
static vails_message_fn vails_message_target = NULL;

static void vails_message_received(WebKitUserContentManager *manager,
                                   WebKitJavascriptResult *result, gpointer data) {
	(void)manager;
	if (vails_message_target) {
		vails_message_target(result, data);
	}
}

static inline void vails_message_set_target(void *message_fn) {
	vails_message_target = (vails_message_fn)message_fn;
}

// vails_message_connect wires both halves in the order WebKit's own
// documentation recommends: connect the signal *before* registering the
// channel, so no message can arrive with nobody listening.
static inline gboolean vails_message_connect(WebKitUserContentManager *manager,
                                             const char *name, void *data) {
	g_signal_connect(manager, "script-message-received", G_CALLBACK(vails_message_received),
	                 data);
	return webkit_user_content_manager_register_script_message_handler(manager, name);
}

// vails_add_runtime injects the bridge runtime (window.vails) as a user script
// at document start. This is Linux's answer to the webview library's
// webview_init: without it the page has no bridge at all and every example
// renders in preview mode.
//
// The 2.52 spelling takes an injected-frames enum (no length argument) and
// WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START - the older
// WEBKIT_USER_SCRIPT_INJECTION_START_FRAME name is gone, which is the third
// compile error this shim hit. The three API facts above are all in
// /usr/include/webkitgtk-4.1/webkit/WebKitUserContent.h; read them, do not
// remember them.
static inline void vails_add_runtime(WebKitUserContentManager *manager, const char *js) {
	WebKitUserScript *script =
	    webkit_user_script_new(js, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
	                           WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
	webkit_user_content_manager_add_script(manager, script);
	webkit_user_script_unref(script);
}

#endif // VAILS_LINUX_SHIM_H
