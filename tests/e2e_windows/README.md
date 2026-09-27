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

## Phase 5 S1 wave 1 — services: `dialog` + `os_info` (ADR-0014, 2026-09-27)

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o dialog.exe ./examples/dialog   # same 5 DLLs next to the exe
./dialog.exe
```

Verified in this run (Windows 11 + MSYS2 gcc 16.1 + V 0.5.2 + WebView2
runtime):

- The page renders (E0 conventions, `prefers-color-scheme`, `focus-visible`)
  and the preview fallback disables every button outside a Vails window.
- `dialog.open` opens the **Common Item Dialog** parented to the webview
  window, with the title from the params and the filters built in pure V
  and parsed in C (`Text (*.txt;*.md)`). Proof:

  ![dialog proof](dialog.png)

- The proof is driven by the documented example hook, because a synthetic
  mouse click does not reach WebView2 content (two attempts, no event):

  ```powershell
  $env:VAILS_DIALOG_PROBE = "open"   # or: multi | save | message | host
  ./dialog.exe
  # the page calls that command on load; the picker blocks until answered
  ```

- Manual checks still to do by hand (they need a human answer):
  - `Open several…` → multi-select → the `<ul class="paths">` lists every
    path (one `IShellItem` per entry, `IShellItem::GetDisplayName`).
  - `Save as…` → type a name → `ready to write: <path>`.
  - `Ask…` / `Confirm…` → MessageBox with OK / Yes-No-Cancel; the status
    shows `button: ok|yes|no|cancel`.
  - `Read host info` → os/arch/hostname/cwd/cpus from the `os_info` service.
  - `Call an ungranted command` → rejected with `forbidden: app.not_granted
    is not allowed for window "main"` (never `unknown method`).
  - Cancel every dialog once: the result is `{canceled: true}` and the
    promise **resolves** (ADR-0014).
- `vails dts --config examples/dialog/vails.json --js` regenerates
  `examples/dialog/frontend/vails.d.ts` (committed) and the per-service JS
  snippet; `vails doctor` lists the granted services.
- `v test .` is green (26 files) and never opens a window or a dialog —
  modal services are the ADR-0014 exception and are only exercised through
  a fake backend in the tests.
