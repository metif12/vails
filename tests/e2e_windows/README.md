# Windows E2E (manual, needs MSYS2 ucrt64 + Edge WebView2 runtime)

## Which capture tool to use: `capture.ps1`, not `capture.vsh`

Two capture scripts live here and only one works.

| | |
|---|---|
| **`capture.ps1`** | **Use this.** It works, and every command below calls it. |
| `capture.vsh` | A V shell script that **compiles, returns correct exit codes, and prints nothing at all**. Unresolved as of 2026-10-03. |

The `.vsh` failure is worth naming precisely, because it is not a build failure
and not a missing window: its code is provably in the binary (the string literals
are in the `.exe`), `entry()` runs (exit codes differ per command), a bare
`println` at top level *in that file* prints nothing, and four-line probe scripts
using the same `capture_shim.h` print correctly. So the encoder and the
privacy clamp inside it are the parts believed good, and the fault is structural.
Its header documents all of it, including the three VSH script-mode rules that
*were* real bugs along the way. Do not spend an afternoon on it before reading
that header.

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
→ promise resolves).

> **The screenshots in this file were removed on 2026-09-29.** They were taken
> with `capture.ps1` on a real desktop, so every one framed the app window
> against the user's actual desktop — taskbar, open windows, a file manager and
> the local username all visible around the window. They were purged from this
> repository's history, not just deleted, because a screenshot that leaks a
> machine's desktop stays in a clone forever otherwise. The *proofs* they
> carried are all still written out as steps below; only the pictures are gone.
> The Linux proofs in `tests/e2e_linux/` are unaffected and are kept, because
> they are captured under Xvfb on a headless box and show the app window and
> nothing else.
>
> To regenerate one, raise the app window so it covers the screen (or move the
> desktop out of the way) and run `capture.ps1 -WindowTitle "<title>"` — the
> per-window capture is what keeps the desktop out of the frame.

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
v -cc gcc -o vails.exe ./cli
# (0.5.2 needed -cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32' here;
#  the current compiler needs neither - AGENTS.md §1)
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
  and parsed in C (`Text (*.txt;*.md)`). The screenshot that showed this is
  gone (see the note at the top); the picker itself is the visible proof, and
  the steps to re-take it are the same two commands below.

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
  - `Pick a folder.` (`{"folder": true}`, ADR-0039) - the dialog offers
    directories only; a chosen directory comes back in `paths` exactly like a
    chosen file. This is the Common Item Dialog with `FOS_PICKFOLDERS`
    (`shobjidl.h:21513`), so no WinRT is involved and it keeps working on an
    image whose WinRT class store is stripped.
  - `Pick several folders.` (`{"folder": true, "multi": true}`) - multi-select
    of *directories*, a third thing distinct from both file multi-select and
    folder single-select.
  - `Pick a folder with a filter.` - must fail with `bad params:` naming
    `folder` and `filters`. A filter cannot select a directory, and silently
    showing a file picker instead is the failure this guards.
  - `{"multi": true}` on a `message` command - must also fail with
    `bad params:`. It used to be silently ignored: the kind-scoping checks sat
    below `message`'s early return, so a dropped flag looked like a working
    one. `folder` would have inherited the same hole.
  - `Read host info` → os/arch/hostname/cwd/cpus from the `os_info` service.
  - `Call an ungranted command` → rejected with `forbidden: app.not_granted
    is not allowed for window "main"` (never `unknown method`).
  - Cancel every dialog once: the result is `{canceled: true}` and the
    promise **resolves** (ADR-0014).
- `vails dts --config examples/dialog/vails.json --js` regenerates
  `examples/dialog/frontend/vails.d.ts` (committed) and the per-service JS
  snippet; `vails doctor` lists the granted services.
- `v test .` is green (29 files) and never opens a window or a dialog —
  modal services are the ADR-0014 exception and are only exercised through
  a fake backend in the tests.

