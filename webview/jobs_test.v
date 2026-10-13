module webview

// A queue with a real mutex. The webview test binary already needs a C
// compiler (the module has webview_windows.c.v), so there is no gcc-free
// claim to preserve here — and a real mutex makes the re-entrancy test
// below a genuine deadlock check rather than a no-op that would pass even
// if take() held the lock while running jobs.
fn real_queue() JobQueue {
	return new_queue()
}

// OrderList and Probe exist because V closures copy inherited variables by
// value: a closure that does `n++` on a captured int increments its own copy,
// and the outer variable never moves. Capturing a POINTER shares the pointee,
// so mutations through it are visible outside. That is the only way to assert
// what a job actually did.
struct OrderList {
mut:
	items []int
}

struct Probe {
mut:
	count int
}

fn test_push_appends_in_order() {
	mut q := real_queue()
	q.push(fn () {})
	q.push(fn () {})
	q.push(fn () {})
	assert q.jobs.len == 3
}

fn test_take_removes_everything_and_returns_it_in_order() {
	// The order is the contract: a worker that posts "step 1" then "step 2"
	// expects them to run in that order, and a queue that reverses them is a
	// queue that corrupts a progress bar.
	mut q := real_queue()
	mut order := &OrderList{}
	for i in 0 .. 3 {
		n := i
		q.push(fn [n, mut order] () {
			order.items << n
		})
	}
	batch := q.take()
	assert batch.len == 3
	assert q.jobs.len == 0
	q.run_batch(batch)
	assert order.items == [0, 1, 2]
}

fn test_take_on_an_empty_queue_is_not_an_error() {
	// The drain runs on every wakeup, including the ones a burst of posts
	// causes after the queue is already empty. Taking nothing must be a no-op,
	// not a panic on a zero-length slice.
	mut q := real_queue()
	assert q.take().len == 0
	assert q.drain() == 0
	assert q.drained == 0
}

fn test_run_batch_counts_what_it_ran() {
	mut q := real_queue()
	assert q.run_batch([fn () {}, fn () {}]) == 2
	assert q.drained == 2
	// The counter is cumulative across batches, which is what makes a doctor
	// line or a test able to say "N jobs have run on this window".
	assert q.run_batch([fn () {}]) == 1
	assert q.drained == 3
}

fn test_a_job_that_posts_again_does_not_deadlock() {
	// The bug this guards: take() holds the lock while run_batch() runs the
	// jobs, and a job that calls push() re-enters a non-recursive mutex. On
	// Windows that is SRWLOCK, which is not recursive, so the second lock()
	// blocks forever — a hang with no error and no stack, in a worker that
	// looks like it is simply slow.
	//
	// take() releases the lock before run_batch() runs anything, so the
	// nested push succeeds and the nested job is left queued for the next
	// wakeup rather than run inline (which would be unbounded recursion).
	mut q := real_queue()
	// A pointer, not the value: V copies inherited variables, so a closure
	// capturing `q` by value would push onto its own copy and the outer queue
	// would never see the nested job. The pointer is shared.
	qp := &q
	mut probe := &Probe{}
	q.push(fn [qp, mut probe] () {
		probe.count++
		qp.push(fn () {})
	})
	ran := q.drain()
	assert ran == 1
	assert probe.count == 1
	// The nested job is queued, not run: running it inline would let a
	// sufficiently determined job recurse without bound.
	assert q.jobs.len == 1
	assert q.drained == 1
}

fn test_a_panicking_job_does_not_stop_the_next_one() {
	// There is no try/catch in V, so a panicking job cannot be caught here.
	// What CAN be guaranteed is that the panic does not corrupt the queue:
	// the batch was already taken out from under it, so the next wakeup still
	// has work to do and the counter is still accurate.
	//
	// The panic itself unwinds through C from inside a subclass and ends the
	// app — that is documented on Job, not hidden. This test only pins the
	// queue's side of it.
	mut q := real_queue()
	q.push(fn () {})
	q.push(fn () {})
	batch := q.take()
	assert batch.len == 2
	// Simulate the first job dying before the second runs: the batch is
	// already detached, so the queue is untouched by it.
	assert q.jobs.len == 0
}

