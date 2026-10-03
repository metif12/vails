# ADR-0019 — `webview.post_to_main`: a worker handing work back to the window thread

Date: 2026-09-29. Status: **accepted, Windows half shipped; Linux half deferred**
(ROADMAP track U0 / W0). The job queue and `webview.post_to_main` are in
`webview/jobs.v` and verified on Windows. `g_idle_add` is not written.

> **The subscriber list was never built, and does not need to be.** The first
> draft of this ADR proposed a `subs []HostHandler` list on `HostCtx` so two
> services could both listen on one window. ADR-0023 rejected that and shipped
> chaining instead (`HostHandler` returns `!bool`, handlers chain through
> `SetWindowSubclass`). **The `tray` service was consequently not migrated** —
> it still owns its own `&HostCtx`, which is correct and unchanged. The chaining
> answer covers OS-initiated messages; it does not deliver a V closure, so the
> job queue below is still the missing half, and that half shipped.
>
> **Two decisions below were changed by the implementation, and the reasons are
> worth more than the plans they replaced.** Both are recorded in "Decisions
> (as shipped)" with what the first version got wrong:
>
> 1. The wakeup subclass is installed **eagerly, by `webview.run`, on the window
>    thread** — not lazily on the first post as planned. `SetWindowSubclass` is
>    thread-affine, and `post_to_main` is by definition called from a worker, so
>    the lazy version failed on the first real run.
> 2. A posted job is a **`Job` closure (`fn ()`), not a `&Job` pointer** whose
>    lifetime the main thread owns. V owns the closure; the explicit
>    free-the-job-here rule has nothing left to do.
>
> The plan's Linux half (`g_idle_add`) is unwritten, and the reason is still the
> one below: writing GTK C that has never been compiled is how wave 3 broke.

Date added: 2026-09-29.

## Context

ADR-0010 set the threading rule the whole framework runs on: **command
handlers execute on the webview main thread, so they must be fast; slow work
goes to a `spawn`ed worker and the result comes back as an event.** Every
service so far is either fast (clipboard, opener, os-info) or modal
(`dialog`, `menu` — both run their own nested native loop, so the window
keeps painting). Nothing in the catalog actually needs a worker yet, which is
why the hole has stayed hidden.

The hole is in the second half of the rule. `webview/ctx.v` says it plainly:

> Threading: `eval_fn` runs on the webview main thread, the same thread the
> command handlers run on (ADR-0010).

So a spawned worker can compute a result and then has no way to hand it to the
page. It cannot call `ctx.emit`, because that ends in `webview_eval` on a
thread the WebView2/WebKitGTK object does not own. The work is computed and
then dropped on the floor.

ADR-0017 built the only thing that crosses back, and it is the wrong shape for
this:

- **It is Windows-only.** There is deliberately no `host_linux.c.v` (ADR-0017:
  "Linux needs no window procedure at all"). That reasoning is correct for the
  OS-initiated direction — a `GtkMenu` emits `activate` on the item that was
  clicked — and irrelevant here, because a V worker is not a GTK object and
  holds no signal.
- **It is one handler per window.** `HostCtx` carries a single
  `on_event HostHandler`, and `tray` owns it. `SetWindowSubclass` with a second
  proc on the same HWND is not a second listener, it is a replacement or a
  failure.
- **Its payload is an integer.** `HostEvent` is `{msg u32, wparam u64, lparam
  i64}` because a `NOTIFYICONDATA` callback carries exactly that. There is no
  way to post "run this closure".

Three items already on the ROADMAP need a worker, and each would otherwise
have to reinvent this or avoid it:

- **the `window` service** (ADR-0021, track W) — a frameless window's drag
  and resize contract, and `window-state` / `positioner` (persist size and
  position, which needs a debounce timer on a worker). `WM_SIZE` / `WM_MOVE`
  arrive on the window thread, but restoring them means the debounce.
- **`menu.set_menu`** (S1 wave 4) — `WM_COMMAND` routing for a window menu bar.
  Same seam, different messages, and it competes with `tray` for the slot.
