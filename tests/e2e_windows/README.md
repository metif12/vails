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

## F0 — two windows on Windows (ADR-0035) — **unproven, and this is the run that settles it**

This is the one outstanding item in the whole Windows list, and it is not a
routine check: **nobody has watched two windows open on this platform.** The
routing rules are proven by `webview/window_test.v` (two fake eval sinks, no
window), and the backend now gives every window's thread its own COM apartment
(`com_enter` in `webview/webview_windows.c.v`) before `webview_create` — but
that fix has only been type-checked. It has not been run. The machine this was
written on crashes its host on the `webview` test module, so the run never
happened there.

What the fix is for, because "it did not work" is not a reason: WebView2 binds
the HWND, the COM apartment and the message pump to the thread that created the
window, and `webview_run` blocks per instance — so window 2 needs its own
thread, and a `spawn`ed thread has **no apartment**. The measured symptom
without the fix is nasty: the second window *appears*, its page renders, and
then the library refuses the first `webview_dispatch` to it and the process
dies. That is why the code used to refuse a second window by name.

```powershell
$env:VAILS_MULTIWINDOW_PROBE = "pings"
v -cc gcc -o multiwindow.exe ./examples/multiwindow
Copy-Item C:\msys64\ucrt64\bin\{libwebview-0.12.dll,WebView2Loader.dll,libgcc_s_seh-1.dll,libstdc++-6.dll,libwinpthread-1.dll} .
Copy-Item examples\multiwindow\frontend\index.html .
Copy-Item examples\multiwindow\vails.json .
.\multiwindow.exe
# 1. TWO windows come up, not one. This is the whole claim: window 2 lives on a
#    second thread with its own STA.
# 2. each window's badge shows its OWN label (main / settings) - the per-window
#    runtime injection, so one document can tell the two pages apart
# 3. ~2s in, the "settings" window's inbox lists a ping FROM "main", and the
#    "main" window's inbox lists a ping FROM "settings". The RECEIVER's inbox is
#    the evidence; the sender only ever says "sent"
# 4. both inboxes then list the broadcast. If routing had collapsed to "one
#    window", broadcast is what notices
# 5. close ONE window -> the other stays up and stays interactive. This is
#    webview_linux_shim.h's last-window rule's Windows counterpart and the
#    reason `stop_all` exists
# 6. close both -> the process exits on its own, no orphan thread
```

**What counts as passing:** steps 1–4, with a screenshot showing **both**
windows at once. Two separate screenshots do not prove the claim — the failure
mode is one window rendering perfectly while the other is dead, which is exactly
what two separate shots would hide.

**What to do if it dies at step 1 with no second window:** that is the pre-fix
symptom and it means the apartment is not taking. Check the stderr for
`webview[settings]:` — `com_enter`'s return value is not logged today, and
logging it (S_OK / S_FALSE / RPC_E_CHANGED_MODE) is the first thing to add if
this needs diagnosing from a bug report rather than from this machine.

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
