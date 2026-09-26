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
- **Bridge (`bridge.Router`)**: maps a JS-initiated call to a V function.
  Wire format is JSON: `Request{id, method, params}` → `Response{id, result,
  err}` where `params`/`result` are raw JSON strings. No reflection:
  methods are registered explicitly via `register(name, handler)`.
  `handle_message(raw)` is the native callback entry point (always returns
  JSON, never errors). It unwraps the webview library's one-element array
  wrapping (`unwrap_args`) and accepts a bare object (raw WebKitGTK path).
  `runtime_js()` is the injected `window.vails` runtime
  (`call`/`onEvent` + internal `__resolve`/`__emit`); `runtime_js_bound(name)`
  is the same runtime for the webview-library backend where the bound fn
  resolves with PARSED JSON (normalized before `__resolve`). `resolve_js(res)`
  builds the reply snippet. See ADR-0004/0005.
- **Event (`events.Bus`)**: fire-and-forget pub/sub both directions.
  `on(event, handler)` / `emit(event, data) returns handler-count`.
  Ordering guarantee: handlers run in registration order, synchronously
  (async delivery is a Phase 5+ concern).
  `to_js(event, data)` builds the `__emit` evaluate snippet for the JS side.
- **JS escaping (`jsesc.escape`)**: single-quote JS-literal escaping
  (`'`, `\`, newlines, `<`→`\x3c`); shared by `resolve_js` and `to_js`.
- **Asset (`assets.Server`)**: read-only file provider for the frontend.
  `content_type(path)` maps extensions to MIME. Prod = embedded bytes,
  dev = directory served through `veb` with livereload (Phase 3).
- **Service**: a named native capability (`clipboard`, `dialog`, …)
  registered on the `App` by string name. Implementations live in
  `services/` and may be OS-gated.
- **Binding spec (`generator.MethodSpec`)**: static description of one
  bound method used to emit TypeScript declarations (`generate_dts`).
  Hand-written specs for now; compile-time auto-derivation is Phase 5+.
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
