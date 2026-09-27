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
- **Managed state (`state.Store`, T4)**: Tauri-`.manage()` equivalent —
  one store per `application.App` (`set_state`/`get_state`/`has_state`
  forwarders). Values are raw JSON strings; typed access is hand-written
  (`set_string`/`get_string` pattern, `$for` only if proven sufficient).
  Same threading rule as handlers (main thread; `spawn` workers reply as
  events). See ADR-0011.
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
  (UTF-8 C ABI, NUL-separated paths; V has no COM projection). Linux: an
  explicit stub until Phase 5b (the toolchain now exists; the GTK chooser is
  the last S1 item that needs a human answering a modal window). See
  ADR-0014/0015.
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
- **Notification service (`services/notification`)**: a short native message
  the OS shows without stealing focus (`notification.notify` → `string`,
  `notification.is_supported` → `boolean`). Windows: a tray balloon
  (`Shell_NotifyIconW` + `NIF_INFO`, no COM) whose icon a V worker removes
  again after the clamped timeout (`clamp_timeout`, 1.5–60 s), because a tray
  icon left behind outlives the balloon. Every other platform is an explicit
  stub, and `is_supported` answers `false` there, so a frontend can ask
  instead of firing a notification that quietly does nothing. The validated
  byte bound (512/128) is deliberately wider than the shell's fixed fields
  (256/64 UTF-16 units): a long body is shown clipped, not refused. A WinRT
  toast is the recorded follow-up (ADR-0015).
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
