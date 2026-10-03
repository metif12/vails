// host_shim.h — the comctl32 subclass seam behind a C ABI V can call.
//
// Three things live here and nowhere else:
//
//  1. the cast from a plain function pointer to SUBCLASSPROC. A V function
//     pointer is not one (V has no Windows callback types), and gcc rejects
//     the mismatch instead of warning about it — the same lesson as
//     webview_shim.h, one function further out.
//  2. DefSubclassProc, the default route for every message this seam does not
//     own. A message that does not reach the webview library's original
//     procedure breaks WebView2, so this default is a safety property and not
//     a convenience (ADR-0017).
//  3. the context pointer's *carrier field*. SetWindowSubclass's dwDataRef is
//     a DWORD, and a 64-bit heap address does not fit in 32 bits — passing it
//     there truncates the pointer and the callback dereferences rubbish.
//     uIdSubclass is a UINT_PTR, so the pointer rides there and dwDataRef
//     stays 0. The two are only distinguished by comctl32, never by us: the
//     subclass id IS the context.
//
// Because the id IS the context and every attach allocates its own, MORE THAN
// ONE subclass can sit on the same window: comctl32 keeps them in a chain,
// calls the most recently installed first, and DefSubclassProc calls the next
// one down. Two services that each need a callback (tray's WM_APP+1 and the
// menu bar's WM_COMMAND) therefore each install their own and neither has to
// share a hook or grow a dispatch table. Each only has to keep rule 2: a
// message it does not own must reach DefSubclassProc, or the webview library
// never sees it. (An earlier revision of this file claimed "exactly one hook per
// window". That was true only because there was one caller, not because of
// anything in the mechanism.)
//
// Included via `#insert "@VMODROOT/webview/host_shim.h"`, like
// webview_shim.h, so no -I flag is needed.
#ifndef VAILS_HOST_SHIM_H
#define VAILS_HOST_SHIM_H

#include <windows.h>
#include <commctrl.h>

static inline BOOL vails_host_subclass(HWND hwnd, void *proc,
                                       unsigned __int64 context) {
	return SetWindowSubclass(hwnd, (SUBCLASSPROC)proc, (UINT_PTR)context, 0);
}

static inline BOOL vails_host_unsubclass(HWND hwnd, void *proc,
                                         unsigned __int64 context) {
	return RemoveWindowSubclass(hwnd, (SUBCLASSPROC)proc, (UINT_PTR)context);
}

static inline LRESULT vails_host_defproc(HWND hwnd, UINT msg, WPARAM w,
                                         LPARAM l) {
	return DefSubclassProc(hwnd, msg, w, l);
}

#endif
