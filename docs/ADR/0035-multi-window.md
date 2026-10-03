# ADR-0035 — multi-window: the registry, the routing, and the window that is
# not open yet

Date: 2026-09-30. Status: **accepted; the Windows second window is written and
type-checked but NOT observed** (ROADMAP track F0). The routing half is shipped
and tested. The window half no longer refuses — it runs — and nobody has watched
it work, because this machine's `webview` test module crashes the host. The
proof is named in "Verification" and it has not been run.

## Context

Every app in this repo has exactly one window. `webview.run(cfg)` creates one
webview and blocks in its message loop; `VailsConfig.windows` is a *list*, but
`window(label)` returns one entry and every call site runs a single `webview.run`.
A list of configs is not multi-window.

Three dependents are waiting on it, which is what makes it the highest-leverage
single item in the backlog: the window-chrome track's per-window tests,
`tray.set_menu`'s window menu bar, and the updater's own UI (which needs a second
window because there is no second window to run it in).

The ROADMAP named the hard half precisely, and it is worth preserving verbatim
because it is the reason this ADR exists:

> plus a window registry keyed by label, a `Ctx` per window, and **per-label
> event routing** — the last is the half that is easy to get wrong, because
> `Ctx.emit` resolves through one `eval_fn` and two windows with the wrong one
> deliver one window's events into the other's page, **which is invisible in a
> single-window test suite**.

That last clause is the whole problem. With one window, emitting to the wrong
window is not a crash: the event is delivered, the promise resolves, the status
line on the wrong page changes, and every test and every screenshot still looks
fine. A single-window proof suite *cannot* find this class of bug, so the fix
cannot be "be careful" — it has to be a structure that makes the mistake
unrepresentable and then a test that pins the structure.

## Decisions

- **`webview.Window` is a thing, not a `Ctx`.** `Window{label, ctx, state,
  native}` where `state` is `created → ready → running → closed`. The `Ctx`
  knows its own label but is not addressable, and building the app's own parallel
  `&Window`s would mean two registries that can disagree about which window is
  which. So `Config.on_window` hands the app **the backend's own** `&Window`,
  once per window, before `on_ready` for that window — the app's registry and
  the backend's then route through the same objects.
- **`emit_to(label, event, data)` is the public routing surface.** A caller
  names a window and never holds a `Ctx` it could use by mistake. Every branch
  in it is a bug that was reachable in the single-window shape:
  - **an unknown label is an error**, and nothing is delivered anywhere. The
    tempting alternative is to fall back to "the first window" or to "main",
    which delivers the event to a real and *wrong* page — a missing route that
    looks like a success. The message names the labels that ARE open, because
    `no window labelled x` with an empty list is much harder to act on.
  - **a window that is not `ready` is an error naming its state**, because
    emitting through a nil `eval_fn` is a call through a null function pointer,
    which is a crash rather than an error.
  - **the event goes through THAT window's own `ctx`**, never a cached one.
- **Two windows may not share a label.** Two windows with one label share a
  capability identity (T1/ADR-0007) — a command granted to `main` would be
  allowed from the second window — and `emit_to("main")` would have two
  destinations and no way to choose. It is a security hole and an ambiguous
  route at once, so `add` refuses it.
- **`find` returns a plain `&Window`, not `?&Window`.** That is a V 0.5.2 bug
  workaround, not a style choice, and the damage was nasty enough to be worth
  spelling out: for an `Option` of a **reference** type holding **none**, `or`
  does not run its block, so `has()` written the obvious way returns **true for
  a window that does not exist** and a duplicate check rejects the *first*
  insert. It presented as `assert !r.has('main')` failing on a provably empty
  registry. AGENTS.md §2c has the measurement.
