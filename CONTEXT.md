# CONTEXT.md — Vails domain model

Ubiquitous language. Keep this file in sync with the code; agents use it
to stay consistent across sessions.

## Core concepts

- **Application (`application.App`)**: owns the lifecycle (`new` → register
  services → `run`). Created from `AppOptions` (title, size, assets dir).
  OS-agnostic. Never touches GTK/WebKit directly.
- **Window (`webview.Config` + `webview.run`)**: a native window hosting one
  webview. The **only** module allowed to contain C calls. Every other
  module talks to it through plain V structs/strings.
  `Config.validate()` rejects empty title / non-positive size pre-native.
  `Config.document()` returns the HTML to load with the default CSP
  injected (both backends use it; empty in URL mode). `Config.on_ready`
  hands the app the window's `Ctx` after the native window exists and
  before the event loop starts (services install there). See ADR-0014.
- **Backend status (`services.ServiceStatus`, `support.v`)**: whether *this*
  build has a real native backend for a service, on *this* platform.
  `supports()` collects one `*_support()` per catalog service (each answers
  from the same `$if` its dispatch uses, so they cannot drift), and
  `report`/`ok_count` render it for `vails doctor`. A grant in `vails.json` is
  not a promise — `notification.*` is a valid grant on Linux where the
  backend is a stub — so doctor says so before the app runs. A stub always
  carries a `note`. See ADR-0015.
- **Window handle (`webview.Ctx`)**: the window-scoped runtime handle a
  service talks to: `emit(event, data)` (V -> JS via the `events.to_js`
  snippet), `run_js`, and `parent` (the native window handle, HWND /
  GdkWindow, used to parent native UI). Pure-V: the backends only fill
  `eval_fn` + `parent`, so it is unit-testable with a fake sink.
  `emit` from a spawned worker is the answer to ADR-0010's
  "heavy work via spawn + result as event"; on Windows the eval must
  happen on the webview thread, so push it from a handler, not from a
  worker. On Linux the same two values are filled by GTK: the eval
  through `vails_run_javascript` and `parent` through
  `gtk_widget_get_window` (both in `webview_linux_shim.h` /
  `webview_linux.c.v`; the C shim exists because a V function pointer is
  not a `GAsyncReadyCallback`). See ADR-0014/0015.
- **Window host seam (`webview/host.v`, ADR-0017)**: the one place the OS may
  call *into* V. `attach(Ctx, HostHandler) ! &HostCtx` stacks a comctl32
  `SetWindowSubclass` on the window the webview library created, so a native
  message (tray: `WM_APP+1`) reaches a V handler; `detach` removes it and
  frees the context; `post_message` sends one message (that is how
   `menu.close` escapes a modal menu loop). Services attach **opt-in per
   service**; the one exception is the job wakeup below, which `webview.run`
   installs because it has to. It is **Windows-only**: on Linux the C->V
  direction is per-object (a `GtkMenu` emits `activate`, a `StatusNotifierItem`
  has no click at all), so `attach`/`post_message` return an explicit
  "not available on this platform" error and there is no
  `webview/host_linux.c.v`. `HostEvent{msg, wparam, lparam}` carries raw
  message data with no meaning attached: the vocabulary belongs to the
  service (`tray` turns it into `tray:clicked`). No globals: the subclass's
  `dwRefData` ferries a heap `&HostCtx` and C never dereferences it, the same
  rule as `BindCtx`/`DispatchCtx`.
- **The seam is a chain, and a handler says what it consumed** (ADR-0023):
  `HostHandler = fn (e HostEvent) !bool`, where `true` means consumed and `false`
  means "not my message" — which is what lets **more than one** service attach
  to the same window (tray takes `WM_APP+1`, the menu bar takes `WM_COMMAND`).
  comctl32 keeps subclasses in a chain and routes through `DefSubclassProc`, and
  because the context pointer is the subclass id, each `attach` is a distinct
  entry and `RemoveWindowSubclass` takes exactly one. An **error** is treated as
  consumed (recognised then failed), and a false is what preserves the safety
  property that every unowned message still reaches the webview library — the
  reason the seam exists. `host_proc` therefore asks the handler about *every*
  message rather than filtering on a hardcoded id, which was correct with one
  hook and wrong with two.
