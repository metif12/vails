# Vails — Desktop apps with V + Web technologies

Wails-inspired, V-native, with ideas borrowed from Tauri.
**Not** a line-by-line port of [wailsapp/wails](https://github.com/wailsapp/wails):
Wails v2 (stable) and v3 (beta) are used as a **design guide**, while the
implementation is idiomatic V — and improves on both Wails and Tauri where
V is stronger (sub-second builds, `v -live`, `veb` livereload, a single
binary, direct C interop with zero COM code on our side).

> Status: Phases 0–4 E2E ✅ on **Windows** (Edge/WebView2) and **Linux**
> (WebKitGTK) — screenshots in `tests/e2e_windows/` and
> `tests/e2e_linux/run_headless.sh`. Phase 5 S1 wave 1 (the `dialog` and
> `os-info` services, the T5 manifest model, `vails dts`) is
> Windows-proven; macOS comes in Phase 6, mobile is planned (see ROADMAP).

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
  Windows E2E proof in `tests/e2e_windows/dialog.png`) and **`os-info`**
- Planned next: `notification`, native `clipboard`, `menu`, `tray`,
  `opener` (Phase 5 S1 wave 2), then the Linux backends (Phase 5b) —
  see ROADMAP.md

## Comparison

|  | Wails (v2/v3) | Tauri (v2) | Vails (this repo) |
|---|---|---|---|
| Backend language | Go | Rust | V |
| Web engine | OS native (WebView2/WKWebView/WebKitGTK) | OS native (wry) | OS native (webview lib / WebKitGTK) |
| App model | Single window + services (v3) | Multi-window + labels | Single window ✅ / multi-window (planned) |
| JS → backend | Bound methods, reflection-based | `invoke` commands (typed) | Bound methods, explicit registration ✅ |
| Backend → JS | Events | Events + channels | Events ✅ / channels ✅ (T3) |
| Security model | Open bridge | Capabilities + permissions + scopes | Capabilities ✅ (T1) + service commands as grant names |
| Services/plugins | Built-in services (v3) | 30+ plugins | Service manifests + first services ✅ / dialog, os-info (T5, ADR-0014) |
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
| `services/` | Services as plugin manifests (T5 ✅, ADR-0014) + `install` path; `dialog` (Windows native), `os_info`, `clipboard` seam |
| `generator/` | `.d.ts` generation for bound methods; `vails dts` drives it from service manifests |
| `capabilities/` | Per-window command allowlists (T1 ✅, ADR-0007) |
| `config/` | `vails.json` project config: windows, capabilities, asset root, bundle (T6 ✅, ADR-0008) |
| `mobile/` | Mobile entry + no-op stubs (planned, M0) |
| `cli/` | `vails init/run/build/doctor/dts` |
| `examples/hello/` | Minimal app (window + ping button) |
| `examples/dialog/` | Two services in one window (native dialogs + os-info) |
| `tests/e2e_windows/` | Manual Edge E2E + proof screenshot |
| `tests/e2e_linux/` | Headless xvfb script + screenshot |
| `docs/ADR/` | Architecture decisions (why, not what) |

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

`vails doctor` looks for the header at
`C:/msys64/ucrt64/include/webview/webview.h` — if it reports MISSING, the
`pacman` step above is what fixes it.

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

`v test .` never opens a window. GUI checks stay manual — see
`tests/e2e_windows/README.md` and `tests/e2e_linux/README.md`.

## Create a new project

The `vails` CLI is minimal on purpose (full scaffolding arrives with Phase 4).
Today it does five things: `version`, `doctor` (incl. `vails.json` validation),
`init` (scaffolds `main.v` + `vails.json`), and config-validating `run`/`build`
dry-runs (real dev-server run is Phase 3, packaging is Phase 7).

```sh
# 1. build the CLI (from the repo root)
v -o vails ./cli

# 2. sanity checks
./vails version
./vails doctor
#   v version : check with `v version` (need 0.5.x)
#   os        : windows | linux | ...
#   on Linux  : webkit2gtk version or MISSING + apt hint
#   on Windows: gcc version + webview.h found/MISSING + pacman hint
#   vails.json: ok | INVALID + reason | not found (optional here)
#   services  : which services the capabilities grant (T5)

# 3. scaffold a minimal app (default name: hello)
./vails init myapp
ls myapp                                     # contains main.v + vails.json
./vails run --config myapp/vails.json        # dev server + window at its URL
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
    services.install_dialog(mut router, ctx) or { eprintln(err.msg()) }
}
webview.run(router: &router, registry: cfg.to_registry(), html: html, on_ready: on_ready)!
```

`v test .` never opens a window and never opens a native dialog: modal
services are the documented exception to the "handlers stay fast" rule
(ADR-0014), and a test that triggers one would block on a window nobody
can click.

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
service reports `not implemented` until Phase 5b; `os_info` works
everywhere.

## Development workflow

Read `AGENTS.md` first — it is the workflow contract. The short version:

```sh
v fmt -w .        # format before every commit (law, no debates)
v test .          # must be green (Linux GUI tests stay manual)
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
| `dialog.*` says `not implemented` on Linux | Expected until Phase 5b; the Linux backend is an explicit stub | ROADMAP Phase 5b |
| Linux GUI crash / GC fork errors | Always build GUI apps with `-gc none` | ADR-0005, `examples/hello/main.v` header |
| Black/blank window under Wayland | `unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11`, `WEBKIT_DISABLE_COMPOSITING_MODE=1` | `AGENTS.md §1`, `run_headless.sh` |
| `frontend/index.html not found` | Run from the repo root or the example dir so `load_frontend_html` finds its candidates | `examples/hello/main.v` |

## Docs for humans and agents

- `AGENTS.md` — workflow contract (read first)
- `CONTEXT.md` — domain model
- `ROADMAP.md` — phases + Tauri-inspired track (T1–T7) + mobile track (M0–M4)
- `docs/ADR/` — why-not-what decisions
- `tests/e2e_windows/README.md`, `tests/e2e_linux/README.md` — manual GUI proofs
