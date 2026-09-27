# Windows E2E (manual, needs MSYS2 ucrt64 + Edge WebView2 runtime)

```sh
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o hello.exe ./examples/hello
# copy next to hello.exe: libwebview-0.12.dll, WebView2Loader.dll,
# libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll (from ucrt64/bin)
./hello.exe
# click "ping backend" -> status becomes "backend says: pong"
```

Verified 2026-09-26: full JS→V→JS round trip (`window.vails.call('ping')`
→ `bind_cb` → `Router.handle_message` → `ping_handler` → `webview_return`
→ promise resolves). Proof:

![pong proof](pong.png)

## T3 channels / T7 CSP (pure-V, verified via `v test .`)

- Channels (ADR-0011): eval-only — evaluate a `Channel.push_js` snippet
  through the backend and confirm `onEvent('ch_<n>')` fires in order,
  then the `<id>:close` marker after `close_js`.
- CSP (ADR-0012): hello ships `webview.default_csp()` verbatim; confirm
  no CSP violations in DevTools on load.

## Phase 3/4 — dev server + CLI (verified 2026-09-27, ADR-0013)

```sh
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
# CLI itself imports net (dev server): gcc 16 needs these two flags
v -cc gcc -cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32' -o vails.exe ./cli
# copy next to vails.exe: libwebview-0.12.dll, WebView2Loader.dll,
# libgcc_s_seh-1.dll, libstdc++-6.dll, libwinpthread-1.dll (from ucrt64/bin)
./vails.exe init smokeapp; cd smokeapp
../vails.exe doctor   # expect: vails home ok, vails.json ok, asset_root ok
../vails.exe run --serve-only --port 8421
# open http://127.0.0.1:8421/ -> scaffold page with ping button;
# edit frontend/index.html -> page reloads itself (livereload poller)
# /__vails_dev_version returns build_id:tree-fingerprint; /nope -> 404
$env:VAILS_HOME = "D:\MyProjects\vails"   # so build finds the vails root
../vails.exe build    # expect: smokeapp.exe (plain `v -cc gcc`, no extra flags)
```

Notes: `vails run` (window mode) carries an EMPTY router — JS→V calls
fail with `unknown method` until the real app binary runs. Scaffolded
projects outside a checkout need `VAILS_HOME` (or the CLI next to
source) or `build` fails fast telling you so.
