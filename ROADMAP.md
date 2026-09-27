# ROADMAP.md — from MVP to complete

 checkboxes = state. Move exactly one phase at a time (see AGENTS.md §3).

Current position (2026-09-27): Phases 0–4 + T1/T6/T2/T3/T4/T7/M0 done.
Next is Phase 5 services (S1 `dialog` first), then T5 plugin manifests.
Phase 6–7, the M1-M4, C- and E-tracks below are planned, not started.

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
- [x] **Phase 3 — Assets + dev experience** (done 2026-09-27, ADR-0013):
  `assets.Server` prod (`Bundle`, filled with `$embed_file` by the app)
  vs dev (`dev.DevServer`: loopback stdlib-`net.http` server over the
  project dir, capability-scoped via `resolve_for`, livereload poller
  injected into HTML; stdlib chosen over `veb` so Windows tests stay
  gcc-free — veb pulls fasthttp C). `vails run` opens the first window
  at the dev URL (`--serve-only` for headless). This is where Vails
  beats Wails (sub-second rebuilds via `v`).
- [x] **Phase 4 — CLI** (done 2026-09-27, ADR-0013): `vails
  init/run/build/doctor` + scaffold template (`main.v` + `vails.json`
  with frontend grant + `frontend/` with ping demo); `doctor` checks
  `v --version`, toolchain, `vails.json`, `asset_root`; `build` sets
  `VMODULES` to the vails root (`VAILS_HOME` or walk-up).
- [ ] **Phase 5 — Services** (full catalog below; one PR per service +
  Linux manual test; each: `services/<name>.v` seam + `_test.v` +
  capability + ADR line; T5 plugin manifests align here):
  - S1 core (desktop first): `dialog` → `notification` → `menu` →
    `tray` (StatusNotifier/AppIndicator — separate from `menu`) →
    `clipboard` (full: read/write + monitor event) → `opener`
    (open file/URL in external app) → `os-info` → `window-state` /
    `positioner` (persist size/position). Cf. `v3/pkg/services`.
  - S2 system (after S1): `single-instance` → `autostart` →
    `global-shortcut` (risk: Wayland limits) → `keychain`
    (cf. `v3/internal/keychain`) → `store` (persisted KV) →
    `screencapture` (per ADR-0009 B) → `scoped fs` (last, riskiest,
    capability-locked).
  - S3 mobile (feeds M2): `haptics` (= `vibrate`), `biometric`,
    `geolocation`; `barcode-scanner` / `nfc` optional-late.
  - Out of scope (post-desktop, unchanged): signed `updater`,
    `sidecar` binaries, unrestricted `shell` / `process`, `sql` /
    `stronghold`, WebDriver engine, BT/serial/printer (community-level).
- [ ] **Phase 6 — Cross-platform**: Windows first (WebView2/COM behind
  a C wrapper — V has no COM projection; highest risk), then macOS
  (WKWebView/ObjC). Freeze `application/` + `bridge/` API before starting.
- [ ] **Phase 7 — Hardening**: `generator` auto-specs via `$for`
  compile-time reflection, app icons/packaging (cf. `v3/internal/packager`,
  `nfpm`), `doctor-ng` equivalent, docs site (plan parked in
  `docs/site/PLAN.md`: English LTR, static export to GitHub Pages via
  `veb` SSG; build starts only after all phases/tracks are done).

## Tauri-inspired track (approved; runs after Phase 2, interleaved below)

Source: tauri-apps/tauri v2 (111k stars) — same problem space (native
backend + web frontend, OS webview, no bundling). Adopted: capabilities
model (full), low-cost/high-impact ideas only. Deferred to post-desktop:
signed updater, sidecar binaries, SQL/Stronghold, WebDriver
engine, iframe isolation pattern. (`store` lives in Phase 5 S2, mobile
has its own track below.)

- [x] **T1 — Capabilities (first; everything else builds on it)** (done 2026-09-26, ADR-0007):
  new `capabilities/` module: `Capability{id, windows []string,
  commands []string, asset_roots []string, platforms []string}` +
  `Registry.is_allowed(window_label, command)`. `webview.Config` gains a
  `label` (Tauri-style, distinct from title); `Router.call` becomes
  `call_from(window_label, …)` returning `forbidden: …` (not
  `unknown method`, to avoid leaking). `assets.Server` gains an allowlist
  of roots (Tauri asset-protocol scope; today only `..` is rejected).
  Tests: allow/deny matrix + platform filtering, pure-V, green on both
  OSes. Docs: ADR-0007 + CONTEXT.md section.
