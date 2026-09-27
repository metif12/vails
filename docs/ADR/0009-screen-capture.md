# ADR-0009 — Screen capture: getDisplayMedia now, native service later

Date: 2026-09-27. Status: proposed (plan-only, no code, not accepted).

## Context

Electron ships `desktopCapturer` (main-process source enumeration +
`getUserMedia(chromeMediaSource)`) because it bundles Chromium. Vails,
like Tauri, hosts the OS webview (`webview/webview_linux.c.v` =
WebKitGTK, `webview/webview_windows.c.v` = Edge/WebView2 via webview
lib 0.12) with zero capture code wired today. There is no out-of-box
source list; each OS needs its own permission + capture plumbing
(ADR-0002 risk applies: no COM projection for Windows, Portal/PipeWire
on Linux, ScreenCaptureKit on macOS in Phase 6).

## Decision A (now): browser picker passthrough, docs only

- No native code, no `bridge`/`webview` changes. Frontend calls
  `navigator.mediaDevices.getDisplayMedia(...)` directly; Vails neither
  blocks nor wraps it. Source picking stays with the browser-native
  picker, so there is no programmatic enumeration (that is B).
- Manual verification only (unit tests never open windows): load a
  `getDisplayMedia` snippet in `examples/hello` via DevTools/eval on
  each backend and confirm the picker appears and a stream starts.
  Record results in `tests/e2e_linux/README.md` /
  `tests/e2e_windows/README.md` when run.
- Known limits (document, do not fix here): picker UX differs per
  backend; Linux may need the XDG Desktop Portal permission dialog;
  headless/Xvfb runs cannot capture a real screen; CSP work (T7) must
  not block `getDisplayMedia`.

## Decision B (Phase 5+ service issue, not this ADR)

- New `services/screencapture.v` following the `services/clipboard.v`
  seam: pure-V API first + `error('not implemented on …')` stub, one
  PR per OS behind the `webview/` facade (AGENTS.md §3-4).
- Capability-gated (ADR-0007) commands, e.g.
  `screencapture.get_sources` / `screencapture.request_capture`,
  exposed via `bridge.Router.call_from` (`forbidden:` on deny);
  per-service JS snippet + `.d.ts` via the T5 plugin manifest;
  streaming/progress via T3 channels (`events.to_js` eval, handlers
  stay fast/non-blocking per ADR-0007 threading note).
- Backends: Linux first (XDG Desktop Portal Screencast + PipeWire),
  Windows in Phase 6 (GraphicsCapture via a C wrapper — same COM-gap
  risk as ADR-0002), macOS with Phase 6 (ScreenCaptureKit).
- Acceptance for B: service file + `_test.v` + ADR follow-up +
  capability matrix test + Linux manual test (Phase 5 rule).

## Non-goals

- No 1:1 `desktopCapturer` port; no bundled Chromium; no background
  recording without an explicit capability grant.

## Consequences

- A costs a docs line per e2e README when manually verified; zero
  effect on `v test .`.
- B extends `vails.json` capabilities and the T5 manifest schema
  additively (ADR-0008 rule); `application/` + `bridge/` API freeze
  (Phase 6) must include the final method names.
