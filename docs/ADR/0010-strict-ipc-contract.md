# ADR-0010 — Stricter IPC contract (T2)

Date: 2026-09-27. Status: accepted (T2 done, pure-V, green on Windows).

## Context

After T1 every JS→V call expected a reply: `Router.call` served any
registered method, `params` was an unchecked raw string, and error values
were ad-hoc (`boom`, `unknown method`, …). Tauri instead separates
`invoke` (request/response) from events (one-way, no reply) and rejects
with standard `Result` errors the frontend can match on.

## Decisions

- Command vs event split in `bridge` (no native changes):
  - command: `call_json(window_label, id, method, params, reg)` —
    capability gate first (deny returns `forbidden: …`, never `unknown
    method`, so names do not leak), then params-shape validation, then
    the handler. `call_from` delegates to it; `call` stays as the
    unchecked, unvalidated compat path.
  - event: `notify(window_label, event, data, reg)` — gate only, returns
    `!void` (no reply exists). Delivery to V-side subscribers is the
    app's job: `n := decode_notify(…); r.notify(…)!; bus.emit(n.event,
    n.data)`. Event names are checked against the same capability
    allowlist as commands (v1 simplification; per-event scopes arrive
    with T5 plugin manifests).
- Params validation: `register_validated(name, validate, handler)` +
  `ParamsValidator = fn (params string) !void`. Rejection becomes
  `bad params: …`. Shared helper `validate_empty` for no-arg commands
  (accepts `''`, `null`, `""`).
- Standard err values (prefixes are wire contract — JS matches on them):
  `unknown method:`, `forbidden:`, `bad request:`, `bad params:`,
  `bad event:`. Helpers `err_unknown/err_forbidden/err_bad_request/
  err_bad_params/err_bad_event` build them; `__resolve` turns them into
  promise rejections.
- Single native entry point: `handle_envelope_from(raw, label, reg)`
  sniffs the body (`method` set → command, `event` set → one-way,
  method wins when both are set, neither → `bad request:`) and returns
  Response JSON for commands, minimal Ack JSON (`{"ok":true}` /
  `{"err":"…"}`) for events. Windows `bind_cb` now calls it with the
  window label + `Config.registry`; the JS `emit()` helper ignores the
  ack by design. Linux enforcement lands with its transport wiring.
- `runtime_js`/`runtime_js_bound` gain `vails.emit(name, data)` alongside
  `call`/`onEvent`. `Config` gains `registry` (empty = deny all).
  `examples/hello` wires `vails.json` grants via `to_registry()` and
  validates `ping` with `validate_empty`.
- Threading rule (binding): handlers run on the webview main thread →
  must be fast/non-blocking; heavy work via `spawn`, result delivered
  back as an event (`events.to_js` snippet evaluated on the main
  thread). Documented here and on `bridge.Router`, not enforced by code.

## Consequences

- T3 channels build on the event path (repeated `to_js` pushes); T4
  state accessors are called from validated command handlers; T5
  services each declare their commands/events against this contract.
- Error-prefix renames are breaking changes: they require a contract
  bump note in the ADR, not a silent edit.
