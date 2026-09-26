# ROADMAP.md — from MVP to complete

 checkboxes = state. Move exactly one phase at a time (see AGENTS.md §3).

- [x] **Phase 0 — Scaffold** (this repo): `v.mod`, module skeleton,
  `AGENTS.md`/`CONTEXT.md`/`ROADMAP.md`, ADRs, `examples/hello`,
  `v test .` green on Windows.
- [x] **Phase 1 — window PoC (both backends, verified with screenshots)**:
  Linux `webview_linux.c.v` (GTK → window → `WebKitWebView` → `load_html` →
  `gtk_main`) renders under WSL/xvfb (`tests/e2e_linux/run_headless.sh`).
  Windows `webview_windows.c.v` (webview lib 0.12, Edge) opens with title.
  Findings recorded in ADR-0005 (`-gc none` on Linux, Wayland hijack,
  DLL side-by-side on Windows).
- [x] **Phase 2 — JS↔V bridge (Windows side verified E2E)**:
  pure-V seam (`handle_message`, `runtime_js`, `runtime_js_bound`,
  `resolve_js`, `to_js`, `jsesc`) + Windows transport (`webview_bind` →
  `bind_cb` → `webview_return`). Button → `pong` proven, proof in
  `tests/e2e_windows/pong.png`. Transport decided in ADR-0004/0005.
  Remaining: Linux C transport wiring (message handler + run_javascript)
  + V→JS event delivery via `webview_eval`.
- [ ] **Phase 3 — Assets + dev experience**: `assets.Server` prod
  (`$embed_file`) vs dev (`veb` + browser livereload via
  `v -d veb_livereload watch run`); `vails run` uses dev mode.
  This is where Vails beats Wails (sub-second rebuilds).
- [ ] **Phase 4 — CLI**: `vails init/run/build/doctor` + `hello`
  template; `doctor` checks `pkg-config`, webkitgtk, `v --version`.
- [ ] **Phase 5 — Services**: `dialog` (file open/save), `menu`,
  `clipboard`, `keychain` (cf. `v3/pkg/services`, `v3/internal/dbus`).
  One PR per service + Linux manual test.
- [ ] **Phase 6 — Cross-platform**: Windows first (WebView2/COM behind
  a C wrapper — V has no COM projection; highest risk), then macOS
  (WKWebView/ObjC). Freeze `application/` + `bridge/` API before starting.
- [ ] **Phase 7 — Hardening**: `generator` auto-specs via `$for`
  compile-time reflection, app icons/packaging (cf. `v3/internal/packager`,
  `nfpm`), `doctor-ng` equivalent, docs site.

## Tauri-inspired track (approved; runs after Phase 2, interleaved below)

Source: tauri-apps/tauri v2 (111k stars) — same problem space (native
backend + web frontend, OS webview, no bundling). Adopted: capabilities
model (full), low-cost/high-impact ideas only. Deferred to post-desktop:
signed updater, sidecar binaries, mobile, store/SQL/Stronghold, WebDriver
engine, iframe isolation pattern.

- [x] **T1 — Capabilities (first; everything else builds on it)** (done 2026-09-26, ADR-0007):
  new `capabilities/` module: `Capability{id, windows []string,
  commands []string, asset_roots []string, platforms []string}` +
  `Registry.is_allowed(window_label, command)`. `webview.Config` gains a
  `label` (Tauri-style, distinct from title); `Router.call` becomes
  `call_from(window_label, …)` returning `forbidden: …` (not
  `unknown method`, to avoid leaking). `assets.Server` gains an allowlist
  of roots (Tauri asset-protocol scope; today only `..` is rejected).
  Tests: allow/deny matrix + platform filtering, pure-V, green on both
  OSes. Docs: ADR-0006 + CONTEXT.md section.
- [ ] **T2 — Stricter IPC contract (after T1)**: split command
  (request/response, cf. Tauri `invoke`) from event (one-way, no reply).
  `bridge` gains `call_json` validating `params` shape with standard
  `err` values (Tauri `Result` → promise reject). Document threading rule:
  handlers run on the webview main thread → must be fast/non-blocking;
  heavy work via `spawn` + result delivered as event.