- **the `updater` service** (ADR-0020, track U) — a download is the canonical
  slow work, and its progress has to reach the page as
  `updater:download-progress`.

Three dependents, not one, is what makes this the first thing any of the three
tracks should do, and why the window chrome track's W0 and the updater track's
U0 are the same piece of work rather than two.

## Superseded in part: the subscriber list (ADR-0023, 2026-09-29)

The original draft of this ADR proposed a `subs []HostHandler` list on
`HostCtx`, with the first subscriber installing the subclass and the last
removing it. **ADR-0023 rejected that and shipped something else**, so the
list is not the plan:

- `pub type HostHandler = fn (e HostEvent) !bool` — the handler now answers
  whether it consumed the message, which is the piece this ADR had to invent a
  registry to solve.
- Two `SetWindowSubclass` procs chain, each calling the next for a message it
  did not consume, and the last one calls `DefSubclassProc`.

This is a better answer than the one proposed here, for a reason worth
recording: it needs no shared mutable state, so it needs no mutex, and the
thing that was going to be the concurrency risk in U0 does not exist. The
`!bool` return also makes each service's ownership of its own messages
explicit rather than inferred from registration order.

What chaining does **not** do is deliver a V closure. It routes *messages*, and
`HostEvent` is three integers by design — the original draft made the same
point in its Context section. So the job queue, `post_to_main`, and the Linux
`g_idle_add` trampoline below are all still required, and `ROADMAP` U0 now
means "the job half of this ADR", not the whole of it. The window-chrome
track's W0 (ADR-0021) is the same work.

## Decisions (as shipped, 2026-09-30)

- **A posted job is the unit, not a message.** `webview.post_to_main(ctx, fn
  ())` takes a closure and runs it on the window thread. The OS message is
  demoted to what it should always have been: a wakeup. A `HostEvent` still
  exists for genuinely OS-initiated input (`tray`, `window-state`), and a
  closure cannot be confused with a notification's `lParam` because it is not
  an integer. **Changed from plan:** the queue holds `[]Job` where
  `pub type Job = fn ()`, not `[]&Job`. The plan made the posted unit a raw
  pointer and gave the main thread ownership of freeing it, reasoning that "the
  main thread is the only one that dereferences the pointer, so it also owns it"
  (the same argument `detach` makes about its own context). A V closure is
  already a GC-managed value: the main thread *does* dereference it, and V
  frees it, so the ownership rule had nothing left to do and would have been a
  manual free of something already accounted for. The `HostEvent`-is-three-
  integers point — the actual reason the plan rejected a message payload —
  survives unchanged.
- **A job queue, not a job per message.** `JobQueue` is a `&sync.Mutex`-guarded
  `[]Job`. `post_to_main` locks, pushes, unlocks, then posts a single wakeup;
  the window-thread side drains the queue and runs each job. One wakeup per
  burst, and a queue that cannot overflow because it is a slice, not a message
  payload. `sync.new_mutex()` exists on both platforms (Windows and pthread), so
  this needs no C and no `sync/atomic` ring.
- **`take()` releases the lock before the batch runs.** This was not in the
  plan and is the one concurrency property with a test
  (`test_a_job_that_posts_again_does_not_deadlock`): `take` detaches the batch
  under the lock, and `run_batch` runs it with the lock released. Holding the
  lock across `run_batch` would make a job that itself calls `push` re-enter a
  non-recursive `SRWLOCK` and hang forever, with no error and no stack — a hang
  that looks like slow work. A nested job is left queued for the next wakeup
  rather than run inline, so a determined job cannot recurse without bound.
