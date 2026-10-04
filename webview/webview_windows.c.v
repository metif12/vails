// webview_windows.c.v — Windows backend: webview/webview 0.12 (Edge/WebView2)
// via V C-interop. Compiled on Windows ONLY (V `_windows` suffix rule).
//
// Needs MSYS2 ucrt64: mingw-w64-ucrt-x86_64-webview (+ webview2-loader) and
// C:\msys64\ucrt64\bin on PATH (see `vails doctor`). The library owns the
// WebView2 lifecycle; the only COM call on this side is the per-thread
// apartment the library's own COM client requires (com_enter, see F0 below).
// window=NULL asks the library to create and own its window.
//
// ## One thread per window (F0)
//
// The library's `webview_run` blocks in a message loop that belongs to ONE
// webview, so running two windows means two loops, which means two threads.
// That is not a workaround, it is the shape the library's own
// `webview_dispatch` exists to serve: "run this on webview w's thread" is only
// a meaningful question when w is on a thread of its own.
//
// The consequence is the important part and it is why the routing rules live
// in window.v: **no longer does "the main thread" identify a window.** With
// one window, eval_fn could assume it was called from the loop that owned the
// webview. With N, every call may come from any thread — a worker, or another
// window's loop — so every eval goes through `vails_eval_dispatch`, which
// hands the snippet to the window that owns it. The main thread is now only
// the thread that started the app and waits for the windows to close.
module webview

import bridge
import capabilities

#include <webview/webview.h>
// For the apartment the window's own thread needs (F0). objbase, not windows:
// CoInitializeEx is the only COM entry this file makes, and declaring the
// minimum surface (AGENTS.md §2) is cheaper than including all of windows.h.
#include <objbase.h>
#insert "@VMODROOT/webview/webview_shim.h"

// Shared-library consumer: WEBVIEW_API becomes __declspec(dllimport).
#flag windows -DWEBVIEW_SHARED
// Default MSYS2 location; override by symlinking your toolchain to it or
// (Phase 4) by extending `vails doctor`/build to probe more prefixes.
#flag windows -IC:/msys64/ucrt64/include
#flag windows -LC:/msys64/ucrt64/lib
#flag windows -lwebview
#flag windows -ladvapi32 -lole32 -lshell32 -lshlwapi -luser32 -lversion

fn C.webview_create(debug int, window voidptr) voidptr
fn C.webview_destroy(w voidptr) int
fn C.webview_run(w voidptr) int
fn C.webview_set_title(w voidptr, title &char) int
fn C.webview_set_size(w voidptr, width int, height int, hints int) int
fn C.webview_set_html(w voidptr, html &char) int
fn C.webview_navigate(w voidptr, url &char) int
fn C.webview_init(w voidptr, js &char) int
// const-correct wrapper, see webview_shim.h.
fn C.vails_webview_bind(w voidptr, name &char, f voidptr, arg voidptr) int
fn C.webview_return(w voidptr, id &char, status int, result &char) int
// NOT webview_eval: an eval is dispatched to the window's own thread, so it
// is safe from any thread (F0). See webview_shim.h.
fn C.vails_eval_dispatch(w voidptr, js &char) int
fn C.webview_eval(w voidptr, js &char) int
fn C.GetCurrentThreadId() u32
fn C.vails_webview_terminate(w voidptr)
fn C.webview_get_window(w voidptr) voidptr
fn C.CoInitializeEx(reserved voidptr, coinit u32) i32
fn C.CoUninitialize() voidptr

// BindCtx crosses the C boundary as webview_bind's arg so bind_cb can reach
// the instance (for webview_return), our Router and the T2 dispatch
// context (window label + capability registry). Heap-allocated, freed
// after webview_run returns. C never dereferences it — it only ferries
// the pointer back to bind_cb — so V-managed fields are safe here.
// (Named BindCtx, not Ctx: Ctx is the window runtime handle services use.)
struct BindCtx {
	w      voidptr
	router &bridge.Router
	label  string
	reg    capabilities.Registry
}

// bind_cb is the single JS->V entry point on Windows. Plain top-level fn
// (no captures) so it can cross into C. The library resolves the JS
// promise from webview_return; our envelope (Response JSON for commands,
// Ack JSON for one-way events) rides inside. Dispatch runs the T2
// contract: capability gate + params validation for commands, gate only
// for events (see bridge.handle_envelope_from).
//
// The label in this BindCtx is the per-window identity, so a command called
// from window "settings" is gated against "settings"'s capabilities and
// never against the main window's. That half was already correct with one
// window and is what F0 makes load-bearing.
fn bind_cb(id &char, req &char, arg voidptr) {
	unsafe {
		ctx := &BindCtx(arg)
		body := req.vstring()
		out := ctx.router.handle_envelope_from(body, ctx.label, ctx.reg)
		C.webview_return(ctx.w, id, 0, out.str)
	}
}

