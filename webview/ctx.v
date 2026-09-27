// ctx.v — the per-window runtime handle services talk to (Phase 5).
//
// A native service needs three things from the window that hosts it: a way
// to push events to the frontend (V -> JS, the direction ADR-0004 left
// unwired), the native window handle to parent its own windows to, and the
// window's capability label. Ctx bundles exactly those three and stays
// pure-V: the native backends only fill in `eval_fn` and `parent`, so
// every behaviour below is unit-testable on any OS with a fake sink.
//
// Threading: eval_fn runs on the webview main thread, the same thread the
// command handlers run on (ADR-0010).
module webview

import events

// EvalFn evaluates one JS snippet in the window. It is a plain function
// pointer (not a method) so a backend can hand over a closure over its
// native handle; it is only ever invoked from V, never from C.
pub type EvalFn = fn (js string) !

// Ctx is the window-scoped runtime handle. Keep one per window (the app
// stores the copy it receives in Config.on_ready) and pass it to services.
// Fields are public because the native backends construct it.
pub struct Ctx {
pub mut:
	label string
	// eval_fn is nil until the backend wired it (a hand-built Ctx in tests,
	// or a window on a platform without a live webview).
	eval_fn EvalFn = unsafe { nil }
	// parent is the native window handle (HWND on Windows, the GdkWindow on
	// Linux) used to parent native UI (dialogs, menus, tray) to this
	// window. nil means "unknown" — callers must degrade, not crash.
	parent voidptr = unsafe { nil }
}

// emit delivers one event to the frontend through window.vails.__emit
// (the events.to_js snippet). This is the V -> JS direction: services call
// it from handlers or from spawned workers' result delivery.
pub fn (c Ctx) emit(event string, data string) ! {
	if event == '' {
		return error('vails: emit needs a non-empty event name')
	}
	c.run_js(events.to_js(event, data))!
}

// run_js evaluates an arbitrary snippet on the window's main thread.
pub fn (c Ctx) run_js(js string) ! {
	if c.eval_fn == unsafe { nil } {
		return error('vails: no window attached to this context (label "' + c.label + '")')
	}
	c.eval_fn(js)!
}

// has_parent reports whether a native parent handle is available.
pub fn (c Ctx) has_parent() bool {
	return c.parent != unsafe { nil }
}

// is_ready reports whether the context is wired to a live window.
pub fn (c Ctx) is_ready() bool {
	return c.eval_fn != unsafe { nil }
}
