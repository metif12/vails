module webview

fn test_host_message_is_wm_app1() {
	// Pinned because services/tray.v classifies against it and the tray
	// backend registers it with the shell: WM_APP+1 == 0x8001 is the first
	// application message, which is the only reason this id is free.
	assert host_message == 0x8001
}

fn test_a_fresh_context_has_no_hook() {
	h := &HostCtx{
		ctx: Ctx{
			label: 'main'
		}
	}
	assert !h.is_active()
	// A hand-built context has no handler either, and the two facts are
	// independent: the check in host_proc relies on the second one.
	assert !h.has_handler()
}

fn test_attach_needs_a_window() {
	// The precondition is checked in pure V before any platform branch, so
	// this is the same answer on every OS: a Ctx with no parent handle is a
	// hand-built one (or a platform that hands out no handle), and a
	// subclass cannot be installed on nothing.
	// `why` rather than `err`: inside an `or { }` block `err` is the call's
	// own error, so an assignment to a variable called `err` would be a
	// type error (the ADR-0015 shadowing lesson, one file over).
	mut why := ''
	attach(Ctx{
		label: 'main'
	}, fn (_ HostEvent) !bool { return false }) or { why = err.msg() }
	assert why.contains('window handle')
	assert why.contains('on_ready')
}

fn test_post_message_needs_a_window() {
	mut why := ''
	post_message(Ctx{
		label: 'main'
	}, host_message, 0, 0) or { why = err.msg() }
	assert why.contains('window handle')
	assert why.contains('on_ready')
}

fn test_a_stored_handler_is_not_an_installed_hook() {
	// is_active() is about the native hook, not about the handle: a context
	// can carry both a window and a handler and still be inert, because only
	// attach() installs anything. A service asking is_active() before it
	// emits is asking the right question.
	mut h := &HostCtx{
		ctx: Ctx{
			label:  'settings'
			parent: voidptr(0x1234)
		}
	}
	h.on_event = fn (e HostEvent) !bool {
		_ = e
		return false
	}
	assert h.has_handler()
	assert h.ctx.label == 'settings'
	assert !h.is_active()
}

fn test_two_contexts_can_hang_off_one_window() {
	// The window host seam is a stack of comctl32 subclasses, and the context
	// pointer is the subclass id, so two services can listen on one window
	// without either knowing about the other (ADR-0023). The tray takes
	// WM_APP+1 and the menu bar takes WM_COMMAND; both need it.
	//
	// What is checked here is the property the mechanism gives us — two
	// contexts, two distinct ids, both attached to the same handle — because
	// that is what makes the chain safe. The subclasses themselves need a real
	// HWND and are proved by the E2E run, not here.
	a := &HostCtx{
		ctx: Ctx{
			label:  'main'
			parent: voidptr(0x1234)
		}
	}
	b := &HostCtx{
		ctx: Ctx{
			label:  'main'
			parent: voidptr(0x1234)
		}
	}
	assert u64(a) != u64(b)
	// Distinct addresses are distinct subclass ids, which is what stops
	// RemoveWindowSubclass for one from taking the other out of the chain.
	assert a.ctx.parent == b.ctx.parent
}

fn test_a_handler_can_decline_a_message() {
	// The whole chaining contract: "not mine" has to be expressible, or the
	// innermost hook would swallow every message the webview library needs to
	// see. A handler that returns false is a handler that wants the message to
	// keep travelling.
	// Decides per message, which is what a real service does: the tray consumes
	// only its own WM_APP+1 and lets everything else past.
	mut h := &HostCtx{
		ctx: Ctx{
			label: 'main'
		}
	}
	h.on_event = fn (e HostEvent) !bool {
		return e.msg == host_message
	}
	owned := h.on_event(HostEvent{
		msg:    host_message
		wparam: 0
	}) or { panic('the handler does not fail') }
	assert owned

	// WM_COMMAND is the menu bar's, not the tray's: the tray must decline it so
	// it reaches the next subclass in the chain.
	not_mine := h.on_event(HostEvent{
		msg:    0x0111
		wparam: 1
	}) or { panic('the handler does not fail') }
	assert !not_mine
}
