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
