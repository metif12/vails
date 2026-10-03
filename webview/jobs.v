// jobs.v — the job half of the main-thread post seam (U0, ADR-0019).
//
// ADR-0010's threading rule: handlers run on the webview main thread, so slow
// work goes to a spawn()ed worker and the result comes back as an event. The
// hole is the second half: a worker cannot call ctx.emit, because that ends
// in webview_eval on a thread the webview object does not own.
//
// post_to_main closes it: the worker hands a closure to the window thread, and
// the window thread runs it. The closure is the unit, not a message — a
// HostEvent is three integers by design and cannot carry one.
//
// ADR-0019's subscriber list is NOT here: ADR-0023 solved the two-listeners
// problem by making HostHandler return !bool and chaining subclasses, so
// post_to_main is just another user of that chain and needs no registry.
//
// The lock is a real sync.Mutex, not an injectable seam: sync is C on both
// platforms (SRWLOCK on Windows, pthread on Linux), so this file is not
// pure-V. That is fine — the webview module already needs a C compiler, and
// the re-entrancy test below is stronger against a real mutex than a no-op.
module webview

import sync

// Job is one unit of work to run on the window thread.
//
// No error return: a job that can fail reports its own failure by emitting an
// event (ADR-0010), because by the time it runs the caller that could receive
// an error is gone. A job that panics ends the app — there is no try/catch in
// V, and a panic unwinding through C from inside a subclass is not recoverable.
pub type Job = fn ()

// JobQueue is the pending jobs, behind a mutex.
pub struct JobQueue {
pub mut:
	mu      &sync.Mutex
	jobs    []Job
	drained int
}

// new_queue builds a queue with a real mutex.
pub fn new_queue() JobQueue {
	return JobQueue{
		mu: sync.new_mutex()
	}
}

// push appends one job.
pub fn (mut q JobQueue) push(job Job) {
	q.mu.lock()
	q.jobs << job
	q.mu.unlock()
}

// take removes and returns every pending job, under the lock.
//
// The lock is released before the caller runs the batch: a job that itself
// calls push would otherwise re-enter a non-recursive mutex and deadlock.
// That bug only appears under load, so it has a test.
pub fn (mut q JobQueue) take() []Job {
	q.mu.lock()
	batch := q.jobs
	q.jobs = []Job{}
	q.mu.unlock()
	return batch
}

// run_batch runs each job in order and counts them.
pub fn (mut q JobQueue) run_batch(batch []Job) int {
	mut ran := 0
	for job in batch {
		job()
		ran++
	}
	q.mu.lock()
	q.drained += ran
	q.mu.unlock()
	return ran
}

// drain takes the pending batch and runs it.
pub fn (mut q JobQueue) drain() int {
	return q.run_batch(q.take())
}

// destroy releases the mutex. The mutex is inline (SRWLOCK / pthread_mutex_t),
// so there is no heap block to free; destroy is for symmetry with the rest of
// sync and for the day a backend grows one.
pub fn (mut q JobQueue) destroy() {
	q.mu.destroy()
}

// MainThread is the per-window job queue plus the seam that wakes it. One per
// window, created by webview.run and carried on the Ctx.
pub struct MainThread {
pub mut:
	queue JobQueue
	// hook is the chained subclass that drains the queue. Installed on the
	// window thread by install_wakeup, and nil until it has run — so it is not
	// a property new_main_thread has, it is a property webview.run gives this
	// window (see install_wakeup for why it cannot be lazy).
	hook &HostCtx = unsafe { nil }
}

// new_main_thread builds the per-window seam.
pub fn new_main_thread() &MainThread {
	return &MainThread{
		queue: new_queue()
	}
}

// destroy detaches the wakeup and releases the queue's mutex. It runs on the
// window thread after the message loop has returned, which is the only thread
// the subclass may be removed from and the only one that is still the window's
// owner at that point.
pub fn (mut mt MainThread) destroy() {
	if mt.hook != unsafe { nil } {
		detach(mut mt.hook)
		mt.hook = unsafe { nil }
	}
	mt.queue.destroy()
}

