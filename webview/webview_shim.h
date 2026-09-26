// webview_shim.h — const-correct adapter for webview_bind.
//
// V fn params cannot express `const char *`, and gcc 14+ rejects the
// resulting function-pointer mismatch as an error. This adapter takes the
// callback as void* and casts to the library's exact callback type — safe
// because our callback (bind_cb) never mutates id/req.
//
// Included via `#insert "@VMODROOT/webview/webview_shim.h"` so no extra -I
// flag is needed.
#include <webview/webview.h>

typedef void (*vails_bind_fn)(const char *id, const char *req, void *arg);

static inline webview_error_t vails_webview_bind(webview_t w, const char *name, void *fn,
                                                 void *arg) {
	return webview_bind(w, name, (vails_bind_fn)fn, arg);
}