- **Every eval goes to the thread that owns its webview, and which thread that
  is is a property of the window.** The single-window `eval_sink` could assume
  it was on the loop that owned the webview. `window_thread` now reads
  `GetCurrentThreadId()` once — on the thread about to block in
  `webview_run` — and `eval_sink` compares: on the owner's thread it calls
  `webview_eval` directly, from anywhere else it dispatches. The direct branch
  is not an optimisation. The first attempt routed *everything* through
  `webview_dispatch`, and the U0 post probe stopped working: the wakeup handler
  runs *inside* the window's message loop, and asking the library to re-dispatch
  a callback to the loop that is currently calling it is **refused** (dispatch
  returned 0 and the page never saw its result). Keeping the direct call also
  preserves the long-standing property that an emit from a handler has taken
  effect by the time the handler returns.
- **The label is injected into the page, because F0 loads one document into
  every window.** `window.vails.label`, appended *after* the runtime IIFE (which
  returns early when `window.vails` already exists) and **single-quoted** — see
  the rejected alternative below; this one bit in production-shaped code.
- **Every window's thread gets its own COM apartment.** `com_enter` in
  `webview_windows.c.v` is `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)`
  immediately before `webview_create`, and `com_leave` is `CoUninitialize`
  immediately after `webview_destroy`. The process's first window never needed
  it — the OS gives the thread that starts a process an STA at startup — which is
  exactly why the missing apartment stayed invisible for the whole single-window
  era and only bit when F0 added a window on a `spawn`ed thread. See "The window
  that is not open" below.
- **`run_many`'s rules moved into `check_windows`, and the refusal is gone.** See
  below. The extraction is not cosmetic: it is what lets a unit test ask "would
  two windows be accepted?" without opening two WebView2 windows.

## The window that is not open *yet*: WebView2's thread binding

`run_many` on Windows used to open one window and return:

> vails: on Windows, run_many opens ONE window today. The routing
> (`webview.WindowRegistry.emit_to`) works and is tested, but WebView2 binds the
> HWND, the COM apartment and the message pump to the thread that created the
> window, so a second window needs a second thread with the right apartment and
> the library refuses to dispatch to it until that is done.

The measured sequence, because "it did not work" is not a reason:

1. **All windows spawned.** `examples/services` stopped coming up at all — the
   window never appeared and the process died with an unhandled exception. So
   WebView2 wants its first instance on the thread that started the process.
   Fixed by running the **first** window inline on the calling thread, which also
   makes single-window behaviour unchanged by construction.
2. **First inline, rest spawned.** Both windows were created and both appeared.
   Then `webview_dispatch` to the second window **returned 0** —
   `could not hand a snippet to this window from another thread` — and the
   process died shortly after. The second window's `webview_run` starts but its
   dispatcher never comes up.
3. **One thread for all windows** does not work either: `webview_run` blocks per
   instance, so there is no way to pump two.

That leaves the apartment, and it was a two-line change: `CoInitializeEx(NULL,
COINIT_APARTMENTTHREADED)` on the window's thread before `webview_create`, and
`CoUninitialize` after `webview_destroy`. That change is now written — see the
decision above — and the refusal it justified is removed.

### Why the apartment is the whole story

The three-thread-attachment facts WebView2 has are the HWND, the message pump and
the **COM apartment**, and `webview_run` blocking per instance settles the second:
N windows means N threads, and nothing else. Of the three, only the apartment is
ours to supply — the library creates the HWND and owns the pump. So there is one
thing missing on a `spawn`ed thread and one call that fixes it.

The subtlety worth recording is `com_enter`'s return value. `CoInitializeEx` has
three outcomes and they are three different obligations: `S_OK` means this call
made the apartment, `S_FALSE` means the thread already had an STA (still ours to
balance), and `RPC_E_CHANGED_MODE` means something else got to the thread first,
so the apartment is **not** ours and a `CoUninitialize` would unbalance someone
else's initialisation. Hence the `>= 0` test in `com_leave` rather than `== 0`,
and hence the decision to attempt the window even on the third outcome: an MTA
host is not itself a WebView2 error, and refusing there would replace the
library's real diagnosis with our guess.

### What is claimed and what is not

**Claimed:** the routing rules, the registry, the per-window `Ctx`/`MainThread`,
the label injection, the thread-per-window backend, and now the apartment. All of
it type-checks (`v vet webview` green).

