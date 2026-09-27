# ADR-0014 — Service manifests, the install path, and the first services

Date: 2026-09-27. Status: accepted (pure-V core + Windows native dialog
E2E-proofed; Linux deliberately stubbed, see below).

## Context

Phase 5 needs a service model, and T5 needs plugins with manifests. Until
now a "service" was `services/clipboard.v`, a bare function returning
`not implemented`. Three things were missing and all three blocked the
first real service:

1. A native service must push events to the frontend (V -> JS) and parent
   its own native UI to the host window. The V -> JS direction was never
   wired (Phase 2 leftover): `webview_eval` was declared and unused, and
   the T7 default CSP was only ever unit-tested, never injected on the
   native path.
2. V has no COM projection (ADR-0002), so a Windows file picker needs a C
   shim. The COM surface also differs per SDK — a shim written from
   memory would not have compiled.
3. Nothing stopped a service from claiming another service's command
   names, from drifting from its manifest, or from shipping a manifest
   that disagrees with the router.

Verification for this batch: `v test .` green on Windows (26 files), the
Common Item Dialog opened parented to the webview window with the parsed
filters (`tests/e2e_windows/dialog.png`), and `vails dts` generated the
example's `.d.ts` from its grants.

## Decisions

- **One runtime handle per window: `webview.Ctx`** (`webview/ctx.v`).
  `{label, eval_fn, parent}`: `emit(event, data)` builds the
  `events.to_js` snippet and hands it to `eval_fn`; `parent` is the
  native window handle (HWND / GdkWindow) services parent their own UI
  to. Pure-V and testable with a fake sink, because the native backends
  only fill `eval_fn` and `parent`. The app receives it through the new
  `Config.on_ready`, which the backend calls after the native window
  exists and before the event loop starts — so services install against
  a real handle without a second lifecycle hook.
  - Windows: `eval_fn` is `webview_eval`; `parent` is
    `webview_get_window(w)`, which webview 0.12 already exposes. No
    change to the proven window-creation path. A non-OK
    `webview_error_t` becomes a V error instead of a dropped snippet.
  - Linux: `webkit_web_view_run_javascript`, read after
    `gtk_widget_show_all` because `gdk_window_get_window` is NULL until
    the widget is realized.
  - `Config.document()` now feeds both backends, which closes the T7
    gap: the default CSP is injected on the native path (an app-supplied
    CSP still wins, `inject_csp` is override-respecting).
- **Modal services are the documented exception to ADR-0010's threading
  rule.** `dialog.open/save/message` block the webview main thread until
  the user answers. That is the intended behavior — a modal dialog is
  supposed to freeze the UI, and the page behind it cannot be used
  anyway — and it is what Tauri does. The rule that survives: such a
  handler must do no V work while blocked (no parsing, no I/O, no
  `spawn`); everything expensive belongs inside the OS dialog. The
  manifest marks these commands `blocking: true` so the constraint is
  visible in the service description, not only in prose.
  - Consequence for tests: a `blocking` command must never be called from
    `v test`. It blocks on a window nobody can click, and `v test` hangs
    (observed, twice). The dialog tests install the real manifest
    against a fake backend and unit-test the option/result mapping; the
    pickers are proven by hand.
- **A service is described by data, and installed through one path.**
  `services/manifest.v`: `Service{name, version, summary, commands,
  ts_types}` + `Command{name, params, result, blocking, summary}`. A
  service's commands ARE its capability names (`dialog.open`), so
  `vails.json` grants and manifest entries cannot drift apart
  (ADR-0007). `services/install.v` is the only registration path and it
  enforces four invariants: a handler must be declared, a declared
  command must have a handler, a command must live in its own service's
  namespace, and a no-argument command gets `bridge.validate_empty`.
  `install_all` takes a per-service handler map so a handler cannot leak
  between services.
- **COM lives in `services/dialog_shim.h`, values are UTF-8.** Three
  functions with a plain C ABI: `vails_dialog_message` (MessageBoxW),
  `vails_dialog_open`, `vails_dialog_save`. Results are a count, `0` for
  canceled, negative for an error with a message in a static slot; paths
  come back NUL-separated in a 64 KB buffer. The GUIDs and the
  `COMDLG_FILTERSPEC` shape were read out of the installed MSYS2
  headers, and two header facts shaped the code: the Common Item Dialog
  vtbls are per-interface (`GetResults` on `IFileOpenDialog`,
  `GetResult` on `IFileSaveDialog`, so a multi-select is walked item by
  item because the mingw C vtbl of `IShellItemArray` has no
  `GetDisplayName`), and the base `IFileDialog` vtbl carries every
  configurable member, so one configuration function covers both
  dialogs. `CoInitializeEx(COINIT_APARTMENTTHREADED)` per call: the
  handlers run on the main thread, which is the first thread to touch
  COM here, so that is the app's apartment.
