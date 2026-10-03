# ADR-0036 — drag & drop: `WM_DROPFILES`, and what it costs the DOM

Date: 2026-10-03. Status: **accepted; Windows written and unit-tested, not
observed at runtime. Linux native half deliberately unwritten.**

## Context

`docs/COMPETITIVE-MATRIX.md` named exactly two gaps that are capabilities of
the *shell* rather than missing services, and drag & drop is one of them. Wails
ships `drag-n-drop`, Tauri ships a `drag` plugin, and Vails had nothing: for any
app whose user has files on disk, a window that will not accept a dropped file is
a prototype.

ROADMAP F1 also asked the question that decides the whole design, and it is worth
keeping because the answer was not the expected one:

> **The first thing to check is whether `EnableWebDrop` is reachable at all.**

It is not. Measured against the installed `webview` 0.12 header: sixteen
`WEBVIEW_API` functions, none of them about dropping —

```
create  destroy  run  terminate  dispatch  get_window  get_native_handle
set_title  set_size  navigate  set_html  init  eval  bind  unbind  return  version
```

`EnableWebDrop` is a WebView2 **host** setting; it lives on
`ICoreWebView2Controller`, and the webview library does not hand the controller
out. There is no `webview_set_drag*` either. So the design choice was never
"which drop API" — it was "what is left", and what is left is
`WM_DROPFILES` on the HWND.

That is fortunate rather than lucky. `WM_DROPFILES` is a window message, and
`webview/host.v` exists to deliver window messages to V (ADR-0017). The seam is
not an obstacle here; it is the mechanism.

## Decisions