- [ ] **T3 — Light channels for streaming (after T2)**: Tauri
  `ipc::Channel` equivalent for progress/streaming: channel id (`ch_<n>`),
  repeated pushes via `to_js`-style eval, explicit close. No native
  changes — eval only. Contract: `__emit`-compatible, documented in
  e2e READMEs.
- [ ] **T4 — Managed state (after T2)**: Tauri `.manage()` equivalent:
  new `state/` module, one store per App, read/write from inside handlers.
  V1 with `json` + hand-written typed accessors (V generics are limited);
  `$for` auto-derivation only if proven sufficient (else stays manual,
  same rule as generator Phase 7).
- [ ] **T5 — Services as plugins (aligns with Phase 5)**: each service
  (`dialog`, `notification`, scoped `fs`, …) gets a small manifest —
  name, version, required capabilities, its own JS snippet (no monolithic
  runtime). `generator` emits `.d.ts` from the manifest. Order:
  `dialog` → `notification` → scoped `fs` (riskiest, locked by
  capabilities) → rest.
- [ ] **T6 — `vails.json` config (aligns with Phase 4 CLI)**: minimal
  Tauri-`tauri.conf.json` equivalent: windows list (label/title/size),
  enabled capabilities, asset roots, bundle settings (icon, name,
  Windows side-by-side DLLs — the pain felt in Phase 1). CLI `run`/`build`
  reads it; `doctor` validates it. Hand-written JSON schema + tests.
- [ ] **T7 — Secure frontend defaults (with T1, half a day)**: default
  injected `<meta CSP>` (Tauri CSP); hello's preview fallback documented
  and tested as the secure mode (no API outside a Vails window).

Execution order: T1 → T6 → T2 → T3 → T4 → T5. Estimate: ~3 focused weeks.
Each item: code + tests on both OSes + short ADR + ROADMAP checkbox.

## Mobile track (both platforms, plan-only until SDK/macOS exist; ADR-0006)

Model: Wails v3 (same desktop code + `$if android/ios` platform files;
in-process assets; fullscreen ⇒ geometry/menus/tray are intentional
no-ops; one `mobile/` entry + platform-neutral `events.Common.*`).
vab is a helper (NDK flags, keystore/AAB know-how), NOT a dependency:
Gradle scaffold à la Wails.

- [ ] **M0 — Pure-V prep (zero prerequisites, can start now)**: `mobile/`
  module with desktop no-op stubs; `capabilities` gains `platforms`
  (from T1); `events.Common.*` contract (battery/network/theme/low-memory)
  that future backends will feed. Tests: pure-V, green on Windows/WSL.
- [ ] **M1 — Android PoC (needs SDK/NDK/JDK on this Windows machine)**:
  Gradle template (`MainActivity` + WebView + asset loader +
  `VailsBridge`/`VailsJSBridge`); V as shared lib with JNI exports —
  FIRST SPIKE validates `@[export]` + shared-lib loading (unproven in V;
  gates all of M1). Transports reuse the current seam
  (`Router.handle_message` for the array-wrapped JS→V shape from ADR-0005,
  `evaluateJavascript` for V→JS). Done when hello+ping runs on the
  emulator (`chrome://inspect`).
- [ ] **M2 — Android services**: toast → vibrate → clipboard → share-sheet
  → device-info → system events into `Common.*`; one capability each (T1);
  manifest permissions documented per service.
- [ ] **M3 — iOS scaffold (no verify here; needs a Mac)**: Xcode template
  (`.app`, `Info.plist`, `main.m` with `UIApplicationMain` + `WKWebView` +
  `wails://` scheme + `messageHandlers` — the ADR-0004 raw path),
  `application.IOS*` mirroring Android, codesign/devicectl scripts.
  Output: code ready to test on a Mac, not tested code.
- [ ] **M4 — CLI integration**: `vails run/build --target android|ios`,
  `build/android` + `build/ios` templates, `doctor` checks (sdkmanager/NDK/
  Xcode), `ANDROID_KEYSTORE_*` vars à la Wails.

Risks: V-JNI unproven (M1 spike first); M3 untestable locally; heavy
environment (several GB SDK + emulator) — hence M0 decoupled.

## Out of scope

Porting Wails' Go toolchain helpers (`menumanager`, `winres`, `icns`,
`go-git`-based templates, `staticanalysis` on `x/tools`): replaced by V
idioms or dropped — never translated.
