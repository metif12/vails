# ADR-0004 — WebKit script-message transport + run_javascript replies

Date: 2026-09-26. Status: accepted (pure-V seam implemented, C wiring pending).

## Decision

- JS→V: `webkit_user_content_manager_register_script_message_handler(mgr, 'vails')`;
  frontend posts via `window.webkit.messageHandlers.vails.postMessage(json)`.
  The C `script-message-received::vails` callback forwards the body string to
  `bridge.Router.handle_message` and evaluates the returned JSON with
  `webkit_web_view_run_javascript`.
- V→JS: snippets from `bridge.resolve_js` (call results → `__resolve`) and
  `events.to_js` (events → `__emit`), evaluated with `run_javascript`.
- Rejected: custom URI scheme (`vails://call/…`) — awkward for async
  request/response pairing and harder to debug than message handlers.

## Constraints recorded for the Linux session

- Use `run_javascript` (4.0/4.1) — NOT `evaluate_javascript` (4.1-only) —
  so both webkit2gtk generations build.
- `gboolean` is a 4-byte C int: declare such returns as V `int`, never `bool`.
- Receiving needs `WebKitJavascriptResult` → `JSCValue` → C string
  extraction in the C callback; signature must be verified against installed
  headers (`libwebkit2gtk-4.1-dev`) — the highest-risk line of Phase 2.
- `bridge.runtime_js()` must be injected at document start
  (user script, `webkit_user_content_manager_add_script` or equivalent).