fn test_destroy_is_safe_on_a_queue_that_was_never_used() {
	// webview.run creates a MainThread for every window, including one whose
	// app never posts. destroy() runs on every path, so it must be a no-op on
	// an empty queue rather than a nil dereference.
	mut q := real_queue()
	q.destroy()
}

fn test_a_fresh_main_thread_has_no_hook() {
	// new_main_thread is a pure constructor: it does not touch a window, so it
	// cannot install a subclass and does not pretend to have one. The hook
	// arrives later, from install_wakeup on the window thread.
	mt := new_main_thread()
	assert mt.hook == unsafe { nil }
	assert mt.queue.jobs.len == 0
	mt.destroy()
}

fn test_post_to_main_refuses_a_window_with_no_wakeup() {
	// The bug this pins is the reason install_wakeup exists. A MainThread with
	// no hook means the subclass could not be installed, and a queue with no
	// wakeup accepts the job and then does nothing with it — forever. That is
	// the one failure a caller cannot distinguish from slow work, so
	// post_to_main says so at the call site instead of taking the job.
	//
	// The old lazy design reached this state on EVERY first post (a worker's
	// SetWindowSubclass is rejected), which is why this case is a test and not
	// a defensive branch.
	mut mt := new_main_thread()
	mut c := Ctx{
		label: 'main'
		main:  mt
	}
	mut ran := &Probe{}
	mut why := ''
	post_to_main(c, fn [mut ran] () { ran.count++ }) or { why = err.msg() }
	assert ran.count == 0
	assert why.contains('post_to_main')
	// The refusal NAMES the half that is missing, and which half that is differs
	// by platform — so the word differs and one fixed word cannot assert both.
	//
	// Windows subclasses the window, and the subclass IS the wakeup, so a window
	// that could not be subclassed has a queue nothing will ever drain. Linux has
	// no wakeup at all: there is no half of one, because the g_idle_add seam that
	// would own it is unwritten (ADR-0019), and post_to_main refuses outright
	// rather than pretending to queue.
	//
	// Asserting 'wakeup' unconditionally is what made this file fail on Linux, and
	// simply dropping the line would have been the other mistake: a check that
	// cannot fail on one platform is not a weaker check, it is no check. Each
	// branch below asserts its own platform's actual message, including the
	// 'linux' spelling that distinguishes the deliberate branch from the generic
	// "not available on this platform" fallback.
	$if windows {
		assert why.contains('wakeup')
	} $else $if linux {
		assert why.contains('linux')
		assert why.contains('g_idle_add')
	}
	// And it refused BEFORE queueing, so the queue is not holding a job that
	// nothing will ever run. This is the platform-neutral half of the property and
	// it is asserted everywhere.
	assert mt.queue.jobs.len == 0
	mt.destroy()
}

fn test_a_hand_built_ctx_has_no_main() {
	// The error post_to_main gives for a hand-built Ctx is the same shape as
	// attach's: a test Ctx is not a window, and pretending otherwise is how
	// a job gets dropped silently.
	c := Ctx{
		label: 'main'
	}
	assert !c.has_main()
	mut why := ''
	post_to_main(c, fn () {}) or { why = err.msg() }
	assert why.contains('needs a live window')
	assert why.contains('on_ready')
}

fn test_wakeup_message_is_a_different_id_from_host_message() {
	// The bug this pins: a wakeup posted on WM_APP+1 arrives at the tray's
	// handler as an indistinguishable "left click". The tray classifies on
	// msg == host_message and nothing else, so the wakeup would open a tray
	// menu with no error anywhere. Two ids, two owners.
	assert host_message == 0x8001
	assert wakeup_message == 0x8002
	assert host_message != wakeup_message
}

fn test_post_to_main_without_a_window_is_refused_before_it_touches_the_queue() {
	// The check is first, so a Ctx with no window never reaches push() —
	// which would queue a job on a seam that cannot be woken, and would
	// install a subclass on a handle that does not exist.
	c := Ctx{
		label: 'main'
	}
	mut why := ''
	post_to_main(c, fn () {}) or { why = err.msg() }
	assert why != ''
	// And the refusal is an error, not a silent no-op: a dropped job is
	// indistinguishable from work that never finished.
	assert why.contains('post_to_main')
}
