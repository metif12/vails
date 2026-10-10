# CHANGELOG

Notable changes to Vails. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow the
framework version (`vails version`, `buildinfo.framework_version`).

Conventions for this file:

- `## [Unreleased]` at the top holds work that is committed but not yet
  released; it is emptied into a version section at release time.
- Lines are written for a user of the framework, not for a git reader: which
  module, which command, which guarantee. A change with no user-visible
  effect (a refactor, a test) goes under **Changed** only when it changes a
  contract; otherwise it does not get a line at all.
- Every PR adds its lines to `## [Unreleased]` — see `AGENTS.md` §5.
- Architectural decisions do not live here; they live in `docs/ADR/`. An ADR
  is referenced by number in the entry that implements it.

## [Unreleased]

### Changed

- **The Dockerfile's V layer was five days stale, and that is why the json2 bug
  "came back" on Linux.** The layer cloned whatever master pointed at on the day
  it was first built and then never rebuilt, because a cached layer is content-
  addressed: every later `docker build` reused a V from 2026-10-05 while the host
  moved on. Measured 2026-10-10: the image carried V `e5ab344` while the Windows
  host ran `ef2ec06`. The stale V still had the `config` + `net.http` zero-decode
  defect (AGENTS.md §1b), so in the container `vails doctor` reported
  `vails.json : INVALID` **on a suite that was 45/45 green**, while the same
  command on the host reported `ok`. Nothing in the test output could tell the
  two compilers apart, which is the whole danger: the cache chooses which
  compiler you are testing against and does not announce it. V is now pinned to a
  commit, fetched by full sha (a short sha is refused by GitHub), with the
  measured failure and the bump procedure in the Dockerfile. Pinning also gives
  this file the property its own header argues for in point 3 and had left
  unapplied to V — an unpinned ref can change under a fixed name, which makes a
  green run meaningless.
- **`vails doctor` stopped lying about the Linux dialog, and the test that kept
  it quiet is fixed too.** `dialog_support()` answered `stub: the GTK chooser
  lands in Phase 5b` on Linux for two releases after Phase 5b landed the real
  backend (ADR-0027) — so `doctor` said `stub dialog`, `5/9 backends native`, on
  a machine with `GtkFileChooserDialog` compiled in and its response mapping
  tested. `services/support_test.v:67` was pinning the opposite assertion, with a
  comment saying dialog "is still the GTK stub", so the stale line was green the
  whole time. That is the §2c failure at service scale: a test that asserts
  something false. Both are fixed, and the new assertions pin the *content* of the
  note — `ready` and `GtkFileChooserDialog` present, `stub` absent — so the stub
  cannot come back without a red test. Linux `doctor` now reports
  `6/9 backends native, ok dialog - GtkFileChooserDialog + GtkMessageDialog`.
  Seen red by planting the stub string back on Linux
  (`assert dialog_support().ready` failed), then green on restore — which is also
  the first time the container has been used to turn a Windows-only check red.

- **The `json2` zero-decode bug no longer reproduces, and the three `.d.ts` are
  regenerated.** The compiler moved from `bb0d229` to `ef2ec06` while this branch
  was open and the bug stopped reproducing — verified across three fresh project
  roots, `vails doctor` reporting `vails.json : ok`, and `vails dts` regenerating.
  The blocking-command JSDoc now reaches all three checked-in declarations
  (11 added lines, no churn). `buildplan/json2_import_test.v` is unchanged: it is a
  guard on this repository's test layout, and a second `net.http` importer goes red
  at review time now rather than at `vails doctor` time. AGENTS.md 1b records the
  whole thing, including **two explanations that were offered and then killed** —
  the `_str_N` literal collision (refuted by a control: an *unused* `import sync`
  changes 507 of 2160 identical-index literals and both programs decode
  correctly) and "a module named `cfg` is special too" (refuted: it is a *variable*
  named `cfg` colliding with `import cfg`; a module named `zzz` with a variable
  `zzz` fails identically).
- **A documentation accuracy pass on the one file the last pass only partly
  reached.** `ROADMAP.md` carried four claims that had been overtaken, and all four
  under-stated what the project now does:

  - *"`menu.png` / `tray.png` / `dialog.png` exist"* — `git log --all` returns zero
    commits for all three. ADR-0017 and ADR-0027 are where the citations were fixed;
    this file had been left saying the screenshots exist.
  - *"the runner has still never reported a single green job"* — the Linux container
    job passes, and this branch is what took it there.
  - *"this machine crashes its host on the `webview` test module"* — all six files
    compile **and** run, twice, at 45/45, on the same compiler both measurements
    were made against. Kept as history, labelled *currently green* rather than
    *fixed*, because **what changed is not known**.
  - the priority table called F1 drag & drop "planned" — it landed as ADR-0036 on
    2026-10-03. The next unwritten row is W1-W4.

  `ADR-0038` gains a dated implementation note rather than a rewrite: the resolver
  now has a production caller (`vails doctor`), an unset `VAILS_TOOLCHAIN` prints
  the byte-identical header path as before, a set one no longer reports the default
  root as healthy, and the `#flag` half is still unwritten and still uncompiled.
- **Documentation accuracy pass, 2026-10-05.** No behaviour changed; three
  documents no longer cite screenshots that have never existed in this repository.
  `git log --all` returns **zero commits** for `tests/e2e_windows/tray.png`,
  `tests/e2e_windows/menu.png` and `tests/e2e_linux/dialog.png`, yet ADR-0017
  cited the first two as its evidence, ADR-0027 cited the third as "Linux, proven
  end to end", and `README.md` cited the first as the tray's "E2E proof". The runs
  themselves are not in doubt — the tray loop is still machine-checked by the E2E
  script's `PostMessage` -> subclass -> `tray:clicked` assertion — but the
  citations were evidence-shaped without evidence, which is the one failure mode
  this project cannot afford in a document other people rely on. The dated ADRs
  got **errata appended rather than rewritten**, so the record of what was believed
  on the day stays intact; the living docs (`README.md`, `ROADMAP.md`) were
  corrected directly. One broken markdown image link removed, and the Linux
  `v test` status in ADR-0017 updated from "Pending" (with a named compiler
  blocker) to 44/44 green.

  Two further claims were stale in the same pass, and both were wrong in the
  direction of under-reporting what the project achieves:

  - **`v test webview` on Windows.** `ROADMAP.md` said it "cannot be run: it
    takes the host down", measured 4× on 2026-09-30 and again on 2026-10-03. On
    2026-10-05 all six files compile **and** run, twice, inside a full
    `v -cc gcc test .`. What changed is not known — no test needed editing and
    the compiler is the same. The row now records the history and labels this
    *currently green*, not *fixed*, because a claim with no known cause should
    not be stated without its history.
  - **The Windows test command "carries one extra flag, and it is not
    optional"** — over a code block that contained no extra flag. No link flag
    has been needed since the move to the V master build this project requires;
    `README.md` now says so and keeps the reason, so the flag is recognisable as
    version-scoped rather than mysterious.
- **`menu.set_menu` now fails instead of pretending it worked.** If the window's
  message hook cannot be installed, `set_menu` returns that error rather than
  swallowing it, and the `HMENU` it just built is destroyed rather than leaked.
  The hook is now installed *before* `SetMenu`, so there is no window in which a
  click can arrive for a menu the window is not yet routing. Previously a failed
  hook left the handler counting clicks against a bar that would never be
  drawn. Two tests pin it: one at the native seam, one at `set_menu`.
- **`vails dts` now marks the blocking commands in the generated `.d.ts`.** The
  four commands that open a native dialog — `dialog.message`, `dialog.open`,
  `dialog.save`, `menu.popup` — get a JSDoc note, so an editor can tell a call
  that will not resolve until a human answers from one that resolves
  immediately. The set is pinned by a test, so a fifth blocking command shipped
  without a marker fails the suite. (The checked-in example declarations are one
  release behind — see "Not done" below.)

### Added

