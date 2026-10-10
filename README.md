# Vails — Desktop apps with V + Web technologies

Wails-inspired, V-native, with ideas borrowed from Tauri.
**Not** a line-by-line port of [wailsapp/wails](https://github.com/wailsapp/wails):
Wails v2 (stable) and v3 (beta) are used as a **design guide**, while the
implementation is idiomatic V — and improves on both Wails and Tauri where
V is stronger (sub-second builds, `v -live`, `veb` livereload, a single
binary, direct C interop with zero COM code on our side).

> Status: Phases 0–4 E2E ✅ on **Windows** (Edge/WebView2) and **Linux**
> (WebKitGTK) — screenshots in `tests/e2e_windows/` and
> `tests/e2e_linux/`. Phase 5 S1 waves 1–3 are shipped
> (ADR-0014/0015/0017): the `dialog`, `os-info`, `clipboard`, `opener`,
> `notification`, `menu` and `tray` services with real Windows backends
> (including the window host seam, the first OS-initiated events in Vails),
> Linux backends for `clipboard` + `opener` + `menu` + `tray`, the
> grant-driven `.d.ts`, and `vails doctor` reporting which backends are
> native here. macOS comes in Phase 6, mobile is planned (see ROADMAP).

## Ideas & features

**From Wails** — native backend without bundling a browser engine; unified
bindings, events and asset serving; a small `vails` CLI (`init/run/build/
doctor`) in the spirit of the `wails` CLI.

**From [Tauri](https://github.com/tauri-apps/tauri)** — a capabilities model
(per-window command allowlists, asset scope, platform filtering); a strict
command-vs-event IPC contract; services shaped as plugins with manifests;
a `vails.json` project config; secure frontend defaults (CSP, no API outside
a Vails window).

**Better than both, thanks to V** — full rebuilds in about a second,
`veb` browser livereload in dev mode, one self-contained binary, and C
interop so thin that the Windows backend needs no COM code at all (the
`webview` library owns the WebView2 lifecycle).

Current state (all verified, not promised):

- Window + WebView on Windows and Linux, HTML rendering proven by screenshot
- JS → V → JS round trip: `window.vails.call('ping')` → V handler → `pong`
- V → JS events: `webview.Ctx.emit` (services push results/events back)
- JSON-RPC bridge (`bridge/`), two-way event bus (`events/`), JS escaping
  (`jsesc/`), asset serving with traversal protection (`assets/`), a dev
  server with livereload (`dev/`), the `vails` CLI (`cli/`), and
  services as plugin manifests (`services/`, T5) with grant-driven
  `.d.ts` generation (`vails dts`)
- Services: **`dialog`** (native file picker / save dialog / message box —
  Windows E2E proof in `tests/e2e_windows/dialog.png`), **`os-info`**,
  **`clipboard`** (Windows + Linux, E2E round trip on both —
  `tests/e2e_windows/services.png`, `tests/e2e_linux/services.png`),
  **`opener`** (Windows + Linux, with a scheme allowlist),
  **`notification`** (Windows: a real WinRT toast — a proper Action Center
  notification carrying the app's own name, with `is_supported` so a
  frontend can ask first and a documented `bundle.identifier` as its
  AppUserModelID; compile-verified, runtime proof pending — see
  `docs/ADR/0018`), **`menu`** (native popup on both platforms; the
choice arrives as an event, never as the command's result) and
  **`tray`** (Windows: a shell icon whose click reaches V through a comctl32
  subclass - `webview/host.v` - and arrives as `tray:clicked`; proven end to end
  by the E2E script's `PostMessage` → subclass → `tray:clicked` check, which is
  in `tests/e2e_windows/README.md` - no screenshot of it is committed, though an
  earlier version of this line cited one)
- `v test .` green on **Windows and Linux**, **44 test files each** (measured
  2026-10-05; the Linux run was the first this project ever had, and it is what
  found three real cross-platform defects - see `ROADMAP.md`)
- Landed since: the window menu bar (`menu.set_menu`, ADR-0023), the tray menu
  (`tray.set_menu`, ADR-0026) and the GTK `dialog` (ADR-0027)
- **The build track landed 2026-09-29 (ADR-0034)**: `vails build` produces a
  binary that *starts* (it stages the five side-by-side DLLs that used to be
  only a README comment), `--version` stamps it, a `Dockerfile` + a first
  matrix CI exist, `vails.json` gains a `dependencies` block with
  `vails.lock`, and the `sql` security policy is code (`sqlreg`) rather than
  prose. Six corrections came out of it, four of which are in `AGENTS.md` §2b
  because they will bite the next contributor.
- Planned next: `notification` on Linux, then `post_to_main` (U0/W0) — see
  ROADMAP.md

## Comparison

|  | Wails (v2/v3) | Tauri (v2) | Vails (this repo) |
|---|---|---|---|
| Backend language | Go | Rust | V |
| Web engine | OS native (WebView2/WKWebView/WebKitGTK) | OS native (wry) | OS native (webview lib / WebKitGTK) |
| App model | Single window + services (v3) | Multi-window + labels | Single window ✅ / multi-window (planned) |
| JS → backend | Bound methods, reflection-based | `invoke` commands (typed) | Bound methods, explicit registration ✅ |
| Backend → JS | Events | Events + channels | Events ✅ / channels ✅ (T3) |
| Security model | Open bridge | Capabilities + permissions + scopes | Capabilities ✅ (T1) + service commands as grant names |
| Services/plugins | Built-in services (v3) | 30+ plugins | Service manifests + 7 services ✅ / dialog, os-info, clipboard, opener, notification, menu, tray (T5, ADR-0014/0015/0017) |
| Mobile | v3: Android ✅ / iOS ✅ | Android + iOS | Planned (M0–M4, ADR-0006) |
| Config file | `build/config.yml` (v3) | `tauri.conf.json` | `vails.json` ✅ (T6) |
| Build speed | Go toolchain (tens of seconds) | Rust/cargo (minutes) | V + gcc (≈ seconds) ✅ |
| Binary size story | Single Go binary | ~600KB minimal | Single V binary ✅ |
| License | MIT | Apache-2.0 / MIT | MIT |

## Layout

| Path | What |
|---|---|
| `application/` | `App` + `AppOptions` (cf. Wails `v3/pkg/application`) |
| `webview/` | Pure-V facade + `webview_windows.c.v` (Edge) + `webview_linux.c.v` (WebKitGTK) + `webview_shim.h` |
| `bridge/` | JSON-RPC dispatch: JS calls V methods (`handle_message`, `runtime_js`, `runtime_js_bound`) |
| `events/` | Two-way event bus (JS <-> V) + `to_js` snippets |
| `jsesc/` | JS string-literal escaping shared by bridge/events |
| `assets/` | Asset serving with traversal protection; `$embed_file` prod / `veb` dev (Phase 3) |
| `services/` | Services as plugin manifests (T5 ✅, ADR-0014) + `install` path + `support` (per-OS backend report for `doctor`); `dialog` (Windows native), `os_info`, `clipboard` + `opener` + `menu` + `tray` (Windows + Linux), `notification` (Windows) |
| `generator/` | `.d.ts` generation for bound methods; `vails dts` drives it from service manifests |
| `capabilities/` | Per-window command allowlists (T1 ✅, ADR-0007) |
| `config/` | `vails.json` project config: windows, capabilities, asset root, bundle (T6 ✅, ADR-0008) |
| `buildinfo/` | The app's build identity: `-d vails_version=` stamping, SemVer validation, the framework version and `v.mod` drift (B0 ✅, ADR-0034) |
| `buildplan/` | What `vails build` runs and stages, as a value — flags, output name, the five side-by-side DLLs — with the target as an argument so a Linux recipe is asserted on a Windows run (B1 ✅, ADR-0034) |
| `deps/` | The `dependencies` block + `vails.lock`: Vails declares and reports, VPM resolves (B5 ✅, ADR-0034) |
| `sqlreg/` | The `sql` security policy as code: a page names a query, V owns the statement (D0 ✅, ADR-0034) |
| `mobile/` | Mobile entry + no-op stubs (planned, M0) |
| `cli/` | `vails init/run/build/doctor/dts/deps` |
| `examples/hello/` | Minimal app (window + ping button) |
| `examples/dialog/` | Two services in one window (native dialogs + os-info) |
| `examples/multiwindow/` | Two windows, one document, `emit_to` routing by label (F0, ADR-0035) |
| `examples/showcase/` | **The reference**: one panel per capability, four honest verdicts, one tally (R3, ADR-0037) |
| `examples/services/` | Seven services in one window + the E2E probe vehicle (superseded as the vehicle by `showcase`, kept for its probes) |
| `tests/e2e_windows/` | Manual Edge E2E + proof screenshot |
| `tests/e2e_linux/` | Headless xvfb script + screenshot |
| `docs/ADR/` | Architecture decisions (why, not what) |
| `CHANGELOG.md` | Per-release changelog (Keep a Changelog) |

## Prerequisites

| Need | Windows | Linux / WSL Ubuntu | Notes |
|---|---|---|---|
| V | 0.5.x (`v version`) | 0.5.x, built from source (e.g. `/root/vsrc`) | `vails doctor` only checks the version string; GUI on Linux requires a source build |
| C toolchain | MSYS2 ucrt64 (`gcc --version` must work) | `gcc` + `pkg-config` | Windows: put `C:\msys64\ucrt64\bin` first on `PATH` in every terminal |
| Webview deps | `mingw-w64-ucrt-x86_64-webview` + `mingw-w64-ucrt-x86_64-webview2-loader` | `libgtk-3-dev libwebkit2gtk-4.1-dev` | Linux E2E also needs `xvfb` (`xwd`, `xwininfo` for screenshots) |
| Browser engine | Edge WebView2 Runtime (ships with Windows 10/11; install it on bare VMs) | WebKitGTK 4.1 (`pkg-config --modversion webkit2gtk-4.1`) | No bundled Chromium — the OS engine is used |
| Git | any recent Git | any recent Git | Needed to clone V and this repo |

Check your machine any time with the built-in doctor (see below). It reports
exactly these items: V version, OS, `webkit2gtk` on Linux, `gcc` + `webview.h`
on Windows.

## Install

### 1. Install V (0.5.x)

Follow the official V install guide, then verify:

```sh
v version                                    # need 0.5.x
```

On WSL Ubuntu the GUI path needs V built from source (the `-gc none`
requirement in ADR-0005 only holds for that setup).

### 2. Windows setup (MSYS2 ucrt64)

Run in PowerShell:

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
gcc --version                                # must print a ucrt64 gcc
```

If `gcc` is missing, install MSYS2 ucrt64 and its toolchain, then install the
webview packages inside the ucrt64 shell:

```sh
pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader
```

`vails doctor` looks for the header under the *resolved* toolchain root, whose
default is `C:/msys64/ucrt64` (so it looks at
`C:/msys64/ucrt64/include/webview/webview.h`). Set `VAILS_TOOLCHAIN` to move it —
the `toolchain` line reports the root and where it came from. If the header is
MISSING, the `pacman` step above is what fixes it.

Runtime DLLs are **not** linked statically. After every Windows build, copy
these next to the `.exe` (all from `C:\msys64\ucrt64\bin`):

- `libwebview-0.12.dll`, `WebView2Loader.dll`
- `libgcc_s_seh-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll`

### 3. Linux / WSL Ubuntu setup

```sh
sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev xvfb
pkg-config --modversion webkit2gtk-4.1      # must print a 4.1.x version
```

Headless runs (no desktop) additionally need:

```sh
unset WAYLAND_DISPLAY
export GDK_BACKEND=x11 WEBKIT_DISABLE_COMPOSITING_MODE=1
```

See `tests/e2e_linux/run_headless.sh` for the exact sequence (build with
`-gc none`, run under `xvfb-run`, screenshot with `xwd`).

### 4. Clone and verify

```sh
git clone <this-repo> vails
cd vails
v test .                                     # unit tests, all green, no windows opened
```

**On Windows with gcc the test command needs one flag, for the compiler, not for
the tests:**

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc test .    # 44 test files, `webview` included
```

The **reason** that flag is worth knowing: `dev/` imports `net.http`, V's
`dependency_scan_fallback` link path emits `#flag`-sourced `-l` flags *before*
most object files, and GNU `ld` only resolves an archive against the objects
that precede it — so `ws2_32` is on the link line and cannot resolve anyway. A
`#flag` in the importing module does not help (`-ldflags` is emitted last); see
ADR-0034 and `AGENTS.md` §1.

**But no link flag is needed today.** That paragraph is why the flags are
*version-scoped*, not because they are wrong: on the V master build this project
now requires (§1b of `AGENTS.md` — no released V can build it), `v -cc gcc test .`
and the CLI both link clean with no `-ldflags` and no `-cflags`, measured across
all 44 test files. If a build ever fails with `undefined reference to
__imp_connect` or `__WSAFDIsSet`, add `-ldflags "-lws2_32"` back rather than
hunting: `buildplan.cli_flags` still emits it precisely so that this stays a
version difference and not a mystery.

`v test .` never opens a window. GUI checks stay manual — see
`tests/e2e_windows/README.md` and `tests/e2e_linux/README.md`.

### Continuous integration

`.github/workflows/ci.yml` runs `v test .` plus a smoke build on both
platforms per push: Linux inside the repository's `Dockerfile` (V's own
`thevlang/vlang:ubuntu-build` image, GTK + WebKitGTK + AppIndicator, V
compiled once as a cached layer), Windows on a native runner with MSYS2
ucrt64. The Windows job's distinguishing step runs `vails build` and then
**asserts the five side-by-side DLLs are in the artifact directory** — a
green CI that ships an `.exe` which cannot start is worse than no CI. A
`v*` tag additionally triggers a version-stamped release build.

```sh
docker build -t vails-ci -f Dockerfile .
docker run --rm vails-ci                   # v test . inside the container
```

## Create a new project

The `vails` CLI is minimal on purpose. It does six things: `version`,
`doctor` (incl. `vails.json` validation), `init` (scaffolds `main.v` +
`vails.json`), config-validating `run`, a `build` that produces a binary
that **starts**, `dts` (grant-driven `.d.ts` + per-service JS) and
`deps` (the declared dependencies and how they compare to `vails.lock`).

```sh
# 1. build the CLI (from the repo root)
#    Windows + gcc 16 needs two extra flags: the CLI embeds the dev
#    server, so it imports net and links winsock.
v -o vails ./cli

# 2. sanity checks
./vails version
./vails doctor
#   v version : check with `v version` (need 0.5.x)
#   os        : windows | linux | ...
#   on Linux  : webkit2gtk version or MISSING + apt hint
#   on Windows: the resolved toolchain root (VAILS_TOOLCHAIN, default
#              C:/msys64/ucrt64) + gcc version + webview.h found/MISSING +
#              pacman hint, and how many of the 5 side-by-side DLLs are present
#   vails.json: ok | INVALID + reason | not found (optional here)
#   services  : which services the capabilities grant (T5)
#   backends  : which services have a NATIVE backend on this machine, and
#               which granted service is a stub here (ADR-0015)
#   deps      : what the dependencies block declares, and whether
#              vails.lock matches it
#   build     : whether THIS binary was stamped with a version. `dev`
#              means every update check is silently disabled (ADR-0034)

# 3. scaffold a minimal app (default name: hello)
./vails init myapp
ls myapp                                     # contains main.v + vails.json
./vails run --config myapp/vails.json        # dev server + window at its URL

# 4. build it - the five side-by-side DLLs are staged for you, and
#    --version stamps the binary so `buildinfo.version()` is not 'dev'
./vails build --config myapp/vails.json --version 1.0.0
./vails deps  --config myapp/vails.json     # declared vs. resolved
```

`vails init <name>` creates `./<name>/main.v` — a single-file window that
loads the project frontend. It is a starting point; for the fuller pattern
copy `examples/hello/` (bridge + handlers) or `examples/dialog/` (services
+ `on_ready` + generated `.d.ts`).

## Services (T5) and the generated `.d.ts`

A service is a manifest (`services/manifest.v`) plus a native backend, and
it registers through one path (`services.install`). Its commands **are**
its capability names, so a grant in `vails.json` is all a frontend needs:

```json
"capabilities": [
  { "id": "dialogs", "windows": ["main"], "commands": ["dialog.open", "dialog.save", "dialog.message"] }
]
```

```sh
./vails dts --config myapp/vails.json --js
# wrote myapp/frontend/vails.d.ts (1 service(s): dialog)
# wrote myapp/frontend/vails-services.js (load it from index.html)
```

The `.d.ts` is generated **from the grants**, so a TypeScript frontend can
only type-check what it was actually allowed to call; grant names that no
service provides (your own commands) are reported as such, not as errors.
`--check` prints instead of writing (CI). In the app, services are
installed from `Config.on_ready`, which is where the window handle a
service needs to parent its native UI to exists:

```v
mut router := bridge.new_router()
on_ready := fn [mut router] (ctx webview.Ctx) {
    services.install_clipboard(mut router, ctx) or { eprintln(err.msg()) }
    services.install_dialog(mut router, ctx) or { eprintln(err.msg()) }
}
webview.run(router: &router, registry: cfg.to_registry(), html: html, on_ready: on_ready)!
```

One field-name rule worth knowing before you write a service: a V struct
field name **is** the wire name (json2 drops keys it does not recognize, and
`@json:` attributes do not survive V's C codegen), so a manifest's `ts_types`
promise `default_path`, never `defaultPath`.

The built-in catalog today, and where each one actually works:

| Service | Commands | Windows | Linux |
|---|---|---|---|
| `dialog` | `open` / `save` / `message` | ✅ Common Item Dialog | ✅ GTK (ADR-0027) |
| `os_info` | `get` | ✅ pure V | ✅ pure V |
| `clipboard` | `read_text` / `write_text` | ✅ user32 | ✅ GTK clipboard |
| `opener` | `open_url` / `open_path` | ✅ `ShellExecuteW` | ✅ GIO (no `with`) |
| `notification` | `notify` / `is_supported` | ✅ WinRT toast (ADR-0018) | stub |
| `menu` | `popup` / `close` | ✅ `TrackPopupMenuEx` | ✅ `GtkMenu` |
| `tray` | `set` / `destroy` | ✅ `Shell_NotifyIconW` + click → `tray:clicked` | ✅ StatusNotifierItem (needs a tray host) |

`vails doctor` prints that same table for the machine you are on
(`backends : 7/7 service(s) native here` on Windows), and
`notification.is_supported` lets a frontend ask at runtime instead of firing
a notification that quietly does nothing.

`menu` and `tray` are the two services that are *driven by the OS* rather than
by the page (ADR-0017): a native menu choice and a tray click both arrive as
events — `menu:clicked` / `menu:canceled` and `tray:clicked` — and on Windows
they reach V through a comctl32 subclass the window host seam installs on
demand (`webview/host.v`), so an app that uses neither service never gets a
subclass on its window.

`v test .` never opens a window, never opens a native dialog or menu, and
never touches the real clipboard or tray: modal services are the documented
exception to the "handlers stay fast" rule (ADR-0014), and the clipboard is
shared machine state — its round trip is proven by `examples/services` instead.

Project config (`vails.json` with windows list, capabilities, asset roots,
bundle settings) is live (T6, ADR-0008): `vails init` scaffolds it,
`vails run`/`build` read it, `vails doctor` validates it.

## Run the hello example

Windows (PowerShell, MSYS2 ucrt64):

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o hello.exe ./examples/hello
# copy the 5 DLLs listed above next to hello.exe
./hello.exe                                  # click "ping backend" -> "pong"
```

Linux / WSL Ubuntu:

```sh
v test .                                     # unit tests first
v -gc none -o hello ./examples/hello        # -gc none is required (ADR-0005)
./hello
```

What success looks like: a 1024x768 window titled "Hello Vails", HTML
rendered, clicking "ping backend" changes the status to "backend says: pong"
(JS → V → JS round trip through `bridge.Router.handle_message`). Proof
screenshots live in `tests/e2e_windows/pong.png` and `tests/e2e_linux/`.

## Run the dialog example (services)

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o dialog.exe ./examples/dialog    # same 5 DLLs next to the exe
./dialog.exe
# "Open file…" / "Open several…" / "Save as…" -> real Windows dialogs,
# parented to the window; "Ask…"/"Confirm…" -> MessageBox; "Read host info"
# -> the os_info service; "Call an ungranted command" -> `forbidden: …`
```

`vails dts` regenerates `examples/dialog/frontend/vails.d.ts` from its
grants. `VAILS_DIALOG_PROBE=open|multi|save|message|host` makes the page
call that command on load — the E2E hook used for the proof below (a
synthetic click does not reach WebView2 content). On Linux the dialog
service is real as of ADR-0027 — a call made with no display is refused
with a message saying so, and `os_info` works everywhere.

## Run the services example (clipboard / opener / notification)

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o services.exe ./examples/services   # same 5 DLLs next to the exe
$env:VAILS_SERVICES_PROBE = "clipboard"         # or: opener | notification | none
./services.exe
```

The clipboard probe is the one worth running: it copies a fixed non-ASCII
string and pastes it back **without a human in the loop**, so the status line
is the whole round trip through the real Windows clipboard — proof in
`tests/e2e_windows/services.png`. `opener` reports what the shell said, and
`notification` asks `is_supported` before firing.

Linux (WSL Ubuntu, V at `/root/vsrc/v`):

```sh
cd /mnt/d/MyProjects/vails
VAILS_SERVICES_PROBE=clipboard sh tests/e2e_linux/run_services.sh
# builds with -gc none, runs under xvfb, screenshots to
# tests/e2e_linux/services.png
```

Same proof through the GTK clipboard (`tests/e2e_linux/services.png`), and
`VAILS_SERVICES_PROBE=notification` shows the honest Linux answer:
`not supported here - the service says so instead of doing nothing`
(`tests/e2e_linux/notification.png`).

On Windows, `tests/e2e_windows/capture.ps1 -Out shot.png -WindowTitle "Vails
Services Demo"` takes the screenshot and raises the window first — a shot of
a covered window proves nothing.

## Development workflow

Read `AGENTS.md` first — it is the workflow contract. The short version:

```sh
v fmt -w .        # format before every commit (law, no debates)
v test .          # must be green on Windows AND on Linux
```

Linux (WSL Ubuntu, the `v` there is not on `PATH`):

```sh
wsl -d Ubuntu -- /root/vsrc/v test .        # 45/45 as of 2026-10-05
wsl -d Ubuntu -- /root/vsrc/v -gc none -o services ./examples/services
```

Rules that matter daily:

- No globals. `pub` only what other modules need.
- Errors as values (`!T` + `or { }`). Never panic in library code;
  `panic`/`exit` is allowed only in `cli/` and `examples/`.
- C interop (`#include` + `fn C.*`) lives **only** in `*_linux.c.v`
  (later `_windows.c.v` / `_darwin.c.v`) files. Everything else is pure V
  and must compile and pass tests on Windows too (the CI machine has no
  gcc/pkg-config; `webview_linux.c.v` is skipped there by the `_linux`
  suffix rule).
- Cross-platform code goes behind the `webview/` facade;
  `application/`, `bridge/`, `events/` stay OS-agnostic.
- New native capability = new file under `services/` + test + ADR entry.
- Every change gets a line in `CHANGELOG.md` under `## [Unreleased]`.
- Work only inside the current phase's scope (`ROADMAP.md` checkbox); each
  phase ends with code + tests + a docs line.

## Troubleshooting

| Symptom | Fix | Ref |
|---|---|---|
| `vails doctor`: `webkit2gtk: MISSING` | `sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev` | `cli/vails.v`, `tests/e2e_linux/README.md` |
| `vails doctor`: `gcc: MISSING` (Windows) | Install MSYS2 ucrt64 toolchain, prepend `C:\msys64\ucrt64\bin` to `PATH` | `cli/vails.v` |
| `vails doctor`: `webview: MISSING` (Windows) | `pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader` | `cli/vails.v` |
| `hello.exe` exits silently / WebView2 error | Install Edge WebView2 Runtime; copy the 5 DLLs next to the exe | `tests/e2e_windows/README.md` |
| `services/` fails to build on Windows | It holds a `.c.v`: needs MSYS2 gcc (same as `webview/`). `v test ./services` fails without it | ADR-0014, `vails doctor` |
| `dialog.*` rejects with `forbidden:` | The capability in `vails.json` does not grant that command (names are `dialog.open`, …) | ADR-0007/0014 |
| `dialog.*` says `no display available` on Linux | The app has no `DISPLAY` (headless). GTK needs `gtk_init` first, so the service refuses with a message naming the cause rather than crashing | ADR-0027 |
| A right click on a tray icon with a menu attached stops emitting `tray:clicked` | That is the contract: the menu owns the right click. Apps that never call `tray.set_menu` are unaffected | ADR-0026 |
| `notification.notify` says `not implemented` on Linux | Expected: the Windows backend is a WinRT toast, which has no Linux equivalent yet. Ask `notification.is_supported` first — it answers `false` there | ADR-0015/0018, ROADMAP Phase 5b |
| `notification.notify` says `no app identity` | `vails.json` has no `bundle.identifier`, and a desktop app cannot raise a toast without an AppUserModelID. `vails init` scaffolds one; `vails doctor` warns about it too | ADR-0018 |
| `notification.notify` says `the Windows toast could not be shown (…hr=0x80040154)` | The machine has no WinRT runtime (a stripped/Server-style Windows image): `CLASS_E_CLASSNOTAVAILABLE`, so no WinRT class can be activated. Not a Vails bug — check for `C:\Windows\System32\Windows.Foundation.dll` | ADR-0018 |
| A page renders but every button is disabled ("preview mode") | `window.vails` was never injected: the bridge is not wired on this platform/build | ADR-0015 (the Linux transport was declared, not connected) |
| A Linux app fails to build with a `-Wincompatible-pointer-types` / implicit-declaration error | gcc 14+ treats those as errors; a V function pointer is not a WebKit callback, and some WebKit getters are not public in your version — read the installed headers | `webview/webview_linux_shim.h`, ADR-0015 Notes |
| A service's params arrive empty although the `.d.ts` type-checks | The wire names are the V field names: `default_path`, not `defaultPath` | ADR-0015, `dialog_test.v` |
| `vails doctor` shows a service as `stub` | It is honest: this platform has no backend for it yet (the note says which phase) | ADR-0015, `services/support.v` |
| A Linux build of `services/` fails on `app_indicator_*` | `sudo apt install libayatana-appindicator3-dev` (needed by the `tray` backend) | ADR-0017, `tests/e2e_linux/README.md` |
| The tray icon is installed but invisible on Linux | There is no StatusNotifierHost in a headless session; the item is registered, nothing draws it. `dbus-run-session` is also needed for the D-Bus registration | ADR-0017, `tray_support()` |
| A menu or tray answer never arrives | Both are *events*, not command results — listen for `menu:clicked` / `menu:canceled` / `tray:clicked` with `onEvent`. On Linux the tray has no click event at all (the host opens the item's menu) | ADR-0017 |
| `v test` on Linux hangs on a file that builds a `Backend` | A V 0.5.2 C-codegen problem with a closure inside a `map[string]fn` in a *test* build (the same code compiles in seconds in an app build) | ADR-0017 Notes, `tests/e2e_linux/README.md` |
| Linux GUI crash / GC fork errors | Always build GUI apps with `-gc none` | ADR-0005, `examples/hello/main.v` header |
| Black/blank window under Wayland | `unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11`, `WEBKIT_DISABLE_COMPOSITING_MODE=1` | `AGENTS.md §1`, `run_headless.sh` |
| `frontend/index.html not found` | Run from the repo root or the example dir so `load_frontend_html` finds its candidates | `examples/hello/main.v` |

## Docs for humans and agents

- `AGENTS.md` — workflow contract (read first)
- `CONTEXT.md` — domain model
- `ROADMAP.md` — phases + Tauri-inspired track (T1–T7) + mobile track (M0–M4)
- `CHANGELOG.md` — what changed, per release (Keep a Changelog)
- `docs/ADR/` — why-not-what decisions
- `tests/e2e_windows/README.md`, `tests/e2e_linux/README.md` — manual GUI proofs
