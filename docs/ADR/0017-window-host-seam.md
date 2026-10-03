# ADR-0017 — The window host seam: a native window procedure that can reach V (Phase 5 S1 wave 3)

Date: 2026-09-27. Status: accepted (Windows E2E-proofed; the Linux backends
compile and the Linux popup menu is written against the installed GTK 3.24 —
the Linux test suite and the Linux screenshots are recorded as pending in
`tests/e2e_linux/README.md`, see "Verification status" below).

## Context

ADR-0015 deferred `menu` and `tray` and recorded the reason: "both need a
hidden window, a `WndProc`, and a callback from C into a running V handler
(tray: `NOTIFYICONDATA` + `WM_APP+1`; menu: `HMENU` + `TrackPopupMenuEx`)".

Writing the two services showed that reason to be half wrong, and the half
that was wrong is the expensive half:

- **A hidden window is not needed.** The tray balloon in
  `notification_windows.c.v` already proved it: the webview library's own
  `HWND` is a perfectly good owner for a shell icon and for native UI. The
  library owns one window per `webview.run` call and there is never a case
  where no window exists.
- **A popup menu needs no window procedure either.** `TrackPopupMenuEx` with
  `TPM_RETURNCMD` hands the chosen command id straight back to the caller.
  So `menu.popup` is a plain native call, in the same class as
  `dialog.open` — the shape wave 1 already shipped.

What is genuinely new is narrower and is what `tray` needs: **the OS has to be
able to call *into* V.** A tray icon is a `NOTIFYICONDATA` with
`uCallbackMsg = WM_APP+1`; when the user clicks it the shell sends `WM_APP+1`
to the window, and a Vails frontend must hear about that click. On Windows
that means intercepting a message on a window the webview library created and
whose window procedure the library owns. There was no seam for it, and there
is no precedent in the codebase: `BindCtx` and `DispatchCtx` are the other two
places C calls V, and both exist because a *library* hands us a pointer, not
because *we* asked to be called.

Verification for this batch: `v test .` green on **Windows** (30 files, 22 of
them new for `menu`/`tray`/`webview.host`); `v -o vails ./cli` builds on both
platforms and `v -gc none -o services ./examples/services` builds on Linux with
all seven backends compiled in; the Windows tray click loop proven
machine-checkably end to end (`PostMessage(WM_APP+1)` → subclass → V →
`ctx.emit` → the page's `tray:clicked` handler, screenshot
`tests/e2e_windows/tray.png`); a real `TrackPopupMenuEx` popup captured in
`tests/e2e_windows/menu.png`; `vails doctor` reporting 7/7 native backends on
Windows. **Pending:** the Linux `v test` run and the Linux screenshots — see
"Verification status" in `tests/e2e_linux/README.md` for the exact state and
the one compiler issue that is holding it.

## Decisions

- **`SetWindowSubclass`, not a hand-written window procedure.** Vails does not
  replace the library's `WndProc`; it stacks a comctl32 subclass on the
  window it already has. Two reasons: a subclass composes with whatever the
  webview library installed (a raw `SetWindowLongPtr(GWLP_WNDPROC)` would not,
  and would have to chain by hand), and comctl32 routes every unrecognized
  message to `DefSubclassProc` for us. That default is not a convenience, it
  is a safety property: **a message the seam does not understand must reach
  the webview unchanged**, or WebView2 breaks. The shim keeps the cast, so the
  V function never has to spell a Windows callback type it cannot express.
- **The per-window context is a heap pointer, and there are no globals.** The
  subclass's `dwRefData` carries a `&HostCtx{ctx, on_event}`, the same
  "C ferries the pointer back to V and never dereferences it" rule as
  `BindCtx`/`DispatchCtx` (AGENTS.md §2). A closure is stored in it, so a
  service can install a handler that closes over its own state, and two
  windows never see each other's hook.
- **The seam is installed on demand, never by `webview.run`.** A window with
  no service that needs a callback gets no subclass at all, so the 95% case
  (hello, dialog, clipboard) cannot be affected by this ADR. `webview/host.v`
  is opt-in: `install(&HostCtx)` is called by the `tray` backend, not by the
  backend runner.
- **Classification is pure V, so it is unit-testable without a window.**
  `classify_windows_msg(msg, lparam)` maps the raw `WM_APP+1` + `lParam`
  pair onto a `HostEvent` (`tray:clicked` with the button, for the four
  messages the shell sends). The table is the part worth testing, and it is
  testable on a machine with no display — which is why `host_test.v` covers
  all four buttons plus the "not ours" cases.