- **`balloon` service** (ADR-0039): `balloon.show` shows a tray balloon
  (`Shell_NotifyIconW` with `NIF_INFO`) and resolves with the mechanism that ran,
  so a frontend can tell a real shell message from a stub. It is a *secondary*
  service, never a fallback for `notification` - no code path reaches it from
  there, and `notification` still has no fallback. Its reason to exist: a Windows
  image whose WinRT class store is stripped cannot activate any WinRT class, so
  the toast cannot work there at all (see below).
  `balloon.is_supported` reports whether the platform has a backend. Shipped with
  a panel in `examples/showcase` (verdict NEEDS YOU) and a section in
  `examples/services`, both granting `balloon.show`/`balloon.is_supported`.
- **`examples/showcase` now proves the pair side by side.** A verify run reports
  `notify FAIL ... REGDB_E_CLASSNOTREG` next to `balloon NEEDS YOU ... reported ok`
  on a Windows whose WinRT is stripped, which is the clearest statement of
  ADR-0039's reasoning that the framework can produce.
- **`dialog.open({ folder: true })`**: selects a directory instead of a file, via
  `FOS_PICKFOLDERS` on the Common Item Dialog. Composes with `multi` for a
  multi-select of directories; combining it with `filters` is refused, because a
  filter cannot select a directory and silently showing a file picker is worse
  than an error (ADR-0039). No WinRT involved, so it works where a
  `Windows.Storage` picker would not.
- **Toast action buttons are accepted, validated and built, but not sent**
  (ADR-0039). `NotificationOptions.actions` decodes, is bounded (three buttons,
  unique ids, legal placement, escaped attributes) and renders to a tested
  `<actions>` element - but `toast_actions_available` is false, so `notify`
  sends a toast without them and `vails doctor` says why. Rendering a button that
  does nothing would be the same lie the balloon was removed for; delivery needs
  two WinRT IIDs that this build environment cannot supply, and the gate is the
  one constant to flip when it can.

### Changed

- **`vails doctor` resolves the Windows toolchain instead of asserting one
  machine's path** (ADR-0038). The `webview` line checked
  `C:/msys64/ucrt64/include/webview/webview.h` literally, so a relocated or
  scoped toolchain was reported against the one root that cannot be the answer.
  It now goes through `buildplan.resolve_toolchain()` — already the tested owner
  of that decision, previously with no production caller — and a new
  `toolchain` line names the resolved root and where it came from. An unset
  `VAILS_TOOLCHAIN` prints the same header path as before, because the default
  *is* that root; a set one follows, and any missing piece (`webview.h`,
  `libwebview.dll.a`, the `bin` directory holding the five side-by-side DLLs) is
  listed once, here, instead of surfacing as a header error three minutes into a
  build.
- **`vails doctor` now names the cause of an unavailable toast**
  (ADR-0039). It previously reported `REGDB_E_CLASSNOTREG`, whose two causes -
  a wrong AppUserModelID and a Windows with no WinRT class store - need opposite
  fixes. It now distinguishes them and, for a stripped image, says that
  `HKLM\SOFTWARE\Classes\ActivatableClasses\ClassId` is missing, that this
  affects *all* WinRT and is not a Vails bug, and names the repair commands.
- **`{"multi": true}` on `dialog.message` is now refused** instead of silently
  ignored. The kind-scoping checks sat below `message`'s early return, so a
  dropped flag looked like a working one (ADR-0039).

### Fixed

- **`v test .` on Linux is green: 44 of 44 test files, from 20 of 44 failing.**
  Measured 2026-10-05 in the CI container (`Dockerfile`, V `0.5.2 e5ab344`,
  WebKitGTK 2.52.6) — the first time this had ever been run on this project.
  Twenty files failed for **three** root causes, none of them flaky:
  - **`services` did not compile at all on Linux**, so all 13 `services` test
    files failed at once. `drop.v`'s `on_drop_message` called
    `read_dropped_paths_native`, which is Windows-only: a platform-neutral module
    may not name a platform function, so the *whole module* failed, not one
    function. `on_drop_message` moved to `drop_windows.c.v` beside its only caller
    and its only platform dependency — the same arrangement
    `menu_windows.c.v`'s `on_bar_command` already used. Every testable piece
    (`decide_drop`, `validate_dropped_paths`, `drop_files_data`) stayed in
    `drop.v` and stays covered on both platforms.
  - **`webview/webview_linux.c.v` had 7 compile errors**: `vails_window_opened`
    and `vails_window_closed` were never declared on the V side (they are
    `static inline` in the shim, and an `#insert`-ed header supplies definitions
    but not V signatures); `label_js(...)` was passed where `vails_add_runtime`
    wants a `&char`; and four `mut` errors on `win`. All seven are the F0
    multi-window work that had only ever been compiled on Windows.
  - **`webview/jobs_test.v` asserted a Windows-only error string.** The refusal is
    real on both platforms and the load-bearing half of the property — refused
    *before* queueing, so the queue is not holding a job nothing will run — is
    asserted everywhere. Only the wording is platform-specific, so each platform
    now asserts its own message rather than one of them passing vacuously.
  - Consequence worth stating plainly: **the six `webview` test files now run on
    Linux**, which is coverage Windows cannot give at all (on Windows they take
    the host down — see ROADMAP). Windows is unchanged at 44/44.
- **`app_flags` is a pure function of its `target` argument again.** Its `-cc gcc`
  branch was wrapped in `$if windows`, so `app_flags(.windows)` returned `[]` when
  called on Linux: a Windows build plan could only be checked on a Windows
  machine, which is precisely the half-checking that taking `Target` as an
  argument exists to prevent. Found by the Linux run, in the test written to catch
  exactly this. The `$if` was never load-bearing — the only production caller
  passes the host's own target — and `cli_flags` has always added its Windows
  flags without one, which is what made the outlier visible. No real build
  changes; `buildplan_test.v`'s exact-equality assertion now runs and bites on
  both platforms.
- **`emit_to` across windows no longer crashes the process or lie about
  succeeding** (F0, found by running `examples/multiwindow` on 2026-10-04 — two
  defects that had shipped since 2026-09-30 behind a green `v vet`):
  - `webview_dispatch` returns a `webview_error_t`, not a bool. `WEBVIEW_ERROR_OK`
    is `0` and success is `>= 0`, so the shipped `if (!webview_dispatch(...))`
    took the **failure branch on success** — freeing the job the window thread
    was about to run (a use-after-free) and then reporting a healthy window as
    refusing the emit. Visible symptom: every cross-window emit failed with
    "could not hand a snippet to this window from another thread".
  - With that corrected it still crashed: `0xC0000005` **inside
    `libwebview-0.12.dll`**, because the call needs a COM apartment on the
    **calling** thread and every caller is a `spawn`ed worker, which has none.
    The cross-thread path now goes through `post_to_main` (queue + `PostMessage`,
    pure Win32, already proven by ADR-0019) instead. The owner-thread path still
    evaluates directly, so an emit from a command handler still has taken effect
    by the time the handler returns.
  - `buildplan/dispatch_test.v` guards both, because no unit test can reach C.
    It is verified red on a reintroduced call — naming the file and line — and
    green after, which is the only way a guard is known to guard.
- **Known, NOT fixed, and recorded rather than papered over**: closing the
  *first* of several windows while another is still open leaves the process
  running with no windows. Closing the second one first exits cleanly, and
  single-window apps exit cleanly, so it is specific to N > 1 and
  order-dependent. `tests/e2e_windows/README.md` (F0, step 6) carries the
  measurement, the debugger backtrace, and the two fixes that were tried and
  reverted.

- `dialog.open({ folder: true })` rejects `filters` combinations that could not be
  honoured instead of ignoring them.

- **`vails doctor` no longer claims a notification works where one cannot be
  shown.** `notification`'s support line was a hardcoded `ready: true` — a
  *compile-time* fact dressed up as a runtime one — while `notification.is_supported`
  answers a deliberately different question ("is the backend compiled in?"). The
  machine-level probe, `toast_available()`, **existed and was called by nothing**,
  and that dead function was the entire bug. `doctor` now activates the WinRT
  classes for real and reports a `stub` line with the HRESULT when they do not.
  Found by the showcase's verify run, which called `notification.notify` on the
  strength of the false claim and got
  `RoGetActivationFactory` → `hr=0x80040154` (`REGDB_E_CLASSNOTREG`). A test now
  asserts the support line and the machine probe cannot disagree.
