# Vails — Desktop apps with V + Web technologies

Wails-inspired, V-native, with ideas borrowed from Tauri.
**Not** a line-by-line port of [wailsapp/wails](https://github.com/wailsapp/wails):
Wails v2 (stable) and v3 (beta) are used as a **design guide**, while the
implementation is idiomatic V — and improves on both Wails and Tauri where
V is stronger (sub-second builds, `v -live`, `veb` livereload, a single
binary, direct C interop with zero COM code on our side).

> Status: Phases 0–2 E2E ✅ on **Windows** (Edge/WebView2) and **Linux**
> (WebKitGTK) — screenshots in `tests/e2e_windows/` and
> `tests/e2e_linux/run_headless.sh`. macOS comes in Phase 6, mobile is
> planned (see ROADMAP).

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
- JSON-RPC bridge (`bridge/`), two-way event bus (`events/`), JS escaping
  (`jsesc/`), asset serving with traversal protection (`assets/`), `.d.ts`
  generation (`generator/`), native service stubs (`services/`)
- Planned next: capabilities (T1), `vails.json` (T6), mobile (M0–M4) —
  see ROADMAP.md

## Comparison

|  | Wails (v2/v3) | Tauri (v2) | Vails (this repo) |
|---|---|---|---|
| Backend language | Go | Rust | V |
| Web engine | OS native (WebView2/WKWebView/WebKitGTK) | OS native (wry) | OS native (webview lib / WebKitGTK) |
| App model | Single window + services (v3) | Multi-window + labels | Single window ✅ / multi-window (planned) |
| JS → backend | Bound methods, reflection-based | `invoke` commands (typed) | Bound methods, explicit registration ✅ |
| Backend → JS | Events | Events + channels | Events ✅ / channels (planned) |
| Security model | Open bridge | Capabilities + permissions + scopes | Capabilities (planned, T1) |
| Services/plugins | Built-in services (v3) | 30+ plugins | Service stubs ✅ / plugin manifests (planned, T5) |
| Mobile | v3: Android ✅ / iOS ✅ | Android + iOS | Planned (M0–M4, ADR-0006) |
| Config file | `build/config.yml` (v3) | `tauri.conf.json` | `vails.json` (planned, T6) |
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
| `services/` | Native services (clipboard stub → plugin manifests in T5) |
| `generator/` | `.d.ts` generation for bound methods |
| `capabilities/` | Per-window command allowlists (planned, T1) |
| `mobile/` | Mobile entry + no-op stubs (planned, M0) |
| `cli/` | `vails init/run/build/doctor` |
| `examples/hello/` | Minimal app (window + ping button) |
| `tests/e2e_windows/` | Manual Edge E2E + proof screenshot |
| `tests/e2e_linux/` | Headless xvfb script + screenshot |
| `docs/ADR/` | Architecture decisions (why, not what) |

## Quick start

Windows (MSYS2 ucrt64 with `mingw-w64-ucrt-x86_64-webview`):

```sh
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v test .                                     # unit tests, all green
v -cc gcc -o hello.exe ./examples/hello
# copy next to hello.exe: libwebview-0.12.dll, WebView2Loader.dll,
# libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll
./hello.exe                                  # click "ping backend" -> "pong"
```

Linux / WSL Ubuntu (`libgtk-3-dev libwebkit2gtk-4.1-dev`, V from source):

```sh
v test .                                     # unit tests, all green
v -gc none -o hello ./examples/hello        # -gc none is required (ADR-0005)
./hello
```

## Docs for humans and agents

- `AGENTS.md` — workflow contract (read first)
- `CONTEXT.md` — domain model
- `ROADMAP.md` — phases + Tauri-inspired track (T1–T7) + mobile track (M0–M4)
- `docs/ADR/` — why-not-what decisions
