// host_windows.c.v — the Windows half of the host seam: a comctl32 subclass on
// the window the webview library created. Compiled on Windows ONLY (V
// `_windows` suffix rule).
//
// Why a subclass and not our own window procedure: the webview library owns
// the HWND and has already installed a WndProc on it. Stacking comctl32's
// SetWindowSubclass composes with whatever is there and routes everything we
// ignore to DefSubclassProc; replacing the procedure with SetWindowLongPtr
// would mean chaining by hand and would fight the library. See ADR-0017.
//
// Services install the subclass on demand, never by webview.run: a window whose
// app uses no service that needs a callback gets no subclass from this file, so
// a window with no services on it is untouched by it.
//
// There is one exception, and it is the runtime's own job wakeup (U0,
// ADR-0019): webview.run installs that one itself. It cannot be left to the
// first post, because post_to_main is only ever called from a spawn()ed worker
// and SetWindowSubclass is thread-affine — see webview/jobs.v install_wakeup,
// which is the long version of that sentence.
module webview

#insert "@VMODROOT/webview/host_shim.h"

// comctl32: SetWindowSubclass / RemoveWindowSubclass / DefSubclassProc
// user32: PostMessageW / GetLastError
#flag windows -lcomctl32 -luser32

fn C.vails_host_subclass(hwnd voidptr, proc voidptr, context u64) int
fn C.vails_host_unsubclass(hwnd voidptr, proc voidptr, context u64) int
fn C.vails_host_defproc(hwnd voidptr, msg u32, wparam u64, lparam i64) i64
fn C.PostMessageW(hwnd voidptr, msg u32, wparam u64, lparam i64) int
fn C.GetLastError() u32

// host_proc is the window procedure the shell ends up in for every message.
//
// Plain top-level fn, no captures, because it has to be a C function
// pointer. The fifth parameter is the comctl32 *uIdSubclass*, which is where
// we put the HostCtx address (dwDataRef is a DWORD and cannot hold a 64-bit
// pointer — see host_shim.h). The sixth is that same dwDataRef, which we
// always leave 0; it is declared only so the parameter list matches
// SUBCLASSPROC's exactly.
//
// The handler decides. It is asked about EVERY message and says whether it
// consumed this one, and only then is the message swallowed; "no" falls
// through to DefSubclassProc, which reaches the next subclass in the chain and
// eventually the webview library's own procedure. Filtering here instead
// (matching one hardcoded id) was correct while there was one hook and is wrong
// now that there are two: a message the inner hook does not own would never
// get the chance to reach the outer one.
fn host_proc(hwnd voidptr, msg u32, wparam u64, lparam i64, context u64, dw_data_ref u64) i64 {
	_ := dw_data_ref
	unsafe {
		if context != 0 {
			host := &HostCtx(context)
			if host.on_event != unsafe { nil } {
				consumed := host.on_event(HostEvent{
					msg:    msg
					wparam: wparam
					lparam: lparam
				}) or { true }
				if consumed {
					return 0
				}
			}
		}
		return C.vails_host_defproc(hwnd, msg, wparam, lparam)
	}
}

// attach_native installs the subclass. The context already carries the window
// handle (attach checked it), so there is nothing to resolve here.
fn attach_native(mut host &HostCtx) ! {
	host.handle = host.ctx.parent
	unsafe {
		if C.vails_host_subclass(host.handle, voidptr(host_proc), u64(host)) == 0 {
			host.handle = unsafe { nil }
			return error('vails: SetWindowSubclass failed (code ' +
				C.GetLastError().str() + ')')
		}
	}
}

// detach_native removes the subclass. The context is freed by the caller
// (detach), and only after this returns — the window must not be able to
// reach a freed pointer even for one message already in flight.
fn detach_native(mut host &HostCtx) {
	if host.handle == unsafe { nil } {
		return
	}
	unsafe {
		C.vails_host_unsubclass(host.handle, voidptr(host_proc), u64(host))
	}
	host.handle = unsafe { nil }
}
