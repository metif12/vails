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

// CloseFn closes one window. A plain function pointer (not a method) so a
// backend can hand over a closure over its own native handle; it is only ever
// invoked from V, never from C. nil until the backend has built the window.
pub type CloseFn = fn ()

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
	// toplevel is the window's top-level *widget*, which is the handle some
	// toolkits need and `parent` is not. On Windows the two are the same HWND.
	// On Linux they are different objects: `parent` is a GdkWindow and
	// `toplevel` is the GtkWindow that owns it, because GTK APIs that take
	// "the window" (a menu bar, a transient parent) want the widget and not
	// the drawable. There is no way to recover one from the other, so this is
	// a separate field rather than something a service derives.
	// nil means "unknown", exactly as for parent.
	toplevel voidptr = unsafe { nil }
	// main is the per-window job queue + wakeup seam (U0, ADR-0019): the
	// thing a spawn()ed worker hands a closure to, so the window thread runs
	// it. A pointer, not a value, because Ctx is copied by value in several
	// places and the queue must be shared by every copy.
	//
	// nil means "no live window" — a hand-built Ctx in a test, or a platform
	// whose backend has not run. post_to_main says so rather than dropping
	// the job, because a dropped job looks exactly like a hung download.
	main &MainThread = unsafe { nil }
	// close_fn is the backend's "close this window" hook, filled in when the
	// native window exists. nil means this window cannot be closed
	// programmatically, which `close` reports rather than pretending. It exists
	// because F0 made windows a set rather than a singleton — with one window
	// the OS window manager is enough, and with several an app needs to be able
	// to say "close the other one" without holding a second, differently-typed
	// handle to it. Same shape as eval_fn: a plain function pointer, nil until
	// the backend wires it.
	close_fn CloseFn = unsafe { nil }
}

// close asks the backend to close this window. A window that cannot be closed
// programmatically says so; it is not a silent no-op, because "the window is
// still open" and "the window is closing" are different states to an app.
pub fn (c Ctx) close() ! {
	if c.close_fn == unsafe { nil } {
		return error('vails: this window cannot be closed programmatically ' +
			'(label "' + c.label + '": no backend close hook)')
	}
	c.close_fn()
}

// can_close reports whether a close hook is available.
pub fn (c Ctx) can_close() bool {
	return c.close_fn != unsafe { nil }
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

// has_toplevel reports whether the top-level widget handle is available. A
// service that needs it (the window menu bar) must check, because a Ctx built
// by hand in a test has none.
pub fn (c Ctx) has_toplevel() bool {
	return c.toplevel != unsafe { nil }
}

// is_ready reports whether the context is wired to a live window.
pub fn (c Ctx) is_ready() bool {
	return c.eval_fn != unsafe { nil }
}

// has_main reports whether the per-window job seam is available. A Ctx built
// by hand in a test has no queue, and post_to_main refuses there with a named
// error instead of silently dropping the job — a dropped job is
// indistinguishable from work that never finished.
pub fn (c Ctx) has_main() bool {
	return c.main != unsafe { nil }
}