- **A job is the unit a worker hands back, and a message is only a wakeup**
  (`webview/jobs.v`, ADR-0019): `Job = fn ()`, `JobQueue` is a
  `sync.Mutex`-guarded `[]Job`, and `webview.post_to_main(ctx, job)` runs that
  closure on the window thread. The two directions are different problems and
  the vocabulary keeps them apart: chaining (ADR-0023) routes **OS-initiated
  messages**, and `HostEvent` is three integers so it cannot carry a closure —
  the job queue is what delivers **V work**. This is the missing second half of
  ADR-0010, where a `spawn`ed worker had no way to reach the page because
  `ctx.emit` ends in `webview_eval` on a thread the webview does not own.
  - `Ctx.main` is a `&MainThread` (a pointer, not a value: `Ctx` is copied in
    several places and the queue must be shared), nil meaning "no live window".
  - `take()` detaches a batch **under** the lock and `run_batch` runs it with
    the lock **released**, because a job that posts again would otherwise
    re-enter a non-recursive `SRWLOCK` and hang with no error and no stack. A
    nested job waits for the next wakeup rather than recursing inline.
  - The wakeup is `WM_APP+2` (`wakeup_message`), deliberately **not**
    `host_message`: `tray` classifies on that id alone, so a wakeup sharing it
    would arrive as an indistinguishable left click and open a tray menu.
  - **The subclass is installed eagerly by `webview.run`, on the window
    thread** — the ADR's planned lazy "install on first post" could not work,
    because `SetWindowSubclass` is thread-affine and `post_to_main` is by
    definition called from a worker. The first real run failed with
    `SetWindowSubclass failed (code 0)`. `install_wakeup` is therefore the one
    thread-affine step and it is not something `post_to_main` may do; a failed
    install is logged, not fatal, and `post_to_main` then refuses with a named
    error rather than accepting a job nothing will ever run.
  - Windows-only: the Linux `g_idle_add` trampoline is unwritten, so
    `post_to_main` returns an explicit "not available on linux yet" and
    `webview.run` still creates and destroys a `MainThread` to keep the shape
    symmetric.
