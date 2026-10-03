# ADR-0021 — Window chrome: frameless windows and a custom title bar

Date: 2026-09-29. Status: planned (ROADMAP track W; no code yet).

## Context

The request: support windows with no title bar, and windows with a title bar
the app draws itself.

`application/app_options.v` has been expecting this since Phase 1 — the field
comment reads, in full: *"More fields (frameless, fullscreen, …) arrive in
Phase 5+"* — and `services/menu` already draws a native popup with a real
title bar, so the capability is a change of chrome rather than something
new. What is missing is the config surface, the window operations, and the
plumbing.

**`webview` 0.12 has no window-chrome API at all.** That is the finding that
shapes everything below, and it was read out of the header on this machine
(`C:\msys64\ucrt64\include\webview\webview.h`, `WEBVIEW_VERSION_MINOR 12`)
rather than recalled. The complete `WEBVIEW_API` surface is:

```
create, destroy, run, terminate, dispatch, get_window, get_native_handle,
set_title, set_size, navigate, set_html, init, eval, bind, unbind, return,
version
```

There is no `set_chrome`, no `set_bounds`, no `set_decorated`. Wails gets
`Frameless` and `Titlebar` because it owns its window; Vails does not —
`webview_create(0, NULL)` makes the *library* own the HWND
(`webview/webview_windows.c.v:90`). So a frameless window here cannot be
requested at creation time; it has to be done *to* an existing HWND.

That is fortunate rather than lucky. `webview_get_window(w)` returns the HWND,
and ADR-0017's seam already installs a comctl32 `SetWindowSubclass` on exactly
that handle (`webview/host_windows.c.v:66`). Frameless is therefore not a new
window system — it is two more messages in a window procedure that already
exists and already forwards everything it does not own to
`DefSubclassProc`.

`window-state` and `positioner` are already on the ROADMAP as S1 wave-4 items
(`WM_SIZE`/`WM_MOVE` through the same subclass). This ADR absorbs them into
one `window` service rather than shipping a second half-window service beside
them.

## Decisions (planned, to be confirmed in W1)

- **Two chrome modes, not three.** `window.chrome.mode: "native" | "frameless"`
  in `vails.json`, mapped 1:1 onto a new `webview.Config.chrome` field with
  `native` as the default, so every existing `vails.json` keeps validating
  (json2 leaves an absent key at its declared default — the additive-schema
  property `config.v` already relies on and `config_test.v:39` pins).
  "A custom title bar" is not a third mode: it is `frameless` plus an app that
  draws its own bar, which is the Electron/Tauri model and the smallest surface
  that answers the request. A third mode that keeps the native frame and only
  hides the caption (Wails' `TitlebarOverlay`, so the drop shadow and taskbar
  behaviour stay correct) is **rejected**: on Linux it means client-side
  decorations, and CSD cannot be rendered or screenshotted under the Xvfb
  session this repo proves in, so the mode would ship compile-verified only.
- **A `window` service, and it is where `window-state`/`positioner` land.**
  `window.minimise`, `window.maximise`, `window.unmaximise`,
  `window.toggle_maximise`, `window.is_maximised`, `window.close`, `window.centre`,
  `window.set_size`, `window.set_position`, `window.set_fullscreen`. It is
  capability-gated like every other service, so an app whose page must not be
  able to move or close its window simply does not grant it — the same
  argument ADR-0020 makes for the updater.
- **The drag and resize contract is driven by the page, not by a native hit
  test.** The injected runtime listens for `mousedown`; if the target element
  or an ancestor carries `data-ta-drag-region`, it calls `window.begin_drag`
  with the pointer position, and for `data-ta-resize="n|s|e|w|ne|nw|se|sw"`
  it calls `window.begin_resize` with the edge. One contract, both platforms,
  and **no rectangle synchronisation**: the page already knows which element
  was hit, and nothing has to be re-pushed on scroll or resize.

  The native alternative — `WM_NCHITTEST` returning `HTCAPTION` for a list of
  registered rectangles — is better in exactly one way, that the drag is
  handled entirely inside the window procedure with no round trip through the
  page, and worse in three: the rectangle list has to be kept in sync with
  scroll and layout, the Linux side would need a completely separate
  implementation anyway, and the same one-frame delay would be added on both
  platforms. It is recorded here as the upgrade path if a measured delay
  turns out to matter, not as work to do now.