// eval_sink builds the Ctx.eval_fn for this window.
//
// The rule it implements is one line — **evaluate on the thread that owns this
// webview, whichever thread that turns out to be** — and both branches were
// forced by real failures rather than chosen:
//
//   - FROM THE WINDOW'S OWN THREAD it calls `webview_eval` directly, exactly as
//     the single-window version always did. This is not an optimisation: the
//     first attempt routed everything through `webview_dispatch`, and the post
//     probe (U0) stopped working — the wakeup handler runs INSIDE the window's
//     message loop, and asking the library to re-dispatch a callback to the
//     loop that is currently calling it is refused (dispatch returned
//     WEBVIEW_ERROR_OK, which the old wrapper read as failure, and the page
//     never saw its result). Keeping the direct call also means the
//     long-standing behaviour that an emit from a handler has taken effect by
//     the time the handler returns is unchanged, which is what services rely on.
//   - FROM ANY OTHER THREAD (a `spawn`ed worker, or another window's loop, both
//     of which exist because of F0) it hands the snippet to post_to_main, which
//     runs it on the window thread. NOT webview_dispatch, which is the obvious
//     tool and does not work: it needs a COM apartment on the CALLING thread,
//     and the caller here is by definition a worker that has none. Measured as
//     0xC0000005 inside libwebview-0.12.dll (see webview_shim.h).
//
// Which thread owns the window is decided once, by reading the thread id HERE
// — this function body runs on that thread, before `webview_run` — and carried
// in the closure. Comparing ids is what makes the fast path possible; without
// it every emit would take the slow path and the synchronous behaviour that
// services depend on would be gone.
//
// `mt` and `parent` are the two things post_to_main needs, passed separately
// rather than as a Ctx so this closure does not have to capture the Ctx that
// contains it.
fn eval_sink(w voidptr, owner_thread u32, mt &MainThread, parent voidptr) fn (js string) ! {
	return fn [w, owner_thread, mt, parent] (js string) ! {
		unsafe {
			if C.GetCurrentThreadId() == owner_thread {
				// 0 == WEBVIEW_ERROR_OK
				rc := C.webview_eval(w, js.str)
				if rc != 0 {
					return error('vails: webview_eval failed (code ' + rc.str() +
						')')
				}
				return
			}
			// The snippet is copied into the closure here, on the calling
			// thread, which is what makes handing it over safe: `js` is a
			// temporary that would otherwise be freed before the window thread
			// read it.
			//
			// The eval inside the job cannot report back — a Job returns
			// nothing, because by the time it runs the caller that could have
			// received an error is gone (jobs.v says the same). So a failure
			// there is printed rather than returned. That is the honest
			// asymmetry: the POST is reportable and is reported, the eval is
			// not.
			post_ctx := Ctx{
				label:  ''
				parent: parent
				main:   mt
			}
			post_to_main(post_ctx, eval_job(w, js)) or {
				return error('vails: could not hand a snippet to this window from ' +
					'another thread: ' + err.msg())
			}
		}
	}
}

// eval_job is the closure that actually runs the snippet, on the window thread.
//
// It is a separate named function because a closure LITERAL cannot be an
// argument to a call that is followed by `or` in this V: the parser attaches the
// `or` to the anonymous function and reports `expected return type, not 'or' for
// anonymous function`. Measured, and the message at least names the problem.
//
// It cannot report a failure, and that is not an oversight. A Job returns
// nothing (jobs.v: by the time it runs, the caller that could have received an
// error is gone), so the eval is printed rather than returned. The honest
// asymmetry is that the POST is reportable and is reported by the caller, while
// the eval is not reportable at all.
fn eval_job(w voidptr, js string) Job {
	// The `()` is REQUIRED and its absence is a parse error, not a style choice:
	// a closure literal with a capture list and no explicit signature does not
	// parse as a return expression in this V, and the message points at the
	// function's own closing brace rather than at the closure. Measured in a
	// standalone file with no Vails code - `return fn [js] { … }` fails,
	// `return fn [js] () { … }` compiles. That belongs in AGENTS.md §2b; it is
	// recorded here so the next reader does not rediscover it.
	return fn [w, js] () {
		unsafe {
			// 0 == WEBVIEW_ERROR_OK
			rc := C.webview_eval(w, js.str)
			if rc != 0 {
				eprintln('vails: a queued webview_eval failed on the window ' +
					'thread (code ' + rc.str() + ')')
			}
		}
	}
}