// install_wakeup attaches the subclass that drains this window's queue. It MUST
// be called on the window's own thread, and webview.run does exactly that,
// right after the window exists and before any app code can post.
//
// WHY IT CANNOT BE LAZY — and the wrong version of this function shipped first.
//
// The first draft installed the hook on the first post_to_main call, which is
// what "a window whose app never posts gets no subclass" wants, and it failed
// on the first real run: SetWindowSubclass returned FALSE and the app got
// "could not install the window wakeup (code 0)". The reason is that
// post_to_main's caller is by definition a spawn()ed worker (ADR-0010 — a
// worker is the only thing with a reason to post), and SetWindowSubclass is
// thread-affine: it mutates state comctl32 associates with the window's
// creating thread, so a subclass installed from a worker is rejected. The
// lazy design was therefore not merely an optimisation, it was the one design
// that cannot work, and it failed silently in the only direction that matters
// (the first post, from the only thread that posts).
//
// The eager cost is one subclass per window that does nothing but forward every
// message to DefSubclassProc, which is the same forwarding the tray's subclass
// already does. The lazy saving is not worth a feature that cannot be called
// from the thread it exists for. The ADR-0017 on-demand property still holds
// where it was actually about: *services* (tray) attach on demand, and
// post_to_main did not need to be a service to be correct.
//
// A failed install is not fatal to the window — an app that never posts never
// notices, and post_to_main reports this as a named error if it tries — so this
// is a `!` the backend logs rather than a startup abort.
pub fn (mut mt MainThread) install_wakeup(ctx Ctx) ! {
	$if windows {
		if mt.hook != unsafe { nil } {
			return
		}
		mt.hook = attach(ctx, fn [mt] (e HostEvent) !bool {
			if e.msg == wakeup_message {
				// The address of the real field, not a copy of it: V refuses to
				// pass a field expression as a `mut` receiver, and taking the
				// address keeps the drain operating on the shared queue rather
				// than on a snapshot.
				mut q := &mt.queue
				q.drain()
				return true
			}
			// Not the wakeup: the tray's own subclass (or the library's window
			// procedure) owns everything else, and swallowing it would break
			// WebView2 (ADR-0023's chaining rule).
			return false
		}) or {
			return error('vails: could not install the main-thread job wakeup: ' +
				err.msg())
		}
	} $else {
		// No window procedure to subclass, so there is no wakeup to install.
		// post_to_main is unavailable on this platform anyway (see below); this
		// exists so the backend call site is not inside a $if.
		_ = ctx
	}
}

// post_to_main hands one job to the window thread.
//
// The job runs on the webview main thread, so it can call ctx.emit and touch
// native UI — the two things a worker cannot do. The caller gets no result:
// the job is fire-and-forget by the time it runs.
//
// Safe to call from any thread, which is the whole point: every operation here
// is thread-safe (push is under a mutex, the wakeup is a PostMessage) and none
// of them touch the window directly. The thread-affine part — installing the
// subclass — was moved to install_wakeup, on the window thread, for the reason
// documented there.
pub fn post_to_main(ctx Ctx, job Job) ! {
	if !ctx.has_main() {
		return error('vails: post_to_main needs a live window (pass the Ctx from Config.on_ready)')
	}
	$if windows {
		mut mt := ctx.main
		// A queue with no wakeup would accept the job and it would sit there
		// forever, which is the one outcome a caller cannot tell from a hang.
		// Say it happened here, where the caller is still watching.
		if mt.hook == unsafe { nil } {
			return error('vails: post_to_main: this window has no job wakeup (the ' +
				'window could not be subclassed - see webview.run)')
		}
		mt.queue.push(job)
		post_message(ctx, wakeup_message, 0, 0) or {
			return error('vails: post_to_main could not wake the window: ' + err.msg())
		}
	} $else $if linux {
		// The g_idle_add half is deliberately unwritten: nothing in this repo
		// has ever pushed work onto the GTK main loop from a thread that does
		// not own it, and writing GTK C that has never been compiled is how
		// the wave-3 Linux build broke for four ordinary reasons while being
		// blamed on V (ADR-0015). The half waits for the container.
		return error('vails: post_to_main is not available on linux yet (the ' +
			'g_idle_add half is unwritten - ADR-0019)')
	} $else {
		return error('vails: post_to_main is not available on this platform')
	}
}