- **The subclass is installed eagerly, by `webview.run`, on the window thread.**
  This replaces the plan's "install on the first post", and the plan was not
  merely an optimisation — **it could not work.** `post_to_main`'s caller is by
  definition a `spawn`ed worker (ADR-0010: a worker is the only thing with a
  reason to post), and `SetWindowSubclass` is thread-affine: it mutates state
  comctl32 associates with the window's creating thread, so a subclass
  installed from a worker is rejected. The first real E2E run failed with
  `SetWindowSubclass failed (code 0)` on the first post, from the only thread
  that posts. `webview.run` therefore calls `MainThread.install_wakeup` right
  after the window exists and before `on_ready` hands out the `Ctx`; from then
  on `post_to_main` does only the two thread-safe things (push under the mutex,
  `PostMessage`).
  - **What this costs, stated honestly:** every window now carries one subclass
    that does nothing but forward every message to `DefSubclassProc` — the same
    forwarding the `tray` subclass already does. ADR-0017's on-demand property
    still holds where it was actually about: *services* (`tray`) attach on
    demand and are unchanged. The job wakeup is runtime, not a service, and one
    forwarding subclass is a cheaper price than a feature that cannot be called
    from the thread it exists for.
  - **A failed install is not fatal to the window.** `install_wakeup` returns
    `!`, the backend logs it, and the app still runs: an app that never posts
    never notices, and `post_to_main` turns a missing wakeup into a named error
    at the point of use. A window that cannot be subclassed is a broken
    feature, not a broken app.
- **`Ctx` carries the seam.** `webview.run` builds one `MainThread` per window
  and puts it on the `Ctx` it hands to `on_ready`, so `post_to_main` finds the
  window's queue without the app holding anything extra. `Ctx` is copied by
  value in several places and the queue must be shared by every copy, so
  `Ctx.main` is a `&MainThread`, not a value. **Changed from plan:** this was
  written as "one `HostCtx` per window" and was corrected to a separate
  `MainThread` type. A `HostCtx` is a *subclass* (a message filter, owned by
  whoever attached it) and the queue is not a subclass; giving the queue its own
  type keeps `tray`'s context and the runtime's queue from ever being mistaken
  for the same thing, which is the mistake ADR-0023 already had to unpick once.
- **A job queue with no wakeup is refused at the call site.**
  `post_to_main` checks `hook == nil` and returns an error *before* pushing,
  because a queue with no wakeup would accept the job and then do nothing with
  it forever — the one outcome a caller cannot distinguish from slow work. This
  is not a defensive branch for a rare state: it is the state every first post
  reached under the lazy design, and it is pinned by
  `test_post_to_main_refuses_a_window_with_no_wakeup`.
- **A platform with no wakeup says so, loudly.** `post_to_main` without a
  parent handle, or without a `main`, is an error naming the fix (pass the
  `Ctx` from `on_ready`), not a silent no-op that drops the job. A dropped job
  looks exactly like a hung download.
- **The wakeup has its own message id.** `host_message` is `WM_APP+1` and is
  owned by `tray`; the wakeup is `WM_APP+2` (`webview/host.v`). A wakeup on
  `WM_APP+1` would arrive at a live tray as an indistinguishable "left click",
  because `tray` classifies on `msg == host_message` and nothing else — so a
  job-queue wakeup would open a tray menu with no error anywhere. Two ids, two
  owners, and each handler declines the other's. Pinned by
  `test_wakeup_message_is_a_different_id_from_host_message`.

## Rejected alternatives

- **Let services emit from a worker and document the risk.** WebView2 and
  WebKitGTK both have undefined behaviour for evaluation from a foreign
  thread. "Probably works on the main platforms" is precisely the class of
  claim this repo's Verification-status sections exist to avoid.
- **Run the slow work on the main thread and accept the freeze.** This is the
  smallest diff — no seam at all — and it is what ADR-0010 forbids. It is also
  self-defeating for the updater: a frozen window cannot render a progress bar.
- **One handler per service, each installing its own subclass.** Two
  `SetWindowSubclass` procs on one HWND do not compose; the second call either
  fails or silently replaces the first, and `tray` would stop working the
  moment the updater was installed. This is the bug the subscriber list exists
  to make impossible rather than unlikely.
- **A process-wide registry of seams, keyed by HWND.** It is the obvious
  design, and it needs a global — forbidden by AGENTS.md §2 and a garbage
  collector's problem in V. Hanging the seam off the `Ctx` the backend already
  builds costs one pointer and has no lifetime question at all.

