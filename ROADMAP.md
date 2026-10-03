# ROADMAP.md — from MVP to complete

Checkboxes are the state. Move exactly one phase at a time (AGENTS.md §3).

This file is the **plan**; the diary is `CHANGELOG.md`. What follows is the
current position, then what has shipped, then the priority table that decides
what happens next. Anything about *why* something took three attempts belongs in
an ADR, not here.

## Where we are (2026-09-30)

| | |
|---|---|
| `v test .` on Windows | **33/33 test files green**, excluding `webview` (below). No `-ldflags` needed on the current compiler — AGENTS.md §1, §1c |
| `v test webview` on Windows | **cannot be run**: it takes the host down. Measured 4× on 2026-09-30 and once more on 2026-10-03, one file at a time and as a directory, with **no OOM in the Windows event log**. All six `webview` test files *compile* (`v -o`, no run). |
| `v test .` on Linux | 32/32 as of 2026-09-28. **Stale**: not re-measured since ADR-0034/0035, and this repo does not have a Linux runner. Treat as "was green", not "is green". |
| Current phase | **Phase 5** (services) — S1 waves 1–4 and Phase 5b shipped |
| Next by the table | **F0's proof run** (one command: `examples/multiwindow`), then F1, then W1–W4 |
| Runtime-blocked on | a two-window run on Windows (F0), a display session for the Linux GUI proofs, a macOS backend (Phase 6) |

**Three V 0.5.2 bugs are now pinned in `AGENTS.md §2b` + `§2c`** and they are not
exotic: two `if`/`$d` parser bugs, `or` silently not running for a none
`Option<&T>`, a closure copying a `mut … &T` *parameter* by value, and `spawn`
with a `mut … &T` parameter crashing or hanging. Any threading or optional-value
code in this repo should read §2c before it is written.

## What has shipped

| Track | Shipped | ADR | Date |
|---|---|---|---|
| Phases 0–4 | window, bridge, channels, CSP, state, dev server + CLI | ADR-0004, 0011–0013 | 2026-09-26/27 |
| Tauri-inspired | T1 capabilities, T2 IPC contract, T3 channels, T4 managed state, T6 assets, T7 CSP | ADR-0007, 0010, 0011, 0012 | 2026-09-26/27 |
| M0 | one mobile stub, documented as a no-op | ADR-0006 | — |
| S1 wave 1 | `dialog` + `os_info` | ADR-0014 | 2026-09-27 |
| S1 wave 2 | `clipboard` + `opener` + `notification` (WinRT toast) | ADR-0015, 0018 | 2026-09-27 |
| S1 wave 3 | `menu` + `tray`, and the window host seam | ADR-0017 | 2026-09-28 |
| S1 wave 4 | `menu.set_menu` (window menu bar), `tray.set_menu` | ADR-0023, 0026 | 2026-09-29 |
| Phase 5b | the GTK `dialog` backend | ADR-0027 | 2026-09-29 |
| B (build & release) | `D0` sql policy, `B5` half (`deps`), `B0` version stamping, `B1` runnable `vails build`, `B2+B3` Dockerfile + CI | ADR-0034 | 2026-09-29 |
| U/W0 | `webview.post_to_main` — **Windows**; Linux `g_idle_add` deferred | ADR-0019 | 2026-09-30 |
| F0 | multi-window **routing** (`WindowRegistry`, `emit_to`) proven; the second Windows window written, **not observed** | ADR-0035 | 2026-09-30 |

## What is claimed and what is proven

The repo's own rule (AGENTS.md §5) is that a line either names a proof or says it
is unproven. The four things most likely to be over-read:

- **B2+B3 (Dockerfile + CI) is written but never executed.** No runner and no
  container on this machine, so "the CI is green" is not a claim anyone can make
  yet.
- **The Linux GUI proofs need a real session.** `menu.png` / `tray.png` /
  `dialog.png` exist; the Linux `menu:clicked {id}` mapping does not, because Xvfb
  has no window manager to deliver the click.
- **`post_to_main` is Windows-only.** On Linux it refuses by name; the
  `g_idle_add` trampoline is unwritten, and it is the first push onto the GTK
  main loop from a foreign thread in this repo's history.
- **F0's second Windows window is written and type-checked, not observed.** The
  COM apartment that unblocks it is in `webview_windows.c.v` and `v vet webview`
  is green, but **this machine crashes its host on the `webview` test module** —
  measured three times on 2026-09-30, with one test file at a time and with the
  whole directory, and with no OOM in the Windows event log, so the cause is
  still unknown. Until somebody runs `examples/multiwindow` and puts two windows
  in a screenshot, "multi-window works" is a claim. Every other module's tests
  pass: 15 of 16 modules green on 2026-09-30, and `webview` is the sixteenth.

## Corrections worth remembering

Five decisions were reversed while planning, and the reversals matter more than
the plans they replaced:

1. The signed `updater` came **out** of "out of scope" and became the U track —
   V has `crypto/ed25519` and a streaming `net.http`, so the whole
   verify-then-swap pipeline is reachable in pure V.
2. `window-state` / `positioner` were **handed to** track W instead of shipping as
   two small services.
3. Version stamping moved **out of** the updater's U6 **into** B0: CI needs it
   before the updater exists.
4. `Program Files` install was recognised as **incompatible** with the in-app
   updater, which makes per-user install a requirement rather than a preference.
5. ADR-0020's rejection of a framework-owned updater window is **conditional**,
   not final: its stated reason was "Vails has one window", and F0 makes windows a
   set — though only the routing half has landed, so the second window is still
   the thing standing between that and an updater UI of its own.

## Priority and execution order

Nine planned tracks is one too many to read, so this is the one list that
decides what happens next. **Every track is below; this table is the order.**
Effort is in focused days and is an estimate, not a commitment.

