# Linux E2E (manual until Phase 2)

Unit tests (`v test .`) never open windows. These checks need a real Linux
desktop or Xvfb and run by hand:

## Prereqs (Debian/Ubuntu)

```sh
sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev xvfb
```

## Phase 1 — window PoC

```sh
v run ./examples/hello
# expect: 1024x768 window titled "Hello Vails", HTML rendered, closes cleanly
```

Record here: exact webkit2gtk version, any signature fixes applied to
`webview/webview_linux.c.v`.

## Phase 2 — bridge (pure-V seam done, C transport wiring pending)

Pure-V coverage (runs on any OS via `v test .`):

- `bridge.Router.handle_message` — JSON in, JSON out (incl. malformed input)
- `bridge.runtime_js` — injected `window.vails` runtime markers
- `bridge.resolve_js` / `events.to_js` — evaluate snippets, escaping via `jsesc`

Manual Linux steps once the message handler is wired (ADR-0004):

```sh
v run ./examples/hello
# 1. window shows "backend: not connected"
# 2. click "ping backend" -> status becomes "backend says: pong"
#    (JS: window.vails.call('ping') -> handler 'vails' ->
#     Router.handle_message -> run_javascript(__resolve(...)))
# 3. evaluate events.to_js('ready', 'hi') -> status becomes "event: hi"
```

## T3 channels / T4 state / T7 CSP (pure-V, verified via `v test .`)

- Channels (`bridge.ChannelHub`, ADR-0011): no native changes — the V
  side evaluates `push_js`/`close_js` snippets via run_javascript and
  the frontend subscribes with the existing
  `window.vails.onEvent('ch_<n>', cb)`. Manual check: open a channel in
  a handler, evaluate two pushes + close, confirm ordered delivery and
  the `<id>:close` marker.
- State (`state.Store`, ADR-0011): same-thread handler access only;
  `spawn` workers must deliver results as events (ADR-0010 rule).
- CSP (T7, ADR-0012): hello ships `webview.default_csp()` verbatim;
  confirm DevTools shows no CSP violations on load and the preview
  fallback (file:// open of `frontend/index.html`) renders with the
  counter running locally.

## Phase 3/4 — dev server + CLI (ADR-0013; CLI E2E-verified on Windows)

Headless runs need the usual env (see `run_headless.sh`):
`unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11`,
`WEBKIT_DISABLE_COMPOSITING_MODE=1`, plus `-gc none` on every GUI
build/run (Boehm vs WebKit fork, ADR-0005).

```sh
v -o vails ./cli && ./vails init smokeapp && cd smokeapp
./vails doctor   # expect: vails home ok, vails.json ok, asset_root ok
./vails run --serve-only --port 8421 &
curl -s http://127.0.0.1:8421/ | grep __vails_dev_version
# expect: the livereload poller script, injected before </body>
curl -s http://127.0.0.1:8421/__vails_dev_version
# expect: build_id:tree-fingerprint (moves on every frontend save)
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8421/nope
# expect: 404
export VAILS_HOME=<vails checkout>   # only outside a checkout
./vails build    # expect: ./smokeapp binary
./vails run      # expect: window at the dev URL; ping fails with
# 'unknown method' (empty router — frontend iteration only, ADR-0013)
```

## Phase 5 S1 wave 1 — services on Linux (ADR-0014, NOT verified here)

This machine has no WSL/Linux V toolchain, so the Linux service backend
was **not** written blind: `services/dialog_linux.c.v` is an explicit
stub (`error('dialog.open: not implemented on linux yet (Phase 5b …)')`).
On Linux today: `os_info` works, `dialog.*` rejects with that message, and
the example still renders (it shows the error in its status line).

This is the checklist for whoever has a Linux box (Phase 5b):

```sh
v -gc none -o dialog ./examples/dialog
./dialog
# 1. "Open file…" -> GtkFileChooserDialog, parented to the GTK window,
#    the params' title + filters applied, UTF-8 paths in the result
# 2. cancel -> the promise resolves with {canceled: true} (not a rejection)
# 3. "Save as…" -> default name in the name field
# 4. "Ask…"/"Confirm…" -> GtkMessageDialog with ok / yes-no-cancel
# 5. "Read host info" -> os_info.get resolves (no native code involved)
# 6. "Call an ungranted command" -> 'forbidden: …'
```

What the implementation must respect (recorded in the stub's header):

- parent the chooser to `Ctx.parent` (the GdkWindow) — the same handle
  `webview.Ctx` hands the app on Linux;
- run it from the GTK main loop: handlers already run there, and
  `gtk_dialog_run()` spins a nested loop, which is exactly why modal
  services are allowed to block (ADR-0014). Never `gtk_main_quit` from a
  response handler;
- keep UTF-8 end to end (`g_filename_to_utf8` / `g_filename_from_utf8`),
  because the V side speaks UTF-8 JSON;
- map the response to the same `Result` shape (`canceled` / `paths`), and
  map a GTK failure to an error, never to a silent empty result.

Same rule for the rest of the catalog (clipboard via GTK clipboard or
xclip, notification via libnotify/`notify-send`, opener via `xdg-open`):
pure-V seam + tests first, native side second (AGENTS.md §4).