- **The seam is one-sided, and that asymmetry is the finding.** Linux needs no
  window procedure: a `GtkMenu` emits `activate` on the item that was clicked
  and an `AppIndicator` registers itself, so the C→V direction is per-object
  and there is nothing to hook on the window. Which is why
  `webview/host_linux.c.v` **does not exist**: `attach` and `post_message`
  return an explicit "not available on this platform" error naming the reason,
  and a Linux service connects the signal of the GTK object it owns. An empty
  file whose functions succeed would be worse — it would let a Windows-only
  code path look portable.
- **A menu choice is an event, never a command result.** `menu.popup` is
  `blocking: true` on Windows (the native modal exception of ADR-0014:
  `TrackPopupMenu` spins a nested message loop on the handler's thread) and
  returns immediately on Linux (the GTK signal arrives later). The frontend
  contract is the same either way: the chosen id arrives as a
  `menu:clicked` event, a dismissal as `menu:canceled`, and the command's own
  result is always `""`. A per-platform difference in *when* the answer comes
  is invisible; a difference in *where* it comes would force every frontend
  to branch on the platform.
- **`menu.set_menu` (a window menu bar) is deliberately out of this wave.**
  A real menu bar is not a popup: it is `SetMenu` plus `WM_COMMAND` routing,
  i.e. the seam plus a second message filter plus menu-state tracking. That is
  a service of its own, it is not needed by `tray`, and shipping it half-done
  behind a `menu.` prefix would be worse than not shipping it. It is recorded
  as the next `menu` item.
- **One Windows file owns `NOTIFYICONDATA`.** ADR-0015 predicted the balloon
  would show which half of the shell-icon code is reusable; it was right, so
  `services/trayicon_windows.c.v` now holds the struct and the
  add/update/remove helpers, and `notification` and `tray` use it with
  **different `uId`s**. Same-window + same-id would have had the two services
  overwrite each other's icon — the balloon would have deleted the tray icon
  when its timeout expired.
- **The Linux tray is a real StatusNotifierItem, with an honest note.**
  `libayatana-appindicator` is how a Linux tray works today
  (`v3/pkg/services` does the same), and it is a new *build* dependency, so it
  is a `doctor` check and a README prereq rather than a surprise. Under Xvfb
  there is no StatusNotifierHost, so the item is created and registered but
  nothing draws it: `tray_support()` says exactly that instead of claiming a
  proof it does not have.

## Consequences

- `menu` and `tray` are the first services that **push** to the frontend by
  themselves. Both do it through the existing `webview.Ctx.emit`
  (ADR-0014's leftover), which means a menu click and a tray click take the
  same path as any other V→JS event: no new transport, no new JS runtime, and
  the ADR-0010 threading rule holds because the window procedure runs on the
  window thread, which is the thread the handlers run on.
- The example can prove a tray click without a human. `examples/services`
  posts `WM_APP+1` to its own window from a V worker and the page waits for
  `tray:clicked`. That is a synthetic input, and it is honest about what it
  proves: the whole C→V→event→JS path, not a user's mouse. The pixel proof for
  the tray icon itself stays a per-session Windows question, exactly like the
  balloon in ADR-0015 (Windows 11 puts new icons in the overflow flyout).
- `webview/host.v` adds a third platform-specific surface to `webview/`
  (`host_windows.c.v` + `host_shim.h` beside the two existing backend pairs,
  and no Linux file — see the decision above). This is the seam
  `window-state`/`positioner` needs next (`WM_SIZE`/`WM_MOVE`/
  `WM_EXITSIZEMOVE` are the same subclass with different messages), which is
  why it lives in `webview/` and not in a service: only this module can reach
  the window the webview library owns.
- Linux `tray` needs `dbus-run-session` for the SNI registration to have a
  bus to talk to, and a real desktop needs a StatusNotifierHost to draw the
  item at all. `tests/e2e_linux/README.md` carries both as the two-line
  difference between "created" and "clickable".
- This version of libayatana-appindicator has **no `activate` signal** (only
  new-icon, new-status, new-label, connection-changed and scroll-event),
  because on Linux the SNI *host* owns the click and opens the menu the app
  attached. So `tray:clicked` is a Windows event, and `simulate_click` refuses
  on Linux with that reason instead of manufacturing a gesture the platform
  does not have. Attaching the item's menu is the next `tray` item
  (`tray.set_menu`), which is why it is not in this wave.

## Notes (things that bit)

- **V 0.5.2 mis-types a closure capture of a `mut` pointer *parameter*.** In
  `tray_backend(mut st &TrayState)` the generated C built the closure context
  as `{.st = st}` — i.e. it typed the captured field as `&(&TrayState)`, and
  gcc rejected the assignment
  (`initialization of 'TrayState *' from incompatible pointer type
  'TrayState **'`). A plain local (`mut state := st`, captured from there)
  types correctly. The same bit `tray_windows.c.v`, where the closure passed
  to `webview.attach` captured the `mut` parameter directly. The workaround is
  a one-line local in both places and the reason is written next to both,
  because the error message points at the parameter and the fix is not the
  parameter. This is the third time this V codegen shape has cost time here
  (ADR-0015 Notes); the pattern to remember is "a `mut` pointer parameter is
  not capturable — copy it to a local first".
- **A `mut` *local* captured by a closure is fine**, and the capture list does
  accept `mut`: `fn [mut state] (...)` is the shape both new services use, and
  it is what `examples/services` already did. Only the *parameter* case is
  broken.
- V's `mut` argument convention is a call-site keyword: a function declared
  `fn f(mut x &T)` must be called `f(mut x)`, and the caller's own binding has
  to be mutable too. Half the errors in this wave were that rule, not logic.
- A V function pointer handed to `SetWindowSubclass` is cast inside the shim,
  not at the V call site: `void *` in, the exact `SUBCLASSPROC` out. Passing
  the V function directly to the comctl32 prototype makes gcc compare
  `__int64 (…)` against `LRESULT CALLBACK(…)` and reject the function pointer
  (the ADR-0015 lesson about generated signatures, one function over).
- **V's `WPARAM`/`LPARAM` are `usize`/`isize`-shaped on the generated side**;
  the subclass receives them as `u64` and hands `lParam` to the classifier as
  an `i64`, because every message this seam handles packs a small message id
  there. Comparing the full 64 bits in the classification table would make it
  both unreadable and untestable.
- The shell packs the *notification area* events (`WM_LBUTTONDOWN`,
  `WM_LBUTTONUP`, `WM_LBUTTONDBLCLK`, `WM_RBUTTONUP`, `WM_RBUTTONDBLCLK`,
  `WM_CONTEXTMENU`) into `lParam`, not `wParam`. Reading the wrong one gives
  a classifier that passes its own tests and never fires.
- `TrackPopupMenuEx` must get `TPM_RETURNCMD`: without it the selection
  arrives as a `WM_COMMAND` message the window has no handler for (no
  subclass is installed for a popup), so the command id would be lost instead
  of returned. `TPM_NONOTIFY` is not needed on top of it.
- A `GtkMenu` is not a menu bar, and a popup menu on a windowless X server has
  no pointer to anchor to: `gtk_menu_popup_at_pointer(menu, NULL)` positions
  it at the current pointer, which is the honest Linux answer for a
  right-click menu and needs no `GdkEvent` (V cannot construct one).
- GTK emits `item-activated` **and then** `deactivate` for one activation, so a
  `chosen` flag is the only thing that tells a selection from a dismissal. And
  the teardown belongs to the `deactivate` handler alone: `gtk_menu_popdown`
  ends the grab by making GTK emit that signal, so a second destroy from
  `menu.close` would free the context twice.
- An `AppIndicator` is a GObject whose lifetime the tray owns: it must be
  unreffed, not just forgotten, or a second `tray.set` leaks the previous
  item and the notification area grows a row of dead icons — the same failure
  mode ADR-0015 recorded for the balloon, inverted.
- `Shell_NotifyIconW` identifies an icon by `(hWnd, uId)`, so `notification`
  and `tray` must use different uIds on the same window. Sharing one would
  make the balloon's lifetime worker delete the tray's icon eight seconds
  after a notification. This is the one thing the shared
  `services/trayicon_windows.c.v` exists to make visible.
- The `services` module is a flat namespace, so two services with the same
  shape collide: `parse_options` (dialog's), `validate_options`,
  `clicked_data` and a `json_str` helper all had to become
  `parse_tray_options` / `validate_tray_options` / `tray_clicked_data`, and
  `json2.encode` is used directly. Worth knowing before writing the second
  service with a `Result` and a `clicked_data`.
- `#include <libayatana-appindicator/app-indicator.h>` costs more than it
  looks: it drags the dbusmenu/glib/indicator/ido headers with it, and the
  `services` module's C is recompiled by every one of its test files. Six
  hand-declared `fn C.*` prototypes plus the pkgconfig line build in 7s where
  the header chain did not finish — the same call `opener_linux.c.v` already
  made for `GError`.