## Phase 5 S1 wave 2 — services: `clipboard` + `opener` + `notification` (ADR-0015, 2026-09-27)

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o services.exe ./examples/services   # same 5 DLLs next to the exe
$env:VAILS_SERVICES_PROBE = "clipboard"         # or: opener | notification | none
./services.exe
```

Verified in this run (Windows 11 + MSYS2 gcc 16.1 + V 0.5.2 + WebView2
runtime). The screenshots taken with `capture.ps1` in this directory were
removed on 2026-09-29 because they framed the window against the desktop — the
proofs below are the status lines, which are the machine-checkable part anyway.

- The **clipboard round trip needs no human**: the page writes
  `vails clipboard proof — héllo 🌱` (non-ASCII on purpose: the Windows path
  is UTF-8 → UTF-16 → clipboard → UTF-8) and reads it straight back, so the
  status line *is* the proof. It reads
  `round trip ok, read back: "vails clipboard proof — héllo 🌱"`.
  `VAILS_SERVICES_PROBE=clipboard`.

- **`opener`**: `open_url` on `https://vails.invalid/probe` →
  `probe opener: ok - the OS accepted the URL` (ShellExecuteW returned > 32).
  `open_url` with `file:///C:/Windows/win.ini` answers
  `bad params: scheme "file" is not allowed (http, https, mailto, tel)`
  before the OS sees anything.

- **`notification`**: this is now a **real WinRT toast** (ADR-0018), not the
  tray balloon these notes used to describe. `is_supported` → `true`, then
  `notify` resolves with the mechanism that ran, so the page shows
  `shown via: toast` and that status line is the machine-checkable evidence.
  - **PROOF STILL OUTSTANDING — read before trusting this section.** The
    toast was **not** seen running on this machine. `v test .` is green
    (32/32) and `examples/services` builds and *links* on Windows, but
    `RoGetActivationFactory` returns `0x80040154` (`CLASS_E_CLASSNOTAVAILABLE`)
    for every WinRT class here: `Windows.Foundation.dll` and
    `Windows.UI.Notifications.dll` are absent from `System32` and `WinSxS`
    and `HKLM\SOFTWARE\Classes\ActivatableClasses` holds only `CLSID` and
    `Package`. This is a stripped Windows 11 26H1 (build 28000) image. The
    AUMID registration and the loud-failure path *were* proven; a toast in
    the Action Center was not. **To finish the proof, on a machine with a
    normal Windows image:**
    ```powershell
    $env:VAILS_SERVICES_PROBE = "notification"
    ./services.exe
    ```
    The page must show `shown via: toast`, and a toast must appear
    attributed to **Vails Services Demo** (from `bundle.identifier` +
    `bundle.name` in `vails.json`) and stay in the Action Center afterwards.
    There is no tray icon and nothing to clean up any more — that is the
    point of the change. If the page shows a rejection instead, the message
    carries the real HRESULT from the shell.
  - `vails doctor` names the precondition: granting `notification.*`
    without a `bundle.identifier` prints a `!` line, because a desktop app
    cannot raise a toast without an AppUserModelID and the failure otherwise
    is a notification that never appears.
  - `Copy` / `Paste` by hand: put something in the clipboard from Notepad, press
    **Paste** — the text shows up; press **Copy**, then paste into Notepad.
  - **Try it anyway** (the `file://` URL) → `bad params: …`, shown in green,
    because that rejection is the feature.
  - **Ask is_supported** → `is_supported: true` on Windows.
  - **Call an ungranted command** → `forbidden: app.not_granted is not allowed
    for window "main"`.

### Taking the screenshots

`capture.ps1` raises the target window (retrying, because a busy desktop
races `SetForegroundWindow`) and then captures its rect — a shot of a covered
window proves nothing:

```powershell
.\capture.ps1 -Out services.png -WindowTitle "Vails Services Demo"
.\capture.ps1 -Out full.png     # whole screen (what a toast near the corner needs)
```