- **Windows: the caption bit, plus `WM_NCCALCSIZE`, plus `WM_NCHITTEST`.**
  Strip `WS_CAPTION` with `SetWindowLongPtrW(hwnd, GWL_STYLE, …)` followed by
  `SetWindowPos(…, SWP_FRAMECHANGED)`, keeping `WS_THICKFRAME` so the user can
  still resize. **`WM_NCCALCSIZE` must then return 0**, because Windows
  otherwise keeps an invisible ~8px resize border and the window keeps a 1px
  white frame around the content — that artefact is the single most common
  signature of a frameless window that was not finished, and it is invisible
  in code review and obvious in a screenshot. `WM_NCHITTEST` answers the edge
  codes (`HTLEFT`/`HTRIGHT`/`HTTOP`/`HTBOTTOM` and the four corners) for the
  same 8px band.
- **Linux: GTK's own drag API, which is also the only way to make resize
  work without a window manager.** `gtk_window_set_decorated(window, FALSE)`
  removes the frame, and
  `gtk_window_begin_move_drag(w, button, x, y, time)` /
  `gtk_window_begin_resize_drag(w, edge, button, x, y, time)` do the rest.
  This is the whole reason W2's edge protocol is specified rather than
  delegated: with `decorated == FALSE` on X11 there is no resize grip at all
  unless the application implements one, and the E2E environment has no window
  manager, so a CSD-based design would be unprovable exactly where this repo
  proves things. Pointer coordinates arrive in webview space and must be
  translated to root coordinates with `gdk_window_get_origin` before the
  drag call — a step that is easy to omit and produces a window that jumps.
- **The title-bar buttons are ordinary commands.** A page that draws minimise
  / maximise / close calls the corresponding `window.*` command; the framework
  does not synthesise buttons, does not draw them, and does not decide where
  they go. `System` decoration, spacing, RTL and the button glyphs stay the
  app's problem, because they are app design.
- **Mobile is an explicit no-op, and `doctor` says so.** ADR-0006 makes window
  geometry an intentional desktop-only concern and the OS owns the chrome on
  Android and iOS. `window.*` therefore follows the existing
  `ServiceStatus` / `*_support()` pattern (ADR-0015): a compile-time
  `is_supported`, a stub error elsewhere, and one `doctor` line. A
  `chrome.mode` on a mobile target is not an error — it is ignored, and
  ignored is the honest description of it.
- **The config block is window-scoped, not bundle-scoped.** A title bar is
  per window, so it goes on `WindowConfig` (`config/config.v:11-21`), not on
  `BundleConfig`. This means it is plumbed to all **five** places that copy a
  `WindowConfig` into a `webview.Config` by named argument: `cli/vails.v:141`
  and `cli/vails.v:490`, `examples/hello/main.v:123`,
  `examples/dialog/main.v:155`, `examples/services/main.v:402`. The second of
  those is **inside a `const` string** (the `scaffold_main` template), so the
  field has to be emitted as text there, not just as an argument. That is the
  single most forgettable part of this feature and it is why the sites are
  listed here rather than discovered.

## Waves

`W0` → `W1` (Windows frameless + screenshot) → `W2` (Linux frameless + drag
and resize) → `W3` (the `window` service and the buttons) → `W4`
(`window-state` / `positioner` persistence + the example). Each ends green:
`v fmt -w .`, `v test .` on Windows, one ROADMAP checkbox, one CHANGELOG line,
one CONTEXT line, one e2e README entry with a screenshot.

**W0 depends on ADR-0019.** `tray` and this service both need the window host
seam, and that seam is one handler per window until ADR-0019 gives it a
subscriber list. Building W0 before ADR-0019 means either two subclasses
fighting over one HWND or a second bespoke workaround. W4's size/position
persistence additionally needs a debounce timer on a worker, and a worker
cannot reach the page at all until `webview.post_to_main` exists — so W0 and
U0 are the same piece of work, not two.