- [x] **T2 — Stricter IPC contract (after T1)** (done 2026-09-27, ADR-0010):
  command (`call_json`: gate → params validation → handler) split from
  event (`notify`: gate only, no reply; app forwards to its own
  `events.Bus`). Standard `err` prefixes (`unknown method:`,
  `forbidden:`, `bad request:`, `bad params:`, `bad event:` → promise
  reject via `__resolve`); `register_validated` + `validate_empty`;
  single native entry `handle_envelope_from` (Windows `bind_cb` calls it
  with label + `Config.registry`); `vails.emit` in both runtimes;
  `examples/hello` enforces `vails.json` grants. Threading rule
  documented: handlers on webview main thread → fast/non-blocking,
  heavy work via `spawn` + result as event. Pure-V, green on Windows.
- [x] **T3 — Light channels for streaming (after T2)** (done 2026-09-27, ADR-0011):
  Tauri `ipc::Channel` equivalent: `bridge.ChannelHub.open(event)` mints
  `ch_<n>` ids (no globals), repeated pushes via `to_js`-style eval
  snippets on the channel id, idempotent `close_js` (`<id>:close`
  marker). No native changes — eval only. `__emit`-compatible (frontend
  uses existing `onEvent`), documented in e2e READMEs.
- [x] **T4 — Managed state (after T2)** (done 2026-09-27, ADR-0011):
  Tauri `.manage()` equivalent: new `state/` module (`Store`: raw JSON
  per key + hand-written `set_string`/`get_string` accessors; `$for`
  auto-derivation only if proven sufficient), one store per
  `application.App` (`set_state`/`get_state`/`has_state`, handlers
  capture `&app`). Threading follows ADR-0010 (main-thread access,
  `spawn` workers reply as events).
- [ ] **T5 — Services as plugins (aligns with Phase 5)**: each service
  gets a small manifest — name, version, required capabilities, its own
  JS snippet (no monolithic runtime). `generator` emits `.d.ts` from the
  manifest. Order follows the Phase 5 catalog: S1 core first (`dialog` →
  `notification` → …) then S2 (`single-instance` → … → scoped `fs` last,
  locked by capabilities).
- [x] **T6 — `vails.json` config (aligns with Phase 4 CLI)** (done 2026-09-26, ADR-0008):
  minimal Tauri-`tauri.conf.json` equivalent: windows list (label/title/size),
  enabled capabilities, asset roots, bundle settings (icon, name,
  Windows side-by-side DLLs — the pain felt in Phase 1). CLI `run`/`build`
  reads it; `doctor` validates it. Hand-written JSON schema + tests.
- [x] **T7 — Secure frontend defaults (with T1, half a day)** (done 2026-09-27, ADR-0012):
  default injected `<meta CSP>` (`webview.default_csp`/`csp_meta`/`inject_csp`,
  app override wins, idempotent; Tauri CSP); hello's preview fallback
  documented and tested as the secure mode (test fails when hello's meta
  drifts from `default_csp()`).

Execution order: T1 → T6 → T2 → T3 → T4 → Phase 3 → Phase 4 → T5 (all done except T5; next: Phase 5 S1 `dialog`, then T5). Estimate: ~3 focused weeks.
Each item: code + tests on both OSes + short ADR + ROADMAP checkbox.

## Mobile track (both platforms, plan-only until SDK/macOS exist; ADR-0006)

Model: Wails v3 (same desktop code + `$if android/ios` platform files;
in-process assets; fullscreen ⇒ geometry/menus/tray are intentional
no-ops; one `mobile/` entry + platform-neutral `events.Common.*`).
vab is a helper (NDK flags, keystore/AAB know-how), NOT a dependency:
Gradle scaffold à la Wails.

- [x] **M0 — Pure-V prep (zero prerequisites, can start now)** (done 2026-09-27, ADR-0012):
  `mobile/` module with desktop no-op stubs (`is_mobile` via
  `$if android || ios`, `apply_geometry` intentional desktop no-op);
  `capabilities` `platforms` already from T1 (no changes needed);
  `events.Common.*` contract (`common:battery/network/theme/low-memory`
  + JSON payload shapes) that future backends will feed. Tests: pure-V,
  green on Windows/WSL.
