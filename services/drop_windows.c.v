// drop_windows.c.v - Windows backend of the drop service: WM_DROPFILES read on
// the window seam (ROADMAP F1). Compiled on Windows ONLY (V `_windows` suffix
// rule).
//
// Everything design-shaped is in services/drop.v; this file is the shell API
// and nothing else:
//
//   DragAcceptFiles       arm the window (or disarm it)
//   DragQueryFileCount    how many items the drop carried
//   DragQueryFileW        item i, as UTF-16
//   DragFinish            release the shell's drop handle
//
// <shellapi.h> is already in this module's translation unit via
// trayicon_windows.c.v, so this file declares no header of its own.
//
// There is no `#insert` here and there is no shim, and the reason is worth
// recording because it cost two wrong attempts. The obvious fourth call is
// `DragQueryFileCount`, and **it does not exist**: MinGW's <shellapi.h> omits it
// and MinGW's import library has no such symbol (`nm -g libshell32.a` lists
// DragFinish, DragAcceptFiles and DragQueryFileW and nothing else). Writing the
// prototype by hand compiles cleanly and then fails at link with
// `undefined reference to __imp_DragQueryFileCount`, so a shim would have moved
// the error rather than fixed it.
//
// The count comes from DragQueryFile itself: `iFile == 0xFFFFFFFF` with a NULL
// buffer returns the number of files in the drop, which is the documented way to
// ask and the only one available. See dropped_file_count.
//
// The `#insert` question, for whoever adds the next shim to this module: V takes
// the FIRST statement in a file as its module, so an `#insert` placed above
// `module services` makes the whole file look like it belongs to `main`, and the
// error names this file and a module it never mentions:
//
//     error: bad module definition: ./examples/showcase/main.v imports module
//     "services" but services/drop_windows.c.v is defined as module `main`
module services

import webview

// The three shell calls, with the minimum signatures this file uses.
//
// `bool` for fAccept rather than `int`: DragAcceptFiles takes a BOOL, and V maps
// BOOL to bool. The count and length returns are UINT, which is u32 - and u32
// again rather than int, because the failure value is what the callers below
// compare against and an int would invite a signed comparison on a value the
// shell documents as unsigned.
fn C.DragAcceptFiles(hwnd voidptr, faccept bool)
fn C.DragQueryFileW(hdrop voidptr, ifile u32, buffer voidptr, cch u32) u32
fn C.DragFinish(hdrop voidptr)

// drag_query_file_count_index is the `iFile` value that turns a length query into
// a count query. See the module header for why there is no fourth shell call.
const drag_query_file_count_index = u32(0xFFFFFFFF)

// dropped_file_count is how many files the drop carried.
//
// `iFile == 0xFFFFFFFF` with a NULL buffer and zero length: DragQueryFile then
// returns the number of files instead of copying a name, which is the documented
// way to ask and the only one shell32 offers.
//
// The buffer is genuinely unused here, so passing NULL is safe rather than a
// gamble — but it is worth saying, because the same call with a real index and a
// NULL buffer is a different function's error.
fn dropped_file_count(hdrop voidptr) u32 {
	return unsafe { C.DragQueryFileW(hdrop, drag_query_file_count_index, unsafe { nil }, 0) }
}

// The buffer DragQueryFileW reads into, in UTF-16 code units, plus the NUL.
//
// MAX_PATH is the shell's own answer for a path and the bound drop.v applies
// (max_dropped_path_len) is deliberately the same number: a longer path needs
// LONG_PATH_MAX handling and a manifest block, which is a different feature with
// its own failure modes, and truncating at 1024 is the same choice `opener`
// makes rather than a limit reached by accident.
const drop_buffer_units = max_dropped_path_len + 1

// enable_drop_native arms the window and installs the seam on the first call.
//
// The order is arm-then-hook, not hook-then-arm, and the reason is the failure
// mode: if the hook cannot be installed after DragAcceptFiles has run, the window
// is accepting drops that nobody will read, and the user's next drag disappears
// with no error anywhere - which is the exact shape of bug `post_to_main`
// refuses to have (webview/jobs.v). So the seam goes on first, and the window is
// armed only once there is something listening.
//
// An arm with no hook is also what makes `drop.enable` idempotent: the second
// call finds the hook present, re-arms the window (harmless - DragAcceptFiles is
// a set, not a counter) and returns, rather than stacking a second subclass.
fn enable_drop_native(mut st &DropState) ! {
	require_parent(st.ctx, 'drop.enable')!
	if st.hook == unsafe { nil } {
		// `owner` rather than `st` in the capture: V 0.5.2 types a closure
		// capture of a `mut` pointer *parameter* as a pointer to the pointer and
		// gcc rejects the generated assignment. A plain local captures correctly -
		// the same workaround as set_tray_native, for the same reason.
		owner := st
		hook := webview.attach(st.ctx, fn [owner] (e webview.HostEvent) !bool {
			return on_drop_message(owner, e)!
		}) or {
			return error('drop: could not hook the window for drops: ' + err.msg())
		}
		st.hook = hook
	}
	unsafe {
		C.DragAcceptFiles(st.ctx.parent, true)
	}
	st.enabled = true
}

