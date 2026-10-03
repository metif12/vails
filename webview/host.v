// host.v — the window host seam (Phase 5 S1 wave 3, ADR-0017): the one place
// where the OS is allowed to call *into* V.
//
// C called V twice before this, both times because a library handed us a
// pointer (webview_bind's arg, GTK's signal user_data). Neither let us ask
// for a message. `tray` needs exactly that: a tray icon is a NOTIFYICONDATA
// whose uCallbackMsg is WM_APP+1, and when the user clicks it the shell
// sends a message to the window the *webview library* owns. Somebody has to
// be listening, and that somebody is here.
//
// The shape is the shape of the other two call-ins: a heap context whose
// pointer travels through C and is never dereferenced by it
// (BindCtx/DispatchCtx, AGENTS.md §2 — no globals), a plain top-level V
// function so it can be passed as a C function pointer, and every message we
// do not own forwarded to the previous procedure. That last rule is a safety
// property, not politeness: a message that does not reach the webview
// library's original procedure breaks WebView2.
//
// There is no Linux half on purpose. Linux needs no window procedure at all —
// a GtkMenu emits `activate` on the item that was clicked, an AppIndicator
// emits `activate` on itself, so the C->V direction is per-object and there is
// nothing to hook on the window. Services on Linux connect the signal of the
// GTK object they own; `attach` here is a Windows-only capability and says so
// instead of pretending. See ADR-0017.
module webview

// host_message is the window message the seam registers for: WM_APP+1.
// It is a constant because the message id is what a service registers for, not
// what identifies a service: the tray owns this id, and a service that needs a
// different message (the menu bar's WM_COMMAND) passes its own to the handler
// and filters there. The per-window half is the context pointer, not the id.
// Pinned by host_test.v because services/tray.v classifies against it.
pub const host_message = u32(0x8001)

// wakeup_message is the job queue's wakeup: WM_APP+2.
//
// It is a SEPARATE id from host_message, and the reason is a live bug rather
// than tidiness. A wakeup posted on WM_APP+1 would arrive at the tray's
// handler as an indistinguishable "left click" — the tray classifies on
// msg == host_message and nothing else, so a job-queue wakeup would open a
// tray menu (or whatever the app does on a click) with no error anywhere.
// Two ids, two owners, and each handler declines the other's.
pub const wakeup_message = u32(0x8002)

// HostEvent is one intercepted message, handed to V as plain data. There is
// deliberately no JSON and no event name: the payload has not been given a
// meaning yet, and the handler owns the vocabulary. `services/tray.v` turns
// msg == host_message plus an lParam into `tray:clicked` and builds the
// payload itself, so the host stays plumbing and the service keeps the words.
pub struct HostEvent {
pub:
	msg    u32
	wparam u64
	lparam i64
}

// HostHandler receives every message the seam intercepts. It runs on the
// window thread, which is the thread the command handlers run on, so the
// ADR-0010 threading rule is unchanged: keep it fast, deliver slow work as an
// event.
//
// It returns whether it CONSUMED the message. That is what makes chaining
// correct: subclasses are a stack, each one deciding about its own messages, and
// "this is not mine" has to be expressible or the innermost hook would swallow
// everything the webview library needs to see. Returning false forwards the
// message to the next subclass in the chain and, eventually, to the library's
// own procedure.
//
// An error is not a "not mine": it means the handler recognised the message and
// then failed, and that case is consumed (reported nowhere — the return value of
// a window procedure is a result, not a channel — and the frontend notices as an
// event that never arrives). A handler is expected to report its own failures by
// emitting an event rather than by returning one.
pub type HostHandler = fn (e HostEvent) !bool

// HostCtx is the state behind one subclass. The C side only ever carries its
// address; the address is the whole protocol.
pub struct HostCtx {
pub mut:
	ctx Ctx
	// on_event is the V handler. Never nil once attach returns, and checked
	// on every message anyway: a nil call through a V function pointer is a
	// crash, not an error.
	on_event HostHandler = unsafe { nil }
	// handle is the native window the hook is installed on, or nil when no
	// hook is installed (a hand-built context, or a platform whose callbacks
	// are per-object).
	handle voidptr = unsafe { nil }
}

// is_active reports whether a native hook is installed: a message posted to
// the window will reach the handler.
pub fn (h &HostCtx) is_active() bool {
	return h.handle != unsafe { nil }
}

// has_handler reports whether a handler is installed.
pub fn (h &HostCtx) has_handler() bool {
	return h.on_event != unsafe { nil }
}

// attach installs `on_event` as the window's message hook and returns the
// context that carries it. The caller owns the returned pointer and must
// detach it before the window goes away (detach does both).
//
// More than one service may attach to the same window. comctl32 chains
// subclasses, and because the context pointer is used as the subclass id each
// attach is a distinct entry in the chain, with DefSubclassProc routing to the
// next one down. So a second caller does not overwrite the first, and neither
// needs to know the other exists. The obligation that comes with the chain is
// the one in the header: a message a hook does not recognise must be passed to
// DefSubclassProc, or the webview library's own procedure never runs.
//
// Windows only (ADR-0017): the seam is a window procedure, and Linux has none
// to subclass. A Linux service does not call this — it connects the signal of
// the GTK object it owns — so the error below names the real reason instead of
// reporting a missing dependency.
pub fn attach(ctx Ctx, on_event HostHandler) !&HostCtx {
	if !ctx.has_parent() {
		return error('vails: attach needs the window handle (pass the Ctx from ' +
			'Config.on_ready)')
	}
	mut host := &HostCtx{
		ctx:      ctx
		on_event: on_event
	}
	$if windows {
		attach_native(mut host)!
	} $else {
		return error('vails: attach is not available on this platform (there is ' +
			'no window procedure to hook; on linux a service connects the signal ' +
			'of the GTK object it owns - ADR-0017)')
	}
	return host
}

// detach removes the hook and frees the context. Safe on a context that never
// attached (a Linux service's hook, or a failed attach), because removal is
// guarded on the handle.
pub fn detach(mut host &HostCtx) {
	$if windows {
		detach_native(mut host)
	}
	unsafe {
		free(host)
	}
}

// post_message sends one message to a window and returns without waiting for
// it to be processed. Two uses, both needing the asynchrony: dismissing a
// modal native menu (WM_CANCELMODE reaches the nested loop TrackPopupMenu
// runs, which is the only way out of it) and manufacturing a message for a
// proof run. Windows only, for the same reason attach is.
pub fn post_message(ctx Ctx, msg u32, wparam u64, lparam i64) ! {
	if !ctx.has_parent() {
		return error('vails: post_message needs the window handle (pass the Ctx ' +
			'from Config.on_ready)')
	}
	$if windows {
		unsafe {
			ok := C.PostMessageW(ctx.parent, msg, wparam, lparam)
			if ok == 0 {
				code := C.GetLastError()
				return error('vails: PostMessage failed (code ' + code.str() + ')')
			}
		}
	} $else {
		return error('vails: post_message is not available on this platform ' +
			'(ADR-0017)')
	}
}
