# ADR-0005 — Windows backend via webview lib + bridge lessons

Date: 2026-09-26. Status: accepted, verified E2E (see tests/e2e_windows/).

## Backend choice

Windows uses `webview/webview` 0.12 from MSYS2 ucrt64
(`mingw-w64-ucrt-x86_64-webview` + `webview2-loader`) with `window=NULL`
(the library owns its window). Zero COM code on our side. V file:
`webview/webview_windows.c.v`; declarations rechecked against the
installed header, not copied from docs.

## Environment facts (Windows + MSYS2)

- `C:\msys64\ucrt64\bin` must be on PATH or even `cc1` cannot find its own
  DLLs (silent gcc failure). `vails doctor` checks this.
- Build needs `-cc gcc` (V default tcc cannot link the C++-built import
  lib the same way; verified with gcc 16.1).
- Runtime needs next to the exe: `libwebview-0.12.dll`,
  `WebView2Loader.dll`, plus MinGW runtime (`libgcc_s_seh-1.dll`,
  `libstdc++-6.dll`, `libwinpthread-1.dll`). Phase 4 decides static link
  vs side-by-side DLLs.
- `vails doctor` verifies header presence at
  `C:/msys64/ucrt64/include/webview/webview.h`.

## V↔C friction, solved

- gcc 14+ rejects `void (*)(char*,…)` → `void (*)(const char*,…)` for
  function POINTERS (passing `char*` values is fine). V fn params cannot
  express `const`, so `webview_bind` goes through `webview_shim.h`
  (`#insert "@VMODROOT/…"`, the ui2 pattern) with an explicit C cast.
- V emits `#insert '…'` single-quoted if written so — must use double
  quotes or the C compiler rejects the `#include`.

## Bridge protocol lessons (both backends)

- The library wraps bound-call args in a JSON array:
  `vails_call(body)` arrives as `["<body>"]`. `bridge.handle_message`
  unwraps one-element string arrays (`unwrap_args`) and still accepts a
  bare object (raw WebKitGTK path, ADR-0004).
- The library resolves the JS promise with the PARSED JSON value, not the
  string. `runtime_js_bound` normalizes
  (`typeof raw === "string" ? raw : JSON.stringify(raw)`) before
  `__resolve`, whose try/catch otherwise swallows the mismatch silently
  (this exact silent hang cost a full debug session — file-logged via a
  temporary `bind_cb` log to find it).

## Linux notes (verified same day, WSL Ubuntu + webkit2gtk-4.1 2.52.6)

- Apps MUST build with `-gc none`: Boehm GC crashes (`GC_noop1_ptr`,
  fork-unsafe) when WebKit spawns subprocesses.
- Under WSLg, `WAYLAND_DISPLAY` hijacks GTK to Wayland (window invisible
  to Xvfb): test script unsets it + `GDK_BACKEND=x11`.
- Headless render needs `WEBKIT_DISABLE_COMPOSITING_MODE=1`.
- Window render verified by screenshot (`run_headless.sh`).