- **`VAILS_SHOWCASE_VERIFY=1` makes the showcase report as text and an exit code**
  (ADR-0037, ROADMAP R4). It runs every panel a machine can complete and prints
  each verdict as it happens, because **a PNG is not a verdict** — nobody can diff
  a screenshot for "the clipboard panel passed". The process exits non-zero on any
  `FAIL`, and also on "almost nothing reported", since a run that exits 0 because
  nothing ran is the failure mode that matters most here. `NEEDS YOU` and
  `NOWHERE` do **not** fail a run. **Proven on Windows 2026-10-03**: `7 pass,
  0 fail, 1 not on this platform, 3 never ran`, exit 0 — and the first run found
  five bugs in the showcase itself.
- **`demo.verdict` / `demo.finish`** — the channel a verify run reports through.
  The page owns each verdict (V cannot read the DOM) and this is how one becomes
  text. Both are unset on a normal launch: no probe modes, no injected script, and
  no auto-answer shim, exactly as ADR-0037 requires.

### Changed

- **`v test .` and `vails build` need no `-ldflags`/`-cflags` on current V**
  (ADR-0034, ADR-0038). Both documented workarounds — `-ldflags "-lws2_32"` for
  `net.http`, and `-cflags "-Wno-incompatible-pointer-types"` for the CLI — are
  gone on the compiler this is developed against, measured 2026-10-03 across 33
  test files. They are still emitted by `buildplan.cli_flags` and still
  documented, because they are *version-scoped*: a V 0.5.2 build still needs
  them, and the flag-ordering bug behind them is real. `AGENTS.md` §1 now says
  which compiler wants which, and says how to tell.
- **The Windows toolchain is resolved from one variable** (ADR-0038).
  `VAILS_TOOLCHAIN` holds a ucrt64-shaped root (`include/`, `lib/`, `bin/`) and
  defaults to `C:/msys64/ucrt64`, so every command works unchanged on a machine
  that sets nothing. `buildplan.toolchain` reports what it resolved, where the
  answer came from, and which of the three vendored pieces a scoped install is
  missing. **`-cc msvc` works for pure-V modules and refuses by name for
  anything that links webview**: MSYS2 ships `libwebview.dll.a` and there is no
  `webview.lib`, so no GUI target or CLI can link under MSVC without vendoring
  one.

### Added

- **`examples/showcase`: one panel per capability, four honest verdicts, one
  tally** (ADR-0037, ROADMAP R3). Every capability gets a panel, and every panel
  ends in a badge reading `PASS`, `NEEDS YOU`, `FAIL` or `NOWHERE` - and the
  sticky line at the top counts all four, because "6 pass, 3 need a human, 1 not
  on this platform, 0 fail" is a verdict on the framework and "10 panels" is not.
  - A panel never claims `PASS` for something only a human can finish (a drag, a
    tray right-click, a file picker). It says `NEEDS YOU` instead - ADR-0018's
    discipline applied to a demo rather than to a backend.
  - **The page does not decide what is supported**: `demo.support` returns
    `services.supports()`, the same table `vails doctor` prints, and a panel whose
    service is not ready shows the framework's own note and never calls the
    command.
  - Two panels are inverted on purpose, because their failure mode is silence: the
    capability gate and the opener's scheme allowlist **pass when the call is
    refused**.
  - It supersedes `examples/services` as the E2E vehicle and has **no probe
    modes**; `examples/services` is kept for the screenshots and probes it
    already has. It is a reference, not a template - `vails init` still scaffolds
    `hello`.
  - **Unverified: the page itself.** It builds, its manifest validates and the
    generated `.d.ts` carries the `drop` namespace, but no browser has executed
    it yet (R4's job). Writing it also turned up a gap in the runtime:
    `window.vails` has no `off`, so a listener cannot be unregistered.
- **`drop` service: report the files a user dropped on a window** (ADR-0036).
  `drop.enable` / `drop.disable` are capability-gated and take no params; a drop
  arrives as one `drop:files` event carrying `{"paths": [...], "count": n}`.
  **Paths only, never contents** - a page that wants a file's bytes has to be
  given a way to ask, and that capability should be granted on its own.
  Windows uses `WM_DROPFILES` on the window seam, because `EnableWebDrop` is a
  WebView2 *host* setting the `webview` 0.12 library does not expose (its header
  declares sixteen functions and none is about dropping).
  - **The page gets `drop:files` and NOT the DOM's `dragover` / `drop`.**
    `DragAcceptFiles` on the top-level window takes the drop away from WebView2's
    child, and there is no reachable alternative - so `vails doctor` says so on
    the `drop` line rather than reporting a bare "ok".
  - A drop that carried nothing usable is **still reported**, with
    `paths: []`: the user did something, and silence reads as a hang. Bounds are
    applied to the report rather than to the drop - at most 64 paths, 1024
    characters each, NUL-bearing paths rejected instead of truncated, and a
    larger drop truncated keeping the user's first paths.
  - **Windows: written and unit-tested, not observed.** 18 pure-V tests green on
    both platforms; the native path has never seen a human drag a file. **Linux:
    the `GtkDropTarget` half is deliberately unwritten** (no native code that has
    never been compiled), and `doctor` says "unwritten" rather than
    "unsupported", because only one of those is true. The outstanding runs for
    both are in `tests/e2e_windows/README.md`.
- **`webview.run_many` opens more than one window on Windows** (ADR-0035).
  The blocker was never the routing - that was already proven with two fake
  eval sinks - it was that WebView2 binds the HWND, the COM apartment and the
  message pump to the thread that created the window. Windows beyond the first
  therefore run on a thread each, and a `spawn`ed thread has **no COM
  apartment**, which is why the old code refused a second window by name
  instead of crashing. Each window's thread now calls
  `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)` before `webview_create`
  and `CoUninitialize` after `webview_destroy`, and the refusal is gone.
  **Not yet observed**: this machine's `webview` test module crashes the host,
  so the run that would prove two windows actually opening has not happened.
  Treat the second window as written-and-type-checked, and see "What is claimed
  and what is not" in ADR-0035.
- **`webview.check_windows(cfgs)`** (ADR-0035). The rules `run_many` applies
  before any window exists - at least one window, every config valid, no two
  windows sharing a label - as a callable function. A test can now ask "would
  two windows be accepted?" without opening two WebView2 windows, which is the
  only reason the multi-window validation is testable at all.

### Changed

- **`vails doctor` takes `--config`** (ADR-0034). It hard-coded
  `vails.json`, which made it useless in a workspace with more than one
  project in it — which is exactly what a build matrix looks like.
- **`v.mod`'s `version` is now checked against the framework version**
  (ADR-0034). They were two hand-edited numbers and they were already
  disagreeing (0.2.0 vs 0.4.0); `v.mod` is now 0.4.0 and a test fails if
  they drift again. The framework version lives in
  `buildinfo.framework_version`.
- **`state.Store` is now `state.AppState`**, and `new_store()` is
  `new_appstate()` (ADR-0030). The reason is a collision: the ROADMAP lists a
  persisted `store` service for durable key-value data, and the two differed by
  the case of one letter in a language whose house style is snake_case — the
  same word, two meanings, unreadable in prose. The bare word `store` went to
  the thing that persists (matching Tauri, where `tauri-plugin-store` is
  exactly that) and the in-memory type took the name its own doc comment
  already claimed. **The public API is unchanged** — `set_state` / `get_state`
  / `has_state` were always the only surface, and the generated `.d.ts` never
  carried the name — so an app built on `application` needs no change. Only a
  direct `import state` + `state.Store` does, and in this repository the sole
  importer was `application` itself. `state.AppState` and the persisted
  `store` are **not** interchangeable and are not merged: one is a
  main-thread in-process map, the other is a capability-gated service touched
  by workers.

### Added

- **`webview.Window` / `WindowRegistry` / `emit_to` — address a window by label**
  (ADR-0035, F0, in part). With more than one window, `ctx.emit` through a
  single `Ctx` is a bug with no symptom: the event is delivered, the promise
  resolves, and the **wrong** page's status line changes — invisible to a
  single-window test suite and to a single-window screenshot. `emit_to(label,
  event, data)` makes the caller name the window and never hold a `Ctx` it could
  use by mistake. Every branch is a bug that was reachable before and is now
  pinned by a test: an **unknown label is an error and nothing is delivered
  anywhere** (the tempting fallback to "the first window" delivers to a real and
  wrong page — a missing route that looks like a success), a window that is not
  `ready` is refused **naming its state** (a nil `eval_fn` is a crash, not an
  error), and **two windows may not share a label** — which would be a
  capability hole and an ambiguous route at once.
  - `Window{label, ctx, state}` with a `created → ready → running → closed`
    lifecycle, `Config.on_window` to hand an app the backend's own `&Window`,
    and `emit_all` / `stop_all` for "tell both pages" and "quit N windows".
    `emit_all` reports the **first** failure rather than continuing, because a
    partial broadcast that silently skipped one window is the same bug again.
  - `run_many([]Config)` is the entry point; `run(cfg)` is unchanged and is
    exactly its one-element case, so every existing app is unaffected by
    construction.
  - `Ctx.close()` / `can_close()`: with several windows an app needs to say
    "close the other one". A window with no backend hook says so rather than
    pretending.
  - **Windows: N windows, one thread each.** WebView2 binds the HWND, the COM
    apartment and the message pump to the thread that created the window, and
    `webview_run` blocks per instance — so window 2..N each need a thread, and a
    `spawn`ed thread has **no COM apartment**, which is why this used to refuse a
    second window by name. Each window's thread now calls `CoInitializeEx(NULL,
    COINIT_APARTMENTTHREADED)` before `webview_create` and `CoUninitialize`
    after `webview_destroy`. **Not yet observed** — see the Added entry above.
  - **Linux is structurally done** — one GTK main loop with any number of
    windows in it, quitting when the *last* window closes (the single-window
    version quit on the first).
  - **A window label is injected into the page** (`window.vails.label`), because
    F0 loads one document into every window and the page otherwise cannot tell
    which window it is. It is single-quoted and JS-escaped: `jsesc.escape` does
    **not** escape `"`, so a double-quoted literal was a script injection from a
    `vails.json` field into every page of the app. Found by a test written while
    landing this, and pinned by three now.