// close_sink builds the Ctx.close_fn for this window: ask the library to make
// this window's webview_run return, which closes the window and lets the
// window's thread finish.
//
// `webview_terminate` is documented for exactly this (it is what the library's
// own API is for when a window must be closed from outside its own thread),
// and it is the only reason this can be a plain function pointer with no
// window thread marshalling: the library posts the request to the right loop.
fn close_sink(w voidptr) fn () {
	return fn [w] () {
		unsafe { C.vails_webview_terminate(w) }
	}
}

// COINIT_APARTMENTTHREADED. Spelled as a constant rather than as `0x2` at the
// call site so the one line that has to be right says what it is.
// (webview.h does not pull in objbase.h, so the symbol is not available here
// even though the include below is.)
const coinit_apartmentthreaded = u32(0x2)

// WM_DESTROY and WM_QUIT are declared by trayicon_windows.c.v's siblings, not
// here: this file's window-lifetime work is written up in window_thread and is
// currently REVERTED, so an unused constant would only be a notice in the build
// output (AGENTS.md §2). They come back with the fix, not before it.

// com_enter puts THIS thread into a single-threaded apartment.
//
// ## Why the first window never needed this and the second one dies without it
//
// WebView2 is a COM client, and the thread that creates a webview must already
// have an apartment. The process's FIRST window is fine without this line: the
// OS gives the thread that starts a process an STA at startup, so `webview.run`
// — the shape every shipped app uses — has always had one, which is exactly why
// the missing apartment stayed invisible for the whole single-window era.
//
// A `spawn`ed thread has NO apartment at all, and WebView2's failure in that
// state is the nastiest kind: the window is created, `webview_run` enters its
// loop, the page renders — and the first *dispatched* call to that window is
// refused, after which the process dies. That is ADR-0035's measurement, and it
// is why the refusal in `run_many` existed rather than a crash.
//
// The value is RETURNED rather than logged, because its three outcomes are
// three different obligations and the difference matters at the far end of a
// long function:
//
//   - `S_OK` (0): this call made the apartment, so this thread owes exactly one
//     `CoUninitialize`.
//   - `S_FALSE` (1): the thread was already an STA — ours to balance all the
//     same, which is why the test is `>= 0` and not `== 0`.
//   - `RPC_E_CHANGED_MODE` (0x80010106, so negative): something got to this
//     thread first with a different concurrency model. The apartment is NOT
//     ours, and a `CoUninitialize` here would unbalance someone else's
//     initialisation. The window is still attempted, because an MTA host is not
//     itself a WebView2 error: refusing here would replace a real diagnosis
//     from the library with a guess from us.
//
// The first window's thread goes through this too, deliberately. `CoInitializeEx`
// on a thread that already has an STA returns `S_FALSE` and is harmless, so
// there is no branch here for "is this the first window" — which is what keeps
// `webview.run` the same code path it has always been.
fn com_enter() i32 {
	unsafe {
		return C.CoInitializeEx(unsafe { nil }, coinit_apartmentthreaded)
	}
}

// com_leave balances com_enter, and only if com_enter initialised.
fn com_leave(hr i32) {
	if hr >= 0 {
		unsafe { C.CoUninitialize() }
	}
}

// WindowJob is one window's whole lifecycle, heap-allocated because it crosses
// into a `spawn`ed thread and outlives the call that built it. The window's
// own &Window pointer rides in it so the registry and the thread agree on
// which object this is.
@[heap]
struct WindowJob {
mut:
	win &Window
	cfg Config
	// error is set by the thread if the window could not be built, and read by
	// the joining side. A `!T` is a struct, not shareable state, so the
	// failure is reported as a string and turned back into an error there.
	error  string
	failed bool
	// done is the join signal: one token per window thread on return. A
	// channel because sync.WaitGroup.done() crashes when called from a
	// spawned thread in this V build (AGENTS.md 2c).
	done chan int
}