- **Cancellation is a result, not an error.** A dismissed dialog
  resolves with `{canceled: true}`; the promise fulfills and the
  frontend decides. Only real failures reject. Option problems are
  wrapped in the standard `bad params: …` value (ADR-0010) so a
  frontend can branch on the prefix.
- **`os_info` was pulled forward from S1** (the catalog order is
  dialog → notification → menu → tray → clipboard → opener → os-info).
  It is the cheapest possible service — pure V, no native handle — and it
  is what proves the manifest/install path a second time, on a service
  with zero platform code. Host facts only: no user names, no
  environment, no installed software. `arch` comes from a compile-time
  `$if` because V exposes no runtime arch value; the CPU count from
  `runtime.nr_cpus()`.
- **`clipboard` gained its command surface, not its native half.** It is
  not in the catalog yet: a grant now produces a named "wave 2" backend
  error instead of `unknown method`, which is the honest state.
- **T5 codegen is driven by the grants.** `vails dts` maps
  `vails.json` capability commands to manifests and emits one namespace
  per service (manifest `ts_types` first, then one Promise-returning
  function per command) plus the per-service JS snippet. A frontend can
  only type-check against what it was granted. `--check` prints (CI),
  `--js` writes the snippet, an unchanged file keeps its mtime so the
  dev server does not reload for nothing, and unknown grant names are
  reported as app commands rather than failures. `doctor` lists the
  granted services so a forgotten `vails dts` is visible early.
- **Linux is a stub, on purpose.** This machine has no WSL/Linux V, so
  GTK chooser code could not be compiled, let alone verified. Writing it
  blind would have shipped a file whose first compilation happened
  later (AGENTS.md §4 says the opposite of that: pure-V seam first, stub
  the native side with `not implemented on …`). `dialog_linux.c.v` names
  the wave and the manual test lives in `tests/e2e_linux/README.md`.
- **Test hook for the E2E proof: `VAILS_DIALOG_PROBE`** in
  `examples/dialog`. A synthetic mouse click does not reach WebView2
  content reliably (verified: two attempts, no event), so the probe
  appends one call to the document instead and travels the exact
  production path. It is an example-only hook, documented in the example
  header and both e2e READMEs.

## Consequences

- `services/` now needs gcc on Windows (it holds a `.c.v`), the same
  constraint `webview/` has had since Phase 1. `v test ./services`
  without MSYS2 gcc fails like `v test ./webview` does; everything else
  stays gcc-free.
- A service that needs the window must be installed from `on_ready`, not
  before `webview.run` — the handle does not exist yet. The router has
  to be heap-allocated so the closure and the native dispatch path share
  one instance.
- Next waves (`notification`, `menu`, `tray`, `opener`, full
  `clipboard`) reuse `Ctx.parent` and the shim pattern; `tray` also
  needs the HWND for `NOTIFYICONDATA`, so this seam is the prerequisite
  for the rest of S1.
- macOS (Phase 6) will need its own shim (`NSOpenPanel`/`NSAlert`) with
  the same three-function ABI; the Ctx seam stays as is.

## Notes (V toolchain, cost real time)

- A map literal whose value is a fn literal does not parse — build the
  map, then assign.
- A closure body ending in a `!void` call needs an explicit `!` (or
  `or { return err }`); a bare `return f()` yields a `none` error whose
  message is empty, which is a nasty thing to debug.
- V closures capture locals by value: shared state in a handler needs a
  heap pointer (the `&Counter` pattern hello already used).
- `v` compiles each `_test.v` as its own module, so a test helper in one
  test file is invisible in another; list-based core functions are the
  fix (and better design anyway).
- `os.getarch`/`os.cpus` do not exist; `runtime.nr_cpus()` does.
- `document.title = …` never reaches the native window caption without a
  title-changed callback, so it is useless as a V->JS smoke test — a
  page element or a screenshot is the honest check.
