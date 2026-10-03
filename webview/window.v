// window.v — the multi-window registry and its event routing (F0).
//
// The single-window shape was fine while there was only ever one window: the
// app kept one `Ctx` and `ctx.emit` reached the one page. F0 makes that shape
// wrong, and wrong *quietly* — which is why the routing lives here, in pure V,
// with its own tests, rather than inside a backend.
//
// The failure this file exists to make impossible:
//
//   two windows, one Ctx, and an event emitted through the wrong one. The
//   event arrives, resolves the promise, and updates a status line on the
//   WRONG PAGE. There is no error anywhere. A screenshot of either window
//   looks fine on its own, so the bug survives a single-window test suite and
//   a single-window screenshot — which is exactly how it would have shipped.
//
// The fix is structural, not a convention: a caller says `emit_to(label, …)`
// and never holds a Ctx it could use by mistake. An unknown label is an error,
// never a fall back to "the first window" or "the main window", because a
// silent default is the same bug wearing a different hat.
//
// Everything here is OS-agnostic and C-free (AGENTS.md §3.3): a `Window` is a
// label, a `Ctx` and a lifecycle state, and a `Ctx`'s `eval_fn` is a plain
// function pointer the backend fills in. So the routing rules — which are the
// hard part and the part worth pinning — are unit-tested on any platform with
// a fake sink, with no window open.
//
// ## Why find does not return an Option
//
// `find` returns a plain `&Window` and "not found" is `unsafe { nil }`, rather
// than the `?&Window` this should obviously be written as. That is a V 0.5.2
// bug, measured rather than guessed:
//
//     fn f() ?&Window { return unsafe { nil } }
//     f() or { /* THIS BLOCK NEVER RUNS */ }
//
// An `Option` of a **reference** type, holding **none**, does not trigger its
// `or` block — the `or` treats it as `some`. Every other combination is fine
// (verified individually): `?int` none and some both behave, and a `some`
// `?&Window` behaves. Only the one cell is broken.
//
// The damage is not a crash, it is worse: `has()` written as
// `f() or { return false }` returns **true for a window that does not exist**,
// and a duplicate-label check written that way rejects the *first* add. Both
// were live in the first draft of this file and both presented as
// "assertion failed" on an empty registry, which is a very misleading
// symptom for a lookup bug. The plain-reference spelling
// (`w != unsafe { nil }`) is correct in every case, so that is what the file
// uses.
//
// `.is_none()` is not an alternative: V 0.5.2 rejects it on an Option
// ("Option type cannot be called directly, you should unwrap it first"), and
// it cannot be called on a call's return value either.
//
// Nothing else in this repo returned `Option<&T>` before this file, so no
// shipped code was affected — but the pattern is worth avoiding until the
// compiler is fixed, and the finding belongs in AGENTS.md §2b next to the
// other three.
module webview

import jsesc

// label_js appends this window's label to the injected bridge runtime.
//
// Why a page needs it at all: F0 loads the SAME document into every window, so
// a page cannot know which window it is in from its own source. That is the
// honest multi-window shape (a real app usually has one bundle with several
// entry points, but the runtime should not depend on that), and it is what
// makes the cross-window example readable: `v.label` is the only thing that
// distinguishes the two windows' pages.
//
// APPENDED, not wrapped around, and that matters: `runtime_js` is an IIFE that
// returns early when `window.vails` already exists, so anything placed *inside*
// it would be skipped on a second injection. Putting the assignment after the
// closing call means it always runs.
//
// The label is JS-escaped, not pasted, and the QUOTE CHARACTER it is wrapped in
// matters as much as the escaping. A label reaches this string from
// `vails.json`, so an unescaped quote would be a script injection into every
// page of the app.
//
// The literal is single-quoted, and that is not a style choice: it was written
// double-quoted first, and the test below caught that `jsesc.escape('a"b')`
// returns `a"b` **unchanged** — the double quote passes straight through into
// the JS literal and closes it. `jsesc.escape` is built for the single-quote
// case, which is exactly what `events/js.v` has always used for event names and
// payloads, so this follows the pattern already proven in production rather
// than inventing a second one.
pub fn label_js(base string, label string) string {
	return base + '\nwindow.vails = window.vails || {};\n' +
		"window.vails.label = '" + jsesc.escape(label) + "';\n"
}

