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

Phase 5 S1 wave 2: three services with real backends on both platforms, plus
the fixes the codegen work surfaced.

### Added

- **Windows + Linux backends**: the WSL image has V (`/root/vsrc/v`), GTK 3.24
  and webkit2gtk-4.1, so a Linux service backend is compiled and proven again
  instead of stubbed. See ADR-0015.
- **`opener`**: `opener.open_url` and `opener.open_path` hand a URL or a path
  to the user's default handler — `ShellExecuteW` on Windows, GIO's
  `g_app_info_launch_default_for_uri` on Linux (no `xdg-open` process
  involved). `open_url` accepts only `http`, `https`, `mailto` and `tel`, and
  `open_path` only a local path, so a granted capability cannot be turned into
  a `file://` read or a `smb:` launch. `with` (an application override) is
  Windows-only for now and says so on Linux. See ADR-0015.
- **`notification`**: `notification.notify` shows a short message without
  taking focus (a Windows tray balloon — no COM, no shim) and
  `notification.is_supported` lets a frontend ask before trying, instead of
  firing a notification that quietly does nothing on a platform with no
  backend. Other platforms get an explicit "not implemented" error. The WinRT
  toast (real Action Center notifications) and a real `tray` service need a
  window-procedure seam and are the recorded next step. See ADR-0015.

### Changed

- **`clipboard` got its native half** and is a catalog service now, so
  `vails dts` and `vails doctor` see it. `clipboard.read_text` /
  `clipboard.write_text` work on Windows (user32 `CF_UNICODETEXT`) and Linux
  (the GTK clipboard); an empty clipboard resolves with `""` rather than
  rejecting, and the payload is bounded at 1 MiB. `read_text`/`write_text` now
  take the window's `webview.Ctx` (writing needs the parent handle), which is a
  signature change to a service that had no native half yet. See ADR-0015.
- **The generated `.d.ts` no longer promises camelCase the decoder drops.** A
  V struct field name *is* the wire name: json2 silently ignores keys it does
  not recognize, so the shipped `dialog` types offered `defaultPath` /
  `defaultName` while the values were discarded. The types (and the `dialog`
  example page) now use `default_path` / `default_name`, and a test pins the
  pair together. A TypeScript frontend that was passing `defaultName` must
  rename it. See ADR-0015.
- `v test .` now passes on **Linux** as well as Windows (29 test files). It
  never did: `dialog_test.v` referenced a Windows-only helper, which moved to
  pure V so the mapping is testable everywhere.
- **A Vails app builds on Linux again, and its bridge works.** The Linux
  backend had not compiled since the `Ctx.parent` / V→JS work landed, and
  even once it did, the page had no `window.vails` at all: the JS→V
  transport was the Phase 2 leftover, still only declared
  (`webkit_user_content_manager_register_script_message_handler` was
  declared and never called) — every example rendered in preview mode. Now
  the runtime is injected as a user script, the `script-message-received`
  channel is wired, and the reply rides back out through
  `bridge.resolve_json` + `run_javascript`. The Linux service proofs in
  `tests/e2e_linux/` are the first that could run at all. See ADR-0015.
- **`vails doctor` reports the native backends.** A new `backends` section
  lists every built-in service with `ok`/`stub` for *this* platform, and names
  a granted service that is a stub here. A `vails.json` grant is not a
  promise, and doctor says so before the app runs. See ADR-0015.
- **`examples/services`**: four services in one window (clipboard, opener,
  notification, os_info) and the E2E vehicle for the wave. The clipboard probe
  is the one that needs no human — write a known non-ASCII string, read it
  back, compare — so a screenshot is the whole round trip through the real
  user32/GTK clipboard. `tests/e2e_windows/capture.ps1` makes the Windows
  screenshots repeatable, and `tests/e2e_linux/run_services.sh` does the same
  under xvfb.

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
