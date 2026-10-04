// balloon_windows.c.v - Windows backend of the balloon service:
// `Shell_NotifyIconW` with `NIF_INFO`. Compiled on Windows ONLY (V `_windows`
// suffix rule).
//
// Deliberately NOT a notification backend (ADR-0039): `notification` is the WinRT
// toast and has no fallback, and nothing here is reachable from it. This is a
// separate service that exists because a machine can be unable to activate any
// WinRT class - measured on Windows 11 build 28000, where the system class store
// is missing - and a framework whose only way to speak to the user depends on a
// component the user cannot repair is a framework with one user-facing
// capability.
//
// ## The three calls per balloon
//
//	1. NIM_ADD with NIF_ICON | NIF_INFO  install the icon AND the text together
//	2. spawn a cleanup worker        the icon outlives this call on purpose
//	3. NIM_DELETE from the worker    once the balloon's own timeout has passed
//
// Step 1 is one call rather than add-then-modify because NIF_INFO on NIM_ADD is
// the documented way to raise a balloon, and doing it in two calls leaves a
// window in which a bare icon is visible with no message attached.
//
// Step 3 is the hazard ADR-0018 named: nothing removes a balloon's icon, so
// something has to. It is a worker rather than a timer on the main thread
// because a blocking sleep would freeze the app for the balloon's duration.
//
// ## Why the worker takes plain parameters (AGENTS.md §2c)
//
// `spawn` with a `mut ... &T` parameter crashes or hangs on this compiler, and
// the failure mode is inconsistent - a crash in one program, a hang in another.
// The worker here needs no mutable reference: it reads an hWnd and a uId it was
// handed and then does one C call. Both are passed by value, which is the shape
// that measurably works.
module services

import time
import webview

// balloon_is_supported_native answers "does this build have a backend", which is
// a compile-time fact: the shell calls are linked in, so yes.
//
// It is deliberately NOT runtime-probed the way notification's is. A balloon
// needs no component that can be missing at runtime - shell32 is there or the
// process would not have started - so a probe would be theatre.
fn balloon_is_supported_native() bool {
	return true
}

// The cleanup worker. `spawn`ed from show_balloon_native, sleeping until the
// balloon's icon may go.
//
// Three arguments, all immutable, all by value - see the module header on why
// that shape and not a `mut &T`. It must not take a context or a service state
// struct: the whole reason this function is three lines is that it has nothing
// to capture and therefore nothing to get wrong.
fn balloon_remove_icon_after(hwnd voidptr, uid u32, delay_ms int) {
	time.sleep(delay_ms)
	icon_remove(hwnd, uid)
}

// show_balloon_native raises one balloon against a fresh icon id.
//
// The icon is the same stock application icon `tray` falls back to, so this
// service ships no asset. `load_icon` is trayicon_windows.c.v's, which is the
// point of that file existing: two services that both need a shell icon cannot
// each declare their own NOTIFYICONDATA in one module (the V `_windows` rule
// concatenates them into a single translation unit, so a duplicate struct is a
// redefinition error, not a link error).
//
// `uid` arrives as a parameter rather than being read from the state here: the
// increment belongs to the pure half, where it can be tested.
fn show_balloon_native(ctx webview.Ctx, uid u32, opts BalloonOptions) !string {
	// The balloon attaches to a window-owned icon, so it needs an hWnd. A headless
	// caller has none, and that is a real limitation rather than a detail to paper
	// over: `Shell_NotifyIconW` has no way to show a balloon without one.
	if !ctx.has_parent() {
		return error('balloon.show: needs a window. A balloon is a tray icon, and a ' +
			'tray icon belongs to a window - unlike notification, which the shell ' +
			'attributes on its own (ADR-0039)')
	}
	nid := NotifyIconData{
		cb_size:       u32(sizeof(NotifyIconData))
		hwnd:          ctx.parent
		uid:           uid
		u_flags:       nif_icon | nif_info
		h_icon:        load_icon('')
		u_timeout:     u32(clamp_balloon_timeout(opts.timeout_ms))
		// dw_info_flags asks the shell for the default chrome. niif_none in the
		// balloon's *icon* field means "no icon inside the balloon", which is not
		// the same request and is why both constants exist.
		dw_info_flags: niif_none
	}
	set_wide_field(nid.sz_info_title, opts.title)
	set_wide_field(nid.sz_info, opts.body)
	// The shell's refusal, reported rather than swallowed: a 0 here means there
	// is no notification area in this session, which the caller cannot fix and
	// deserves to be told about instead of being handed a cheerful
	// 'balloon' for a message nobody will ever see.
	if shell_notify(nim_add, &nid) == 0 {
		return error('balloon.show: the shell refused the icon (Shell_NotifyIconW ' +
			'returned 0). There is no notification area available to this session')
	}
	// The icon now outlives this call, and the worker is what takes it away.
	// Plain value arguments by construction - see the module header on why.
	spawn balloon_remove_icon_after(ctx.parent, uid, balloon_cleanup_ms(opts.timeout_ms))
	return balloon_backend_balloon
}