## Phase 5 S1 wave 3 — services: `menu` + `tray`, and the host seam (ADR-0017, 2026-09-28)

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o services.exe ./examples/services   # same 5 DLLs next to the exe
$env:VAILS_SERVICES_PROBE = "menu"   # or: tray | clipboard | opener | notification | none
./services.exe
```

Verified in this run (Windows 11 + MSYS2 gcc 16.1 + V 0.5.2 + WebView2
runtime):

- **`menu` — a real native popup.** The page calls `menu.popup` with items,
  separators, a disabled item and a submenu, and V builds an `HMENU` and shows
  it with `TrackPopupMenuEx`. The page then reports the dismissal it received
  as an event, which is the part that can be read back as text:
  `probe menu: ok · dismissed: menu:canceled`.

  > **The screenshot for this one was never captured.** Every other proof here
  > has an image; this bullet used to point at a `menu.png` that does not exist
  > in the repo, so there is no picture of the popup. Take it with
  > `.\capture.ps1 -Out ..\menu.png -WindowTitle "Vails Services Demo"` while
  > `VAILS_SERVICES_PROBE=menu` is set — the popup is modal, so the capture has
  > to happen inside `VAILS_SERVICES_PROBE_HOLD_MS`. Note that a full-screen
  > capture can come back showing the Windows Widgets panel instead of the app
  > if that overlay is up, which is what made this one get skipped.

  The hold timer is armed *before* the call, because on Windows `menu.popup`
  is a modal native loop — a timer armed after the `await` would start once
  the menu was already gone. `menu.close` posts `WM_CANCELMODE`, which the
  menu's own nested loop processes; that is the only way out of it from
  outside, and it is why `close` is a post and not a call.
  `menu:clicked {id}` needs a human to pick an item, so it is a checklist
  item, not a screenshot.

- **`tray` — the OS-driven click loop, machine-proven.** `tray.set` installs a
  `NOTIFYICONDATA` whose `uCallbackMsg` is `WM_APP+1` and installs a comctl32
  subclass through `webview/host.v`; the example's worker then posts the message
  the shell would post on a click, and the page's `tray:clicked` handler
  reports it. Proof: the status line says `clicked: left`, which means the
  whole `PostMessage(WM_APP+1)` → subclass → V → `ctx.emit` → JS path ran:

  The status line is the proof. The screenshot that showed it is gone (see the
  note at the top of this file) — and it was never going to show the icon
  anyway: Windows 11 puts new tray icons in the overflow flyout, and a
  synthetic message cannot be screenshotted. The "pixels are a per-session
  setting" caveat applies, which is why the status line is the machine-checkable
  evidence.
  - Manual check by eye: press **Install tray icon**, click the icon in the
    notification area (overflow `^` on Windows 11), and confirm the status
    line shows `clicked: left` or `clicked: right`. **Remove it** must leave
    no icon behind — that is `tray.destroy`, which removes the icon *and*
    detaches the subclass.
  - **Open popup menu** with the page focused: the menu is owned by the
    window, so clicking away dismisses it and the page reports
    `menu:canceled`. Picking **About Vails** reports `menu:clicked` with
    `id: about` — that is the id → HMENU command id → back again mapping.
  - **Remove it** twice: the second press is a no-op, not an error (a
    frontend that cleans up defensively must not get a rejection).
  - `vails doctor` now prints `7/7 service(s) native here` and lists
    `menu` and `tray` with the mechanism each one uses.

## Phase 5 S1 wave 4 — `menu.set_menu`, the window menu bar (ADR-0023) — **unproven at runtime**

`menu.set_menu` compiles and links on Windows, and the classifier behind it
(`services/menu.v`'s `bar_click`, which turns a `WM_COMMAND` into an item id and
rejects everything that is not one of ours) is unit-tested on every platform.
It has **not** been run in a window here: the capture session could not get the
E2E window to come up, so there is no screenshot. The one-command check:

```powershell
$env:VAILS_SERVICES_PROBE = "menubar"
v -cc gcc -o services.exe ./examples/services
Copy-Item C:\msys64\ucrt64\bin\{libwebview-0.12.dll,WebView2Loader.dll,libgcc_s_seh-1.dll,libstdc++-6.dll,libwinpthread-1.dll} .
Copy-Item examples\services\frontend .\frontend -Recurse
Copy-Item examples\services\vails.json .
.\services.exe
# 1. the window has a menu bar along the top: File  Edit  Help
# 2. click File -> the status line reads "chose: file" and the File drop-down
#    opens; that is CreateMenu + SetMenu + DrawMenuBar, the WM_COMMAND, the
#    bar's second host-seam hook, and menu:clicked, all in one
# 3. click Help -> "chose: help"
# 4. install it again with a different tree -> the bar is replaced and the old
#    HMENU is gone (no ghost entries)
# 5. the page's popup still works while the bar is installed: the two have
#    separate id spaces and separate hooks
# 6. VAILS_SERVICES_PROBE=menu (the popup) still behaves as above
```

What makes step 2 interesting is that the tray may also be installed: two
`SetWindowSubclass` entries now sit on one window, the bar's and the tray's, and
each handler declines the messages that are not its own. If picking a menu
item ever stops the tray from being clickable, the chaining is wrong — that is
the regression to look for, and it is the one thing this platform's run would
have caught.

## Phase 5 S1 wave 4 — `tray.set_menu` (ADR-0026) — **unproven at runtime**

`tray.set_menu` compiles and links on Windows, and its whole policy — which
message shows the menu, which emits a click, which is passed on — is the pure
`decide` function in `services/tray.v`, unit-tested on every platform. It has not
been run in a window here, so there is no screenshot.

```powershell
$env:VAILS_SERVICES_PROBE = "traymenu"
v -cc gcc -o services.exe ./examples/services
Copy-Item C:\msys64\ucrt64\bin\{libwebview-0.12.dll,WebView2Loader.dll,libgcc_s_seh-1.dll,libstdc++-6.dll,libwinpthread-1.dll} .
Copy-Item examples\services\frontend .\frontend -Recurse
Copy-Item examples\services\vails.json .
.\services.exe
# 1. "Attach a menu to it" -> the page says the menu is attached
# 2. RIGHT click the icon in the notification area -> the menu opens
#    (Open / Settings / - / Quit). This is the part that needs a version-4
#    icon: NIM_SETVERSION is what makes WM_CONTEXTMENU arrive at all
# 3. click Quit -> the page's menu:clicked handler reports tray/quit
# 4. LEFT click the icon -> the page reports tray:clicked {left}. A menu is a
#    CONTEXT menu and must never take the left click; if step 4 shows a menu
#    instead, that rule is broken
# 5. attach a menu with a different tree -> it is replaced, no ghost entries
# 6. set_menu({items: []}) (or destroy the icon) -> a right click reports
#    tray:clicked {right} again, as it did before tray.set_menu existed
```

Step 6 is the one that matters most for an upgrade: the contract change is that
a right click *stops* emitting while a menu is attached, and step 6 is the proof
that removing the menu puts everything back.

**The regression this platform is best placed to catch.** The Windows tray
handler once branched on a `bool` that conflated "the menu owns this message"
with "not the tray's message", and answered the second by opening the tray menu
and consuming the message. Its visible effect was that an installed tray icon
ate the window menu bar's `WM_COMMAND` — so in a window with both, picking a bar
item did nothing. Step 6 of the `menubar` check above (bar and popup together)
and step 3 here are the two that would show it. Fixed and pinned by a test; see
ADR-0026 decision 3.

## U0/W0 — `webview.post_to_main`, the main-thread post seam (ADR-0019, 2026-09-30) — **proven**

This is the first proof in this file that is **V-side initiated**: nothing on the
page is clicked, and the status line changes on its own. That is the point of the
feature — a `spawn`ed worker has no way to call `ctx.emit` (it ends in
`webview_eval` on a thread the webview object does not own), so before U0 a worker
computed its result and dropped it on the floor.

```powershell
$env:VAILS_SERVICES_PROBE = "post"
v -cc gcc -o services.exe ./examples/services   # same 5 DLLs next to the exe
./services.exe
```

The `post` panel reads, in green:

> `probe post: ok · worker posted back to the main thread`

That single line is the whole round trip: a worker spawned in `on_ready` →
`webview.post_to_main` → the queue behind its mutex → a `WM_APP+2` wakeup → the
window thread drains it → the job calls `ctx.emit` → the page's `probe:done`
listener renders. Screenshot: **`post.png`** in this directory.

This run earned its keep twice, and both catches are the reason it is here:

- **A false-positive probe.** The page-side probe snippet originally returned
  `Promise.resolve("waiting for the worker to post back...")`, and the generic
  probe wrapper turns any resolved value into a `probe:done`. So the page
  reported `ok` **on page load**, before the worker had posted anything — a
  green line that proved nothing and raced the real answer to the same panel.
  The snippet now returns a promise that never settles
  (`new Promise(function () {})`), so the V-side `report_probe` is the only
  thing that can report this probe. A unit test could not have found this: the
  whole failure mode is that the page lies.
- **`SetWindowSubclass` from the wrong thread.** ADR-0019 planned to install the
  wakeup subclass lazily, on the first `post_to_main` call. The first real run
  failed with `vails: post_to_main could not install the window wakeup: vails:
  SetWindowSubclass failed (code 0)`. `SetWindowSubclass` is thread-affine, and
  `post_to_main` is by definition called from a worker — so the planned design
  was the *only* one that could not work, and it failed on the first post, from
  the only thread that posts. `webview.run` now installs the wakeup itself on
  the window thread, before `on_ready`; see ADR-0019 "Decisions (as shipped)".

**Regression to look for:** the job wakeup is now a **second** `SetWindowSubclass`
on every window, chained with `tray`'s. If installing a tray icon ever stops the
`post` probe from reporting — or the reverse — the chaining is wrong. Both
handlers decline messages that are not theirs (`WM_APP+1` is the tray's,
`WM_APP+2` is the wakeup's), which is what keeps a wakeup from arriving at the
tray as a "left click".

**Not proven here: the Linux half.** The `g_idle_add` trampoline is unwritten, so
`post_to_main` returns `... is not available on linux yet` there. See
`tests/e2e_linux/README.md`.

### Capturing a privacy-safe shot of this one

Two things bite, and both are recorded because `post.png` had to be re-taken
after each:

1. **The services window is 1089 px tall, which is taller than the desktop.**
   `capture.ps1` captures `GetWindowRect`, and `CopyFromScreen` on a rect that
   runs off the bottom of the screen leaves a **strip of the taskbar — with the
   user's installed apps in it — across the bottom of the frame**. That is the
   exact leak the header of `capture.ps1` describes, and it is why `post.png` is
   clamped to the work area (`SPI_GETWORKAREA`) rather than shot straight from
   the window rect. If you re-take it, keep the clamp.
2. **`SetForegroundWindow` can fail while the webview is still loading.** The
   shot then captures whatever is on top — a browser, with a URL bar in it. Wait
   past the probe's own settle window (~6 s here) *before* raising the window,
   and check that the window really owns the foreground before capturing; a
   retried raise loop alone is not enough if the raise happens too early.

## F0 — two windows on Windows (ADR-0035) — steps 1–4 **PROVEN** 2026-10-04; step 6 is a **known defect**

**Result of the run, and it found two shipped bugs.** `examples/multiwindow`
with `VAILS_MULTIWINDOW_PROBE=pings` now passes steps 1–4 with both windows
captured. Along the way it turned up two defects that had been in the tree since
2026-09-30 behind a green `v vet` and a clean `v fmt`, both in the cross-thread
emit, and both now fixed and guarded by `buildplan/dispatch_test.v`:

1. **`webview_dispatch`'s result was read backwards.** It returns a
   `webview_error_t`, not a bool — `WEBVIEW_ERROR_OK` is **0** and success is
   `>= 0`. The code was `if (!webview_dispatch(...)) { free the job; fail }`, so
   the failure branch ran **on success**: it freed the job the window thread was
   about to execute (a use-after-free) and then reported a healthy window as
   refusing the emit.
2. **Fixed, the dispatch crashed anyway** — `0xC0000005`, faulting module
   **`libwebview-0.12.dll`**, thrown inside the library on the **calling**
   thread. It needs a COM apartment where it is called and every caller here is
   a `spawn`ed worker, which has none. `com_enter` gives each window's thread an
   apartment and fixed window *creation*; it says nothing about the caller.

The cross-thread path now uses **`post_to_main`** (a queue plus a `PostMessage`
to a comctl32 subclass): pure Win32, needs no apartment from either thread, and
already screenshot-proven by ADR-0019. The owner-thread path still calls
`webview_eval` directly, because services depend on an emit from a handler
having taken effect by the time the handler returns.

**What the proof showed** (both windows captured with `PrintWindow`, which
renders window content only — `CopyFromScreen` frames whatever is behind the
window, and this repository purged desktop-leaking screenshots from its history
once already):

| claim | evidence |
|---|---|
| two windows, one document | both titled `Vails Multiwindow - main` / `- settings` |
| per-window runtime injection | each badge shows **its own** label |
| routing, forward | `settings` inbox: `pinged by main (I am settings)` |
| routing, reverse | `main` inbox: `pinged by settings (I am main)` |
| broadcast | both inboxes list it |
| **no echo** (the negative half) | **neither** sender's status line moved — still `no result yet` |

Four runs: four `webview_eval` successes each, empty stderr.

### Step 6 is a real, open defect — do not record it as passing

Closing a window leaves the process running with **no windows**, reproducibly:

| what you close | result |
|---|---|
| the **second** window first | exits cleanly |
| the **first** window first | **hangs forever**, 0 windows, ~5 threads |
| single-window `examples/hello` | exits cleanly |

So it is specific to N > 1 and it is **order-dependent**, which is the useful
part. A debugger attach shows the main thread still inside `webview_run` →
`GetMessageW` with its window already destroyed and no `WM_QUIT` in its queue:
the library only ends the loop for the **last** webview torn down in the
process. `run_windows` then waits forever for a token no thread will send.

**Two fixes were tried and reverted**, recorded so a third attempt starts from
the measurement rather than from scratch:

- `webview_terminate(w)` on `WM_DESTROY` — ends the hang, but closing one window
  then takes the **other** one down too.
- `PostThreadMessageW(owner_thread, WM_QUIT, …)` — same over-correction, and that
  is the informative part: the surviving window is *not* being closed by the
  quit, so whatever couples the two is downstream of the loop.

The right shape is the one Linux already has: a Windows **last-window rule** that
does not treat "`webview_run` returned" as the liveness signal, because it is not
one. That is real work, not a patch.

```powershell
$env:VAILS_MULTIWINDOW_PROBE = "pings"
v -cc gcc -o multiwindow.exe ./examples/multiwindow
Copy-Item C:\msys64\ucrt64\bin\{libwebview-0.12.dll,WebView2Loader.dll,libgcc_s_seh-1.dll,libstdc++-6.dll,libwinpthread-1.dll} .
Copy-Item examples\multiwindow\frontend\index.html .
Copy-Item examples\multiwindow\vails.json .
.\multiwindow.exe
# 1. TWO windows come up, not one. This is the whole claim: window 2 lives on a
#    second thread with its own STA.                                    [PROVEN]
# 2. each window's badge shows its OWN label (main / settings) - the per-window
#    runtime injection, so one document can tell the two pages apart    [PROVEN]
# 3. ~2s in, the "settings" window's inbox lists a ping FROM "main", and the
#    "main" window's inbox lists a ping FROM "settings". The RECEIVER's inbox is
#    the evidence; the sender only ever says "sent"                     [PROVEN]
# 4. both inboxes then list the broadcast, and NEITHER sender's own line moved
#                                                                     [PROVEN]
# 5. close ONE window -> the other stays up and stays interactive     [PROVEN]
# 6. close both -> the process exits on its own, no orphan thread    [FAILS today]
```

**What counts as passing:** steps 1–4, with a screenshot showing **both**
windows at once. Two separate screenshots do not prove the claim — the failure
mode is one window rendering perfectly while the other is dead, which is exactly
what two separate shots would hide.

**What to do if it dies at step 1 with no second window:** that is the pre-`com_enter`
symptom and it means the apartment is not taking. Check the stderr for
`webview[settings]:` — `com_enter`'s return value is not logged today, and
logging it (S_OK / S_FALSE / RPC_E_CHANGED_MODE) is the first thing to add if
this needs diagnosing from a bug report rather than from this machine.

## F1 — drag & drop (`drop` service, ADR-0036) — **unproven at runtime**

Same status as the section above, for a different reason: this one needs a human
to drag a file, and the Windows GUI proofs need this machine's `webview` module.
The policy (bounds, payload, which message is a drop) is proven by 18 pure-V
tests; **the native path has never been exercised.**

Read this before assuming the page gets a DOM event, because it does not.
`DragAcceptFiles` on the top-level window takes the drop away from WebView2's
child, so **there are no `dragover` / `drop` handlers in the page** — the service
emits `drop:files` instead. That is the price of the only reachable exit
(`EnableWebDrop` is a controller setting the webview library does not expose —
ADR-0036's Context).

```powershell
# FIRST: grant the capability. `examples/services/vails.json` does not include
# `drop` yet, because nothing in that example calls it - an unused grant is a
# promise the manifest makes to nobody. Add to the "capabilities" array:
#
#   { "id": "drop", "windows": ["main"],
#     "commands": ["drop.enable", "drop.disable"],
#     "asset_roots": [], "platforms": [] }
#
# `vails doctor --config examples\services\vails.json` must then list 8
# services and `drop` among them - that is the cheapest check that the catalog,
# the manifest and the grant agree, and it needs no window.
v -cc gcc -o services.exe ./examples/services
Copy-Item C:\msys64\ucrt64\bin\{libwebview-0.12.dll,WebView2Loader.dll,libgcc_s_seh-1.dll,libstdc++-6.dll,libwinpthread-1.dll} .
Copy-Item examples\services\frontend .\frontend -Recurse
Copy-Item examples\services\vails.json .
.\services.exe
# 1. from the page's console, call window.vails.drop.enable() (needs the
#    `drop.enable` capability granted above). Then drag ONE .txt file from
#    Explorer onto the window.
# 2. the page receives drop:files with {"paths":["C:\\...\\notes.txt"],"count":1}
# 3. drag a .png and a .md TOGETHER -> one event, count 2, the user's order
# 4. drag a whole FOLDER -> the paths the shell reports; the report is capped at
#    64 (ADR-0036) so this is where the bound shows, and `count` is the number
#    actually reported, not the number offered
# 5. drag something with no name (a shortcut) -> an event with paths: [] and
#    count 0. NOT silence: an empty report is a deliberate rule, and a page that
#    waits for a non-empty drop is the bug this step catches
# 6. call drop.disable() -> the next drag does nothing, and the window has no
#    drop hook left on it
```

**What counts as passing:** steps 1–3, with the status line showing the paths.
Step 5 is the one most likely to be got wrong and the cheapest to check.

**Note on `examples/services`:** it has no drop panel yet, so steps 1 and 6 are
console/`v.run` calls for now. Adding the panel is R4's job (one screenshot per
panel), not this ADR's.

## Phase 5b — the GTK `dialog`, from the Windows side (ADR-0027)

Nothing changed on Windows: `dialog.open` / `save` / `message` are still the
Common Item Dialog and `MessageBoxW`, and the manual check in the wave-1 section
above still applies unchanged. ADR-0027 only adds the Linux half.

What *did* change is the shared surface, so it is worth confirming nothing
regressed on the side that was already working: the four button names
(`ok` / `yes` / `no` / `cancel`) and the `{canceled, paths, button}` shape are
now pinned on both platforms by the same pure-V tests, so the two native halves
are held to one vocabulary. If a GTK dialog ever reports a button the Windows
box does not, that is the assertion to look at.


## If `doctor` says the WinRT class store is missing (ADR-0039)

`vails doctor` prints this on a machine whose Windows cannot activate **any**
WinRT class:

```
stub notification - ... this Windows has no WinRT class store:
HKLM\SOFTWARE\Classes\ActivatableClasses\ClassId is missing, so NO WinRT class
can be activated - not just the toast ones. This is a stripped/debloated
Windows image, not a Vails bug, and no AppUserModelID will fix it.
```

The first thing to check, because it costs nothing and it is the diagnostic
that matters:

```powershell
# 0. does the store exist? On a healthy Windows 11 this key HOLDS THOUSANDS of
#    system WinRT classes, so "absent" is the whole answer
Test-Path 'HKLM:\SOFTWARE\Classes\ActivatableClasses\ClassId'