// disable_drop_native disarms the window and removes the seam.
//
// Disarm first, then unhook: the reverse order leaves a window that has already
// stopped accepting drops but still has a hook installed, which is harmless for
// one instant and is the kind of "harmless for one instant" that survives a
// refactor. DragAcceptFiles(FALSE) does not release a handle that is already in
// flight - if a drop is mid-message when the app calls this, on_drop_message
// still reads it, because the handle belongs to the shell and not to us.
fn disable_drop_native(mut st &DropState) ! {
	// No hook means this window was never armed: `drop.enable` installs the seam
	// BEFORE it calls DragAcceptFiles, so hook-less and armed cannot both be true.
	// Returning here is what lets a defensive `drop.disable` work on a window
	// this service never touched, instead of demanding a window handle to disarm
	// something that was never on.
	if st.hook == unsafe { nil } {
		st.enabled = false
		return
	}
	// Disarm first, then unhook: the reverse order leaves a window that has
	// already stopped accepting drops but still has a hook installed, which is
	// harmless for one instant and is the kind of "harmless for one instant" that
	// survives a refactor. DragAcceptFiles(FALSE) does not release a handle that
	// is already in flight - if a drop is mid-message when the app calls this,
	// on_drop_message still reads it, because the handle belongs to the shell and
	// not to us.
	unsafe {
		C.DragAcceptFiles(st.ctx.parent, false)
	}
	webview.detach(mut st.hook)
	st.hook = unsafe { nil }
	st.enabled = false
}

// read_dropped_paths_native reads every path out of one DROPFILES handle.
//
// ## DragFinish is called on every path out of here, including the failure ones
//
// That is the load-bearing detail. The HDROP is a shell resource, and the only
// way to release it is DragFinish; a handler that returns early without it leaks
// one handle per drop, and a user dropping files repeatedly is a slow, silent
// leak rather than a visible failure. So there is exactly one exit that does not
// go through `finish`, and every other path routes through it.
//
// ## Why the length check is a rejection and not a retry
//
// DragQueryFileW returns the number of characters copied, excluding the NUL -
// or the *required* size, excluding the NUL, when the buffer was too small. A
// caller that cannot tell those two apart reads a truncated path and reports a
// file that does not exist, which is worse than reporting nothing. So the copy is
// compared against the buffer it was given: a return at or above the capacity
// means the name did not fit, and the item is skipped.
//
// (The distinction is worth its own comment because the second call to learn the
// exact length is the obvious "fix" and it is a trap: it returns the required
// size, not the content, so a naive retry writes the *number* into the buffer.)
fn read_dropped_paths_native(hdrop i64) ![]string {
	if hdrop == 0 {
		return error('drop: the drop message carried no handle')
	}
	handle := voidptr(hdrop)
	count := dropped_file_count(handle)
	mut paths := []string{}
	// The `[]u16{cap: …, len: …}` form rather than `[]u16(len: …)`: the latter is
	// a parse error in this V (the AGENTS.md §2b family — the message points at
	// the closing paren), and it is the form dialog_windows.c.v already uses for
	// its path buffer.
	mut buf := []u16{cap: drop_buffer_units, len: drop_buffer_units}
	mut i := u32(0)
	for i < count {
		got := unsafe { C.DragQueryFileW(handle, i, voidptr(&buf[0]), u32(drop_buffer_units)) }
		// Two reasons to skip an item rather than report it: the shell could not
		// express it as a name (a shortcut, a virtual item - DragQueryFileW
		// returns 0), or the name did not fit (got >= capacity).
		if got > 0 && got < u32(drop_buffer_units) {
			// `string_from_wide` reads to the NUL, and DragQueryFileW always writes
			// one when there is room for it - which there provably is here, because
			// `got < drop_buffer_units` is exactly the condition that leaves space
			// at buf[got]. So the buffer cannot be read past its end, which is the
			// one thing a NUL-terminated read needs to be guaranteed.
			s := unsafe { string_from_wide(&buf[0]) }
			if s != '' {
				paths << s
			}
		}
		i++
	}
	unsafe { C.DragFinish(handle) }
	return paths
}