- **A window is addressed by label, never by a `Ctx` you are holding**
  (`webview/window.v`, ADR-0035, F0): `Window{label, ctx, state, native}` with
  a `created → ready → running → closed` lifecycle, and `WindowRegistry` keyed
  by label. `emit_to(label, event, data)` is the public routing surface.
  - **Why a struct and not just the `Ctx`:** `Ctx` knows its own label but is
    not addressable, and building the app's own parallel `&Window`s would mean
    two registries that could disagree about which window is which. So
    `Config.on_window` hands the app **the backend's own** `&Window`, before
    `on_ready` for that window.
  - **The bug this makes impossible** is the one the ROADMAP called "the half
    that is easy to get wrong": with two windows, emitting through the wrong
    `Ctx` is **not** a crash. The event is delivered, the promise resolves, and
    the wrong page's status line changes — so a single-window test suite and a
    single-window screenshot both pass. An unknown label is an **error** and
    nothing is delivered anywhere, because the convenient fallback ("the first
    window", "main") delivers to a real and wrong page, which is the same
    defect with a plausible deniability.
  - **Labels are unique and non-empty**, checked at `add`: two windows sharing a
    label would share a capability identity (T1) *and* give `emit_to` two
    destinations.
  - **`find` returns a plain `&Window`, never `Option<&Window>`** — a V 0.5.2
    bug workaround (AGENTS.md §2c): `or` does not run for a none
    `Option<&T>`, so the obvious `has()` returns true for a window that does not
    exist.
  - **An eval always goes to the thread that owns its webview**, and which
    thread that is is a property of the *window*. `eval_sink` compares
    `GetCurrentThreadId()` against the id read once on the window's own thread:
    same thread → `webview_eval` directly (the wakeup handler runs inside the
    window's loop, and re-dispatching to the loop that is calling you is
    refused); any other thread → `webview_dispatch`.
- `run_many([]Config)` is the entry point; `run(cfg)` is its one-element case
    and is unchanged, so every existing app is unaffected by construction. Its
    rules live in `check_windows([]Config)` - at least one window, every config
    valid, no two windows sharing a label - because that is the only form of
    them a test can ask about without opening a native window. **Windows opens
    N windows**: WebView2 binds the HWND, the COM apartment and the message
    pump to one thread, so window 2..N each get a thread and each thread calls
    `CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)` before `webview_create`.
    Linux is structurally multi-window (one `gtk_main` with N `GtkWindow`s,
    quitting when the last closes).
- **Bridge (`bridge.Router`)**: maps a JS-initiated call to a V function.
  Wire format is JSON: `Request{id, method, params}` → `Response{id, result,
  err}` where `params`/`result` are raw JSON strings. No reflection:
  methods are registered explicitly via `register(name, handler)`.
  `handle_message(raw)` is the native callback entry point (always returns
  JSON, never errors). It unwraps the webview library's one-element array
  wrapping (`unwrap_args`) and accepts a bare object (raw WebKitGTK path).
  `runtime_js()` is the injected `window.vails` runtime
  (`call`/`emit`/`onEvent` + internal `__resolve`/`__emit`); `runtime_js_bound(name)`
  is the same runtime for the webview-library backend where the bound fn
  resolves with PARSED JSON (normalized before `__resolve`). `resolve_js(res)`
  builds the reply snippet. See ADR-0004/0005.
- **IPC contract (T2)**: command = request/response via
  `call_json(window_label, id, method, params, reg)` (capability gate, then
  params-shape validation via `register_validated` + `ParamsValidator`, then
  handler); event = one-way, no reply via `notify(window_label, event, data,
  reg)` (gate only; the app forwards to its own `events.Bus`). Wire shapes:
  `Notify{event, data}`, `NotifyAck{ok, err}` (ignored by JS `emit`), and
  `handle_envelope_from` (the single native entry point; `method` set →
  command, `event` set → event). Standard err prefixes (wire contract):
  `unknown method:`, `forbidden:`, `bad request:`, `bad params:`,
  `bad event:` (builders `err_unknown/…`). Threading rule: handlers run on
  the webview main thread → fast/non-blocking; heavy work via `spawn` +
  result as event. `webview.Config.registry` (empty = deny all) feeds the
  gate; `validate_empty` covers no-arg commands. See ADR-0010.
- **Event (`events.Bus`)**: fire-and-forget pub/sub both directions.
  `on(event, handler)` / `emit(event, data) returns handler-count`.
  Ordering guarantee: handlers run in registration order, synchronously
  (async delivery is a Phase 5+ concern).
  `to_js(event, data)` builds the `__emit` evaluate snippet for the JS side.
- **JS escaping (`jsesc.escape`)**: single-quote JS-literal escaping
  (`'`, `\`, newlines, `<`→`\x3c`); shared by `resolve_js` and `to_js`.
- **Channel (`bridge.Channel`/`ChannelHub`, T3)**: Tauri-`Channel`
  equivalent for progress/streaming. `new_hub().open(event)` mints
  `ch_<n>` ids (no globals, one hub per window); `push_js(data)` builds
  the `__emit(id, …)` eval snippet (delivery on the id, parallel streams
  never interleave; push-after-close errors); `close_js()` emits the
  terminal `<id>:close` marker and is idempotent. No native changes.
  See ADR-0011.
- **Managed app state (`state.AppState`, T4)**: Tauri-`.manage()` equivalent —
   one `AppState` per `application.App` (`set_state`/`get_state`/`has_state`
   forwarders). Values are raw JSON strings; typed access is hand-written
   (`set_string`/`get_string` pattern, `$for` only if proven sufficient).
   Same threading rule as handlers (main thread; `spawn` workers reply as
   events). See ADR-0011. **In-memory and session-scoped, NOT persistence** —
   and it used to be called `state.Store`, which collided with the persisted
   `store` service below by one letter's case. The bare word went to the
   durable thing (matching Tauri, where `tauri-plugin-store` is exactly that)
   and this took the name its own comment already claimed. The two are not
   merged and are not interchangeable: this one is not thread-safe *because*
   handlers are on the main thread, a persisted store is touched by workers and
   by a capability-gated page. See ADR-0030.
- **Persisted `store` (planned, track D)**: the durable key-value surface, and
  the only thing in Vails that "store" means. One key-value service with a
  **swappable engine behind a seam**, default a JSON file (the data is
  config-shaped and a few KB, the file stays inspectable, and it keeps the
  suite gcc-free per ADR-0013), with `v.lang/leveldb` as an opt-in engine for
  data that outgrew it. Deliberately *not* a second KV API beside it. See
  ADR-0032.
- **Build identity (`buildinfo.version()`, ADR-0034)**: the *app's* version,
  stamped in at compile time by `vails build --version` as
  `-d vails_version=<semver>` and read back with `$d('vails_version', 'dev')`.
  A binary with no stamp reports `dev`, and `dev` silently disables every
  update check, so the distinction between "a development build" and "a
  release nobody stamped" is a `vails doctor` line rather than something a
  user can see. Separate from the *framework* version
  (`buildinfo.framework_version`), which `v.mod` must match — they were two
  hand-edited numbers and they were already disagreeing. `validate_version`
  refuses `1.0` and `01.2.3` because the updater *compares* the string.
- **Build recipe (`buildplan.recipe`, ADR-0034)**: what `vails build` decided,
  as a value — the compiler flags, the output name, whether the five
  side-by-side DLLs get staged, and any warnings. `Target` is an *argument*
  rather than `os.user_os()` so a Linux recipe is asserted on the Windows CI
  run. `-gc none` on Linux and `-cc gcc` on Windows come from here rather
  than from a CI command, because a build flag a developer has to remember is
  a flag CI gets wrong on the first run.
- **Side-by-side DLLs (`buildplan.side_by_side_dlls`)**: the five files a
  Windows GUI app cannot start without, from `C:\msys64\ucrt64\bin`. A
  constant, not a directory scan — a scan picks up whatever else is in
  `bin`. The `0.12` in `libwebview-0.12.dll` is why `webview` is pinned.
- **Dependency declaration (`deps.Set`, ADR-0034)**: a `vails.json`
  `dependencies` block in the `v.mod` shape, plus `vails.lock` recording what
  was **resolved**. The two are different on purpose — a config records what
  was asked for, a lock what was fetched — so only an *exact* requirement is
  compared between them. **Vails declares and reports; VPM resolves.** There
  is no `vails deps install`, because a framework that keeps its own resolved
  tree and a hand-run `v install` can disagree, and the build then depends on
  which ran last.
- **`sql` takes a query name, never SQL text (`sqlreg`, ADR-0034)**: the
  security decision ADR-0032 recorded in prose, now as the code D3 will be
  written against. A page names a query; V owns the statement. SQL text from
  a page is not a query name and never becomes SQL. Multiple statements are
  refused **at registration**, so a statement that could smuggle a second one
  is never in the registry; parameter *values* are bounded as well as
  statements; a named parameter the statement does not contain is refused;
  and `resolve_read` exists separately from `resolve` so a read-only grant
  cannot reach a write by naming it. The registry has **no mutating entry
  point** — that absence is the threat model, and a `sql` command accepting a
  query string is remote code execution the moment an app loads remote
  content. Backed by `elliotchance/vsql`, pure V, so gcc-free. See ADR-0032.
- **Secure defaults (`webview.default_csp`/`csp_meta`/`inject_csp`, T7)**:
  every window runs under a default CSP (`default-src 'self'`,
  `object-src 'none'`, `frame-ancestors 'none'`; inline script+style
  allowed so single-file frontends keep working). App-supplied CSP meta
  wins (`inject_csp` is override-respecting + idempotent); hello ships
  the policy verbatim and its preview fallback is the tested secure mode.
  See ADR-0012.
- **Mobile prep (`mobile`, `events.common_*`, M0)**: `mobile.is_mobile()`
  (`$if android || ios`), `apply_geometry` (intentional desktop no-op;
  explicit `not implemented (M1/M3)` on mobile targets).
  `events.common_battery/network/theme/low_memory` (`common:*` names +
  JSON payload shapes) is the contract future backends feed. See
  ADR-0012.
- **Asset (`assets.Server`)**: read-only file provider for the frontend.
  `content_type(path)` maps extensions to MIME. Prod = embedded bytes
  (`assets.Bundle`, filled with `$embed_file` by the app), dev =
  directory reads (`Server.read`); both enforce the same traversal +
  allowlist checks. Registry-driven entry points `Server.resolve_for` /
  `Bundle.resolve_for` scope reads to the window's granted roots (no
  grant = deny); the dev side is `dev.DevServer` (loopback HTTP +
  livereload, same checks). See ADR-0012/0013.
- **Dev server (`dev.DevServer`, Phase 3)**: loopback stdlib-`net.http`
  server over the project dir (stdlib, not `veb`, so Windows tests stay
  gcc-free — ADR-0013). `root` = project dir, `asset_root` prefixes
  every path; reads go through `assets.Server.resolve_for` (no grant =
  deny, same as prod). `/` → `<asset_root>/index.html`; missing → 404,
  traversal/outside-grant/no-grant → 403. HTML responses carry an
  idempotent livereload poller (`/__vails_dev_version` =
  `build_id:frontend_version`). `vails run` spawns it and opens the
  first window at `dev_url()` with an EMPTY router (frontend iteration
  only); `--serve-only` skips the window.
- **CLI root (`vails_home`, Phase 4)**: `vails build` sets `VMODULES`
  to the vails source root so scaffolded projects (bare imports) compile
  anywhere: explicit `VAILS_HOME` wins, else walk-up from the CLI binary
  and cwd; absent root fails fast. See ADR-0013.
- **Service**: a named native capability (`clipboard`, `dialog`, …)
  registered on the `App` by string name. Implementations live in
  `services/` and may be OS-gated.
- **Service manifest (`services.Service`, T5)**: the data description of a
  service — `Service{name, version, summary, commands, ts_types}` with
  `Command{name, params, result, blocking, summary}`. A service's commands
  ARE its capability names (`dialog.open`), so grants and manifests
  cannot drift apart. `js_snippet()` emits the per-service frontend glue
  (no monolithic runtime), `ts_types` the TypeScript shapes the generated
  `.d.ts` needs. `services.manifests()` is the one catalog; resolution
  helpers take a list (`find_in`/`service_in`/`lookup_in`/`select_in`) so
  they are testable without the catalog. See ADR-0014.
- **Service install (`services.install`)**: the single registration path
  (`install(router, manifest, backend)`). It refuses a handler for an
  undeclared command, a missing handler, a command outside the service's
  own namespace, and a duplicate registration, and it wires
  `bridge.validate_empty` for commands that declare no params. The
  capability gate stays in `bridge.Router.call_json`; a `blocking`
  command (a modal native dialog) is the documented exception to the
  ADR-0010 threading rule and must never be called from `v test`.
- **Dialog service (`services/dialog`)**: the first service with a real
  OS backend. Commands `dialog.open` / `dialog.save` / `dialog.message`,
  options validated in pure V (kind must match the command, bounded
  strings, filters must be bare extensions), result
  `{canceled, paths, button}` — a dismissal is a *result*, not an error.
  Windows: Common Item Dialog + `MessageBoxW` behind `dialog_shim.h`
  (UTF-8 C ABI, NUL-separated paths; V has no COM projection). Linux:
  `GtkFileChooserDialog` / `GtkMessageDialog` (ADR-0027), parented to
  `Ctx.toplevel` — the `GtkWindow`, not the `GdkWindow` that `Ctx.parent`
  is — with the GTK response-id mapping in pure V so it is tested on every
  platform. A call with no display is refused with a named error rather
  than crashing, because GTK requires `gtk_init` first. The commands stay
  `blocking: true` (the ADR-0014 nested-loop exception), which is also
  why the native path has no unit test: see ADR-0027. See
  ADR-0014/0015/0027.
- **Clipboard service (`services/clipboard`)**: the system clipboard as text
  (`clipboard.read_text` → `string`, `clipboard.write_text` → `string`).
  Params are raw JSON, so a frontend writes
  `vails.clipboard.write_text(JSON.stringify(text))`; the payload is bounded
  at 1 MiB and a non-string payload is `bad params:`. A clipboard holding no
  text is a *result* (`""`), not an error. Reading needs no window handle;
  writing needs `Ctx.parent` (`require_parent`), because `EmptyClipboard`
  makes the opening window the clipboard owner — a rule kept in pure V so it
  is testable. Windows: user32 `CF_UNICODETEXT` with the UTF-8→UTF-16
  conversion into a `GMEM_MOVEABLE` block the clipboard takes over (V has no
  COM here, so no shim). Linux: the GTK clipboard. Both backends are reached
  through `read_text_native`/`write_text_native`; `v test` never calls them
  (the clipboard is shared machine state) — the round trip is proven by
  `examples/services`. See ADR-0015.
- **os-info service (`services.os_info`)**: host facts only (`os_info.get`
  → os, arch, hostname, cwd, home, temp, exe, cpus). The reference
  service with no native half; capability-gated like everything else.
- **Menu service (`services/menu`)**: a native **popup** — what a right-click
  opens, and what a tray icon's right-click will open. Commands `menu.popup`
  (manifest `blocking: true`) and `menu.close`; items are `MenuItem{id, label,
  enabled, separator, children}` with an id **whitelist** (`[A-Za-z0-9_.:-/]`,
  because the id also travels as the Windows HMENU command id) and a label
  that rejects `&` (the Windows mnemonic marker would render a different
  string than the frontend sent). Depth ≤ 4, ≤ 64 items, ids unique. The
  choice arrives as an **event** — `menu:clicked {id}` or `menu:canceled
  {canceled:true}` — and the command's own result is always `""`, because
  `TrackPopupMenuEx` is a nested message loop on the handler's thread (Windows,
  the ADR-0014 modal exception) while the GTK popup returns at once and the
  answer arrives on each item's `activate` signal (Linux). One contract for two
  natives beats a per-platform result. A window *menu bar* is the same service
  as the popup, not a new one (ADR-0023): `menu.set_menu` takes the same
  `MenuPopup` params, is validated by the same `parse_popup`/`validate_items`,
  draws its command ids from the same `flatten_items` order, and answers on the
  same `menu:clicked` event — so one frontend listener serves a right-click
  popup and a window bar. It is NOT `blocking` (installing a bar waits for
  nobody) and an **empty item list removes the bar**, which is how a frontend
  removes it rather than a second command. `bar_click(HostEvent, ids) ?string`
  is the whole of the bar's testable half: LOWORD(wParam) is a 1-based index
  into the flat id list, and it rejects a non-`WM_COMMAND`, a non-zero HIWORD
  (a control notification), 0, and an id past the end — each of which would
  otherwise report a choice the user never made. On Windows a bar's answer can
  only arrive as `WM_COMMAND` (a bar has no call to return a value from, unlike
  `TPM_RETURNCMD`), which makes it the second user of the **window host seam**.
  On Linux the bar needs no hook at all: its items are ordinary widgets whose
  `activate` the backend connects. `MenuState` carries `bar_handle` (the
  persistent bar, unlike the popup's `handle`), `bar_ids` (the decode table — a
  separate id space from an open popup's, which never routes through a
  message), `bar_context` (the `*LinuxBar`, kept alive because the bar's
  callbacks travel in its address) and `bar_hook` (the seam, Windows only).
  See ADR-0023.
- **MenuState** is the popup's shared state: `ctx`, the native `handle`, `open`,
  and `context` — the backend's own per-popup struct, reachable so `menu.close`
  can tear a popup down itself. `context` is a `voidptr` because `MenuState` is
  shared by both backends while `LinuxPopup` exists only in `menu_linux.c.v`.
  It exists because a platform's own dismissal signal is not guaranteed to fire
  when the *app* closes the menu: `gtk_menu_popdown` does not emit
  `deactivate`, so a close path that trusted the signal emitted no event and
  leaked. Teardown is therefore one shared function guarded to run once, called
  by both the signal and `menu.close`.
- **Tray service (`services/tray`)**: an icon in the notification area
  (`tray.set {icon, tooltip}` / `tray.destroy`), and the first service the OS
  *drives*: a click arrives as `WM_APP+1` on the webview library's window,
  reaches V through the **window host seam** and is reported as
  `tray:clicked {button: "left"|"right"}` (`classify_click` maps the shell's
  five notification-area messages; a double click reports the same button).
  The service reports a click and does not interpret one — a left click
  opening a window and a right click showing a `menu.popup` is the app's
  decision, which is why the tray stays reusable. Windows: `NIM_ADD` with
  `NIF_MESSAGE` pointing at the seam's message, and the icon removed again by
  `tray.destroy` — the seam is detached there too, and *after* the icon, so no
  click can arrive for a tray that is gone. Linux: one
  `libayatana-appindicator` `AppIndicator` (a GObject that must be **unreffed**,
  or a second `tray.set` grows a row of dead icons), which needs a D-Bus
  session bus to register and a StatusNotifierHost to be drawn — so Linux has
  **no click event at all** (this version of the library has no `activate`
  signal; the host opens the item's menu) and `simulate_click` refuses there
  with that reason. `simulate_click(ctx, button)` is the service's own
  manufacturing of the click message, so the loop is provable without a
  mouse; it is not a command and not grantable. `install_tray` returns the
  `&TrayState` it created for exactly that reason.   The shell identifies an
  icon by `(hWnd, uId)`, so `tray` and any second shell icon must use different
  ids — they share the `NOTIFYICONDATA` primitive in
  `services/trayicon_windows.c.v` and nothing else. (`notification` was the
  other user of that primitive until ADR-0018 replaced its balloon with a
  WinRT toast; the file is now the tray's alone.) See ADR-0017.
- **Notification service (`services/notification`)**: a real Windows
   notification the OS shows without stealing focus (`notification.notify` →
   `string`, `notification.is_supported` → `boolean`). Windows: a **WinRT
   toast** (`Windows.UI.Notifications` behind `services/toast_shim.h`, no
   tray icon, no lifetime worker — a toast is owned by the shell from the
   moment `Show` returns). The **document is built in pure V** (`toast_xml` +
   `escape_xml`), because an unescaped `<` from a frontend produces a
   document the shell refuses and the symptom points nowhere near the cause.
   An unpackaged app cannot raise a toast **without an AppUserModelID**, so
   the identity is app config — `vails.json` `bundle.identifier`, validated
   in pure V by `config.validate_identifier` (the failure it prevents is a
   toast that silently never appears) and reported by `vails doctor` whenever
   `notification` is granted without one; an empty id is an error naming the
   field, never a guess. `notify` **resolves with the mechanism that ran**
   (`backend_toast` = `'toast'`), which is the only machine-checkable
   evidence a toast produces. `timeout_ms` is a *hint*: the shell decides the
   on-screen duration, and the request only picks the toast's `duration`
   (`toast_duration`). `is_supported` stays compile-time ("is there a
   backend"); `toast_available()` is the separate "can this machine activate
   WinRT" probe, kept apart precisely because a stripped app image compiles
   and links the toast and still cannot raise one. Other platforms remain an
   explicit stub. See ADR-0018 (which replaces ADR-0015's tray balloon).
- **App identity (`config.BundleConfig.identifier`)**: the app's stable
  identity, and on Windows its **AppUserModelID** — the key the shell
  attributes notifications, taskbar grouping and toasts by. Scaffolded by
  `default_identifier` from the app name, validated by
  `validate_identifier` (ASCII alphanumeric plus `.`, `-`, `_`; ≤128 chars;
  no leading/trailing period — the shell's own rules, which are why they live
  in pure V where a test can hold them). Optional, because only `notification`
  needs it. See ADR-0018.
- **Wire field names are snake_case**: a V struct field name *is* the wire
  name — json2 drops keys it does not recognize, and a `@json:` attribute
  does not survive V's C codegen. So `ts_types` promises `default_path`,
  never `defaultPath`; `dialog_test.v` guards the pair. See ADR-0015 Notes.
- **Opener service (`services/opener`)**: hand a URL or a local path to the
  user's default handler (`opener.open_url` → `string`,
  `opener.open_path` → `string`). It is the one service whose job is making
  the OS act on a frontend string, so its validation *is* the security
  boundary: `open_url` accepts only `http`/`https`/`mailto`/`tel`
  (`url_scheme`, and a scheme needs ≥2 chars so `C:\notes.txt` is a path and
  not the scheme "c"), `open_path` accepts only a non-empty local path with
  no `://` and no NUL. Both wrap a rejection in `bad params:` from inside the
  service, so the wire contract is the same whether a command is reached
  through the router or called directly. Windows: `ShellExecuteW` (verb
  `open`; `with` is the program, the path its parameter). Linux: GIO's
  `g_app_info_launch_default_for_uri` after
  `g_canonicalize_filename` + `g_filename_to_uri` — no `xdg-open` process,
  and `with` is refused with a readable error because the desktop resolves
  the application itself. See ADR-0015.
- **Binding spec (`generator.MethodSpec`)**: static description of one
  bound method used to emit TypeScript declarations (`generate_dts`).
  Hand-written specs for now; compile-time auto-derivation is Phase 7.
  `services.Service.specs()` bridges a manifest onto this shape, and
  `services.dts`/`services.snippets` render a manifest into the `.d.ts`
  and the JS glue the CLI writes (`vails dts`, grant-driven).
- **Config (`config.VailsConfig`, `vails.json`)**: the app's persisted
  project file (T6): name/version, `windows` list (`WindowConfig` maps
  1:1 onto `webview.Config` but the caller builds it, so `config`
  never imports `webview`), `capabilities` (decoded as
  `CapabilitySpec`, converted via `to_registry()` for
  `bridge.Router.call_from`), `asset_root`, `bundle` metadata
  (incl. `windows_dll_side_by_side` from the Phase 1 lesson).
  `load`/`load_text` + fail-fast `validate()`; `default_config` is the
  `vails init` scaffold (empty capabilities = deny by default).
  Enforcement of the stored grants is T2. See ADR-0008.
- **Capability (`capabilities.Registry`)**: Tauri-style allowlist (T1).
  `Capability{id, windows, commands, asset_roots, platforms}` granted via
  `grant`; `is_allowed(window_label, command)` gates dispatch
  (`is_allowed_on` is the testable core with injected OS). Empty
  `windows`/`platforms` = all, empty `commands` = none, empty registry =
  deny all. `webview.Config.label` (default `'main'`, distinct from title)
  is the window's security identity; `bridge.Router.call_from` /
  `handle_message_from` return `forbidden: …` (not `unknown method`) on
  deny; `assets.Server.allowed_roots` (empty = legacy root-only) scopes
  file reads. See ADR-0007.

## Non-goals (explicit)

- No Go runtime semantics (goroutines, `reflect`, `go/types` analysis).
- No 1:1 module mapping with Wails internals (`menumanager`, `winres`,
  `webview2runtime`, …). Those problems are solved the V way or dropped.
- No Windows/macOS webview until the Linux vertical slice (Phases 1–4)
  is stable — see ADR-0002.