# the two branches a debloat script removes, and the two it leaves alone
Get-ChildItem 'HKLM:\SOFTWARE\Classes\CLSID' | Measure-Object   # ~7447 = COM fine
Get-ChildItem 'C:\Windows\WinSxS' -Directory | Measure-Object  # ~20 000 = fine
```

- `ClassId` **absent** and COM/WinSxS fine -> a stripped image. This is what
  the note above describes, and it affects every WinRT API, not just toasts.
- `ClassId` **present** but the toast still fails -> a partial install of the
  notification component; `doctor`'s other note covers that case.

### Repair

Run from an **elevated** prompt. This is deliberately not automated: it is an
admin operation on the user's machine, and a test suite should not have the
ability to run it.

```powershell
# 1. repair the component store - this is what can put the registry branches
#    back, because they are delivered as component manifests
DISM /Online /Cleanup-Image /RestoreHealth

# 2. then repair the system files themselves
sfc /scannow

# 3. re-check (a reboot is worth doing before judging the result)
Test-Path 'HKLM:\SOFTWARE\Classes\ActivatableClasses\ClassId'
.\vails.exe doctor
```

If step 3 still reports the key as missing, the image was trimmed far enough
that the manifests are gone too. The reliable fix is an **in-place repair**:
mount an official Windows 11 ISO and run its setup, choosing *Keep files and
apps*. That rebuilds the component store from Windows' own media without
touching your apps or files.

### What works while the toast does not

Worth knowing before spending an afternoon on repair, because the point of
diagnosing this precisely was to know which parts of the framework are
affected:

| capability | needs WinRT? | on a stripped image |
|---|---|---|
| `dialog.open` / `save` / `message` | no - COM (`IFileOpenDialog`, `MessageBoxW`) | **works** |
| `tray`, `menu`, `clipboard`, `opener`, `drop` | no - Win32 + `shell32` | **works** |
| `notification` (toast) | **yes** | fails, with the note above |
| `balloon` | no - `Shell_NotifyIconW` + `NIF_INFO` | **works** |

`notification` is deliberately WinRT-only (ADR-0039): it has no fallback, so it
fails loudly rather than showing you a message that is not a real Windows
notification. The `balloon` service exists for the other case, as its own
service - not as a substitute, and never reachable through `notification`.

## `balloon` service (ADR-0039) - secondary shell message - **RUNS, seen only by a human**

Pure V and unit-tested (`services/balloon_test.v`); the shell calls are not,
because a balloon needs a notification area and a human. `examples/showcase`
and `examples/services` both ship a panel/button for it.

**What a verify run already proves** (measured 2026-10-03, Windows 11 build
28000, the machine whose WinRT class store is missing):

```
notify       FAIL    ... RoGetActivationFactory(ToastNotificationManager) failed (hr=0x80040154)
balloon      NEEDS YOU  balloon reported ok - it appeared in the notification area, ...
```

Two lines from one run, and they are the whole argument for ADR-0039: the toast
cannot work on this machine and the balloon can. `balloon.show` resolved with
`"balloon"`, which means `Shell_NotifyIconW` took the icon - the native half is
live, not just compiled.

What that run does **not** prove is the part only a human sees: that a balloon is
visibly readable, and that the temporary tray icon is removed afterwards. Watch
the notification area:

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -o services.exe ./examples/services   # same 5 DLLs next to the exe
# or the reference vehicle, which also proves the pair side by side:
v -cc gcc -o showcase.exe ./examples/showcase
$env:VAILS_SHOWCASE_VERIFY = '1' ; .\showcase.exe
```

