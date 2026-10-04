// webview_shim.h — const-correct adapter for webview_bind, plus the
// cross-thread eval F0 needs.
//
// V fn params cannot express `const char *`, and gcc 14+ rejects the
// resulting function-pointer mismatch as an error. This adapter takes the
// callback as void* and casts to the library's exact callback type — safe
// because our callback (bind_cb) never mutates id/req.
//
// Included via `#insert "@VMODROOT/webview/webview_shim.h"` so no extra -I
// flag is needed.
#include <stdlib.h>
#include <string.h>
#include <webview/webview.h>

typedef void (*vails_bind_fn)(const char *id, const char *req, void *arg);

static inline webview_error_t vails_webview_bind(webview_t w, const char *name, void *fn,
                                                 void *arg) {
	return webview_bind(w, name, (vails_bind_fn)fn, arg);
}

// --- F0: evaluating on a specific window's thread ---
//
// `webview_eval` is only valid on the thread that owns the webview, and with one
// window per thread (F0) "the thread that owns it" is a property of the WINDOW,
// not of whoever happens to be calling. So V never calls webview_eval off the
// owning thread. It used to reach the owning thread through the library's
// `webview_dispatch`, and that was wrong twice over, both times measured:
//
//  1. `webview_dispatch` returns a webview_error_t, NOT a bool, and success is
//     `>= 0` with WEBVIEW_ERROR_OK == 0. So `if (!webview_dispatch(...))` takes
//     the failure branch ON SUCCESS - it freed the job the window thread was
//     about to run (a use-after-free) and then reported the emit as refused.
//     Nothing in the single-window era hit this, because nothing dispatched.
//
//  2. With the check corrected, the dispatch itself crashed: 0xC0000005, access
//     violation, faulting module `libwebview-0.12.dll`, thrown from inside the
//     library on the CALLING thread. `webview_dispatch` needs a COM apartment
//     where it is called, and post_to_main's caller is by definition a spawn()ed
//     worker (ADR-0010), which has no apartment at all. This is the same
//     measured wall com_enter documents for window CREATION - the fix there gave
//     each window's thread an apartment, and it fixed that, but the dispatch
//     path needs one on the CALLER's side and nobody had gone looking.
//
// So there is no dispatch here. The cross-thread eval goes through post_to_main
// (jobs.v), which is pure Win32 - a queue plus a PostMessage to a comctl32
// subclass - and therefore needs no apartment from either thread. It is also
// already proven on Windows with an E2E screenshot (ADR-0019), which is a
// stronger claim than "compiles".
//
// The snippet is COPIED into the job closure on the calling thread, which is
// what makes that safe: the Ctx's JS string is a temporary that would otherwise
// be freed long before the window thread looked at it.


// vails_webview_terminate makes a running webview_run return, which is how a
// window is closed from another thread (an app quitting N windows, or one
// window asking the app to shut the others down).
static inline void vails_webview_terminate(webview_t w) {
	(void)webview_terminate(w);
}

