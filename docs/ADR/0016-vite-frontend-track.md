# ADR-0016 — Frontend track: Vite + web frameworks with type-safe bindings and JS/V helpers

Date: 2026-09-27. Status: planned (ROADMAP track only; no code yet).

## Context

`examples/hello` proves the bridge but its frontend is a single hand-written
`index.html`: every call is `window.vails.call("counter_inc", "")` plus a
manual `parseInt`, every event is an untyped `onEvent("ready", cb)`, and every
handler in `main.v` repeats `register` + `validate_empty` + manual
`json.decode/encode`. `generator/generate_dts` only emits what a developer
hand-writes into a `MethodSpec`, and `vails dts` (T5, ADR-0014) generates from
service manifests — there is no path from an app's own V handlers to a typed
frontend, and no Vite/framework story at all (`run`/`build` are Vite-unaware,
`VailsConfig` has no `frontend` section).

The request: build frontends with Vite + a web framework (Vue first, then
React/Svelte/Solid/vanilla-ts), keep it type-safe (TS generated from V code
and injected into the frontend), and add JS + V helpers that delete the
repetition above.

## Decisions (planned, to be confirmed in F0)

- **The wire protocol does not change.** T2 (`call_json`/`notify`, standard
  `err` prefixes, single `handle_envelope_from` entry) and T3
  (`ChannelHub` ids, `__emit`-compatible delivery) stay as-is. The track
  adds a typed layer around them, so existing backends, capabilities, and
  the Linux/Windows transports keep working untouched.
- **V structs are the source of truth.** Each command gets `XxxParams` /
  `XxxResult` structs; `bind_typed[T, P]` registers the handler and captures
  the type metadata in one call. The F1 generator starts semi-automatic
  (explicit specs + `v_to_ts` table, `unknown` fallback with a
  `// TODO refine` comment); full `$for` auto-derivation stays Phase 7 work
  and must prove itself before replacing the explicit path.
- **One generator, one output pair.** `generator/bindings.v` emits
  `vails-bindings.d.ts` (types) + `vails-client.ts` (typed `api.*`,
  `onEvent<T>`, `useChannel<T>`, `callOrPreview<T>`) from the same specs
  `vails dts` reads, so manifests (services) and handler specs (app code)
  cannot produce divergent types. Generated files are never hand-edited;
  `vails gen-bindings` owns them and `doctor` warns when they are stale.
- **Framework-agnostic, templates ordered.** Vite is the only build
  assumption; frameworks are `init --template` variants. Order:
  `vite-vanilla-ts` first (proves the loop with no framework magic), then
  `vite-vue` (`useVails` composable), then React/Svelte on demand.
- **Dev/prod split follows the existing seams.** Dev: `vails run --dev`
  spawns `npm run dev` and points `webview.Config.url` at it (dev-server
  module from ADR-0013 stays untouched; only a `localhost:5173` + `ws:`
  CSP allowlist is added, app override still wins). Prod: `vails build`
  runs `npm run build` and embeds `dist/` through the existing
  `assets.Bundle` path. `FrontendConfig` is purely additive with safe
  defaults so old `vails.json` files keep validating.
- **Helpers live where they are testable.** V helpers in
  `bridge/helpers.v` (pure-V, Windows-green without gcc); JS helpers only
  in the generated client (snapshot-tested, `tsc --noEmit` in CI when node
  exists, graceful skip when it does not).

## Order and scope

F0 (schema) → F1 (generator) → F2 (helpers + hello re-registration) →
F3 (config + CLI) → F4 (typed events/channels + `examples/hello-vite`).
Starts after Phase 5 S1 wave 3 + Phase 5b, before Phase 7 (F1 feeds the
`$for` auto-spec work). No F-item starts while Phase 5 is current
(AGENTS.md §3). Each item: code + tests on both OSes + ROADMAP checkbox.

## Risks

- V 0.5 reflection may not carry F1 all the way — hence the explicit-spec
  first step and the `unknown` fallback.
- Windows CI without node/gcc must stay green — hence pure-V tests plus a
  node-dependent check that skips gracefully.
- Scope creep into framework-specific state management (Vuex/Pinia/Redux)
  — explicitly out; the track ships calling conventions, not app
  architecture.
