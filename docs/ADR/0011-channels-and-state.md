# ADR-0011 — Light channels (T3) + managed state (T4)

Date: 2026-09-27. Status: accepted (T3+T4 done, pure-V, green on Windows).

## Context

After T2 every V→JS delivery is a single `__emit`/`__resolve` eval with
no streaming story (progress bars, log tails, downloads need repeated
pushes), and handlers keep state in ad-hoc closures with no shared,
per-app place for it. Tauri answers with `ipc::Channel` (a channel id
the frontend subscribes to, repeated pushes, explicit close) and
`.manage()` (one typed store per app reachable from handlers).

## Decisions

- T3 channels in `bridge/channels.v` (no native changes — eval only):
  - `ChannelHub.open(event) → Channel{id: 'ch_<n>', event}` mints ids
    without globals (AGENTS.md: no globals; one hub per window/router).
  - `Channel.push_js(data)` builds the `events.to_js(id, data)` snippet
    (delivery on the channel id, so parallel streams never interleave);
    pushing after close is an error (fail fast, no silent loss).
  - `Channel.close_js()` emits the terminal `__emit('<id>:close', '')`
    marker and is idempotent (deferred cleanups stay safe).
  - Frontend subscribes with the existing
    `window.vails.onEvent(channel_id, cb)` — fully `__emit`-compatible,
    no runtime changes.
- T4 state in `state/store.v` (Tauri `.manage()` equivalent):
  - `Store` maps keys to raw JSON strings (no reflection, no codegen);
    `set`/`get`/`remove`/`has`/`len`/`keys` plus `set_string`/`get_string`
    as the hand-written typed-accessor pattern (V generics are limited;
    `$for` auto-derivation only if proven sufficient — same rule as the
    generator in Phase 7).
  - One store per `application.App` (`set_state`/`get_state`/`has_state`
    forwarders); handlers capture `&app`. Threading follows ADR-0010:
    handlers run on the webview main thread, so same-thread store access
    needs no locking; `spawn` workers deliver results as events instead
    of touching the store.
- Threading note for channels: push/close snippets are evaluated on the
  webview main thread like any `to_js` eval; handlers stay fast and
  non-blocking per ADR-0010.

## Consequences

- E2 pomodoro can tick over a channel; E1 todo persists via the store
  (later via `store` S2 service); T5 plugin manifests declare per-service
  channels/state keys against this contract.
- Channel close markers (`<id>:close`) are wire contract — renames need
  an ADR bump note, same rule as T2 error prefixes.
