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
// `webview_eval` is not callable from a thread that does not own the webview,
// and with one window per thread (F0) "the thread that owns it" is now a
// property of the WINDOW, not of whoever happens to be calling. So V never
// calls webview_eval directly: it hands the library a snippet and a target
// window through `webview_dispatch`, which the library runs on that window's
// own thread. Every emit — from a handler, from a worker, from a different
// window's thread — goes through here, which is what makes the routing rules
// in window.v sufficient on their own.
//
// The job carries DATA, not a V function pointer: a `void*` to a struct the
// caller allocated. That keeps every V closure out of C (AGENTS.md §2), and
// it means the snippet is copied on the calling thread rather than borrowed —
// the Ctx's JS string is a temporary that would otherwise be freed before the
// target thread ever looked at it.
//
// The job is freed HERE, on the webview's thread, and only on the paths where
// dispatch did not take ownership of it. A strdup failure frees both.
typedef struct {
	webview_t w;
	char *js;
} vails_eval_job;

static void vails_eval_run(void *arg) {
	vails_eval_job *job = (vails_eval_job *)arg;
	(void)webview_eval(job->w, job->js);
	free(job->js);
	free(job);
}

static inline int vails_eval_dispatch(webview_t w, const char *js) {
	vails_eval_job *job = (vails_eval_job *)malloc(sizeof(vails_eval_job));
	if (job == NULL) {
		return 0;
	}
	job->w = w;
	job->js = strdup(js);
	if (job->js == NULL) {
		free(job);
		return 0;
	}
	if (!webview_dispatch(w, vails_eval_run, job)) {
		free(job->js);
		free(job);
		return 0;
	}
	return 1;
}

// vails_webview_terminate makes a running webview_run return, which is how a
// window is closed from another thread (an app quitting N windows, or one
// window asking the app to shut the others down).
static inline void vails_webview_terminate(webview_t w) {
	(void)webview_terminate(w);
}