- **`webview.post_to_main(ctx, fn ())` — a worker can hand a closure to the
  window thread** (ADR-0019, U0/W0, Windows). ADR-0010 says handlers run on the
  main thread and slow work belongs on a `spawn`ed worker, but there was no
  way back: `ctx.emit` ends in `webview_eval` on a thread the webview object
  does not own, so a worker computed its result and dropped it on the floor. A
  posted job is now the unit — a `fn ()` the window thread runs — and the OS
  message is only a wakeup on its own `WM_APP+2` id, deliberately not
  `host_message`, so a wakeup can never reach a live tray as a "left click".
  `webview.run` puts a `&MainThread` on the `Ctx` it hands to `on_ready`, so
  the pattern is `spawn` + `post_to_main` and the service knows nothing about
  the queue, the subclass or the message id. Safe to call from any thread: the
  queue is behind a real `sync.Mutex`, and `take()` releases it before running
  the batch, so a job that posts again cannot deadlock a non-recursive
  `SRWLOCK` (there is a test for exactly that).
  - **`post_to_main` refuses by name instead of dropping the job.** A `Ctx`
    with no live window, or a window with no wakeup, returns an error saying
    what to pass — a dropped job is indistinguishable from slow work.
  - **Linux is not included.** The `g_idle_add` trampoline is unwritten — it
    is the first push onto the GTK main loop from a foreign thread, and
    nothing in the repo has ever done that — so `post_to_main` returns
    `... is not available on linux yet`. `webview.run` still builds and
    destroys a `MainThread` there to keep the shape symmetric.
- **`vails build` produces a binary that starts** (ADR-0034, B1). It used
  to shell out to `v -o <out> <dir>`, print *"DLLs stay side-by-side on
  Windows; packaging arrives in Phase 7"*, and copy nothing — the five
  loader DLLs existed only as `#` comments in the READMEs. It now stages
  them from `C:\msys64\ucrt64\bin` when
  `bundle.windows_dll_side_by_side` is set (a config field that has
  existed since T6 and was never acted on), reports the individual files
  it could not find rather than a generic failure, applies `-gc none` on
  Linux from inside the build rather than from a CI command, and is
  idempotent so a rebuild over a running app is a no-op instead of a
  failure *after* a successful compile.
- **`vails build --version <semver>` stamps the build** (ADR-0034, B0).
  The app reads it with `buildinfo.version()`, so no generated file and no
  `-ldflags` are involved. The argument is validated first: `1.0`,
  `1.2.3.4`, `01.2.3` and an empty string are refused (the updater
  *compares* this string, so `1.0` and `1.0.0` would be different
  versions), while `v1.2.3`, `1.2.3-rc.1` and `1.2.3+build.5` are
  accepted. An unstamped binary reports `dev`, and `vails doctor` says so
  in words — a release nobody stamped looks exactly like a development
  build, and `dev` silently disables every update check.
- **The first CI** (ADR-0034, B2/B3): a `Dockerfile` on V's own published
  `thevlang/vlang:ubuntu-build` image, and `.github/workflows/ci.yml`
  with a Linux job that runs in it and a Windows job on a native MSYS2
  runner. The Windows job asserts that the artifact `vails build`
  produced can start, which is the reason B1 came first. A tag also
  triggers a version-stamped release build.
- **`vails deps` and the `dependencies` block in `vails.json`**
  (ADR-0034, B5). `{"name": "vlang.leveldb", "version": ">=1.0.0"}` — the
  `v.mod` shape, with a `{"name": ">=1.0"}` map accepted as a fallback.
  `vails deps` lists what is declared and diffs it against `vails.lock`;
  `vails doctor` reports both. **It does not fetch.** Vails declares and
  reports; VPM (`v install`) resolves, because the moment Vails keeps its
  own resolved tree a hand-run `v install` and a Vails-run one can
  disagree and the build depends on which ran last. This is what makes
  ADR-0031's `ui2` tier and ADR-0032's data services reachable at all:
  `ui2`, `leveldb` and `vsql` are in no V installation.
- **`sqlreg` — the `sql` security policy as code** (ADR-0034, D0). The
  decision ADR-0032 recorded in prose is now the thing D3 will be written
  against: a page **names** a query and V owns the statement. SQL text
  from a page is not a query name and never becomes SQL; multiple
  statements are refused *at registration*, so a statement that could
  smuggle a second one is never in the registry; parameter values are
  bounded (a bound on the statement is not a bound on the value); a named
  parameter the statement does not contain is refused; and read/write are
  separate grants. The registry has no mutating entry point at all — that
  absence is the threat model. No database is behind it yet; D3 adds
  `vsql`.
- **Four new pure-V modules**, all testable on Windows with no C, no
  network and no toolchain: `buildinfo` (build identity), `buildplan`
  (what a build runs and stages, with the target as an *argument* so a
  Linux recipe is asserted on the Windows CI run), `deps` and `sqlreg`.
  `v test .` is 36/36.

- **`menu.set_menu` installs the window's menu bar** (ADR-0023). `menu.popup`
  was a right-click menu; this is the bar along the top of the window, with
  drop-downs, and it takes the *same* `MenuItem` array, the same id rules and
  the same `menu:clicked` event — so a frontend that already listens for a menu
  choice serves both with one handler. It is not modal: the command installs
  the bar and returns, and the user picks from it whenever they like.
  `set_menu({items: []})` removes the bar, so an app that shows and hides its
  own chrome does not need a second command.
