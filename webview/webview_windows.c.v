// webview_windows.c.v — Windows backend: webview/webview 0.12 (Edge/WebView2)
// via V C-interop. Compiled on Windows ONLY (V `_windows` suffix rule).
//
// Needs MSYS2 ucrt64: mingw-w64-ucrt-x86_64-webview (+ webview2-loader) and
// C:\msys64\ucrt64\bin on PATH (see `vails doctor`). No COM code on our
// side — the library owns the WebView2 lifecycle. window=NULL asks the
// library to create and own its window.
module webview

import bridge
import capabilities

#include <webview/webview.h>
#insert "@VMODROOT/webview/webview_shim.h"

// Shared-library consumer: WEBVIEW_API becomes __declspec(dllimport).
#flag windows -DWEBVIEW_SHARED
// Default MSYS2 location; override by symlinking your toolchain to it or
// (Phase 4) by extending `vails doctor`/build to probe more prefixes.
#flag windows -IC:/msys64/ucrt64/include
#flag windows -LC:/msys64/ucrt64/lib
#flag windows -lwebview
#flag windows -ladvapi32 -lole32 -lshell32 -lshlwapi -luser32 -lversion

fn C.webview_create(debug int, window voidptr) voidptr
fn C.webview_destroy(w voidptr) int
fn C.webview_run(w voidptr) int
fn C.webview_set_title(w voidptr, title &char) int
fn C.webview_set_size(w voidptr, width int, height int, hints int) int
fn C.webview_set_html(w voidptr, html &char) int
fn C.webview_navigate(w voidptr, url &char) int
fn C.webview_init(w voidptr, js &char) int
// const-correct wrapper, see webview_shim.h.
fn C.vails_webview_bind(w voidptr, name &char, f voidptr, arg voidptr) int
fn C.webview_return(w voidptr, id &char, status int, result &char) int
fn C.webview_eval(w voidptr, js &char) int

// Ctx crosses the C boundary as webview_bind's arg so bind_cb can reach
// the instance (for webview_return), our Router and the T2 dispatch
// context (window label + capability registry). Heap-allocated, freed
// after webview_run returns. C never dereferences it — it only ferries
// the pointer back to bind_cb — so V-managed fields are safe here.
struct Ctx {
	w      voidptr
	router &bridge.Router
	label  string
	reg    capabilities.Registry
}

// bind_cb is the single JS->V entry point on Windows. Plain top-level fn
// (no captures) so it can cross into C. The library resolves the JS
// promise from webview_return; our envelope (Response JSON for commands,
// Ack JSON for one-way events) rides inside. Dispatch runs the T2
// contract: capability gate + params validation for commands, gate only
// for events (see bridge.handle_envelope_from).
fn bind_cb(id &char, req &char, arg voidptr) {
	unsafe {
		ctx := &Ctx(arg)
		body := req.vstring()
		out := ctx.router.handle_envelope_from(body, ctx.label, ctx.reg)
		C.webview_return(ctx.w, id, 0, out.str)
	}
}

fn run_windows(cfg Config) ! {
	if cfg.router == unsafe { nil } {
		return error('vails: Config.router is required on windows')
	}
	w := C.webview_create(0, unsafe { nil })
	if w == unsafe { nil } {
		return error('vails: webview_create failed (is the WebView2 runtime installed?)')
	}
	ctx := &Ctx{
		w:      w
		router: cfg.router
		label:  cfg.label
		reg:    cfg.registry
	}
	unsafe {
		C.vails_webview_bind(w, c'vails_call', voidptr(bind_cb), voidptr(ctx))
	}
	C.webview_set_title(w, cfg.title.str)
	// WEBVIEW_HINT_NONE == 0
	C.webview_set_size(w, cfg.width, cfg.height, 0)
	C.webview_init(w, bridge.runtime_js_bound('vails_call').str)
	if cfg.url.len > 0 {
		C.webview_navigate(w, cfg.url.str)
	} else {
		html := if cfg.html.len > 0 { cfg.html } else { '<h1>Vails</h1>' }
		C.webview_set_html(w, html.str)
	}
	rc := C.webview_run(w)
	C.webview_destroy(w)
	unsafe { free(ctx) }
	if rc < 0 {
		return error('vails: webview_run failed')
	}
}