// WindowState is one window's lifecycle. It is not decoration: `emit_to` on a
// window that is not `ready` is a use of an `eval_fn` that may be nil, and
// the alternative to checking is a nil call through a function pointer, which
// is a crash rather than an error.
pub enum WindowState {
	// created: registered, but the backend has not built the native window
	// yet. `ctx.eval_fn` is nil and nothing may be emitted.
	created
	// ready: the native window exists and eval_fn is wired. The page may not
	// have loaded yet, so an event can still land before a listener exists —
	// that race is the frontend's to handle, and the same one every single
	// window already has.
	ready
	// running: the window's message loop is up.
	running
	// closed: the native window is gone. A closed window is removed from the
	// registry; the state exists so a late emit names the real reason instead
	// of "unknown window".
	closed
}

// Window is one window: its security identity, its runtime handle, and where
// it is in its lifecycle.
//
// label is the identity, not title (T1/ADR-0007): it is what a capability is
// checked against and what `emit_to` routes on, so two windows with the same
// title are still two windows and two routing targets.
pub struct Window {
pub mut:
	label string
	// ctx is this window's own runtime handle. It is the reason routing works:
	// each window's `ctx.eval_fn` closes over that window's own native
	// webview, so emitting through the right `Ctx` cannot reach the wrong page.
	ctx   Ctx
	state WindowState
	// native is the backend's own handle (the `webview_t*` on Windows, the
	// `GtkWidget*` on Linux). It is opaque here and exists so a backend can
	// find its own state from a `Window` without a second map.
	native voidptr = unsafe { nil }
}

// new_window registers a window in the `created` state. The backend fills in
// `ctx` and moves the state on once the native window exists.
pub fn new_window(label string) &Window {
	return &Window{
		label: label
		state: .created
	}
}

// is_open reports whether the window can still be used. A closed window is
// never reopened: an app that wants a second window with the same label asks
// for a new label, so that a stale `Ctx` cannot outlive its page.
pub fn (w &Window) is_open() bool {
	return w.state != .closed
}

// can_emit reports whether the window has an eval_fn to emit through. Only
// `ready` and `running` qualify.
pub fn (w &Window) can_emit() bool {
	return w.state == .ready || w.state == .running
}

// WindowRegistry is the app's set of windows, keyed by label.
//
// A slice of pointers rather than a map because the order windows were created
// in is meaningful (it is the order they were asked for, and it is the order
// `labels()` reports) and because N is small — a handful of windows, not
// thousands. Lookup is linear and that is the right answer at this size.
pub struct WindowRegistry {
pub mut:
	windows []&Window
}

// new_registry is an empty registry.
pub fn new_registry() &WindowRegistry {
	return &WindowRegistry{}
}

// add registers a window.
//
// A duplicate label is an error, not an overwrite. Two windows sharing a label
// would share a capability identity (T1), so a command granted to "main" would
// also be allowed from the second window — and `emit_to("main")` would have
// two possible destinations and no way to say which. The failure is a security
// hole and an ambiguous route at the same time, so it is refused where it can
// still be named.
pub fn (mut r WindowRegistry) add(w &Window) ! {
	if w.label == '' {
		return error('vails: a window needs a non-empty label (it is the ' +
			'capability identity and the event route)')
	}
	if r.find(w.label) != unsafe { nil } {
		return error('vails: a window labelled "' + w.label + '" is already ' +
			'registered (labels are the capability identity and the event route, ' +
			'so they must be unique)')
	}
	r.windows << w
	return
}

// find returns the window with that label, or nil.
//
// A PLAIN reference, not `?&Window`, and that is a V 0.5.2 bug workaround
// rather than a style choice — see "Why find does not return an Option" in the
// module header. A caller that found nothing compares against `unsafe { nil }`,
// which is correct, and every rule below reads the same way.
pub fn (r &WindowRegistry) find(label string) &Window {
	for w in r.windows {
		if w.label == label {
			return w
		}
	}
	return unsafe { nil }
}