**Not claimed:** that two windows open on Windows. Nobody has run it. The machine
this was written on crashes its host on the `webview` test module, so the
verification runs did not happen here, and "it type-checks" is the honest ceiling
on the claim. `examples/multiwindow` with `VAILS_MULTIWINDOW_PROBE=pings` is the
run that settles it; a screenshot of two windows in
`tests/e2e_windows/` is what would turn this section from a claim into a record.

Linux is not blocked by any of this: GTK is one process-wide main loop with any
number of `GtkWindow`s in it. `webview_linux_shim.h` counts open windows and
quits when the **last** one closes — the single-window version called
`gtk_main_quit` unconditionally, which is correct with one window and is
"closing the settings window quits the app" with two. Structurally done; not run
in a real session from the machine this was written on.

## Rejected alternatives

- **Fix the routing by convention** ("remember to use the right `Ctx`"). Not
  testable: the failure produces no error, so a test asserting it needs a second
  window and a second sink — which is exactly what the structural fix gets for
  free. And a convention is not checkable by `v test .`.
- **Fall back to a default window for an unknown label.** Rejected: it delivers
  to a real and wrong page, which is the same defect as misrouting, and it gives
  that defect a plausible deniability.
- **Double-quote the injected label.** Rejected **because a test caught it
  working**: `jsesc.escape('a"b')` returns `a"b` **unchanged**. In a
  double-quoted JS literal the quote closed the string and the rest of the label
  became script — a script injection into every page of the app, from a field in
  `vails.json`. `jsesc.escape` is built for the single-quote case, which is what
  `events/js.v` has always used, so the label is single-quoted too. Three tests
  now pin the single quote, the double quote and the trailing backslash.
- **Put the label inside the runtime IIFE.** The IIFE returns early when
  `window.vails` already exists, so a second injection would skip it. The
  assignment goes after the closing call.

## Consequences

- `examples/multiwindow` exists and is a real two-window app — one document
  loaded twice, `vails.json` with two windows, `demo.ping` / `demo.broadcast`
  routing by label through the registry, and `VAILS_MULTIWINDOW_PROBE` to drive
  it. **On Windows it now runs two windows instead of refusing**, which is the
  change that matters here: it is also the proof vehicle, so the outstanding
  verification and the outstanding feature are the same command.
- `Ctx` gains `close_fn` / `close()` / `can_close()`. With one window the OS
  window manager is enough; with several an app needs to say "close the other
  one" without holding a second differently-typed handle. A window with no
  backend hook says so rather than pretending.
- `WindowRegistry.stop_all` / `emit_all` exist because "tell both pages
  something changed" and "quit N windows" are the two things a set of windows is
  for. `emit_all` reports the first failure rather than continuing — a partial
  broadcast that silently skipped one window is the quiet wrong-page bug again.
- **Four V 0.5.2 bugs were measured while landing this**, all now in AGENTS.md
  §2c. The load-bearing one for anyone writing more threading code here is that
  V loses mutability through references: a closure copies a `mut … &T`
  *parameter* by value, and `spawn` with a `mut … &T` parameter crashes or
  hangs. The workaround in all three cases is a plain reference plus `unsafe`.

## Verification

- `webview/window_test.v` — 21 tests, no window opened, green on Windows and
  Linux. The two that matter most: an event addressed to one window leaves the
  other window's sink **empty**, and an unknown label delivers **nothing at all**
  while still reporting why.
- `webview/webview_test.v` — `run_many`'s rules, now through `check_windows`: an
  empty list, a duplicate label and an invalid config are all refused, and two
  distinct valid windows are accepted. The test that pinned the old refusal is
  gone **because the refusal is**; the one that remains asserts a single window
  still takes the ordinary path, which is the regression test for the gate's
  removal.
- `v vet webview` green, `v fmt -l .` clean.
- **NOT PROVEN: two windows open at once on Windows.** `examples/multiwindow`
  exists and compiles; running it with `VAILS_MULTIWINDOW_PROBE=pings` is the
  outstanding proof, and until that run happens the second window is a claim.