- **The window host seam now takes more than one hook** (ADR-0023). Two
  services need to hear from the same window — the tray's `WM_APP+1` and the
  menu bar's `WM_COMMAND` — so `attach` no longer implies a single handler, and
  a handler now says whether it *consumed* the message. A message a hook does
  not recognise is passed to the next subclass in the chain and, eventually, to
  the webview library, which is what keeps an installed tray icon or menu bar
  from silently breaking the page. This corrects a claim in
  `webview/host_shim.h` and `webview/host.v` that there is "exactly one hook per
  window" — true only while there was one caller.
- **`Ctx` gains `toplevel`**: the window's top-level *widget*. The same HWND as
  `parent` on Windows; on Linux the `GtkWindow` that owns the `GdkWindow`, which
  is what GTK APIs that take "the window" (a menu bar, a transient parent) want.
  A window menu bar needs it, and so does the GTK dialog still to come.
- **`vails dts` output** for the new command: `menu.set_menu(params:
  MenuPopup): Promise<string>` in the generated `.d.ts` and
  `v.menu.set_menu(params)` in the service snippet. An app that calls it needs
  `menu.set_menu` in its `vails.json` capability grant, like any other command,
  or it gets `forbidden:`.
- **The Linux `menu` probe grew a `menubar` case**, and `run_services.sh` clicks
  the bar for it. It is the one proof in the Linux suite that is provable
  *further* than a human check: the bar is a normal widget in the window, so a
  click lands and the screenshot carries the resulting `menu:clicked` id.
- **`tray.set_menu` attaches a menu to the tray icon** (ADR-0026). It takes the
  *same* `MenuItem` array as `menu.popup`, and the choice arrives on the *same*
  `menu:clicked` event — so a frontend with one menu listener serves a
  right-click popup, a window menu bar and a tray menu. `set_menu({items: []})`
  removes it, as in ADR-0023.
- **`vails dts` output** for it: `tray.set_menu(params: MenuPopup): Promise<string>`,
  and `v.tray.set_menu(params)` in the service snippet. An app that calls it
  needs `tray.set_menu` in its `vails.json` capability grant or it gets
  `forbidden:`.
- **The Linux `tray` probe grew a `traymenu` case** (`tests/e2e_linux/traymenu.png`).
  On Linux the StatusNotifier *host* opens this menu, so nothing comes back
  through the bridge and there is no click to simulate — the proof is that the
  command resolved, plus, on Windows, that a right click really opens the menu.
- **`dialog` works on Linux** (ADR-0027). It was a stub returning `not
  implemented on linux`, on the stated grounds that it "needs a Linux
  toolchain" — a reason that had expired two waves earlier. It is now a real
  `GtkFileChooserDialog` / `GtkMessageDialog`, parented to the window's
  `GtkWindow` (which is what GTK wants, and is *not* `Ctx.parent`), with
  overwrite confirmation on save and correct UTF-8 filename conversion. Same
  buttons, same result shape and same ids as the Windows Common Item Dialog.
- **A `dialog.*` call with no display now fails with a message naming the
  cause** ("no display available") instead of crashing inside GTK. GTK requires
  `gtk_init` before any other call and has nothing sensible to say when it was
  skipped; this is a path a service can genuinely be called on before the
  webview is up.
- **`notification` shows a real Windows 10/11 toast** (ADR-0018). It was a
  tray balloon — `Shell_NotifyIconW` with `NIF_INFO` — which Windows 11
  attributes to the bare `.exe`, cannot carry an app name or icon, and which
  needed a V worker to delete its tray icon afterwards. It is now a WinRT
  toast (`Windows.UI.Notifications`, behind a new `services/toast_shim.h`): a
  real Action Center notification carrying the app's own name, with no tray
  icon and nothing to clean up. The notification **document is built in pure
  V** and unit-tested, which is the part that is easy to get wrong and hard
  to debug. `vails init` scaffolds a working `bundle.identifier` and
  `vails doctor` names it when `notification` is granted without one, because
  an unpackaged app cannot raise a toast without an AppUserModelID and the
  failure is a notification that never appears. See ADR-0018.
- **`vails.json` gains `bundle.identifier`**: the app's stable identity, and
  on Windows the AppUserModelID notifications and taskbar grouping are keyed
  by. Optional — only `notification` needs it — and validated against the
  shell's own charset rules. An app upgrading an older `vails.json` that
  wants notifications must add it; the service refuses with a message naming
  the field rather than guessing an id.

### Changed

- **A right click on a tray icon that has a menu attached no longer emits
  `tray:clicked`** (ADR-0026). This is the one deliberate behaviour change to an
  event that already shipped, and it is worth reading before upgrading. With a
  menu attached, the right click opens the menu and the event does not fire; with
  no menu attached, **nothing changes at all** — an app that never calls
  `tray.set_menu` sees an identical event stream. The alternative (open the menu
  *and* still emit) was rejected because one physical click would then deliver two
  independent signals. A **left click is never taken by the menu**, even with one
  attached. `set_menu({items: []})` restores the old behaviour outright.
- **`notification.notify` now resolves with the mechanism that ran**
  (`'toast'`) instead of `''`. The generated type is still `Promise<string>`,
  so no `.d.ts` needs regenerating, but a caller that compared the result to
  `''` must stop. This is the only machine-checkable evidence a toast
  produces, which is what makes an E2E run provable.
