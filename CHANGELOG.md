# CHANGELOG

Notable changes to Vails. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow the
CLI's own version (`vails version`, `const version` in `cli/vails.v`).

Conventions for this file:

- `## [Unreleased]` at the top holds work that is committed but not yet
  released; it is emptied into a version section at release time.
- Lines are written for a user of the framework, not for a git reader: which
  module, which command, which guarantee. A change with no user-visible
  effect (a refactor, a test) goes under **Changed** only when it changes a
  contract; otherwise it does not get a line at all.
- Every PR adds its lines to `## [Unreleased]` — see `AGENTS.md` §5.
- Architectural decisions do not live here; they live in `docs/ADR/`. An ADR
  is referenced by number in the entry that implements it.

## [Unreleased]

### Added

- Nothing yet.

## [0.2.0] - 2026-09-27

Phase 5 S1 wave 1 + the Tauri-inspired track (T1–T7). Phases 0–4 (scaffold,
window PoC on both backends, the JS↔V bridge, assets/dev server, the CLI) are
prerequisites rather than releases of their own and are folded in below.

### Added

- **Services as plugin manifests (T5, ADR-0014)**: `services/manifest.v`
  describes a service as data (`Service{name, version, summary, commands,
  ts_types}`), `services/install.v` is the single registration path and
  refuses an undeclared command, a missing handler, a foreign namespace and a
  duplicate. A service's commands ARE its capability names, so `vails.json`
  grants and manifests cannot drift apart.
- **`dialog` service** (Windows native, E2E-proofed): `dialog.open`,
  `dialog.save`, `dialog.message` behind a Common Item Dialog C shim
  (`dialog_shim.h`, UTF-8 C ABI, NUL-separated paths). A dismissal resolves
  `{canceled: true}` instead of rejecting. Linux is an explicit stub.
- **`os_info` service**: host facts only (`os_info.get`).
- **`vails dts`**: grant-driven TypeScript declarations + per-service JS
  snippets, so a frontend can only type-check what it was actually granted.
  Flags: `--config`, `--out`, `--js`, `--check`.
- **`webview.Ctx`**: one runtime handle per window — `emit` (V→JS, the
  direction Phase 2 left unwired), `run_js` and `parent` (the native window
  handle services parent their own UI to), handed to the app through the new
  `Config.on_ready`.
- **Capabilities (T1, ADR-0007)**: per-window command allowlists, asset-root
  scopes and platform filtering. Empty registry = deny all; a denied call
  answers `forbidden:`, never `unknown method`.
- **Strict IPC contract (T2, ADR-0010)**: `call_json` (gate → params
  validation → handler) vs `notify` (gate only), standard `err` prefixes,
  one native entry point (`handle_envelope_from`).
- **Light channels (T3, ADR-0011)**: `ChannelHub` mints `ch_<n>` ids for
  progress/streaming; eval-only, no native changes.
- **Managed state (T4, ADR-0011)**: one `state.Store` per `application.App`
  (Tauri `.manage()` equivalent), raw JSON per key.
- **Secure frontend defaults (T7, ADR-0012)**: a default CSP injected on both
  backends (it was only ever unit-tested before), idempotent and
  override-respecting.
- **Mobile prep (M0, ADR-0012)**: `mobile.is_mobile`, an intentional desktop
  no-op `apply_geometry`, and the `events.Common.*` contract future backends
  feed.
- **Dev server (Phase 3, ADR-0013)**: loopback stdlib-`net.http` server over
  the project dir with a livereload poller, capability-scoped, no `veb` so
  Windows tests stay gcc-free.
- **CLI (Phase 4, ADR-0013)**: `vails init/run/build/doctor`, the `vails init`
  scaffold, and `vails build` setting `VMODULES` to the vails root.
- **`vails.json` (T6, ADR-0008)**: windows, capabilities, asset root and
  bundle settings, validated by `doctor` and read by `run`/`build`.

### Changed

- A `blocking` command (a modal native dialog) is now a documented exception
  to the ADR-0010 threading rule, marked in the manifest so the constraint
  travels with the service. Such a command must never be called from
  `v test` — it blocks on a window nobody can click.

## [0.1.0] - 2026-09-26

Phases 0–2: the framework exists and both backends are proven with
screenshots (`tests/e2e_windows/pong.png`, `tests/e2e_linux/`).

### Added

- Repo skeleton: `v.mod`, `AGENTS.md` (workflow contract), `CONTEXT.md`
  (domain model), `ROADMAP.md` (phases + tracks), `docs/ADR/`.
- **Windows window PoC**: `webview/webview_windows.c.v` (webview 0.12 /
  Edge WebView2). ADR-0005 records the DLL side-by-side pain.
- **Linux window PoC**: `webview/webview_linux.c.v` (GTK + `WebKitWebView` +
  `gtk_main`), rendered headless under `tests/e2e_linux/run_headless.sh`.
  ADR-0005 records why GUI apps need `-gc none` on this setup.
- **JS↔V bridge**: `handle_message` + `runtime_js`/`runtime_js_bound` +
  `resolve_js`, E2E-proven on Windows (`ping` → `pong`).
- `examples/hello`: a window whose UI comes from a file, not from a string.
- The Wails (design guide) and Tauri (capabilities model) plans, plus the
  mobile track (ADR-0006) and the opt-in bundled-Chromium track.

### Changed

- The Linux-first decision (ADR-0002) stands: the Linux vertical slice comes
  before macOS, and no Go→V translation is ever attempted (ADR-0001).