- **The drop arrives as a window message on the existing per-window seam.** No
  new host primitive, no new message id: `is_drop_message` matches `0x0233` and
  nothing else, and every other hook on the chain (`tray`'s WM_APP+1, the menu
  bar's WM_COMMAND, the job wakeup) declines it by id, so the chaining rule
  ADR-0023 added a second hook for keeps holding.
- **F1's dependency on F0 is answered, and it needed nothing new.** ROADMAP F1
  depends on multi-window because "drop onto which window" is a routing question.
  It is answered by the seam already being per-window: each hook closes over that
  window's own `Ctx`, so a drop is reported to the page it landed on. There is no
  global "current window" for a drop to be ambiguous about — which is the failure
  mode that made F0 worth doing first.
- **The page gets `drop:files`, and NOT the DOM's `dragover` / `drop`.**
  `DragAcceptFiles(hwnd, TRUE)` on the **top-level** window takes the drop away
  from WebView2's child, so the page's own HTML5 drop events stop firing for that
  window. This is a real loss and it is the price of the only reachable exit;
  `drop_support()` carries it in the `vails doctor` line rather than hiding it
  behind "ok".
- **One event per drop, carrying every path.** A drop of twelve files is one
  thing the user did; a frontend that has to deduplicate twelve events to learn
  that has a bug.
- **A drop with nothing usable in it is still reported**, as
  `{"paths":[],"count":0}`. The user did something, and silence reads as a bug —
  the page waits for an event that was never sent. This is the pair of failures
  `tray.decide` had to learn separately (a swallowed event, a phantom one), and
  the empty report is the answer that is neither.
- **Paths, never contents.** The service hands the OS's paths to the page and
  stops. A page that wants a file's bytes has to be given a way to ask, and that
  capability should be granted or withheld on its own rather than inherited by
  every window that can receive a drop.
- **Bounds are applied to the report, not to the drop.** At most 64 paths and
  1024 characters each; over-long, empty and NUL-bearing paths are dropped
  individually; a larger drop is *truncated* rather than failed. Dragging a
  directory tree is tens of thousands of paths, and throwing away forty good ones
  because the sixty-fifth was too many is the worse answer.
- **Two commands, neither taking params: `drop.enable` and `drop.disable`.** Both
  are capability-gated (T1), so a page cannot arm a drop it was not granted, and
  `drop.disable` removes the seam so an app that never asks for drops gets no
  subclass on its window at all (ADR-0017's rule).
- **The seam is installed BEFORE the window is armed.** Arm-first would leave a
  window accepting drops nobody reads, and the user's next drag would vanish with
  no error anywhere — the exact shape of bug `post_to_main` refuses to have
  (`webview/jobs.v`).
- **`DragFinish` runs on every path out of the native read**, including its
  errors. The `HDROP` is a shell resource; a handler that returns early without
  releasing it leaks one handle per drop, which is a slow silent leak rather than
  a visible failure.
- **The Linux native half is not written.** See below.
- **`decide_drop`, not `decide`.** The services module is one flat namespace and
  `tray.decide` has the name; V rejects the redefinition outright. Same reason
  `validate_tray_options` is not called `validate`.

## Why the Linux half is unwritten

It would be a `GtkDropTarget` on the window, reading `drag-data-received` and
turning `text/uri-list` into paths. It is not written, and the reason is the rule
AGENTS.md §2 states: **no native code that has never been compiled.** The wave-3
Linux build broke for four ordinary GTK reasons while being blamed on V
(ADR-0015), and this repository has no Linux runner, so a `GtkDropTarget` written
today would be GTK nobody has run.

What *is* written is everything that is not native — the bounds, the payload, the
message policy — all pure V and all tested on **both** platforms. So the Linux gap
is one function's worth of C, not a service that does not exist, and
`drop_support()` says "unwritten" rather than "unsupported", because only one of
those two claims is true.

The Linux shape is also part of *why* the service is an event rather than a DOM
dependency: GTK delivers a drop as a selection of URIs on a destination widget,
and which widget that is, is GTK's answer to give. The page needs one event name
that means the same thing on both platforms, exactly as `tray:clicked` and
`menu:clicked` do.

## Rejected alternatives

- **Enable WebView2's own drop handling.** Unreachable: it is a controller
  property and the controller is not exposed (measured above). This is not a
  preference; it is the reason the ADR exists.
- **An `IDropTarget` on the WebView2 child, re-dispatching into the page.** The
  same wall — it needs the controller or the child HWND plus OLE plumbing, and
  registering it would also *replace* WebView2's own drop handling rather than
  coexist with it. More code, more native surface, same missing prerequisite.
- **Read the file contents in the service.** Capability creep with a security
  shape: `drop.enable` would silently become "read any file this user can read".
  Paths are inert; contents are not.
- **Swallow a drop that carried nothing usable.** Rejected because it is
  indistinguishable from a hang for the page, and from a dropped hook for the
  developer.
- **Fail an over-large drop.** Rejected: 40 good paths lost to enforce a bound the
  user never agreed to. Truncate and say so (`count` is the number reported).
- **Write the GTK half now and test it later.** Rejected on the ADR-0015 evidence,
  which is a record of what that costs.

## Consequences

- The catalog has eight services (`manifest_test.v` asserts the count exactly), so
  `vails dts` emits a `DropFiles` interface and `vails doctor` prints a `drop`
  line that carries the DOM trade-off.
- `examples/services` has **no** drop panel yet, and this ADR does not claim one.
  A drop probe needs a human to drag a file, or a shell-level synthesised drop; see
  Verification.
- Linux `doctor` output now has a second `stub` line whose reason is "unwritten"
  rather than a missing feature. That is honest, and it is a visible piece of
  unfinished work in a report that is supposed to be trustworthy.

## Verification

- `services/drop_test.v` — 18 pure-V tests, green on Windows and on Linux (the
  pure half compiles and passes on both; only `drop_support()`'s branch differs).
  The ones that matter most: a message that is not `WM_DROPFILES` is passed on
  even when the paths it "carried" would be valid; an empty drop is still emitted;
  a path containing a NUL is rejected rather than truncated; a path exactly at the
  bound is kept (the off-by-one that would let the neighbouring test pass for the
  wrong reason); a 128-path drop is truncated to 64 keeping the **first** paths;
  and the payload round-trips through `json2` with backslashes doubled.
- `v fmt -l .` clean, `v vet services` adds no new notice.
- **Not proven: a drop actually reaching a page.** Nothing here has seen a human
  drag a file, because the only Windows GUI proof available on this machine goes
  through the `webview` test module, which crashes the host (ADR-0035's
  Verification section). The outstanding run is the six-step procedure in
  `tests/e2e_windows/README.md`, and the screenshot that would close it is a
  window with a file icon on it and a `drop:files` line in its status area.