- **The tray balloon is removed rather than kept as a fallback**: a
  notification that changes mechanism depending on the machine is harder to
  reason about than one that fails loudly. `notification.notify` therefore no
  longer requires a window handle (a toast is not owned by a window), the
  `NIF_INFO`/`NIIF_*` constants are gone from
  `services/trayicon_windows.c.v` (now the tray's primitive alone), and
  `notification` no longer installs a tray icon at all.
- The `services` module's C links four more Windows libraries
  (`runtimeobject`, `shell32`, `ole32`, `advapi32`) and pulls in a 1.2 MB
  WinRT header for every `services` test compile — measured at ~0.5 s per
  file, which is why the alternative (hand-declared vtbls) was not needed yet.
- The `examples/services` tray probe reports its outcome **to the page**, not
  only to the log. On Linux the probe always ends in "there is no click to
  simulate", and an `eprintln` is not something a screenshot can carry, so the
  tray panel used to sit empty in the run it exists to document. The E2E
  screenshot now shows why.
- **The Linux window is now a vertical box holding the webview**, rather than
  the webview being the window's only child. A `GtkWindow` holds exactly one
  child, so a menu bar installed after the fact had nowhere to go; reserving
  row 0 makes one possible. An app with no menu bar is unaffected — the view
  still gets the whole client area — but the layout is now the backend's rather
  than GTK's single-child default.
- `webview/host_shim.h` and `webview/host.v` no longer claim there is "exactly
  one hook per window". They never guaranteed one; there was only ever one
  caller, and the seam now has two (ADR-0023).
- `tests/e2e_linux/run_services.sh` writes a screenshot **named after the
  probe** instead of one shared `services.png`. It used to write the same file
  for every probe, so each run silently overwrote the previous proof — which is
  not theoretical: `services.png` and `notification.png` were byte-identical,
  and the clipboard round trip the README cites as proven had been destroyed by
  a later notification run. The clipboard proof has been re-taken.

### Fixed

- **An installed tray icon no longer swallows the window menu bar's
  `WM_COMMAND`** (ADR-0026). The tray's host-message handler branched on a
  `bool` that meant both "the attached menu owns this message" and "this message
  is not the tray's at all", so it answered the second case by opening the tray
  menu and consuming the message. The visible effect was that a window with both
  a tray icon and a menu bar stopped responding to the bar. The two cases are now
  separate outcomes of one pure `decide` function, and the regression is pinned by
  a test — the previous tests covered the predicates individually and so passed
  throughout, because the bug was in how their answers were combined.
- **The `menu` service works on Linux.** It did not compile, and once it
  compiled it still did not work: `menu.popup` created a native window the
  user never saw, and `menu.close` emitted no event at all. Four separate
  faults, all now fixed — see `tests/e2e_linux/README.md` for the full
  account. The short version: GTK3 has no `item-activated` signal (so the
  per-item `activate` connection replaced a connection that could never fire),
  `gtk_menu_popup_at_pointer(NULL)` never maps a menu (so the popup anchors to
  the window's own GdkWindow at the pointer instead, which is where Windows
  puts it too), `gtk_menu_popdown` does not emit `deactivate` (so the teardown
  is now shared by the signal and by `menu.close`, and guarded so the context
  is freed once), and two of the GTK calls the file used do not exist in GTK3
  at all.
- **`vails doctor` no longer implies a Linux tray click exists.** The Linux
  `tray` note used to name the mechanism without saying that
  `tray:clicked` — the event a frontend will actually wait for — does not
  happen on Linux, because the StatusNotifier *host* owns the click and opens
  the item's menu. It now says that, and the unit test asserts the absence, so
  the two platforms cannot drift apart silently.
- The Linux `menu` note in `vails doctor` named the wrong signal. It claimed
  the backend uses GTK's `activate` on the menu; it connects `activate` on
  each `GtkMenuItem`. The note is what `doctor` prints, so it now names the
  real mechanism.

### Not done in this release

- **The `vails` CLI cannot read `vails.json`.** *(Fixed in the compiler, on
  2026-10-10 — see the end of this entry. Kept under "Not done" because the
  property of this repository it exposed is still true, and the guard that
  records it is unchanged.)* This was a V master bug, not a Vails one: on
  `vlang/v` master, `json2.decode[T]` returns a **zero-valued struct with no
  error** when the module declaring `T` is named `config` **and** `net.http` is
  linked into the same binary. `cli` imports `dev` (which imports `net.http`),
  and this repository's config module is named `config`, so `vails doctor`,
  `vails run`, `vails build` and `vails dts` all reported
  `vails.json: name must not be empty` on a project whose config was valid.

  Bisected one variable at a time; the full table is in `AGENTS.md` §1b, and the
  upstream report is [vlang/v#29508](https://github.com/vlang/v/issues/29508).
  **Two claims had to be withdrawn along the way, and both mattered:**

  - *"the trigger is a cross-module decode"* — refuted by a 2-field struct in a
    module named `other`, which decodes fine with `net.http` linked.
  - *"struct complexity is irrelevant"* — refuted in the other direction: the
    module name is the axis. `conf`, `configx` and `xconfig` all work; `config`
    does not. So it is the exact identifier, not a prefix rule.

  Two consequences worth stating plainly:

  - **`v test .` was 45/45 green and could not catch this.** Each `_test.v` is
    its own binary, and no test file imports both `dev` and `config`, so the
    one combination that breaks was never linked in a test. That is a property
    of this repository's test layout and it is still true.
  - **The checked-in `examples/*/frontend/vails.d.ts` files were one release
    behind the generator**, carrying the blocking-command JSDoc from
    `services/dts.v` but not in the files themselves. They must not be
    hand-edited, so the gap was listed rather than patched.

  `buildplan/json2_import_test.v` guards the shape of the exposure — `net.http`
  keeps exactly one importer, that importer and every `json2.decode`
  instantiator stay **disjoint**, and `cli` is still where the two meet — so the
  combination cannot be widened without a red test. It cannot assert the bug
  itself: a test that reproduces it would pass only while the compiler is broken
  and would go red on the fix. **It is unchanged by the fix**, because it is
  about this repository, not about V.

  **Status: gone.** Re-measured 2026-10-10 on V master `ef2ec06` — the same
  program across three fresh project roots decodes correctly, `vails doctor`
  reports `vails.json : ok`, and all three example declarations were
  regenerated with their blocking-command JSDoc. Nine `json2` commits landed
  between the two builds and **which one fixed it is not bisected**, so it is
  not attributed here.
- **`menu.set_menu` is unproven at runtime on Windows.** It compiles and links,
  and the pure-V classifier behind it (`bar_click`) is unit-tested on every
  platform, but the E2E window would not come up in the capture session, so
  no Windows screenshot exists. The one-command manual check is in
  `tests/e2e_windows/README.md`. On Linux it is fully proven: the bar renders
  and a click produces `menu:clicked` with the right id. See ADR-0023.
- The **toast is unproven at runtime**. It compiles and links on Windows, but
  this machine's Windows 11 image has no WinRT component DLLs, so
  `RoGetActivationFactory` returns `CLASS_E_CLASSNOTAVAILABLE` for every WinRT
  class and no toast can be raised here. The AUMID registration and the
  loud-failure path *were* proven; the toast appearing in the Action Center
  was not. The exact state and the one-command manual check are in
  `tests/e2e_windows/README.md`. See ADR-0018, "Verification status".
- The Linux `menu:clicked {id}` mapping is still unproven. The id table is
  unit-tested and the popup and the dismissal event are screenshot-proven, but
  proving that a *click* lands on the right item needs a pointer inside an
  open menu, and under Xvfb there is no window manager, so the menu takes the
  first click as a focus click. A real desktop session settles it.
- Planned frontend track (Vite + web frameworks, ADR-0016): type-safe
  bindings generated from V handler structs and injected into the
  frontend (`vails-bindings.d.ts` + `vails-client.ts`), JS/V helpers
  replacing the repetitive `call(method, "")` / manual `json.encode` /
  untyped `onEvent` boilerplate, and `gen-bindings` / `init --template
  vite-vanilla-ts|vite-vue` / `run --dev` / dist-embedding `build`
  wiring. Ordered F0→F4 after Phase 5 S1 wave 3 + Phase 5b, before
  Phase 7; no code yet, ROADMAP track only.
- Planned self-updating track (ADR-0019 + ADR-0020, ROADMAP track U):
  a Wails v3-style updater for a Vails app — check GitHub Releases (then a
  static manifest endpoint), download the asset for the running OS+arch,
  verify a SHA-256 digest **and** an Ed25519 signature against the bytes
  actually received, show the release notes, then swap the running binary
  and relaunch without a separate helper executable (the helper is the
  current binary re-executed with sentinel env vars). Struck from the
  ROADMAP's "out of scope" list: the reason it was ever out of scope was
  that V was assumed to lack the crypto, and it does not —
  `vlib/crypto/ed25519` is complete, `net.http` has real streaming
  downloads, `crypto.sha256` streams, and `os.rename` is exactly the
  rename-aside a Windows `.exe` swap needs. No code yet.
- **The update UI is the app's own window, not a framework-owned one.**
  Vails has no second window — `webview.run` creates one and blocks — so
  the service answers `updater.state` and emits `updater:*` events, and
  the framework ships the *look* as `updater.default_html()` (state icon,
  version pill, Markdown notes, one primary action, `prefers-color-scheme`)
  for the app to inject or replace. It also means the updater is granted
  `updater.*` like any other service: an app that does not want a page
  reaching its filesystem simply does not grant it.
- **A new prerequisite, planned first: `webview.post_to_main`** (ADR-0019).
  ADR-0010 says slow work runs on a `spawn`ed worker and reports back as an
  event — but `eval_fn` is main-thread-only, so today a worker can compute
  a result and has no way to hand it to the page. ADR-0017's seam is the
  wrong shape for it (Windows-only, one handler per window, integer
  payload), and three already-planned items want the same thing:
  the `window` service, `menu.set_menu`'s `WM_COMMAND`, and the
  updater's download progress.
- Planned window chrome track (ADR-0021): frameless windows and a title bar
  the app draws itself, via `window.chrome.mode: "native" | "frameless"`
  and a `window` service. It absorbs the ROADMAP's S1 wave-4
  `window-state` / `positioner` items, which would otherwise have shipped as
  two small services doing half of what this one does. **`webview` 0.12 has no
  window-chrome API at all** — the whole surface is `create / destroy / run
  / terminate / dispatch / get_window / get_native_handle / set_title /
  set_size / navigate / set_html / init / eval / bind / unbind / return /
  version` — and Vails does not own its window the way Wails does, so
  frameless is applied to the existing HWND through the seam ADR-0017 already
  installed rather than requested at creation. "A custom title bar" is not a
  separate mode; it is `frameless` plus an app that draws its own bar.
- Planned build & release track (ADR-0022): the repo's **first CI**, with a
  Linux container built on V's own published base image, a Windows job on a
  native runner, a pinned `webview` 0.12, and a release on a tag that emits
  the manifest the updater consumes. Windows is not built from a Linux
  container here and the plan says why: the backend needs MSYS2 ucrt64 and
  the *Windows* import library of a C++ `webview` linked to WebView2, so
  cross-compiling it is its own project. The first job is not the workflow
  but a `vails build` that produces a **runnable** binary — the five
  side-by-side DLLs are currently copied by nobody and exist only as `#`
  comments in the READMEs, so a first CI would otherwise ship a green tick
  and an `.exe` that cannot start. No code yet.
- **Version stamping moved out of the updater's U6 and into the build
  track's B0**, because CI needs a stamped version before the updater
  exists, both need it exactly once, and one shared implementation that lands
  first is the point. `vails build --version 2.0.0` emits
  `-d vails_version=2.0.0`; an app reads
  `const build_version = $d('vails_version') or { 'dev' }`. B0 also has to
  reconcile a drift that already exists: `v.mod` says `0.2.0` and
  `cli/vails.v` says `0.4.0`.
- Planned distribution track (ADR-0024): a Windows installer (Inno Setup,
  per-user), a lightweight hand-built AppImage, and a Flatpak — all generated
  from `vails.json`, none of them requiring a tool nobody has installed. The
  decision that governs it: **the packaging format decides who updates the
  app**, so `vails.json` gains `bundle.update_channel` and the updater reads
  it rather than guessing. An app under `Program Files` cannot self-update
  without elevation, which makes per-user install a functional requirement
  rather than a preference; a Flatpak build refuses the in-app updater at
  startup and says who owns updates instead. The five side-by-side DLLs stop
  being `#` comments in two READMEs and become something the installer, CI
  and `doctor` all read — which also resolves ADR-0005's static-vs-side-by-side
  question, open since Phase 1. No macOS artifact: Phase 6 has no backend.
- Planned platform-gaps + showcase track (ADR-0025): **multi-window (F0) and
  drag & drop (F1)** — the only two rows where Vails lacks a *shell*
  capability that both Wails and Tauri ship as a worked example, against a new
  `docs/COMPETITIVE-MATRIX.md` that replaces "better than every sample app"
  (a superlative with no definition) with one checkable row per capability.
  F0 is deliberately **not** part of the showcase: it is on the critical path
  of the window-chrome track, `tray.set_menu` and the updater's own UI, and
  inside a demo it would read as work that can be sequenced last. It also
  **reopens a decision in ADR-0020** — the framework-owned updater window was
  rejected there only because one window is all Vails had, so the rejection is
  now conditional rather than withdrawn. The showcase replaces
  `examples/services` as the E2E vehicle instead of joining it, since that
  example has already outgrown its role by becoming five probe modes.
  `EnableWebDrop` is called out in advance: it is a WebView2 *host* setting,
  not on the `webview` 0.12 surface, and it is the first thing F1 has to check
  — a manifest promising a service with no reachable native implementation is
  worse than no service.

## [0.4.0] - 2026-09-28

Phase 5 S1 wave 3: the window host seam, and the two services that are driven
by the OS rather than by the page.

### Added

- **The window host seam (`webview/host.v`, ADR-0017)**: a window procedure
  that can call *into* V. `attach(ctx, handler)` stacks a comctl32
  `SetWindowSubclass` on the window the webview library created, so a native
  message reaches a V handler; `post_message` sends one (that is how a modal
  native menu is dismissed); `detach` removes the hook. It is installed **on
  demand** — never by `webview.run` — so an app that uses no service needing a
  callback has no subclass on its window at all. Every message the seam does
  not own goes to `DefSubclassProc`, because a message that does not reach the
  webview library's original procedure breaks WebView2. The seam is
  Windows-only: on Linux the OS-initiated direction is per-object, so
  `attach`/`post_message` say so instead of pretending.
- **`menu`**: `menu.popup` opens a real native popup — `TrackPopupMenuEx` on
  Windows, `GtkMenu` on Linux — with items, separators, disabled items and
  submenus. The choice comes back as an **event** (`menu:clicked` with the
  item id, or `menu:canceled`), never as the command's result, so one
  frontend contract serves a modal Windows menu and an immediate Linux one;
  `menu.close` dismisses the open popup. Item ids are restricted to
  `[A-Za-z0-9_.:-/]` because the id also travels as a Windows menu command
  id, and labels refuse `&` because that is the Windows mnemonic marker and
  the user would see a different string than the frontend sent. See ADR-0017.
- **`tray`**: `tray.set` installs an icon in the notification area
  (`Shell_NotifyIconW` on Windows, a `libayatana-appindicator`
  StatusNotifierItem on Linux) and `tray.destroy` removes it. A click is an
  OS-initiated `WM_APP+1` that reaches V through the host seam and is
  reported as `tray:clicked {button}`. This is the first service in Vails
  that the OS drives, and it needs a new build dependency on Linux
  (`libayatana-appindicator3-dev`), which `vails doctor` reports. See
  ADR-0017.
- **`services.simulate_click`**: manufactures the message a tray click sends,
  so the whole native-message → V → event → JS loop is provable without a
  human moving a mouse. It is not a command and cannot be granted. On Linux it
  refuses with the real reason (there is no click to simulate: the tray host
  opens the item's menu).
- `examples/services` grew the two services plus `menu` and `tray` probes, and
  the demo page reports the three new events.

### Changed

- **`notification` and `tray` share one Windows shell-icon primitive.**
  `services/trayicon_windows.c.v` now owns `NOTIFYICONDATA` and the
  add/remove calls, because the shell identifies an icon by `(hWnd, uId)`:
  two services on the same window must use different ids, and the balloon's
  lifetime worker deleting the tray's icon would have been a very confusing
  bug rather than an obvious one.
- **`menu.set_menu` is explicitly not part of the `menu` service**: a window
  menu bar is `SetMenu` plus `WM_COMMAND` routing, which is a service of its
  own. It is recorded as the next `menu` item rather than shipped half-done
  behind the same prefix.
- `vails doctor` reports 7/7 native backends on Windows, and the Linux notes
  now say the parts that are true there (a tray item needs a
  StatusNotifierHost to be drawn; a menu choice arrives on the GTK signal).

### Fixed

- **A `mut` pointer parameter cannot be captured by a closure** in V 0.5.2:
  the generated C types the captured field as a pointer to the pointer and
  gcc rejects it. The workaround (copy the pointer to a local first) is
  applied in `tray_backend` and in the `tray` seam install, and the reason is
  written next to both. See ADR-0017 Notes.

### Not done in this release

- The wave-3 **Linux** run is not verified yet: `examples/services` does not
  build on Linux at all, and the Linux screenshots are not taken. The state
  and the exact reproduction live in `tests/e2e_linux/README.md`. Nothing in
  this release claims a Linux proof it does not have — see `[Unreleased]`
  above, where the build and the run are fixed and the remaining gaps are
  named.

## [0.3.0] - 2026-09-27

Phase 5 S1 wave 2: three services with real backends on both platforms, plus
the five defects that only showed up once the code was compiled and run on
Linux.

### Added

- **Windows + Linux backends**: the WSL image has V (`/root/vsrc/v`), GTK 3.24
  and webkit2gtk-4.1, so a Linux service backend is compiled and proven again
  instead of stubbed. See ADR-0015.
- **`opener`**: `opener.open_url` and `opener.open_path` hand a URL or a path
  to the user's default handler — `ShellExecuteW` on Windows, GIO's
  `g_app_info_launch_default_for_uri` on Linux (no `xdg-open` process
  involved). `open_url` accepts only `http`, `https`, `mailto` and `tel`, and
  `open_path` only a local path, so a granted capability cannot be turned into
  a `file://` read or a `smb:` launch. `with` (an application override) is
  Windows-only for now and says so on Linux. See ADR-0015.
- **`notification`**: `notification.notify` shows a short message without
  taking focus (a Windows tray balloon — no COM, no shim) and
  `notification.is_supported` lets a frontend ask before trying, instead of
  firing a notification that quietly does nothing on a platform with no
  backend. Other platforms get an explicit "not implemented" error. The WinRT
  toast (real Action Center notifications) and a real `tray` service need a
  window-procedure seam and are the recorded next step. See ADR-0015.

### Changed

- **`clipboard` got its native half** and is a catalog service now, so
  `vails dts` and `vails doctor` see it. `clipboard.read_text` /
  `clipboard.write_text` work on Windows (user32 `CF_UNICODETEXT`) and Linux
  (the GTK clipboard); an empty clipboard resolves with `""` rather than
  rejecting, and the payload is bounded at 1 MiB. `read_text`/`write_text` now
  take the window's `webview.Ctx` (writing needs the parent handle), which is a
  signature change to a service that had no native half yet. See ADR-0015.
- **The generated `.d.ts` no longer promises camelCase the decoder drops.** A
  V struct field name *is* the wire name: json2 silently ignores keys it does
  not recognize, so the shipped `dialog` types offered `defaultPath` /
  `defaultName` while the values were discarded. The types (and the `dialog`
  example page) now use `default_path` / `default_name`, and a test pins the
  pair together. A TypeScript frontend that was passing `defaultName` must
  rename it. See ADR-0015.
- `v test .` now passes on **Linux** as well as Windows (29 test files). It
  never did: `dialog_test.v` referenced a Windows-only helper, which moved to
  pure V so the mapping is testable everywhere.
- **A Vails app builds on Linux again, and its bridge works.** The Linux
  backend had not compiled since the `Ctx.parent` / V→JS work landed, and
  even once it did, the page had no `window.vails` at all: the JS→V
  transport was the Phase 2 leftover, still only declared
  (`webkit_user_content_manager_register_script_message_handler` was
  declared and never called) — every example rendered in preview mode. Now
  the runtime is injected as a user script, the `script-message-received`
  channel is wired, and the reply rides back out through
  `bridge.resolve_json` + `run_javascript`. The Linux service proofs in
  `tests/e2e_linux/` are the first that could run at all. See ADR-0015.
- **`vails doctor` reports the native backends.** A new `backends` section
  lists every built-in service with `ok`/`stub` for *this* platform, and names
  a granted service that is a stub here. A `vails.json` grant is not a
  promise, and doctor says so before the app runs. See ADR-0015.
- **`examples/services`**: four services in one window (clipboard, opener,
  notification, os_info) and the E2E vehicle for the wave. The clipboard probe
  is the one that needs no human — write a known non-ASCII string, read it
  back, compare — so a screenshot is the whole round trip through the real
  user32/GTK clipboard. `tests/e2e_windows/capture.ps1` makes the Windows
  screenshots repeatable, and `tests/e2e_linux/run_services.sh` does the same
  under xvfb.

### Fixed

Five defects that no amount of reading would have found, all of them on the
Linux side, all of them now covered by a build or an E2E run:

- The Linux **V→JS eval** passed a V function pointer where WebKit wants a
  `GAsyncReadyCallback`, and the **GdkWindow** lookup had no reachable
  declaration — so no Vails app had compiled on Linux since the `Ctx.parent`
  work landed. Both are fixed behind `webview/webview_linux_shim.h`.
- The Linux **JS→V transport was declared and never connected**: no runtime
  injection, no message channel, so every example rendered in preview mode.
  (Described under Changed above.)
- `string.vstring()` **does not copy** the C block it wraps, so reading one
  after `g_free` was a use-after-free. It bit the new Linux bridge and the new
  GTK clipboard read; both now use `cstring_to_vstring`.
- `dialog_test.v` called a **Windows-only helper**, which is why `v test .`
  had never run on Linux.

## [0.2.0] - 2026-09-27

Phase 5 S1 wave 1 + the Tauri-inspired track (T1–T7). Phases 0–4 (scaffold,
window PoC on both backends, the JS↔V bridge, assets/dev server, the CLI) are
prerequisites rather than releases of their own and are folded in below.

### Added

- **Services as plugin manifests (T5, ADR-0014)**: `services/manifest.v`
  describes a service as data (`Service{name, version, summary, commands,
  ts_types}`), `services/install.v` is the single registration path and
  refuses an undeclared command, a missing handler, a foreign namespace and a
  duplicate. A service's commands ARE its capability names, so `vails.json`
  grants and manifests cannot drift apart.
- **`dialog` service** (Windows native, E2E-proofed): `dialog.open`,
  `dialog.save`, `dialog.message` behind a Common Item Dialog C shim
  (`dialog_shim.h`, UTF-8 C ABI, NUL-separated paths). A dismissal resolves
  `{canceled: true}` instead of rejecting. Linux is an explicit stub.
- **`os_info` service**: host facts only (`os_info.get`).
- **`vails dts`**: grant-driven TypeScript declarations + per-service JS
  snippets, so a frontend can only type-check what it was actually granted.
  Flags: `--config`, `--out`, `--js`, `--check`.
- **`webview.Ctx`**: one runtime handle per window — `emit` (V→JS, the
  direction Phase 2 left unwired), `run_js` and `parent` (the native window
  handle services parent their own UI to), handed to the app through the new
  `Config.on_ready`.
- **Capabilities (T1, ADR-0007)**: per-window command allowlists, asset-root
  scopes and platform filtering. Empty registry = deny all; a denied call
  answers `forbidden:`, never `unknown method`.
- **Strict IPC contract (T2, ADR-0010)**: `call_json` (gate → params
  validation → handler) vs `notify` (gate only), standard `err` prefixes,
  one native entry point (`handle_envelope_from`).
- **Light channels (T3, ADR-0011)**: `ChannelHub` mints `ch_<n>` ids for
  progress/streaming; eval-only, no native changes.
- **Managed state (T4, ADR-0011)**: one `state.Store` per `application.App`
  (Tauri `.manage()` equivalent), raw JSON per key.
- **Secure frontend defaults (T7, ADR-0012)**: a default CSP injected on both
  backends (it was only ever unit-tested before), idempotent and
  override-respecting.
- **Mobile prep (M0, ADR-0012)**: `mobile.is_mobile`, an intentional desktop
  no-op `apply_geometry`, and the `events.Common.*` contract future backends
  feed.
- **Dev server (Phase 3, ADR-0013)**: loopback stdlib-`net.http` server over
  the project dir with a livereload poller, capability-scoped, no `veb` so
  Windows tests stay gcc-free.
- **CLI (Phase 4, ADR-0013)**: `vails init/run/build/doctor`, the `vails init`
  scaffold, and `vails build` setting `VMODULES` to the vails root.
- **`vails.json` (T6, ADR-0008)**: windows, capabilities, asset root and
  bundle settings, validated by `doctor` and read by `run`/`build`.

### Changed

- A `blocking` command (a modal native dialog) is now a documented exception
  to the ADR-0010 threading rule, marked in the manifest so the constraint
  travels with the service. Such a command must never be called from
  `v test` — it blocks on a window nobody can click.

## [0.1.0] - 2026-09-26

Phases 0–2: the framework exists and both backends are proven with
screenshots (`tests/e2e_windows/pong.png`, `tests/e2e_linux/`).

### Added

- Repo skeleton: `v.mod`, `AGENTS.md` (workflow contract), `CONTEXT.md`
  (domain model), `ROADMAP.md` (phases + tracks), `docs/ADR/`.
- **Windows window PoC**: `webview/webview_windows.c.v` (webview 0.12 /
  Edge WebView2). ADR-0005 records the DLL side-by-side pain.
- **Linux window PoC**: `webview/webview_linux.c.v` (GTK + `WebKitWebView` +
  `gtk_main`), rendered headless under `tests/e2e_linux/run_headless.sh`.
  ADR-0005 records why GUI apps need `-gc none` on this setup.
- **JS↔V bridge**: `handle_message` + `runtime_js`/`runtime_js_bound` +
  `resolve_js`, E2E-proven on Windows (`ping` → `pong`).
- `examples/hello`: a window whose UI comes from a file, not from a string.
- The Wails (design guide) and Tauri (capabilities model) plans, plus the
  mobile track (ADR-0006) and the opt-in bundled-Chromium track.

### Changed

- The Linux-first decision (ADR-0002) stands: the Linux vertical slice comes
  before macOS, and no Go→V translation is ever attempted (ADR-0001).