- [ ] **M1 — Android PoC (needs SDK/NDK/JDK on this Windows machine)**:
  Gradle template (`MainActivity` + WebView + asset loader +
  `VailsBridge`/`VailsJSBridge`); V as shared lib with JNI exports —
  FIRST SPIKE validates `@[export]` + shared-lib loading (unproven in V;
  gates all of M1). Transports reuse the current seam
  (`Router.handle_message` for the array-wrapped JS→V shape from ADR-0005,
  `evaluateJavascript` for V→JS). Done when hello+ping runs on the
  emulator (`chrome://inspect`).
- [ ] **M2 — Android services**: toast → vibrate/haptics → clipboard →
  share-sheet → device-info → biometric → geolocation → system events
  into `Common.*`; one capability each (T1); manifest permissions
  documented per service.
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

## Bundled Chromium track (opt-in CEF backend; runs last, after Phase 7 + mobile)

Goal: guaranteed rendering consistency across OSes for apps that opt in.
Stays opt-in forever: OS webview (WebView2/WebKitGTK) is the default;
`backend: 'chromium'` (per window, in `vails.json` + `webview.Config`)
selects the bundled engine. `vails build` keeps both flavors (lean + bundled,
~120–200MB extra for CEF). Electron's fork is NOT used (no stable embed API,
drags in Node — decided in the planned CEF ADR, next number 0014); CEF pinned to an upstream
Chromium gives the same rendering without the fork patches.

- [ ] **C0 — CEF spike (gates everything)**: throwaway C99 shim over CEF
  (`init`/`create_window`/`load_html`/`bind`/`eval`/`run_loop`, same pattern
  as `webview_shim.h`), window + `ping→pong` through the unchanged
  `bridge.Router` seam, DLL/`.so` + size inventory, `-gc none` check on
  Linux. Park or delete spike code; no schema changes yet.
- [ ] **C1 — Pure-V seam**: `webview.Config.backend` (`os_webview` default,
   `chromium` opt-in) + `validate()` stub error until C2; `WindowConfig.backend`
   string (`'os'` default, additive) with caller-side mapping; tests pure-V,
   green on Windows; `CONTEXT.md` line + ADR-0014 (planned CEF decision).
- [ ] **C2 — CEF backends behind the facade**: `cef_shim.h` + thin
  `webview_cef_windows.c.v` / `webview_cef_linux.c.v` (`run_chromium_*`,
  dispatched from `webview.run`); bridge protocol reused as-is
  (`handle_message`, `resolve_js`/`to_js`); missing CEF runtime fails fast
  with a `doctor` hint. Manual screenshot proofs on both OSes.
- [ ] **C3 — CLI + packaging**: `doctor` probes CEF
  (`VAILS_CEF_ROOT`/`./cef/`, version + `resources/` + subprocess helper);
  `build [--flavor lean|bundled|both]` stages CEF next to the exe;
  `BundleConfig` gains additive `chromium_version` (+ Electron-parity note);
  `init` documents the `"backend": "chromium"` sample.
- [ ] **C4 — Verify + close**: `v fmt -w .`, `v test .` green on Windows;
  hello with `"backend": "chromium"` renders + `ping→pong` on Win/Linux;
  lean vs bundled sizes recorded; e2e READMEs updated.

Order: C0 → C1 → C2 → C3 → C4, after all phases/tracks above.
Each item: code + tests on both OSes + short ADR update + checkbox.

## Examples track (vanilla, no UI framework)

Bar: system type scale, spacing rhythm, `focus-visible`,
light+dark via `prefers-color-scheme`, LTR English. Each example:
`main.v` + `vails.json` minimal grants + `frontend/` + preview fallback
(runs outside a Vails window, like hello) + e2e README lines.
No example starts before the service it needs.

- [ ] **E0 — Conventions** (once, before any app example)
- [ ] **E1 — todo** (after T4; later persisted via `store`)
- [ ] **E2 — pomodoro** (after `notification` S1; live tick via T3 channel)
- [ ] **E3 — clipboard-notes** (after full `clipboard`)
- [ ] **E4 — files-mini** (after `dialog` + `scoped fs`)
- [ ] **E5 — capture-demo** (after `screencapture`)
- [ ] **E6 — settings** (after `window-state` + `store`)

CLI templates (`init --template todo|pomodoro`) land in Phase 4/7,
not before.

## Out of scope

Porting Wails' Go toolchain helpers (`menumanager`, `winres`, `icns`,
`go-git`-based templates, `staticanalysis` on `x/tools`): replaced by V
idioms or dropped — never translated.