// build_window creates one webview, wires it, and blocks in its message loop
// until the window closes. This is the body of one window's thread.
//
// Every early return frees exactly what it created, because a multi-window app
// that leaks a webview per window leaks it once per window for the life of the
// process — and the single-window version could afford to be careless about it.
// `mut j` is required, not stylistic: the thread writes the failure back into
// the shared job for the joining side to read, and a plain `j &WindowJob`
// parameter makes V treat every field as immutable (it is the same aliasing
// rule that made the `for i, w in` loop fail in window.v).
fn window_thread(j &WindowJob) {
	cfg := j.cfg
	mut win := j.win
	if cfg.router == unsafe { nil } {
		unsafe {
			j.error = 'vails: Config.router is required on windows'
			j.failed = true
		}
		win.state = .closed
		return
	}
	// The apartment is entered HERE, immediately before the create that needs
	// it, so that the two early returns below it are the only ones that have to
	// remember to leave it. Entering it at the top of the function instead would
	// mean a third return path — the missing-router one above — carrying a
	// balance obligation, and an unbalanced CoUninitialize is the kind of bug
	// that shows up as a random failure in an unrelated COM client later.
	com := com_enter()
	w := unsafe { C.webview_create(0, unsafe { nil }) }
	if w == unsafe { nil } {
		com_leave(com)
		unsafe {
			j.error = 'vails: webview_create failed (is the WebView2 runtime installed?)'
			j.failed = true
		}
		win.state = .closed
		return
	}
	win.native = w
	bctx := &BindCtx{
		w:      w
		router: cfg.router
		label:  cfg.label
		reg:    cfg.registry
	}
	unsafe {
		C.vails_webview_bind(w, c'vails_call', voidptr(bind_cb), voidptr(bctx))
	}
	unsafe {
		C.webview_set_title(w, cfg.title.str)
		// WEBVIEW_HINT_NONE == 0
		C.webview_set_size(w, cfg.width, cfg.height, 0)
	}
	// The runtime plus this window's label, so the page knows which window
	// it is (F0 loads one document into every window).
	C.webview_init(w, label_js(bridge.runtime_js_bound('vails_call'), cfg.label).str)
	if cfg.url.len > 0 {
		C.webview_navigate(w, cfg.url.str)
	} else {
		// document() injects the default CSP (T7) into the served HTML.
		mut html := cfg.document()
		if html == '' {
			html = '<h1>Vails</h1>'
		}
		C.webview_set_html(w, html.str)
	}

	// Services (Phase 5) get the window handle + the V->JS eval path here,
	// before webview_run blocks in the message loop. Every window gets its own
	// MainThread, its own Ctx, and therefore its own job queue (U0): the queue
	// is per-window because the wakeup is per-window, and a shared queue would
	// make "which window runs this job" a question the queue cannot answer.
	mt := new_main_thread()
	// Read once, HERE, because this is the thread that owns the webview — the
	// one `webview_run` is about to block in. eval_sink compares against it to
	// decide between a direct eval and a dispatched one.
	owner_thread := unsafe { C.GetCurrentThreadId() }
	parent := unsafe { C.webview_get_window(w) }
	wctx := Ctx{
		label:    cfg.label
		eval_fn:  eval_sink(w, owner_thread, mt, parent)
		parent:   parent
		main:     mt
		close_fn: close_sink(w)
	}
	// The job wakeup is installed HERE, on THIS window's thread, before
	// on_ready. This is the one thread-affine step and it is not something
	// post_to_main may do: SetWindowSubclass from a worker is rejected
	// (webview/jobs.v, install_wakeup).
	mt.install_wakeup(wctx) or {
		eprintln('webview[' + cfg.label + ']: the main-thread job wakeup is ' +
			'unavailable: ' + err.msg())
	}
	// NO LIFETIME HOOK HERE, and the reason is written down because two attempts
	// at one were reverted and a third person would otherwise try a third.
	//
	// THE DEFECT, measured 2026-10-04 with two windows: closing the FIRST window
	// while another is still open leaves the process alive forever with no
	// windows. Closing the SECOND one first exits cleanly. Single-window
	// `examples/hello` exits cleanly, so it is specific to N > 1. A debugger
	// attach shows the main thread still inside `webview_run` -> `GetMessageW`
	// with its window already destroyed, because the library only ends the loop
	// for the LAST webview torn down in the process.
	//
	// WHAT WAS TRIED, both reverted:
	//   - `webview_terminate(w)` on WM_DESTROY: ends the hang but ALSO takes the
	//     other window down with it, so closing one window closed both. The
	//     library's "stop this webview" is coarser than that.
	//   - `PostThreadMessageW(owner_thread, WM_QUIT, ...)`: same over-correction,
	//     which is the useful part - it means the surviving window is not being
	//     closed by the quit at all, so whatever couples the two is downstream of
	//     the loop and has to be found before a third attempt is worth making.
	//
	// The Linux backend already has the shape of the right answer (count the
	// open windows, quit when the last one goes - webview_linux_shim.h), so the
	// fix is a Windows last-window rule that does not depend on `webview_run`
	// returning. That is real work, not a patch, and it is recorded in
	// tests/e2e_windows/README.md as F0 step 6 rather than left as a comment.
	win.ctx = wctx
	win.state = .ready
	// on_window BEFORE on_ready: an app that installs services in on_ready
	// should already have this window in its own registry.
	if on_window := cfg.on_window {
		on_window(win)
	}
	if on_ready := cfg.on_ready {
		on_ready(wctx)
	}
	win.state = .running

	rc := unsafe { C.webview_run(w) }
	// Still this window's thread: the loop has returned. This is the only place
	// the subclass may legally be removed and the only one that still owns the
	// window.
	mt.destroy()
	unsafe {
		C.webview_destroy(w)
		free(bctx)
	}
	win.state = .closed
	win.native = unsafe { nil }
	// The apartment goes LAST, after webview_destroy has released the last COM
	// object this thread was holding. Uninitialising COM while a WebView2
	// controller is still alive is a use-after-uninit that shows up much later
	// and nowhere near here, so the order is the fix and the comment is the
	// only thing that will keep it.
	com_leave(com)
	if rc < 0 {
		unsafe {
			j.error = 'vails: webview_run failed for window "' + cfg.label + '"'
			j.failed = true
		}
	}
}