`examples/services` and `examples/showcase` both ship the grant already, so
`vails doctor --config examples\services\vails.json` lists **8** granted services
and `examples\showcase` lists **11** capabilities - both including `balloons`.

The `vails doctor` check that matters before anything else:

```powershell
vails doctor
```

must show two visibly different lines - `notification` refusing the toast with
the WinRT-class-store diagnosis, and `balloon` reporting `ok`. If balloon's note
ever says "toast", ADR-0039 has been broken.

Then, from the page's console (or the "Show balloon" button in
`examples/services`, which is the same call):

1. `window.vails.balloon.show({ body: "first balloon" })` - a balloon appears in
   the notification area and the promise resolves with `"balloon"`.
2. Add a title: `{ title: "Build", body: "2 errors" }` - the balloon carries both
   strings. On Windows 11 it is attributed to the **bare `.exe` name**, which is
   the limitation ADR-0018 refused to accept for `notification` and the reason
   this is a separate service.
3. **The dead-icon check, and the one that actually matters.** After the balloon's
   `timeout_ms` plus ~1.5 s, the tray icon must be **gone**. Watch the
   notification area while sending five balloons in a row: at most one icon is
   present at any time, and the area is empty once they have passed. A row of
   icons that never clears is ADR-0018's third objection reproducing, and the
   per-call `uId` in `balloon_icon_id` is what prevents it.
4. Send two balloons while the first is still up - the first's icon must not
   reappear, and the second must not be deleted early. That is the "a late worker
   deletes the winner's icon" case, and it is what the 1024-id span buys.
5. `balloon.show({ body: "" })` - rejected with `bad params:` naming
   `body is required`. A balloon with no text is a tray icon with nothing
   attached to it.
6. `balloon.show({ body: "x".repeat(256) })` - rejected with `bad params:` naming
   `body`. The bound is the shell's own `szInfo` width (256 units, minus the
   NUL), so a caller that fits is never clipped by the platform.
7. `balloon.show({ body: "needs a window" })` from a headless caller (no window)
   - an error explaining that a balloon is a tray icon and therefore belongs to a
   window. Unlike `notification`, which the shell attributes on its own.
8. `balloon.show` without the grant - `forbidden:`, never `unknown method`.
