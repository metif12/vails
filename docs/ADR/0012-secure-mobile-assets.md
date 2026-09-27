# ADR-0012 — Secure defaults (T7) + mobile prep (M0) + assets prod seam (P3-pure)

Date: 2026-09-27. Status: accepted (pure-V, green on Windows).

## Context

Three half-day items shared one trait: pure-V, no native changes, green
on Windows without gcc/pkg-config. T7 closes the T1 security story
(default-deny dispatch deserves a default-locked-down document);
M0 unblocks the mobile track without waiting for SDK/NDK; the Phase 3
pure-V slice wires capabilities into asset serving and fixes the
prod/dev seam before the `veb` dev server lands.

## Decisions

- T7 in `webview/secure.v`: `default_csp()` (Tauri-CSP-inspired:
  `default-src 'self'`, `object-src 'none'`, `frame-ancestors 'none'`,
  `media-src 'self' blob:` so ADR-0009 streams stay playable),
  `csp_meta()` renderer, `inject_csp(html)` (app override wins: any
  document already carrying a `Content-Security-Policy` marker is left
  untouched; insertion after `<head>`, else `<html…>`, else prepend;
  idempotent). Inline scripts AND styles stay allowed: hello keeps its
  UI in one file, so strict `script-src 'self'` would break it —
  hardening path (external JS + dropping `'unsafe-inline'`) is
  documented, not default. `examples/hello` ships the policy verbatim;
  `webview/secure_test.v` reads the hello file and fails when the two
  drift. Hello's preview fallback (opened outside a Vails window) is the
  documented secure mode: same policy, no API.
- M0: `mobile/mobile.v` (`is_mobile()` via `$if android || ios`,
  `apply_geometry` — intentional desktop no-op after size validation,
  explicit `not implemented (M1/M3)` on mobile targets) and
  `events/common.v` (`common:battery/network/theme/low-memory` + JSON
  payload shapes). `capabilities.platforms` (T1) needed no changes.
  M1's V-JNI spike still gates all of M1; M3 stays untestable locally.
- P3-pure in `assets/`: `Server.resolve_for` / `Bundle.resolve_for`
  (registry built from `vails.json` scopes reads; no grant for the
  window = deny, same secure-by-default rule as an empty bridge
  Registry) over a shared `check_path` (traversal + allowlist).
  `Bundle` (in-memory bytes keyed by forward-slash relative path) is
  the prod side filled with `$embed_file` by the app; `Server` stays
  the dev side. Same checks both sides. The `veb` dev server with
  livereload + `vails run --dev` stays for the rest of Phase 3.

## Consequences

- CSP text changes are app-visible (hello meta + `default_csp()` must
  move together — enforced by test).
- The CEF decision ADR planned as 0011 shifts to 0013 (this batch took
  0011–0012); ROADMAP references updated.
- Remaining Phase 3: `veb` server + livereload + `vails run` dev mode;
  then Phase 4 CLI, then T5.
