# AGENTS.md — Vails agent contract

Read this before writing any code. The project language is V (0.5.x).
Wails v2/v3 is a **design reference only** — never translate Go line-by-line
(there is no Go→V translator; only `c2v` for C exists).

## 1. Commands (run from repo root `vails/`)

```sh
v fmt -w .        # format before every commit
v test .          # must be green (Linux GUI tests stay manual, see tests/e2e_linux/)
```

Windows (MSYS2 ucrt64): prefix every build command with
`$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH` and use `-cc gcc`:

```sh
v -cc gcc -o hello.exe ./examples/hello
```

Linux (WSL Ubuntu, V built from source at /root/vsrc): GUI apps MUST use
`-gc none` (Boehm vs WebKit fork, ADR-0005); headless runs need
`unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11`,
`WEBKIT_DISABLE_COMPOSITING_MODE=1` — see tests/e2e_linux/run_headless.sh.

`webview_linux.c.v` compiles on Linux only (V `_linux` suffix rule).
All other modules must compile and pass tests on **Windows too** —
this repo's CI machine is Windows without gcc/pkg-config.

## 2. V style rules

- `v fmt` is law. One official style, no debates.
- No globals. `pub` only what other modules need; `pub mut` only for
  structs that `json.decode` must fill.
- Errors as values: `!T` + `or { }`. Never panic in library code;
  `panic` is allowed only in `cli/` and `examples/`.
- C interop: `#include` + `fn C.*` declarations live **only** in
  `*_linux.c.v` (or later `_windows.c.v` / `_darwin.c.v`) files.
  Redeclare the minimum signature surface you actually call.
- Prefer small pure-V modules with `_test.v` over clever code.
- New native capability = new file under `services/` + test + ADR entry.

## 3. Phase discipline

Current phase is tracked in `ROADMAP.md` (checkbox). Rules:

1. Work only inside the current phase's scope.
2. Each phase ends with: code + tests + docs line in `ROADMAP.md`.
3. Cross-platform code goes behind the `webview/` facade;
   `application/`, `bridge/`, `events/` must stay OS-agnostic.
4. When stuck on a native API, write the pure-V seam first and stub the
   native side with `error('not implemented on ...')`.

## 4. Wails reference map (where to look, not what to copy)

| Vails module | Wails guide |
|---|---|
| `application/` | `v3/pkg/application` (AppOptions, lifecycle) |
| `bridge/` | `v2/internal/binding` (method dispatch, JSON) |
| `generator/` | `v2/internal/typescriptify`, `v3/internal/generator` |
| `assets/` | `v2/pkg/assetserver`, `v3/internal/assetserver` |
| `cli/` | `v3/internal/commands`, `v2/pkg/commands` |
| `webview/` | `v2/internal/frontend`, `v3/internal/runtime` |
| `services/` | `v3/pkg/services`, `v3/internal/dbus`, `v3/internal/keychain` |

## 5. Definition of done (per task)

- `v fmt -w .` clean, `v test .` green on Windows.
- New public API has a `_test.v` case and one line in `CONTEXT.md` if it
  changes the domain model.
- Linux-only behavior documented in `tests/e2e_linux/README.md`.