// run_windows opens every window in cfgs and waits for all of them.
//
// THE FIRST WINDOW RUNS ON THE CALLING THREAD. That is not an optimisation,
// it is the one thing that keeps every shipped app working, and it was found
// the hard way: with all N windows spawned, `examples/services` no longer came
// up at all on Windows — the window never appeared and the process died with
// an unhandled exception, because WebView2 wants its first instance on the
// thread that started the process. So `webview.run` (one window) is
// byte-for-byte the code path it always was, and only windows 2..N are
// spawned. Single-window behaviour is therefore unchanged by construction,
// which is the property that made this safe to land at all.
//
// The second window's thread is still the F0 experiment, and it is honest to
// say so: if WebView2 turns out to refuse a second instance off the main
// thread too, the fix is in this function (run all windows on one thread and
// pump one loop), not in window.v, which is platform-neutral and fully tested.
fn run_windows(cfgs []Config) ! {
	// The registry is built and validated BEFORE any window exists, so a
	// duplicate or empty label is refused without a window ever appearing —
	// an app that asked for two windows called "main" should not get one window
	// up and then an error.
	reg := new_registry()
	mut jobs := []&WindowJob{}
	for cfg in cfgs {
		cfg.validate()!
		win := new_window(cfg.label)
		reg.add(win) or { return err }
		jobs << &WindowJob{
			win:  win
			cfg:  cfg
			done: chan int{cap: jobs.len + 1}
		}
	}
	// Windows 2..N get a thread each. The join is a CHANNEL, not
	// `sync.WaitGroup`, and that is a V 0.5.2 bug workaround rather than a
	// preference: `WaitGroup` works on a single thread and CRASHES the process
	// when `done()` is called from a spawned thread (measured in a 10-line file
	// with no Vails code — AGENTS.md §2c). The channel lives in a field of the
	// shared job rather than being an argument, because V rejects a mutable
	// non-reference argument in a `spawn` statement and `chan` is not one.
	for i in 1 .. jobs.len {
		spawn window_thread_tracked(jobs[i])
	}
	// The first window, inline, on the thread the app started on.
	window_thread(jobs[0])
	jobs[0].done <- 0
	// Now every window has to finish. The tokens from the spawned windows are
	// already waiting in the same channel (capacity jobs.len covers them), so
	// this reads one token per EXTRA window: the first window's own token is
	// consumed above, and it is the last thing that happened.
	for _ in 1 .. jobs.len {
		<-jobs[0].done
	}
	// Every window's thread has returned, so nothing can reach the windows any
	// more and the registry's pointers are no longer needed. The Windows are
	// not freed: the app may still hold a &Window, and `is_open()` answering
	// truthfully after a close is worth more than the memory.
	//
	// The FIRST failure is reported, in creation order, because "window 2 of 3
	// failed to create" is more actionable than three messages and a guess.
	for i in 0 .. jobs.len {
		if jobs[i].failed {
			return error(jobs[i].error)
		}
	}
}

// window_thread_tracked is window_thread plus the join signal, as a separate
// function because the signal has to be sent on EVERY path out of the thread
// body — including the early return for a window that could not be built. A
// missed send is not a crash, it is a main thread that waits forever with no
// diagnostic, which is the worst possible symptom of a missed signal.
fn window_thread_tracked(j &WindowJob) {
	window_thread(j)
	j.done <- 0
}
