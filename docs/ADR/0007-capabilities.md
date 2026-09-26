# ADR-0007 — Capabilities (Tauri-style allowlist, T1)

Date: 2026-09-26. Status: accepted (T1 done, pure-V, green on Windows).

## Context

Tauri v2 scopes every IPC call and asset read through capabilities:
which window may call which command on which OS, and which asset roots
are servable. Vails Phase 2 had no such gate (`Router.call` served every
registered method to every window; `assets.Server` rejected only `..`).

## Decisions

- New `capabilities/` module: `Capability{id, windows, commands,
  asset_roots, platforms}` + `Registry.grant/is_allowed/is_allowed_on`.
  Empty `windows`/`platforms` = all; empty `commands` = none (secure by
  default); empty `Registry` denies everything. `is_allowed` delegates to
  `is_allowed_on(label, cmd, os.user_os())` so platform filtering is
  unit-testable with an injected OS on any machine.
- `webview.Config` gains `label` (default `'main'`), Tauri-style and
  distinct from `title`: title is shown, label is the security identity.
  No native changes in T1 — label wiring to the C backends comes later.
- `bridge.Router.call` stays as the unchecked compat path;
  `call_from(window_label, …, reg)` is the checked path. Denied calls
  return `forbidden: <method> …` — never `unknown method` — so ungranted
  method names do not leak. Same split for `handle_message` /
  `handle_message_from`.
- `assets.Server` gains `allowed_roots []string`: subpath prefixes
  relative to `root` (e.g. `['frontend']`). Empty = legacy behavior
  (everything under `root`). Non-empty scopes reads to those subtrees
  (separator-boundary match, `..` still rejected first). Tests use an
  absolute `testdata` dir via `@FILE` so they never depend on the
  runner's working directory.
- `examples/hello` loads `frontend/index.html` from disk (single source
  of truth) instead of an inline copy; `Config{label: 'main'}` is passed.

## Threading note (for T2)

Handlers run on the webview main thread → must stay fast/non-blocking;
heavy work goes through `spawn` with the result delivered as an event.

## Consequences

- T2 (strict IPC contract) builds on `call_from`; T6 (`vails.json`)
  persists the capability set; M0 reuses `platforms` + `asset_roots`.
- `bridge` now depends on `capabilities` (one direction only);
  `application/`, `events/` untouched per the facade rule.