| # | gate | track | size | unblocks | why here | state |
|---|---|---|---|---|---|---|
| 1 | — | **X0** Vinix spike (3 q's) | 3 d | X1, ADR-0031's stakes | 3 days to avoid a wrong foundation; depends on nothing | planned |
| 2 | — | **D0** `sql` security policy | 1 d | D3 | a day of pure V; the decision must exist before any `sql` code | **done (ADR-0034)** |
| 3 | — | **B5** `dependencies` + VPM | 3 d | **N**, **D** | `ui2`, `leveldb` and `vsql` are all absent from `vlib` | **done, half (ADR-0034)** — `deps` + `vails deps` ship; `deps install` deliberately does not |
| 4 | — | **B0** version stamping | 2 d | B1–B4, U6 | CI needs it before the updater exists | **done (ADR-0034)** |
| 5 | B0 | **B1** runnable `vails build` | 3 d | P1, B2–B4 | 5 DLLs are copied by nobody today; a green CI must not ship a dead `.exe` | **done (ADR-0034)** |
| 6 | B0 | **B2+B3** Dockerfile + matrix CI | 4 d | P2–P4, B4 | the repo has no CI; `v test .` is green on both platforms already | **done, unproven (ADR-0034)** — no runner or container here |
| 7 | — | **U0/W0** `post_to_main` | 3 d | U4–U7, W1–W4 | three dependents; also the job half of ADR-0019 (its subscriber half shipped as ADR-0023) | **done on Windows (ADR-0019)** — `jobs.v` + a real E2E screenshot; Linux `g_idle_add` deferred |
| 8 | — | **F0** multi-window | 6 d | **W**, `tray.set_menu`, U4's second window | highest-leverage single item; reopens an ADR-0020 decision | **routing done, window blocked (ADR-0035)** — 21 tests; the second Windows window needs `CoInitializeEx` on the window thread |
| 9 | F0 | **F1** drag & drop | 6 d | R3 | the other platform gap; check `EnableWebDrop` reachability first | planned |
| 10 | U0 | **W1–W4** chrome + `window` service | 6 d | the tutorial's menu item, E6 | absorbs S1 wave-4 `window-state`/`positioner` | planned |
| 11 | W, F0 | **U1–U4** updater core + service | 8 d | U5, P4 | the manifest-as-core half is pure V and no I/O | planned |
| 12 | B1–B4 | **P0–P4** distribution | 8 d | release | the update-channel policy is decision-only and independent | planned |
| 13 | P0 | **U5–U7** swap, helper mode, proof | 6 d | a shipping release | needs a distribution channel to mean anything | planned |
| 14 | B5, X0 | **N0–N4** native tier + VML + editor | 19 d | a second kind of app | `ui2` is 3 weeks old and not in `vlib` — spike first | B5 gate now open |
| 15 | B5, D0 | **D1–D3** `store` + `sql` | 9 d | E1/E3/E6 | both gates are now open (ADR-0034) | **unblocked** |
| 16 | X0=yes | **X1** Vinix backend | 5 d | — | only on a yes from #1 | planned |
| 17 | F0, U, W | **R3–R4** showcase | 6 d | all E2E | replaces `examples/services` as the proof vehicle | planned |

**Total ≈ 91 focused days** at the start of the build track; **≈ 52 left now.**
Landed since: D0, B0, B1, B2+B3, roughly half of B5 (ADR-0034), U0/W0a
(ADR-0019), and F0's routing half (ADR-0035). That is the number this file
previously carried "~2 focused weeks" for, and the discrepancy is stated here
rather than spread across eight sections where nobody adds it up. The honest
reading is that this is **several months of one person**, and the ordering above
is deliberately front-loaded with the cheap, independent, decision-only items
(#1–#4, ~9 days) because those are the ones that change what the expensive items
*are*.

**The order held up.** Four cheap items turned out to be worth more than their
size suggested, because implementing them is what found the six corrections in
ADR-0034 — and three of those would each have cost a future contributor a day.

**Three things are worth doing regardless of anything else**, because they are
cheap and they unblock the most: **X0** (3 d, three questions that decide a
platform), **D0** (1 d, a security decision), **B5** (3 d, without which two
whole tracks cannot start at all).

**C2/C3 (bundling CEF) is deliberately off this list** — see the C track. It
is 20+ days that a V-written browser engine would delete, and the horizon
item that would trigger it is recorded instead.

- [x] **Phase 0 — Scaffold** (this repo): `v.mod`, module skeleton,
  `AGENTS.md`/`CONTEXT.md`/`ROADMAP.md`, ADRs, `examples/hello`,
  `v test .` green on Windows.
- [x] **Phase 1 — window PoC (both backends, verified with screenshots)**:
  Linux `webview_linux.c.v` (GTK → window → `WebKitWebView` → `load_html` →
  `gtk_main`) renders under WSL/xvfb (`tests/e2e_linux/run_headless.sh`).
  Windows `webview_windows.c.v` (webview lib 0.12, Edge) opens with title.
  Findings recorded in ADR-0005 (`-gc none` on Linux, Wayland hijack,
  DLL side-by-side on Windows).
- [x] **Phase 2 — JS↔V bridge (both backends verified E2E)**:
  pure-V seam (`handle_message`, `handle_envelope_from`, `runtime_js`,
  `runtime_js_bound`, `resolve_js`/`resolve_json`, `to_js`, `jsesc`) +
  Windows transport (`webview_bind` → `bind_cb` → `webview_return`).
  Button → `pong` proven, proof in `tests/e2e_windows/pong.png`. Transport
  decided in ADR-0004/0005. The **Linux** transport was declared but never
  connected until wave 2 found it (ADR-0015): no runtime injection, no
  message channel, so every Linux example rendered in preview mode. It is
  wired now — user script + `script-message-received` + a reply evaluated
  back into the page — and proven by the same clipboard round trip that
  proves the service.
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
- [ ] **Phase 5 — Services** (S1 wave 1 + wave 2 shipped 2026-09-27,
   ADR-0014/0015; full catalog below. Each next wave: `services/<name>.v`
   seam + `_test.v` + capability + ADR line, one PR per service + manual
   test):
  - [x] S1 core wave 1 (done, ADR-0014): `webview.Ctx` seam (V->JS
    `emit` + native parent handle, closing the Phase 2 event-delivery
    leftover, and wiring the T7 CSP onto the native path), the service
    manifest + `services.install` model (T5), **`dialog`** (Windows
    native: Common Item Dialog + MessageBoxW behind a C shim; Linux was an
    explicit stub here and became a real GTK backend in ADR-0027), **`os-info`** (pure-V reference service,
    pulled forward from this list on purpose), `vails dts` (grant-driven
    `.d.ts` + per-service JS snippets) and the `examples/dialog` proof.
  - [x] S1 core wave 2 (done, ADR-0015): the Linux toolchain exists (V at
    `/root/vsrc/v`, GTK 3.24, webkit2gtk-4.1), so Linux backends are
    compiled and proven rather than stubbed — and the Linux bridge, which
    had been *declared* but never connected, now injects the runtime and
    dispatches JS→V, so the first Linux service proofs could run at all.
     **`clipboard`** (user32 `CF_UNICODETEXT` + the GTK clipboard, E2E
     round trip on both platforms), **`opener`** (`ShellExecuteW` + GIO,
     with a scheme allowlist because it is the one service that makes the OS
     act on a frontend string), **`notification`** (a tray balloon,
     with `is_supported` so a frontend can ask instead of firing into
     nothing; **replaced by a real WinRT toast in ADR-0018**), the per-service
     backend report in `vails doctor`, and `examples/services` as the proof
     vehicle (`tests/e2e_{windows,linux}/services.png`).
   - [x] S1 core wave 3 (done 2026-09-28, ADR-0017 — Windows **and** Linux
      E2E-proven): **the window host seam** (`webview/host.v`) — the one place
      the OS may call *into* V: a comctl32 `SetWindowSubclass` on the window the
      webview library owns, installed **on demand** (never by `webview.run`),
      with `DefSubclassProc` for every message the seam does not own. It also
      corrected ADR-0015's premise: a hidden window is not needed (the balloon
      already proved the webview window works as an owner) and a popup menu
      needs no window procedure at all, so the seam is one-sided and there is no
      `host_linux.c.v`. **`menu`** (a real native popup on both platforms;
      the choice arrives as `menu:clicked` / `menu:canceled` and *never* as the
      command result, which is what lets one contract serve a modal Windows
      menu and an immediate Linux one), **`tray`** (a shell icon whose click is
      an OS-initiated `WM_APP+1` that reaches V through the seam and arrives as
      `tray:clicked` — the first service the OS drives, with
      `services.simulate_click` so the loop is provable without a mouse), the
      shared `services/trayicon_windows.c.v` primitive (the shell identifies an
      icon by `(hWnd, uId)`, so the balloon and the tray must not share one),
      and the `examples/services` probes for both. The Linux backends were then
      **verified and repaired** in the same wave: they had never compiled, and
      once compiling they had never worked — `menu.set_menu`, `tray.set_menu`,
      `window-state` and the GTK `dialog` are the next items.
  - [ ] S1 core wave 4 (the rest of the S1 list): **`notification` is
     done on Windows — ADR-0018 replaced ADR-0015's tray balloon with a real
     WinRT toast** (`services/toast_shim.h`, the document built and tested in
     pure V, the AppUserModelID from a new `vails.json`
     `bundle.identifier`; compile- and link-verified, runtime proof pending
     a machine with the WinRT runtime — see "Verification status" in ADR-0018
     and `tests/e2e_windows/README.md`). **`menu.set_menu` shipped
     2026-09-29 (ADR-0023)**: the window menu bar, as the *same* service as the
     popup — same `MenuPopup` params, same id rules, same `menu:clicked` event,
     so one frontend listener covers a right-click menu and a window bar. It
     needed the window host seam to take a **second** hook on one window (tray's
     `WM_APP+1`, the bar's `WM_COMMAND`), so a `HostHandler` now returns whether
     it consumed the message and the two chain instead of sharing. GTK3 has no
     `gtk_window_set_menubar` at all, so the Linux half packs a `GtkMenuBar`
     into a vertical box that `run_linux` now always creates, reached through
     the new `Ctx.toplevel` (the `GtkWindow`, not the GdkWindow `parent` is) —
     which the GTK dialog needs too. Linux is E2E-proved (`menubar.png`: the bar
     renders and a click reports the right id — provable *further* than the
     popup, since a bar is a normal widget where a popup is override-redirect);
     Windows compiles and links but is unproven at runtime. Still open:
     `tray.set_menu` (the StatusNotifierItem's menu — on Linux that *is* the
     click, since the tray host owns it, which also forces a ruling on
     `WM_CONTEXTMENU`, already mapped to `tray:clicked {right}`) and the GTK
     `dialog`. **`window-state` / `positioner` were handed to the window chrome track on
     2026-09-29** (ADR-0021) rather than shipped as two small services: they
     became the `window` service, which also carries frameless chrome and the
     title-bar buttons, and they need the seam's subscriber list (ADR-0019)
     anyway. Cf. `v3/pkg/services`.
  - [ ] S2 system (after S1): `single-instance` → `autostart` →
    `global-shortcut` (risk: Wayland limits) → `keychain`
    (cf. `v3/internal/keychain`) → `store` (persisted KV — **moved to D1**,
   see the native/data/Vinx track below) →
    `screencapture` (per ADR-0009 B) → `scoped fs` (last, riskiest,
    capability-locked).
  - [ ] S3 mobile (feeds M2): `haptics` (= `vibrate`), `biometric`,
    `geolocation`; `barcode-scanner` / `nfc` optional-late.
  - Out of scope (post-desktop, unchanged): `sidecar`
     binaries, unrestricted `shell` / `process`, `sql` /
     `stronghold`, WebDriver engine, BT/serial/printer (community-level).
     **The signed `updater` was struck from this list on 2026-09-29** and is
     now the U track below (ADR-0020): V has `vlib/crypto/ed25519` and a
     streaming `net.http`, so the whole verify-then-swap pipeline is
     reachable in pure V with no new dependency. What it does *not* need is
     recorded honestly in that ADR — no second window, so the update UI is
     the app's own; and no way for a worker to reach the page, which is
     U0/ADR-0019.
- [ ] **Phase 5b — remaining Linux service backends** (the toolchain is no
  longer the blocker — ADR-0015 proved it works; what is left is the parts
  that need a human or a desktop session):
  ~~`dialog`~~ **done 2026-09-29** (ADR-0027: `GtkFileChooserDialog` +
  `gtk_dialog_run`; the response-id mapping is pure V and tested everywhere,
  and the E2E proof answers a real `GtkMessageDialog` from a timer so it needs
  no human — the "last S1 item waiting on a human" turned out not to be one).
  Then `notification` (libnotify or GNotification; needs a D-Bus session to be
  visible at all), then the `with` override for `opener` (a `.desktop` file
  rather than an app name). `clipboard`, `opener`, `menu` and `tray` are
  already done (waves 2 and 3), and `tray.set_menu` joined them 2026-09-29
  (ADR-0026).
  **The verification pass that was listed here first is done**
  (2026-09-28): `examples/services` builds on Linux, `v test .` is 32/32 there,
  and `menu.png` / `tray.png` carry the proofs. It turned out not to be a V
  problem at all — the full account, including the two GTK3 signals the file
  used that do not exist, is in `tests/e2e_linux/README.md`. What the pass
  could **not** prove is named there too: the Linux `menu:clicked {id}`
  mapping needs a real desktop session. Remaining checklist for a Linux
  desktop is below.
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
sidecar binaries, SQL/Stronghold, WebDriver
engine, iframe isolation pattern. (`store` moved to D1, below; mobile
has its own track below; the signed `updater` moved out of this list on
2026-09-29 into the U track below — ADR-0020.)

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
- [x] **T4 — Managed app state (after T2)** (done 2026-09-27, ADR-0011):
  Tauri `.manage()` equivalent: new `state/` module (`AppState`, renamed from
  `Store` on 2026-09-29 by ADR-0030 so the bare word `store` could go to the
  persisted service; raw JSON per key + hand-written `set_string`/`get_string`
  accessors; `$for`
  auto-derivation only if proven sufficient), one `AppState` per
  `application.App` (`set_state`/`get_state`/`has_state`, handlers
  capture `&app`). Threading follows ADR-0010 (main-thread access,
  `spawn` workers reply as events).
- [x] **T5 — Services as plugins** (done 2026-09-27, ADR-0014): each
  service is described by a manifest (`services/manifest.v`:
  `Service{name, version, summary, commands, ts_types}`) and registered
  through one path (`services/install.v`) that refuses undeclared,
  missing, foreign-namespace or duplicate commands. Each service ships its
  own JS snippet (`Service.js_snippet()` — no monolithic runtime), and the
  `.d.ts` is generated from the same manifest, grant-driven via
  `vails dts` (a frontend can only type-check what `vails.json` grants).
  `services.manifests()` is the catalog; `os_info.get` and `dialog.*` are
  the first entries. Order for the rest follows the Phase 5 catalog: S1
  core (`notification` → `clipboard` → `menu` → `tray` → `opener` → ...)
  then S2 (`single-instance` → ... → scoped `fs` last, locked by
  capabilities).
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

Execution order: T1 → T6 → T2 → T3 → T4 → Phase 3 → Phase 4 → Phase 5
S1 wave 1 + T5 (all done; the V->JS event-delivery leftover of Phase 2
closed with `webview.Ctx`) → Phase 5 S1 wave 2 (done 2026-09-27, ADR-0015:
clipboard/opener/notification on both platforms, the backend report in
`doctor`, and the Linux bridge that turned out to be declared-but-unwired) →
Phase 5 S1 wave 3 (done 2026-09-28, ADR-0017: the window host seam, `menu`
and `tray`; Windows E2E-proven, the Linux run pending).
Next: Phase 5 S1 wave 4 — `menu.set_menu` (done 2026-09-29, ADR-0023),
`tray.set_menu` (done 2026-09-29, ADR-0026) and the GTK `dialog` (done
2026-09-29, ADR-0027) are landed; what remains is
`window-state`/`positioner` (the same host seam, different messages), then the
rest of Phase 5b starting with `notification` on Linux and `opener.with`.
Estimate: ~2 focused weeks, revised down for the three items above.
Each item: code + tests on both OSes + short ADR + ROADMAP checkbox.

## Frontend track (Vite + web frameworks, type-safe bindings + JS/V helpers; planned, not started — ADR-0016)

Goal: build frontends with Vite + a web framework (Vue/React/Svelte/Solid
or vanilla-ts) while staying type-safe end to end: TS types are generated
from the V side and injected into the frontend, and thin helpers on both
sides remove the repetitive `call(method, "")` / manual `json.encode` /
`parseInt` / untyped `onEvent` boilerplate seen in `examples/hello`.
Stays framework-agnostic: Vite is the build/dev tool, frameworks are
`vails init --template` variants (vanilla-ts first, then vue). The wire
protocol is unchanged (T2 commands/events, T3 channels); only a typed
layer + helpers wrap it, so `vails dts` (T5) stays the single source of
the `.d.ts` shape and manifests stay the per-service source of commands.

- [ ] **F0 — Binding schema decision (half a day, no code)**: `Params` /
  `Result` structs next to each handler + `bind_typed[T, P]` as the
  registration path (replaces `register` + `validate_empty` +
  manual `json.decode/encode`); unknown/complex V types map to `unknown`
  with a `// TODO refine` comment so the build never breaks. Recorded in
  ADR-0016; gates F1.
- [ ] **F1 — Typed generator (pure-V)**: new `generator/bindings.v`
  (`v_to_ts` mapping table `string/int/f64/bool/struct/[]T/map/?T`,
  `TypedSpec`, `generate_client` emitting both
  `vails-bindings.d.ts` and the importable `vails-client.ts` wrapper
  around the existing `window.vails.call/emit/onEvent`); snapshot tests
  in `generator/bindings_test.v`, green on Windows. No bridge/C changes.
- [ ] **F2 — V + JS helpers (pure-V + generated TS)**: new
  `bridge/helpers.v` (`bind_typed`, `bind_empty`, `ok`/`fail`,
  `emit_typed`, typed `ChannelHub` push, `use_state[T]` over
  `application.App` store); generated `api.*` typed functions,
  `onEvent<T>`, `useChannel<T>`, `callOrPreview<T>` (the typed form of
  hello's preview fallback). Proof: `examples/hello/main.v` re-registered
  through helpers with zero protocol change; existing pong E2E stays green.
- [ ] **F3 — Config + CLI wiring (additive)**: `config.FrontendConfig`
  (`dir`, `dev_url`, `dist`, `gen_dir` with `frontend/`,
  `http://localhost:5173`, `dist/`, `src/gen` defaults);
  `vails gen-bindings [--out]`, `init --template vite-vanilla-ts|vite-vue`,
  `run --dev` (spawn `npm run dev`, open `webview.Config.url` at the dev
  URL, CSP dev allowlist for `localhost:5173` + `ws:`), `build` (`npm run
  build` → `dist/` into `assets.Bundle`), `doctor` checks (`node`/`npm`,
  stale `gen/` warning). Tests: config validation + CLI dry-runs, pure-V.
- [ ] **F4 — Typed events/channels + example**: `emit_typed`/`open_typed`
  for `events.Bus` + T3 channels (generic `onEvent<T>` frontend side);
  new `examples/hello-vite/` (same counter/ping as hello, `src/main.ts` +
  `App.vue` calling `api.counter_inc(): Promise<number>`); e2e README
  lines + manual screenshot proofs on Win/Linux.

Order: F0 → F1 → F2 → F3 → F4, after Phase 5 S1 wave 3 + Phase 5b, before
Phase 7 (F1 feeds the Phase 7 `$for` auto-spec work; F3 feeds T5/Phase 7
packaging). Per AGENTS.md §3 phase discipline: none of F1–F4 starts while
Phase 5 is the current phase. Each item: code + tests on both OSes +
short ADR update + checkbox.

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
- [ ] **C5 — the `vox` horizon. No code, on purpose.** A V-written browser
  engine replacing Chromium is a *condition*, not a task — and **the condition
  is not met**: no such engine was findable in the vlang org, in a GitHub
  repository search, or on the web on 2026-09-29. C5 exists to record that,
  and to record what happens when it is met.

**C2/C3 are marked disposable and are no longer scheduled on faith (2026-09-29).**
C1 (`Config.backend` dispatch) is durable: it is where any future engine lands,
and ADR-0031's native tier reuses it rather than building a rival seam. C2/C3
are 20+ days of work that a V browser engine would **delete**. Spending six
weeks binding Chromium and then throwing it away is the outcome this line
exists to prevent, and the decision to spend them now waits on a `vox` signal
rather than on enthusiasm. **A Vails app should ship against the OS webview
(WebView2 / WebKitGTK) until one of those two things is true** — not because
CEF is wrong, but because a bundled third engine is a bet against an
imminent one.

Order: C0 → C1 → C2 → C3 → C4, after all phases/tracks above.
Each item: code + tests on both OSes + short ADR update + checkbox.

## Window chrome track (ADR-0021 — W0a shipped 2026-09-30, rest planned)

Frameless windows and a title bar the app draws itself:
`window.chrome.mode: "native" | "frameless"` in `vails.json` →
`webview.Config.chrome`, plus a `window` service (minimise / maximise /
centre / set_size / set_position / fullscreen) and the drag + resize contract.

**The finding that shapes it: `webview` 0.12 has no window-chrome API at
all** — the full surface is `create / destroy / run / terminate / dispatch /
get_window / get_native_handle / set_title / set_size / navigate / set_html /
init / eval / bind / unbind / return / version`. No `set_chrome`, no
`set_bounds`. Wails owns its window; Vails does not (`webview_create(0, NULL)`
makes the library own the HWND), so frameless is done *to* an existing window
rather than requested at creation. Fortunately that is cheap: the HWND is
already available via `webview_get_window`, and ADR-0017's seam already
subclasses exactly it.

Two modes, not three: a "custom title bar" is not a separate mode, it is
`frameless` plus an app that draws its own bar (Electron/Tauri model). A third
mode preserving the native frame (Wails' `TitlebarOverlay`) is rejected
because on Linux it means CSD, which cannot be rendered under the Xvfb session
this repo proves in.

- [x] **W0a — the seam** (ADR-0019, shipped 2026-09-30 with U0): `Ctx` carries
  the window's `&MainThread` and `webview.post_to_main` hands a closure to the
  window thread, so a worker reaches the page. **The subscriber list was never
  needed** — ADR-0023's `!bool` chaining already let two handlers share one
  window, so `tray` keeps its own `HostCtx` and coexists with the job wakeup
  rather than migrating. See track U's U0 for the details and the E2E proof.
- [ ] **W0b — the config plumbing**: `webview.Config.chrome` +
  `WindowConfig.chrome` + `config` validation, plumbed to **all five**
  `WindowConfig` → `webview.Config` sites (`cli/vails.v:141` and `:490`,
  `examples/{hello,dialog,services}/main.v`), **one of which is inside a
  `const` string** and must be emitted as text. W1 cannot start until this
  exists, because a frameless window with nowhere to say "frameless" is a
  window that silently keeps its caption.
- [ ] **W1 — Windows frameless + proof**: strip `WS_CAPTION` via
  `SetWindowLongPtrW` + `SetWindowPos(SWP_FRAMECHANGED)`, keep
  `WS_THICKFRAME` so resize still works, and **return 0 from
  `WM_NCCALCSIZE`** — without that Windows keeps an invisible ~8 px resize
  border and a 1 px white frame, which is the standard signature of a
  frameless window nobody finished. `WM_NCHITTEST` answers the edge codes.
  Screenshot in `tests/e2e_windows/` (`capture.ps1` already matches on
  `MainWindowTitle`, which a frameless window still has).
- [ ] **W2 — Linux frameless + drag + resize**: `gtk_window_set_decorated(w,
  FALSE)`, `gtk_window_begin_move_drag` and
  `gtk_window_begin_resize_drag`, with pointer coordinates translated to root
  space by `gdk_window_get_origin`. This is a **manual edge-drag protocol
  rather than CSD**, and the reason is provability: with `decorated == FALSE`
  on X11 there is no resize grip at all unless the app implements one, and the
  e2e environment has no window manager — so CSD would ship unprovable
  exactly where this repo proves things. Drag is driven by a
  `data-ta-drag-region` / `data-ta-resize="n|s|e|w|ne|nw|se|sw"` contract in
  the injected runtime, **one contract on both platforms with no rectangle
  synchronisation**; a native `WM_NCHITTEST` + registered-rects version is
  the recorded upgrade path, not v1.
- [ ] **W3 — the `window` service** and the title-bar buttons: minimise,
  maximise/unmaximise/toggle, close, `is_maximised`, centre, `set_size`,
  `set_position`, `set_fullscreen`, plus events `window:resized` /
  `window:moved` / `window:maximised` / `window:closed`. Capability-gated, so
  a page that must not move its window simply is not granted it. The buttons
  are ordinary commands — the framework synthesises nothing and the app owns
  glyphs, spacing and RTL. Mobile is an explicit no-op (ADR-0006) with a
  `doctor` line, per the `ServiceStatus` pattern.
- [ ] **W4 — `window-state` / `positioner`**: persist size and position,
  which is the S1 wave-4 item this track absorbed. Needs a debounce timer on
  a worker, so it is gated on ADR-0019 too. Plus `examples/hello` grows the
  `frameless` proof page.

Order: W0 → W1 → W2 → W3 → W4, after Phase 5b. **W0 and the updater's U0 are
the same piece of work, not two** — ADR-0019 now has three dependents instead
of two (`tray`, `window`, `updater`), which is what made it worth doing first.
**W0a (the seam) shipped 2026-09-30** on Windows with an E2E screenshot, so
what remains here is W0b (the `chrome` config plumbing) and then W1. Note that
ADR-0019's Linux half is still unwritten, so W4's debounced `window-state` is
Windows-provable now and not yet Linux-provable. Linux is otherwise no longer
blocked: `v test .` is green there (32/32) and `examples/services` builds, so
W2 is a matter of adding evidence. What stays unprovable in a container is
unchanged and belongs to the manual checklist (the `menu:clicked {id}` mapping
needs a desktop session). ~6 focused days.
Per AGENTS.md §3, no W-item starts while Phase 5 is the current phase. Each
item: code + tests on both OSes + short ADR update + checkbox.

## Build & release track (ADR-0022/0034 — B0/B1/B2+B3 and half of B5 shipped, rest planned)

The first CI in this repo: reproducible builds per platform, version stamping
that both CI and the updater share, and a release on a tag that emits the
assets the updater's GitHub provider consumes.

**The finding that shapes it: Windows cannot be built from a Linux container
here.** The Windows backend needs MSYS2 ucrt64 and the *Windows* import
library of `webview` (C++, linked to WebView2);
`webview/webview_windows.c.v:20-23` hard-codes
`-IC:/msys64/ucrt64/include` / `-LC:/msys64/ucrt64/lib`. Cross-compiling that
is its own project. So: **Linux in Docker, Windows on a native runner**, one
job per target on a matrix.

**The second finding: `vails build` does not produce a runnable Windows
binary.** It shells out to `v -o <out> <dir>` with `VMODULES` set and prints
"packaging arrives in Phase 7". The five side-by-side DLLs exist **only as
`#` comments in the READMEs** — no script copies them. A first CI that
uploaded that would be worse than none: a green tick and an `.exe` that
cannot start. Hence B1 before B3.

- [x] **B0 — version stamping, and the version-truth decision** (done
  2026-09-29, ADR-0034): `vails build --version 1.2.3` emits
  `-d vails_version=1.2.3` and an app reads it with
  `buildinfo.version()`. The drift is reconciled and now **enforced**:
  `v.mod` was `0.2.0` and the CLI `0.4.0`, `v.mod` is now `0.4.0`, the
  framework version lives in one place (`buildinfo.framework_version`), and
  a test fails if they disagree again — a test is the feature, because two
  hand-edited numbers drift the first time someone bumps one.
  `buildinfo.validate_version` refuses `1.0`, `1.2.3.4` and `01.2.3`
  because the updater *compares* this string, and `doctor` reports an
  unstamped binary in words, because a release nobody stamped looks exactly
  like a development build and `dev` disables every update check.
  **The plan's own example line does not compile:** `$d('vails_version') or
  { 'dev' }` crashes the V 0.5.2 parser, and the only working form is
  `$d('vails_version', 'dev')` with *both* arguments literal. See ADR-0034
  correction 1 and `AGENTS.md` §2b.
- [x] **B1 — a `vails build` that produces a runnable binary** (done
  2026-09-29, ADR-0034): the five
  DLLs (`libwebview-0.12.dll`, `WebView2Loader.dll`, `libgcc_s_seh-1.dll`,
  `libstdc++-6.dll`, `libwinpthread-1.dll`) when
  `bundle.windows_dll_side_by_side` is set; put `-gc none` **inside**
  `build_app` (ADR-0005: Boehm GC crashes with WebKit's subprocesses) rather
than in a CI command a developer has to remember; **two build recipes, not
  one** - the CLI imports `net` for the dev server and, **on V 0.5.2**, needed
  `-cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32'` on gcc 16
  (not needed on the current compiler - AGENTS.md §1b - so the two recipes now
  differ only in what they *emit*, not in what they *require*); and `doctor` stops
  hard-coding
  `vails.json` (`cli/vails.v:356`) so it honours `--config`, which is what a
  multi-project workspace needs. Pure-V parts (flag sets, DLL list, output
  name) extracted as functions so they unit-test on Windows without a
  compiler, per ADR-0013. **Proven end to end on 2026-09-29**:
  `vails build --version 2.5.0` in a scaffolded project produced
  `smoketest.exe` with all five DLLs staged next to it, the process
  started, and `2.5.0` was in the binary. The staging step is
  **idempotent** — a rebuild over a running app skips the DLLs instead of
  failing *after* a successful compile, which is what the first version
  did (ADR-0034 correction 5).
- [x] **B2 — the Dockerfile** (written 2026-09-29, ADR-0034; **unproven** —
  WSL was inaccessible this session, so the image has never been built
  here): `FROM thevlang/vlang:ubuntu-build` (V's own
  published base image, used by V's own `docker_ci.yml`) plus
  `libgtk-3-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev
  pkg-config xvfb x11-apps net-tools`, then `make` **as a cached layer** so
  the from-source V build is slow once, not once per run. Pin `webview` to
  0.12: `doctor` reports the header's `webview_version()` and the MSYS2
  package is pinned, because a rolling `pacman -S` over a C++ dependency can
  break a green CI between two runs and the failure is a link error deep in a
  generated `src.c`.
- [x] **B3 — the matrix workflow** (written 2026-09-29, ADR-0034;
  **unproven** — no GitHub runner here): per push, `v test .` on Windows and
  Linux plus a smoke build each; Windows on `windows-latest` with MSYS2
  installed by
  script and `C:\msys64\ucrt64\bin` on `PATH` explicitly (ADR-0005: without
  it even `cc1` cannot find its own DLLs, which fails as a *silent* gcc
  failure, not a missing-symbol error). No Windows container: it costs more,
  runs slower, and is no more reproducible than a pinned `pacman` step.
  The Windows job's distinguishing step is the one B1 made possible: it
  runs `vails build` and then **asserts the five DLLs are in the artifact
  directory**, because a green CI shipping an `.exe` that cannot start is
worse than no CI. The Windows test line also carries `-ldflags "-lws2_32"`,
  which **V 0.5.2 required and the current compiler does not** — see ADR-0034
  correction 2 and AGENTS.md §1b. The flag stays in the recipe either way: it is
  harmless on a fixed compiler and required on an unfixed one.
- [ ] **B4 — Linux packaging + release on a tag**: AppImage and `deb` (the
  Phase 7 line already names `nfpm`; this finishes it rather than starting
  it), side-by-side folder for Windows, and on a tag a version-stamped build
  per platform + `vails updater manifest` attached to the GitHub Release.
  **This is why the two tracks were planned together**: the manifest the
  updater's provider consumes is produced by the build's own last step, so
  the publisher stops being a separate manual chore. Icons, `.msi`/NSIS and
  macOS stay in Phase 7. **Note:** a `ui_tier: native` app (ADR-0031) links
  none of the five side-by-side DLLs, so `windows_dll_side_by_side` becomes
  tier-dependent and B1 must not assume every artifact is a webview app.
- [x] **B5 — dependencies, and it gates two tracks — half done**
  (2026-09-29, ADR-0034). **Shipped:** the `dependencies` block in
  `vails.json` (the `v.mod` shape, with a `{"name": ">=1.0"}` map accepted
  as a fallback), a `vails.lock` recording what was **resolved**, a
  `vails deps` command that lists and diffs them, a `doctor` line, and
  `deps` as pure V so it is testable on Windows with no compiler and no
  network. 19 tests.

  **Deliberately NOT shipped: `vails deps install`.** Vails *declares* and
  *reports*; VPM (`v install`) *resolves*. The reason is the one ADR-0034
  argues: the moment Vails keeps its own resolved tree, a hand-run
  `v install` and a Vails-run one can disagree, and the build depends on
  which ran last. Two writers for one tree is the disagreement this
  command exists to prevent, and the lock file is how a Vails build *asserts*
  what it got rather than deciding what to get.

  This is the item that makes ADR-0031's native tier and ADR-0032's data
  services reachable: `vlib/ui2` is not in a V installation, nor are
  `vlang/leveldb` and `vsql` (verified 2026-09-29), so without VPM nothing
  in either track can be built. The remaining half is the ergonomic
  wrapper around `v install` and a `doctor` line for a failed fetch, and
  it is a half-day *after* someone decides the question in the paragraph
  above is answered the way it is here.

  **The E2E run found a bug the unit tests missed**, which is why it is
  worth recording: comparing the lock against the config textually
  reported every *ranged* dependency as stale forever (`lock has 1.4.2,
  config asks >=1.0.0`). The fix was not constraint satisfaction — that
  would be a second resolver beside VPM's — but comparing only where
  comparison is meaningful: `deps.is_exact_requirement`.

Order: B0 → B1 → B2 → B3 → B4, after Phase 5b. **B0–B3 and half of B5 are
done** (ADR-0034); B4 is the rest of this track. B0 was a prerequisite of
the updater's U6 (see that track) and it landed, so U6 no longer owes
version stamping. The matrix is written but has never run — a green tick
from this repository's own CI is the one claim it cannot make yet. What a
container cannot supply is the Linux `menu:clicked {id}` mapping, which
stays in the manual checklist. Each item: code + tests on both OSes + short
ADR update + checkbox. Open: how much of Phase 7 packaging (icons,
`.msi`/NSIS) moves into B4 or stays put.

## Self-updating track (ADR-0019/0020 — U0 shipped on Windows 2026-09-30, rest planned)

Port of the Wails v3 updater: check a release source on demand, download the
asset for the running OS+arch, verify a SHA-256 digest and an Ed25519
signature against bytes actually received, show the release notes, swap the
running binary and relaunch — with no separate helper executable, because the
helper is the current binary re-executed with sentinel env vars. GitHub
Releases first, static manifest endpoint second, keygen.sh/Sparkle after that
(the provider seam is what makes them files rather than projects).

Struck from "out of scope" on 2026-09-29. What made it worth reversing is
that every part Wails gets from the Go standard library exists in V's, and
the two that do not are small and local. **Verified in V 0.5.2 while
planning, not assumed:** `vlib/crypto/ed25519` is complete (raw 32/64-byte
keys, `verify`/`sign`/`generate_key`); `net.http` has `on_progress_body` +
`stop_copying_limit`, documented for streaming a download without holding the
response in memory; `crypto.sha256` streams via `Digest`; `os.rename` is
`MoveFileW` *without* `MOVEFILE_REPLACE_EXISTING`, which is exactly the
rename-aside a Windows `.exe` swap needs; `-d ident=value` + `$d` gives
version stamping for free.

Two things the port does **not** get for free, and neither is fudged: there is
no second window **yet**, so the update UI is the app's own window with
framework-supplied markup (`updater.default_html()`); and a `spawn`ed worker
cannot reach the page.

**Both of those are now in flight, and they split.** A worker reaching the page
is U0, and it shipped on Windows 2026-09-30 (ADR-0019). The second window is F0:
its *routing* shipped 2026-09-30 (ADR-0035 — `WindowRegistry.emit_to`, tested with
two eval sinks), while the second *window* is still blocked on WebView2's COM
apartment. So an updater with its own UI is one F0 milestone away, not one track
away — and until that milestone lands, the honest answer stays
`updater.default_html()`.

- [x] **U0 — the main-thread post seam, Windows half** (ADR-0019, shipped
  2026-09-30): `webview/jobs.v` has `JobQueue` (a `&sync.Mutex`-guarded
  `[]Job`), `MainThread` and `webview.post_to_main`, so a worker hands a
  closure to the window thread instead of dropping its result. `Ctx` carries a
  `&MainThread` so services stop competing for one subclass. Verified by
  `webview/jobs_test.v` (queue order, `take()` releasing the lock before
  `run_batch` so a nested `push` cannot deadlock a non-recursive `SRWLOCK`, a
  queue with no wakeup refused at the call site) and by a real Windows E2E
  screenshot: `VAILS_SERVICES_PROBE=post` in `examples/services` shows
  `probe post: ok - worker posted back to the main thread`. `WM_APP+2` +
  `PostMessageW`, with its own `wakeup_message` id so a wakeup can never reach
  the tray as a "left click". Two decisions changed under test and are recorded
  in the ADR: the wakeup subclass is installed **eagerly by `webview.run` on
  the window thread** (the planned lazy install cannot work — `SetWindowSubclass`
  is thread-affine and `post_to_main` is always called from a worker, so the
  first run failed with `SetWindowSubclass failed (code 0)`), and a posted job
  is a `fn ()` closure rather than a manually-owned `&Job`. **Still open: the
  Linux `g_idle_add` trampoline** — the first push *onto* the GTK main loop
  from a foreign thread — which `post_to_main` refuses by name rather than
  dropping the job. `tray` was **not** migrated: ADR-0023's chaining removed
  the need for a subscriber list, so `tray` keeps its own `HostCtx` and now
  coexists with the job wakeup on one HWND. **This is the same work as track
  W's W0** (ADR-0021) — one seam, three dependents (`tray`, `window`,
  `updater`).
- [ ] **U1 — the pure-V core** (no I/O, no network, so the bulk of the work
  is Windows-green without a backend): `updater_version.v` (SemVer 2.0.0
  including prerelease precedence), `updater_manifest.v` (the open manifest
  protocol + `platform_key()` + the GOOS/GOARCH alias table +
  `default_asset_matcher`), `updater_verify.v` (streaming sha256/sha512, and
  a digest parsed as **either** hex or base64 — the manifest uses base64 and
  `SHA256SUMS` uses hex, and getting that wrong fails verification against a
  document the other provider accepts).
- [ ] **U2 — providers**: `updater_github.v` (releases API, optional token /
  prerelease / GHE `BaseURL`, `SHA256SUMS`, filename alias matching) and
  `updater_endpoint.v` (one static manifest, `{{platform}}/{{arch}}/
  {{version}}/{{channel}}` placeholders). Both *produce* the same `Manifest`,
  so verification is written once. GitHub additionally reads an optional
  `SHA256SUMS.sig` — a signature the Wails GitHub provider does not have,
  which is what makes that path as strong as the keygen one.
- [ ] **U3 — downloader + staging** (pure V, both platforms): stream to
  `os.File` while the digest accumulates, cap against `body_expected_size`
  *and* observed bytes, stage under `os.temp_dir()`. Progress reaches the
  page through U0.
- [ ] **U4 — the service**: the state machine (`idle`/`checking`/`available`/
  `downloading`/`verifying`/`ready`/`up-to-date`/`error`), commands
  `updater.{is_supported,state,check,download,apply,skip,skipped_version}`,
  events `updater:*` in the repo's own vocabulary (not Wails'
  `wails:updater:*`), `updater.default_html()` (the framework's look, app's
  own window), the `vails.json` `updater` block, the persisted skip state
  behind a seam a future `store` can take over, and a `doctor` warning for a
  granted updater with no repository or no public key.
- [ ] **U5 — the swap + helper mode** (the only native part):
  `swap_plan(target, staged, stamp) ![]SwapStep` as a **pure function** so the
  dangerous sequence is asserted as a value and only one test moves bytes;
  `updater.helper_entry() bool` as line 1 of `main()` (no `application.New`
  to hide it in yet — recorded as a known cost); abort untouched if the
  parent PID does not exit in time; restore the backup if the relaunch fails;
  a result file surfaces a failed swap on the next launch instead of a
  parent handshake. One `vails_updater_*` C shim: `os.Process` has no `run`,
  so the detached spawn is `CreateProcessW`/`posix_spawn`.
- [ ] **U6 — the CLI**: `vails updater genkey|manifest|verify`, calling the
  *same* `updater_manifest.v` builder the service parses with so the format
  has one writer; `verify` is the CI gate. **Version stamping moved out of
  this item into B0 of the build & release track** (2026-09-29): CI needs it
  before any of this exists, both need it exactly once, and one shared
  implementation that lands first is the point.
- [ ] **U7 — the proof**: `examples/updater` + the e2e READMEs. The chain is
  proven against a **loopback `net.http` fixture server** (the repo already
  depends on `net.http`, ADR-0013, so this stays gcc-free) — no network, no
  GitHub repo, no token, no human — including the two negative tests that
  matter: one flipped byte in the artifact must fail the digest, one flipped
  byte in the signature must fail the verify. Then `tests/swap/`: two builds
  of a tiny two-version program through the real helper path, asserting the
  bytes changed and the relaunch reported v2.

Order: U0 → U1 → U2 → U3 → U4 → U5 → U6 → U7, after Phase 5b, before Phase 7.
Nothing here is a macOS commitment; Phase 6 first. Linux is not blocked —
`v test .` is 32/32 there and the app builds, so U7's Linux entries are added
evidence rather than an unblocking. ~14 focused days, which does **not** fit
the "~2 focused weeks" currently claimed for S1 wave 4 + Phase 5b —
re-baselining the roadmap against that is an open decision in ADR-0020, not
something this track decides. Note also that W0 and U0 are the same work
(ADR-0019), and B0 gates U6. Per
AGENTS.md §3: no U-item starts while Phase 5 is the current phase. Each item:
code + tests on both OSes + short ADR update + checkbox.

## Distribution track (planned, not started — ADR-0024)

A Windows installer, an AppImage and a Flatpak — all generated from
`vails.json`, all in the build track's Linux container, and all agreeing about
who updates the app.

**The decision that governs the whole track: the packaging format decides who
updates the app.** ADR-0020 swaps the running binary with `os.rename`; on
Windows that needs write access to the install directory, so **an app under
`Program Files` cannot self-update without elevation** — per-user install is a
functional requirement, not a preference, and it is why Tauri and Electron
default to `%LOCALAPPDATA%\Programs`. On Linux the answer differs per format,
and shipping without deciding it produces an app that tries to update itself
inside a sandbox that will not let it. So `vails.json` gains
`bundle.update_channel` (`in_app` / `external` / `system`) and the `updater`
service reads it rather than guessing from the platform.

- [ ] **P0 — the update-channel policy** (independent of everything else, and
  decision-only): `bundle.update_channel` + config validation + `doctor`
  reporting the channel and who owns updates under it. On a Flatpak build the
  in-app updater is **refused at startup naming the reason**, because a
  framework that tries to self-update inside a sandbox is not helpful, it is
  broken, and the symptom is a silent no-op nobody can diagnose.
- [ ] **P1 — the Windows installer**: **Inno Setup**, per-user
  (`PrivilegesRequired=lowest`, `{localappdata}\Programs\<App>`), with the
  `.iss` **generated from `vails.json` in pure V** — `installer_script(cfg,
  version) string`, unit-tested on Windows with no compiler, for the same
  reason `vails dts` is: a hand-kept installer script drifts from the config
  that describes the app, and the drift is invisible until an upgrade leaves a
  stale DLL behind. The five side-by-side DLLs are listed from
  `bundle.windows_dll_side_by_side` (a field that has existed since T6 and has
  never been acted on), the uninstaller removes them, and an upgrade replaces
  them. **This also resolves ADR-0005's undecided static-vs-side-by-side
  question.** Depends on B1. WiX/MSI is recorded as rejected with its reason
  (a .NET toolchain, and a per-user install it cannot author).
- [ ] **P2 — the AppImage**: **hand-built `AppDir` and lightweight, and
  `linuxdeploy` is not used.** WebKitGTK is the hardest library to bundle and
  `linuxdeploy` is where the difficulty lives, not the format; building the
  `AppDir` directly (`usr/bin/<app>`, a `.desktop`, an icon, an `AppRun`) and
  running `appimagetool` with no extra libraries gives a ~20 MB artifact. The
  cost is honest and lives in the artifact's own metadata rather than a
  README: it needs `libwebkit2gtk-4.1-0` on the host. A fully self-contained
  AppImage (250–400 MB once ICU, GStreamer, pixbuf loaders and fonts come
  along) is a deliberate non-goal with the number attached.
- [ ] **P3 — the Flatpak**: a generated manifest over the GNOME runtime, which
  already contains WebKitGTK — so the artifact is a few hundred KB, sandboxed,
  and updated by `flatpak`. Not a consolation prize: for a GTK/WebKit stack
  this is the format that *solves* the dependency problem instead of shipping
  around it. The `.desktop`, the icon and the metadata are generated once and
  shared with P2. `deb` via `nfpm` joins here if it turns out to be the cheap
  one-file config the Phase 7 line suggests; `rpm` waits for someone to ask.
- [ ] **P4 — the updater honours the channel**: the last item of the self-
  updating track and the first consumer of this one, so the loop closes
  (ADR-0020's U5 + P0). No macOS artifact — Phase 6 has no backend, and a
  `.dmg` template for a platform Vails cannot build on is a wish, not a plan.
  Icons stay Phase 7 except as generated placeholders that prove the plumbing.

Order: P0 → P1 → P2 → P3 → P4. P0 is independent and can run at any time; P1
needs B1. ~8 focused days.

## Platform gaps + showcase track (ADR-0025/0035 — F0's routing shipped 2026-09-30, rest planned)

What a Vails app can do today that a Wails or Tauri sample app can, and what
it cannot. **"Better than every sample app" is a superlative with no
definition, so it is replaced by a checkable artefact:
`docs/COMPETITIVE-MATRIX.md`**, one row per capability, gathered 2026-09-29
with its confidence levels stated.

The answer came down to **two rows** — the only two gaps that are capabilities
of the *shell* rather than missing services. Every other row is an S2 service,
a small platform nicety, or a non-goal with a reason attached.

- [ ] **F0 — multi-window** (ADR-0035, landed in part 2026-09-30): the hard
  half is **done**, the window half is **written but unobserved**.
  `webview/window.v`
  has `Window`, `WindowRegistry` and `emit_to`, and `window_test.v` (21 tests)
  proves with two fake eval sinks that an event addressed to one window never
  reaches the other's, that an unknown label is refused **and nothing is
  delivered anywhere**, that a window which is not `ready` is refused by name,
  and that two windows may not share a label. `run_many` is the entry point, and
  `Config.on_window` hands the app the backend's own `&Window` so an app's
  registry routes through the same objects the backend does.
  - **That was the half the ROADMAP called "the half that is easy to get
    wrong"**, and it is now pinned by tests rather than by convention: the old
    shape (`ctx.emit` through one Ctx) could not be tested for it at all,
    because with one window there is no wrong window to reach.
  - **The window half is written; nobody has watched it work.** WebView2 binds
    the HWND, the COM apartment and the message pump to the thread that called
    `webview_create`, and `webview_run` blocks in that pump — so a second window
    needs a second thread, and a `spawn`ed thread has **no apartment at all**:
    measured, the second window *appears*, `webview_run` starts, and then the
    library **refuses a `webview_dispatch` to it**, after which the process
    dies. That is why the code used to refuse more than one window by name.
    `com_enter` in `webview_windows.c.v` now calls `CoInitializeEx(NULL,
    COINIT_APARTMENTTHREADED)` on each window's own thread before
    `webview_create`, and `CoUninitialize` after `webview_destroy`, and the
    refusal is gone. `com_enter`'s return value is what makes the third case
    honest: `RPC_E_CHANGED_MODE` means the apartment is **not** ours, so
    `com_leave` only balances when `>= 0`.
  - **So what is left is one run, and it is not optional bookkeeping.**
    `v vet webview` is green and `v fmt -l .` is clean, but this machine
    **crashes its host on the `webview` test module**, so the two-window run
    never happened here. `examples/multiwindow` with
    `VAILS_MULTIWINDOW_PROBE=pings` is the run that settles it, and a
    screenshot of both windows in `tests/e2e_windows/` is what turns ADR-0035
    from a claim into a record. Until then this item stays **unchecked**,
    which is the repo's own rule (AGENTS.md §5) rather than a judgement call.
  - **Linux is structurally done** — GTK is one process-wide main loop with any
    number of GtkWindows in it, so `webview_linux_shim.h` counts open windows
    and quits the loop when the last one closes (the single-window version
    called `gtk_main_quit` unconditionally, which is "closing the settings window
    quits the app" with two). Not run in a real session from this machine.
  - **Three V 0.5.2 bugs were found and measured getting here** and are recorded
    in AGENTS.md §2c: `or` does not run for a none `Option<&T>` (which made a
    lookup report that it had found something); a closure copies a `mut … &T`
    *parameter* by value; and `spawn` with a `mut … &T` parameter crashes or
    hangs. The last two are the same root cause, and the workaround for all
    three is a plain reference plus `unsafe`. Also found by a test written while
    landing this: **`jsesc.escape` does not escape `"`**, so a window label
    wrapped in double quotes was a script injection into every page — the label
    is now single-quoted and there are three escaping tests.
- [ ] **F1 — drag & drop**, the other row, and the `drop` service (ADR-0036,
  landed 2026-10-03): Wails ships `drag-n-drop`, Tauri ships `drag`, Vails had
  nothing, and for any app whose user has files on disk a window that will not
  accept a dropped file is a prototype. A `drop` service reports that a drop
  happened and what it carried; the page decides what to do — the same reasoning
  that made `opener` a capability-gated service with a scheme allowlist
  (ADR-0015), because the OS is being asked to act on something a page supplied.
  **The gating question is answered, and the answer decided the design**:
  `EnableWebDrop` is **not reachable**. The installed `webview` 0.12 header
  declares sixteen `WEBVIEW_API` functions and not one is about dropping,
  because `EnableWebDrop` is a WebView2 *host* setting on `ICoreWebView2Controller`
  and the library does not expose the controller. What is left is `WM_DROPFILES`
  on the HWND, which is a window message, which is what `webview/host.v` already
  delivers — so the seam is the mechanism, not an obstacle.
  - **The routing question F0 was blocking is answered by the seam itself** — it
    is per-window and each hook closes over that window's own `Ctx`, so a drop is
    reported to the page it landed on, with no new routing and no global "current
    window" to be ambiguous about. `drop.enable` / `drop.disable`, both
    capability-gated, neither taking params; one `drop:files` event carrying
    `{"paths":[…],"count":n}`.
  - **18 pure-V tests green on both platforms** — the bounds (64 paths, 1024
    chars, NUL rejected rather than truncated), the truncation order, the empty
    report, the payload round trip, and that a message which is not
    `WM_DROPFILES` is passed on even when its lParam would have looked like a
    handle.
  - **The price is stated rather than hidden: the page does NOT get the DOM's
    `dragover` / `drop`.** `DragAcceptFiles` on the top-level window takes the
    drop from WebView2's child, and there is no reachable alternative. The
    `vails doctor` line for `drop` carries this, because a service reporting
    only "ok" would be exactly the over-read this file's own rules forbid.
  - **Paths, never contents.** A page that wants a file's bytes has to be given
    a way to ask; that capability should be granted on its own rather than
    inherited by every window that can receive a drop.
  - **Linux is unwritten on purpose** (AGENTS.md §3.4, ADR-0015's lesson: no
    native code that has never been compiled, and there is no Linux runner
    here). Everything that is not native is done and tested; the gap is a
    `GtkDropTarget` and one function. `doctor` says "unwritten", not
    "unsupported", because only one of those is true.
  - **Still unchecked, and for the same reason as F0**: nothing has seen a human
    drag a file, because the Windows GUI proofs go through the `webview` module
    that crashes this host. The outstanding run is the six-step procedure in
    `tests/e2e_windows/README.md`; `examples/services` has no drop panel yet, so
    it is console calls until R4 gives every panel a screenshot.
- [ ] **R3 — `examples/showcase`** (ADR-0037, app written 2026-10-03): one
  multi-panel app, one panel per capability, each with a button, a status line and
  a **machine-checkable** verdict — the convention ADR-0014's clipboard round trip
  established, made into a badge. It **replaces `examples/services` as the E2E
  vehicle** rather than joining it; that example has outgrown its role by becoming
  seven probe modes behind `VAILS_SERVICES_PROBE`, and two vehicles is how
  `services.png` and `notification.png` once ended up byte-identical. A panel for a
  service that is a stub on this platform shows the platform's honest answer and
  never a fake (ADR-0018's discipline). The showcase is a **reference, not a
  template** — `vails init` keeps scaffolding the small `hello` app.
  - **The verdict vocabulary is the design**: `PASS` (exercised and *checked*),
    `NEEDS YOU` (works, only a human can finish it), `NOWHERE` (this build has no
    backend, said by `services.supports()` — never guessed from an error string),
    `FAIL`. A sticky tally counts all four, so one screenshot is a verdict on the
    whole framework.
  - **Two panels are inverted on purpose**, because their failure mode is
    silence: the capability gate and the opener's scheme allowlist **pass when the
    call is refused**.
  - **No probe modes and no auto-answer shim** — the dialog panel blocks the
    window and says `NEEDS YOU` while it does, which is also why a screenshot can
    never come out green by accident.
  - Verified: it builds, `vails doctor` reports `ok (1 window(s), 10
    capabilit(ies))` with all eight services, and the generated `.d.ts` carries
    the `drop` namespace with `DropFiles`. **Not verified: the page running** —
    no browser has executed this HTML, so the verdict logic is reviewed rather
    than observed, and R4 is what turns panels into screenshots. `multiwindow` is
    deliberately absent: it needs two windows, and a panel in a one-window window
    would be a lie by omission.
- [ ] **R4 — the machine-checkable half is DONE; the screenshots are not.**
  One screenshot per panel is still outstanding, and it is blocked on something
  that is now named rather than mysterious: `tests/e2e_windows/capture.vsh`
  compiles, returns correct exit codes and **prints nothing at all**
  (tests/e2e_windows/README.md opens with that, and with the four theories
  already ruled out). `capture.ps1` still works, so the capture path is not lost.
  - **PROVEN, and it found five bugs in the showcase on its first run** (below).
    A real transcript, Windows, 2026-10-03:
    ```
    bridge       PASS         demo.ping -> pong:vails
    caps         PASS         refused as expected: unknown method: app.not_granted
    osinfo       PASS         8 host facts
    clipboard    PASS         round trip: "vails showcase clipboard proof"
    notify       FAIL         RoGetActivationFactory(ToastNotificationManager) failed (hr=0x80040154)
    opener       PASS         refused as expected: bad params: opener: scheme "file" is not allowed
    menu         PASS         window menu bar installed - File / Help now open on the window
    post         PASS         demo:posted "from a worker thread"

    showcase: 7 pass, 0 need a human, 0 not on this platform, 1 fail, 3 of 11 panels never ran
    showcase: verify finished with exit code 1
    ```
    Seven capabilities verified on Windows, one line each, in a form a script can
    assert. **The remaining screenshot-per-panel capture is still outstanding** —
    it needs `capture.vsh`, which does not work — but the *checking* half of R4 is
    no longer downstream of it.
  - **The five bugs it found are the argument for having it**: the clipboard panel
    sent `{text}` where the service takes a bare JSON string; the os_info panel
    set its badge by hand and so **reported nothing at all**; `run("menubar")`
    painted a panel named `menubar`, which does not exist, so that card showed no
    "running" line; `IDLE` was counted as a verdict, which pushed the tally past
    11 and made "panels never ran" read 0; and `demo.finish` never closed the
    window. Four of the five were invisible to a human reading the window.
  - **Two open findings, named rather than guessed**:
    1. **`Ctx.close()` does not close a window on Windows.** It reports success —
       `webview_terminate` is reached and returns 0 — and `webview_run` never
       returns. So a verify run gets a **watchdog**: after 15 s it prints the
       report and ends the process itself. A harness that depends on the
       thing-under-test's shutdown cannot report a failure *of* that shutdown.
    2. **The WinRT toast fails with `hr=0x80040154`** (REGDB_E_CLASSNOTREG, the
       class is not registered). Candidate causes are an unregistered
       AppUserModelID for an unpackaged app and a session without the toast
       platform; this is **not yet attributed**, and the earlier
       `notification.png` proof does not settle it.
  - **The report logic is not unit-tested**, because it lives in `examples/` and
    `v test .` does not reach examples. Moving it into a framework module would
    be the wrong home for logic only this app uses; the verify run is its test.

Order: F0 → F1 → R3 → R4, after Phase 5b. **F0 reopens a decision ADR-0020
made** — that ADR rejected a framework-owned updater window because building
one was a phase-scale project, and that condition no longer holds. The
rejection is conditional, not withdrawn: until F0 ships the updater uses the
in-app UI, and the change is recorded rather than smuggled in. ~12 focused
days for F0+F1+R3+R4. Per AGENTS.md §3, no item starts while Phase 5 is the
current phase. Each item: code + tests on both OSes + short ADR update +
checkbox, and a row in `docs/COMPETITIVE-MATRIX.md` flipped from a plan
reference to `done` **with the ADR number** — a `done` with no ADR is not a
claim this repo can support.

## Native UI tier, data services, and Vinix (— D0 shipped per ADR-0034; N, D1—D3 and X planned)

Three more tracks, all added 2026-09-29 after the request for a V-native UI
backend, VML with an optional visual editor, V-written SQL and key-value
storage, and Vinix support. They are **three separate things**, not one
programme, and the reasons they are ordered the way they are are in the
priority table above.

### The findings that shaped them

- **`ui2` is three weeks old.** `vlang/ui2`: MIT, 62 stars, created
  2026-09-05, last pushed 2026-09-26 — and **not in this V installation's
  `vlib`**, so it arrives via VPM. Meanwhile the compiler half *is* present:
  `v.exe` contains `vml`, `ui2`, `Screen`, `Repeater`, `on_tap` and
  `bind.text`, and `doc/docs.md` documents `$vml` in a section of its own. The
  split is real, and it is why N0 starts by *installing* rather than writing.
- **`ui2` is not a third webview backend; it is a second kind of tier.** It has
  no page, no JS runtime, no DOM, no CSS — so a `ui2` app has **no
  `vails.call` and no `.d.ts`**, and `bridge/` and `assets/` become
  tier-1-only. It keeps `services/`, `capabilities`, `application`, `config`
  and `cli`. This is written down because a reader will otherwise expect the
  bridge to work and file a bug against a design that never promised it.
- **Both data libraries are pure V** (so gcc-free, per ADR-0013's rule) and
  **both are young**: `vlang/leveldb` is 9 stars / 2 months / BSD-2, and
  `elliotchance/vsql` is 346 stars but **last pushed 2025-02, 19 months ago**.
  The name `vsql` is ambiguous — `lydiandy/vsql` is an unrelated query
  builder — so the track names the one it means.
- **`vlang/vinix` is an operating system, not a UI toolkit**: 2,358 stars,
  GPL-2.0, pushed the same day this was written. Its flagship app `vlang/ved`
  has hardware-accelerated text rendering, so Vinix has *a* graphics stack —
  but whether it has a **webview** is unknown, and that single unknown decides
  whether a Vinix port is tractable or is a different product.

### Track N — native UI tier (`ui2` + VML + optional visual editor)

- [ ] **N0 — spike, gates the track.** Three questions, none answerable from
  documentation: does `ui2` build on Windows and Linux; what does it need for
  its window and event loop; and **what does a Vails service do in a tier with
  no `webview.Ctx`** to parent native UI to or emit events into. The third is
  the one that matters. ~3 d
- [ ] **N1 — `ui_tier: "webview" | "native"`** in `vails.json`, default
  `webview`, with `webview.backend` (`os_webview` | `chromium`) nested
  underneath — so the C-track's durable `Config.backend` seam is reused rather
  than duplicated, and `ui2` joins the same family. `native` **means** "no
  bridge, no dts", and the tier table is made explicit in the code. The two
  tiers are **not mixed in v1**: `window` and `tray` both hang off one window's
  HWND and `ui2` builds its own windows. ~2 d
- [ ] **N2 — the service bridge**: prove the shipped services work in a native
  tier, with `ctx`-free fallbacks where a service genuinely needs a window
  handle. Cheapest possible place to discover that one of them does not. ~3 d
- [ ] **N3 — VML**: one worked `.vml` example with `bind.*` / `on_tap` and a
  `Repeater`, plus **a pure-V test that the compiled output equals the
  hand-written equivalent**. `$vml` is compile-time, so the editor question
  answers itself: a visual editor is a *file manipulator*, not a runtime
  inspector, and its output is the same text a person would have typed. Editor
  and hand-authoring stay one language by construction, not by discipline.
  ~3 d
- [ ] **N4 — the visual editor**, a separate optional V tool operating on those
  same files, and **not before N3** — an editor that invents a format the
  compiler does not then accept is throwaway work. ~8 d

### Track D — data services (`store` + `sql`)

- [x] **D0 — the security decision, as code** (done 2026-09-29, ADR-0034).
  The paragraph below was the plan; what shipped is `sqlreg/`, the same
  policy with tests. **The `sql` service never takes SQL text from a page.**
  The frontend names a query, V owns the statement, an unregistered name is
  an error *naming the registry*, and multiple statements are refused
  regardless. A database service is the one capability where "the page asked
  nicely" is not a security model - the same argument that gave `opener` a
  scheme allowlist (ADR-0015) and put scoped `fs` last and riskiest. Both
  are **services, not plugins**, and that question was already answered by
  ADR-0014/0015: the manifest, the install path, the capability gate,
  `*_support()` and `.d.ts` are inherited.

  **Why it is code and not the paragraph it came from.** A policy that lives
  only in prose gets quietly widened the first time a feature needs an
  exception, and the exception is one line. What `sqlreg` makes
  unarguable, in 14 tests: SQL text sent as a "query name" never resolves
  (`test_sql_text_from_a_page_is_not_a_query_name`); multiple statements are
  refused **at registration**, so a statement that could smuggle a second
  one is never in the registry at all; the semicolon count is deliberately
  conservative, so `'a;b'` is refused — a false positive costs an author a
  visible workaround and a false negative is the vulnerability; parameter
  *values* are bounded, because a bound on the statement is not a bound on
  the value; a named parameter the statement does not contain is refused;
  `resolve_read` is a separate function from `resolve` so a read-only grant
  cannot reach a write by naming it; and the registry has **no mutating entry
  point at all**, which is the threat model rather than an oversight.

  No `sql` service manifest ships with it, on purpose: a manifest would make
  `vails dts` promise `sql.exec` before there is a database behind it, which
  ADR-0025 calls worse than no service. D3 adds `vsql` against this seam.
- [ ] **D1 — `store`**, promoted out of S2: one durable key-value surface with
  a **swappable engine behind a seam**, default a **JSON file** (the data is
  config-shaped, a few KB, no dependency, gcc-free, and the file stays
  inspectable — a real property, not a nicety). A KV store is a few hundred
  lines, so Vails writing it is not a compromise. `state.AppState` is
  untouched: in-memory session state and durable storage are different
  lifecycles and merging them is the rejection recorded in ADR-0030. ~3 d
- [ ] **D2 — the LevelDB engine**, opt-in, with its maturity recorded (9 stars,
  2 months). Right engine for data that outgrows a JSON file; **not** what a
  framework's default persistence should rest on. ~2 d
- [ ] **D3 — the `sql` service** on `elliotchance/vsql` (pure V, gcc-free, so
  the Windows suite stays green without gcc), with the 19-month gap since its
  last push recorded as a risk rather than waved away. `vsql` is **consumed,
  not written** — a key-value store is a few hundred lines and an SQL engine
  is a different order of problem, and one already exists. ~4 d
- **Sequencing note:** ADR-0020's updater keeps its private JSON file for the
  skipped version and does **not** wait for D1 — the file is the seam D1 later
  absorbs. D1 after U4, not before.

### Track X — Vinix as a target platform

- [ ] **X0 — a three-question spike, and the whole deliverable.** Does Vinix
  have a compositor? Does it have a window API V can call? **Does it have a
  webview?** The third decides everything: a webview makes Vinix a fourth
  `webview/` backend and tractable; no webview makes it a `ui2` native-tier
  app or a headless service, which is a different product and should be called
  that. Same pattern as the C-track's C0, because a week of throwaway code
  that answers the question the design depends on beats a month of design
  assuming one. **X0 depends on nothing** and is why it is scheduled early.
  ~3 d
- [ ] **X1 — only if X0's third answer is yes.** `webview/host_vinx.c.v`,
  `run_vinx` dispatch, a `*_support()` answer per service, an E2E proof in a
  Vinix VM. ~5 d, not scheduled. A `doctor` probe for Vinix arrives with X1
  and not before — reporting a platform with no backend would be reporting our
  own backlog. GPL-2.0 is recorded because GPL governs the OS, not
  applications built to run on it, and the answer belongs in an ADR rather
  than a thread.

### The C track gets a horizon, and a warning

- [ ] **C5 — the `vox` horizon. No code, on purpose.** A V-written browser
  engine replacing Chromium is a *condition*, not a task, and the condition
  **is not met**: no such engine was findable in the vlang org, in a GitHub
  search, or on the web this session. So C5 exists to say that, and to say
  what happens when it is met.
- **C2/C3 are marked disposable, deliberately.** C1 (`Config.backend`
  dispatch) is durable — it is where a future engine lands, and ADR-0031
  reuses it. C2/C3 (actually embedding CEF) are 20+ days of work that a V
  browser engine would **delete**. They are no longer scheduled on faith; a
  decision to spend them waits on a `vox` signal. A framework that spent six
  weeks binding Chromium and then threw it away would have had those six
  weeks back if this line had been written when the C track was.

Order: **X0 and D0 and B5 can start immediately** (independent, and the first
two are the two questions everything else waits on). Then N0 → N1 → N2 → N3,
with N4 last. D1 → D2 → D3. X1 only on a yes from X0. Per AGENTS.md §3 no
item starts while Phase 5 is the current phase. Each item: code + tests on
both OSes + short ADR update + checkbox.

## Examples track (vanilla, no UI framework)

Bar: system type scale, spacing rhythm, `focus-visible`,
light+dark via `prefers-color-scheme`, LTR English. Each example:
`main.v` + `vails.json` minimal grants + `frontend/` + preview fallback
(runs outside a Vails window, like hello) + e2e README lines.
No example starts before the service it needs.

- [x] **E0 — Conventions** (done 2026-09-27, ADR-0014): the bar is
  carried by `examples/dialog` — system type scale, 4px spacing rhythm,
  `focus-visible` on every control, light+dark via
  `prefers-color-scheme`, LTR English, one column, and a preview
  fallback that degrades visibly outside a Vails window.
- [ ] **E1 - todo** (after T4; later persisted via `store`)
- [ ] **E2 - pomodoro** (after `notification` S1 — the service exists now;
  live tick via the T3 channel)
- [x] **E3 - clipboard-notes** (partially unblocked: `clipboard` is
  E2E-proven on both platforms, so the *service* is ready; the example
  waits for `store` to make "notes" worth building)
- [ ] **E4 - files-mini** (after the GTK `dialog` + `scoped fs`)
- [ ] **E5 — capture-demo** (after `screencapture`)
- [ ] **E6 — settings** (after `window-state` + `store`)

CLI templates (`init --template todo|pomodoro`) land in Phase 4/7,
not before.

## Out of scope

Porting Wails' Go toolchain helpers (`menumanager`, `winres`, `icns`,
`go-git`-based templates, `staticanalysis` on `x/tools`): replaced by V
idioms or dropped — never translated.

Struck on 2026-09-29, with the reason kept:

- **`sql`** — was deferred as a Tauri-plugin gap. Reversed: `elliotchance/vsql`
  is a transactional SQL database written in **pure V** (MIT, 346 stars), so
  it costs no C dependency and keeps the Windows test suite gcc-free
  (ADR-0013's rule, and the reason `veb` was rejected for `net.http` in the
  first place). It becomes the D3 service, with one hard rule: the frontend
  names a query, V owns the SQL text. See ADR-0032.
- **`stronghold`** — **stays out of scope**, and for the same reason
  `vlang/leveldb` is an optional engine rather than a second `store`: S2's
  `keychain` covers secrets through the OS keychain behind it, which is a
  different job from persistence. Two overlapping surfaces is the mistake
  ADR-0030 just undid one layer up.