// has reports whether a label is registered.
pub fn (r &WindowRegistry) has(label string) bool {
	return r.find(label) != unsafe { nil }
}

// get is find with the error attached, for call sites that must not continue
// without the window.
pub fn (r &WindowRegistry) get(label string) !&Window {
	w := r.find(label)
	if w == unsafe { nil } {
		return error('vails: no window labelled "' + label + '" (open: ' +
			r.labels().join(', ') + ')')
	}
	return w
}

// labels returns the registered labels in creation order.
pub fn (r &WindowRegistry) labels() []string {
	mut out := []string{}
	for w in r.windows {
		out << w.label
	}
	return out
}

// count is how many windows are registered.
pub fn (r &WindowRegistry) count() int {
	return r.windows.len
}

// remove unregisters a window and marks it closed, returning it (or nil). The
// window itself is not freed, because an app may still hold the `&Window` and
// asking it "is this open?" after the close is a legitimate question with a
// real answer. Plain reference, for the same reason `find` is — see the module
// header.
pub fn (mut r WindowRegistry) remove(label string) &Window {
	// Indexed rather than `for i, w in`: a `for` binding of a `[]&Window` gives
	// an immutable alias of the pointer, and V then (correctly) refuses to let
	// it reach through to the pointee. Indexing off the `mut` receiver keeps
	// the write to the real Window.
	for i in 0 .. r.windows.len {
		if r.windows[i].label == label {
			mut w := r.windows[i]
			w.state = .closed
			r.windows.delete(i)
			return w
		}
	}
	return unsafe { nil }
}

// open_labels returns the labels of the windows that are not closed, in
// creation order. This is what a "bring every window up" step iterates.
pub fn (r &WindowRegistry) open_labels() []string {
	mut out := []string{}
	for w in r.windows {
		if w.is_open() {
			out << w.label
		}
	}
	return out
}

// emit_to delivers one event to the window named by label.
//
// This is the whole point of the file, and every branch in it is a bug that
// was reachable in the single-window shape:
//
//   - an unknown label is an ERROR. The tempting alternative is to fall back
//     to the first window or to "main", which delivers the event somewhere
//     real and wrong — the page updates, the promise resolves, and nothing
//     reports a problem. A missing route must be loud.
//   - a window that is not `ready` is an ERROR, naming its state, because
//     emitting through a nil eval_fn is a crash.
//   - the event goes through THAT window's own `ctx`, never a cached one from
//     another label.
//
// The error propagates rather than being logged here: the caller is V, it can
// decide, and a library that swallows a routing failure is how the wrong-page
// bug gets its first plausible deniability.
pub fn (r &WindowRegistry) emit_to(label string, event string, data string) ! {
	w := r.get(label)!
	if !w.can_emit() {
		return error('vails: cannot emit "' + event + '" to window "' + label +
			'": it is ' + w.state.str() + ', not ready (a window emits only ' +
			'after its native handle exists)')
	}
	w.ctx.emit(event, data)!
}

// emit_all delivers one event to every open, ready window. It is the "tell
// both pages something changed" case, and it reports the FIRST failure rather
// than continuing: a partial broadcast that silently skipped one window is the
// multi-window version of the quiet wrong-page bug.
pub fn (r &WindowRegistry) emit_all(event string, data string) ! {
	for w in r.windows {
		if !w.can_emit() {
			continue
		}
		w.ctx.emit(event, data)!
	}
}

// stop_all asks every window to close, which is how an app says "quit" to a
// set of windows instead of only the one it happens to hold a handle for.
// Windows that cannot be asked are reported, not skipped.
pub fn (r &WindowRegistry) stop_all() ! {
	for w in r.windows {
		if w.state == .closed {
			continue
		}
		w.ctx.close()!
	}
}

// state_name is the lifecycle state as text, for a `doctor` line or an error
// message. It is a function rather than a method on the enum because the
// callers are in this module and V 0.5.2's enum `.str()` is enough on its own
// for the job; this exists so the wording is in one place if it ever changes.
pub fn state_name(s WindowState) string {
	return match s {
		.created { 'created' }
		.ready { 'ready' }
		.running { 'running' }
		.closed { 'closed' }
	}
}
