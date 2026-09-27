# ADR-0008 — `vails.json` project config (T6)

Date: 2026-09-26. Status: accepted (T6 done, pure-V, green on Windows).

## Context

Window geometry, capability grants and asset roots lived in three
different places: hardcoded `webview.run(...)` args in each app,
`Registry.grant` calls in V code, and tribal knowledge (Windows DLL
side-by-side from Phase 1). T2–T5 all need one persistent source of
truth for this data (Tauri `tauri.conf.json` plays that role there).

## Decisions

- New `config/` module (pure-V, OS-agnostic, no C): `VailsConfig{name,
  version, asset_root, windows []WindowConfig, capabilities
  []CapabilitySpec, bundle BundleConfig}` + `load/load_text/validate/
  window/to_registry/encode/default_config`.
- Decode with `json2` (stdlib `json` is deprecated in V 0.5.x), reusing
  the repo's existing JSON style (`bridge` already uses `json2`).
  Missing keys keep declared defaults (`asset_root: 'frontend'`,
  `windows_dll_side_by_side: true`) — verified by test.
- `CapabilitySpec` is a separate decode struct, not `Capability`
  itself: `json` decoding needs `pub mut` fields while `Capability`
  is intentionally immutable. `to_registry()` converts (clone per
  field) into `capabilities.Registry` for `Router.call_from`.
- `config` never imports `webview`: `WindowConfig` maps 1:1 onto
  `webview.Config` but the caller builds it, keeping `config` free of
  the C-toolchain coupling. `application/`, `bridge/`, `events/`
  untouched per the facade rule.
- Validation is fail-fast (`doctor`/`run`/`build` reject bad configs
  with `vails.json: …` messages); empty `commands` in a capability is
  an error (grants nothing — almost certainly a typo), matching the
  repo's fail-fast ethos while T1 runtime semantics stay deny-default.
- CLI `run`/`build` are config-validating dry-runs (summary +
  Phase 3/7 pointer); real dev-server run is Phase 3, packaging is
  Phase 7. `doctor` validates `./vails.json` when present (missing is
  informational, not an error). `init` scaffolds `vails.json` from
  `default_config` (empty capabilities = deny by default).
- `examples/hello` reads `vails.json` for label/title/size (fallback
  to defaults when missing, fail-fast when invalid); the router stays
  on the unchecked path — enforcement is T2.

## Consequences

- T2 builds on `to_registry()`; T5 plugin manifests and Phase 4 CLI
  extend this file's schema; Phase 3 dev mode reads `asset_root`.
- Schema changes are additive: new optional keys must carry defaults
  so old `vails.json` files keep validating.