## Consequences

- **`services/tray.v` is unchanged, on purpose.** The plan had `TrayState` hold
  a subscription instead of a `&webview.HostCtx`, and `tray.destroy`
  unsubscribing instead of detaching. ADR-0023 removed the need for a
  subscription list, so the migration was dropped: `tray` keeps its own
  `HostCtx`, and it now coexists with the job wakeup's subclass on the same
  HWND by chaining. Its wire contract, events and tests are unchanged, and
  `tray` is a second independent confirmation that the chaining design works.
- Any service that wants a worker writes `spawn` + `post_to_main(ctx, fn
  ())` and needs no knowledge of the queue, the subclass, `WM_APP+2` or
  `g_idle_add`. That is the entire point: ADR-0017 leaked the subclass into
  `tray`, and this is where that leak is paid back.
- `MainThread.destroy` detaches the wakeup and then releases the mutex, and it
  runs after `webview_run` returns — still the window's thread, and the last
  moment the subclass may legally be removed.
- **The Linux half is the least-verified piece of the plan and it is unwritten.**
  GTK 3.24 is installed and `v test .` is green there, so nothing *blocks* the
  Linux half on the toolchain any more. What is unproven is narrower and more
  specific: **nothing in this repo has ever pushed work onto the GTK main loop
  from a thread that does not own it**, which is exactly what bit the lazy
  Windows install on its first run. The Linux proof is therefore a
  first-of-its-kind and needs a real check. Until then `post_to_main` returns
  `vails: post_to_main is not available on linux yet (the g_idle_add half is
  unwritten - ADR-0019)` — a named refusal, not a silent drop. `webview.run`
  still creates and destroys a `MainThread` on Linux so the shape stays
  symmetric and the backend call site is not inside a `$if`.
- **What the E2E run taught, beyond the Win32 fix.** The `post` probe in
  `examples/services` is a screenshot, and it earned its keep twice: it caught
  the false-positive probe (a page-side `Promise.resolve` that reported success
  on page load, before the worker had posted anything), and then it caught the
  `SetWindowSubclass` failure as a real error string rather than a missing
  status line. A unit test could not have found either.

## Notes (verified against V 0.5.2 while planning this)

- **`sync.new_mutex()` exists on both platforms** —
  `vlib/sync/sync_windows.c.v` and `vlib/sync/sync_default.c.v` (pthread), both
  returning `&Mutex` with `lock` / `unlock` / `try_lock`. So a queue behind a
  mutex is pure V, and no `sync/atomic` ring buffer is needed. (`sync/atomic`
  is not a module here at all — the atomics live in `vlib/sync/atomic/` as
  `atomic.v` under a different layout than one would guess.)
- **`os.Process` cannot spawn.** `vlib/os/process.v` has exactly four public
  functions — `new_process`, `set_args`, `set_work_folder`, `set_environment`,
  `set_stdin_path` — and **no `run`**. `os.execute` is fully synchronous. So a
  detached spawn is a C shim. That is a finding for ADR-0020's helper mode,
  not for this ADR, but it is recorded here so U0 does not go looking.
- **`os.getpid()` is available on both** (`os_windows.c.v:776`,
  `os_nix.c.v:534`), which is what a parent-identity handoff will need.
- **The `uIdSubclass` carrier from ADR-0017 still applies and is the reason a
  64-bit job pointer cannot ride in a subclass field.** `dwDataRef` is a
  `DWORD`; a job pointer is 64-bit. A new message id plus the queue — not a
  wider carrier — is the fix.
- **The wakeup needs a second message id, not `host_message`.** `host_message`
  is `WM_APP+1` and is pinned by `host_test.v:7`; `tray` classifies `lParam`
  against it in `tray_click`. A wakeup on the same id would be an
  indistinguishable "button left" click to a live tray. `WM_APP+2` is the id,
  and it gets its own constant beside the existing one.