## Rejected alternatives

- **Three chrome modes, including a native-overlay mode.** Faithful to Wails
  and it keeps the drop shadow, but it is the CSD problem above, and the
  "custom title bar" half of the request does not need it.
- **A native `WM_NCHITTEST` drag with registered rectangles.** Faster drag on
  Windows, at the cost of rectangle synchronisation, a second Linux
  implementation, and a round trip on both platforms. Recorded as an upgrade
  path, not as v1.
- **A frameless boolean and nothing else.** Smallest possible diff, and it
  moves the whole problem into every app that wants it — each reimplementing
  drag, resize, and the button plumbing against raw platform calls, with
  nothing in the framework testable about any of it.
- **Client-side decorations on Linux.** The OS draws the title bar, resize
  grips and shadow, which is genuinely less code. It also cannot be rendered
  under Xvfb, so W2 would ship with a Linux screenshot nobody could take, and
  the ROADMAP would gain a third "needs a human" item alongside the GTK
  dialog and the Linux notification.
- **Letting the page move the window with `SetWindowPos` directly.** That is
  what the capability gate exists to prevent; the `window` service is the
  gated path and it is the only one.

## Consequences

- `webview/host_windows.c.v` grows two more handled messages. The
  `DefSubclassProc` default and the "on demand, never by `webview.run`" rule
  from ADR-0017 both survive unchanged, and `host_message` keeps its value
  (a wakeup needs a new id — see ADR-0019).
- `examples/hello` is the natural place for the `frameless` proof, because it
  is the smallest app with a page, and `tests/e2e_windows/capture.ps1`
  already matches on `MainWindowTitle`, which a frameless window still has.
- The `window` service becomes the home for the S1 wave-4
  `window-state` / `positioner` items, so wave 4 shrinks by two entries and
  gains a dependency.
- A frameless window has no `WM_SYSCOMMAND` from the caption, so the taskbar
  context menu ("Minimize", "Close") and the Alt+Space menu need explicit
  handling or the window becomes un-closable by keyboard. That is a known
  item, not an oversight.

## Notes (verified against the installed headers and the repo while planning this)

- **The webview 0.12 API list above is transcribed from the installed
  header**, not from documentation. It is the reason this ADR is a window
  procedure rather than a config flag, and re-deriving it is one `grep` on
  `WEBVIEW_API`.
- **`webview_get_window` already returns the HWND we need**
  (`webview/webview_windows.c.v:40`, already declared and already passed to
  services as `Ctx.parent`), so the frameless change needs no new handle
  plumbing at all.
- **`capture.ps1` needs no change for a frameless proof.** It matches on
  `MainWindowTitle` via `Get-Process`, and a frameless window still has a
  title; `-WindowTitle` therefore still isolates the window for a screenshot.
- **`SetWindowSubclass` composes but does not stack.** Two procs on one HWND
  is a replacement or a failure, which is the concrete reason ADR-0019's
  subscriber list is a prerequisite rather than a nicety.
- **The GTK drag calls are the unverified part of this plan.** This machine is
  Windows; the GTK 3.24 headers are on the WSL side (ADR-0015), and
  `gtk_window_begin_move_drag` / `gtk_window_begin_resize_drag` /
  `gdk_window_get_origin` are checked at implementation time in W2, not
  assumed here. `webview_linux.c.v` already reaches GTK through bare
  `fn C.*` declarations with `#pkgconfig gtk+-3.0`, so adding three more is
  consistent, but `GDK_WINDOW_EDGE_*` are enumerators rather than constants
  and the repo has been bitten by exactly that class of mistake in the toast
  shim (ADR-0018, `AsyncStatus::Error` colliding with V's `Error`).
- **V's `v fmt` re-aligns the struct block** when a field name longer than
  `windows_dll_side_by_side` (20 characters) is added. Harmless, but it
  produces a diff that looks like an unrelated change to
  `BundleConfig`/`WindowConfig`.
