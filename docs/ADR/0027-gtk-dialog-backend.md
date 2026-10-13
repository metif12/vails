# ADR-0027 — The GTK `dialog` backend, and the tests a modal window cannot have

Status: accepted
Date: 2026-09-29
Supersedes: nothing. Completes the Linux half of ADR-0014, whose stub said it
"needs a Linux toolchain" — a reason that had expired two waves earlier.

## Context

ADR-0014 shipped `dialog` with a real Windows backend (the Common Item Dialog via
`services/dialog_shim.h`) and, on Linux, a stub that returned
`not implemented on linux`. The stub's stated reason was that it needed a Linux
toolchain. By the time this was written the toolchain existed, GTK 3.24 and
WebKitGTK 4.1 were both present, and the *actual* remaining difficulty was one
thing: the commands are `blocking: true`, so testing them means answering a
modal window.

The stub also carried a bug in a comment. It said to parent the chooser to
`Ctx.parent`. The chooser wants a `GtkWindow*`; `Ctx.parent` is a `GdkWindow`,
a different object, and not accepted there. ADR-0023 added `Ctx.toplevel` for the
window menu bar, and the dialog is its second consumer — the field was needed
either way, and the comment would have been a type error at best.

## Decision

### 1. The response-id mapping is pure V, in the shared file

GTK answers a dialog with a response id, not a boolean. Everything a frontend
sees is decided by two functions, and both live in `services/dialog.v` so they
are tested on every platform — including Windows, where the native backend does
not exist:

```v
pub fn gtk_button_name(rc int) ?string
pub fn gtk_message_result(rc int) Result
pub fn gtk_chooser_accepted(rc int) bool
```

`gtk_response_*` constants are literals in the same shared file, for the reason
`menu.wm_command` and `host_message` are: the *classification* is the part worth
testing, and a Linux-only file would make it testable only on the platform where
it can never run in CI.

Three decisions inside that mapping are worth stating:

- **The four closed ids are one button.** `CANCEL`, `REJECT`, `DELETE_EVENT` and
  `CLOSE` all report `cancel`. From a frontend's point of view they are one user
  intent — declined — and reporting them separately would push that distinction
  into every app.
- **An unknown id is not guessed.** A custom response id reports `button: "none"`
  with `canceled` set, rather than being coerced into one of the four names.
- **Only `ACCEPT` means the chooser took the files.** Treating `CANCEL` as
  acceptance is how a file dialog returns a path the user never chose.

The mapping is pinned against the Windows half: `OK`/`YES`/`NO`/`CANCEL` are the
same four names `MessageBoxW`'s `IDOK`/`IDYES`/`IDNO`/`IDCANCEL` produce, so
switching platforms does not make a frontend translate a button name.

### 2. Three GTK facts, each verified before being written down

- **`gtk_dialog_run` spins a nested main loop.** This is the documented ADR-0014
  exception that lets the dialog commands be `blocking: true`. It carries two
  rules: never `gtk_main_quit` from a response handler (it would kill the app's
  loop, not the dialog's), and never assume the loop you return to is the one you
  were called from.
- **The parent is `Ctx.toplevel`,** not `Ctx.parent`, per the Context section.
- **`g_filename_to_utf8` is a five-argument macro,** not a two-argument function.
  Declaring it from V with two arguments compiles to a call the GLib header
  static-asserts against. The conversion gets a wrapper in `services/list_shim.h`,
  which also has to exist anyway: walking a `GList` means reading `->data` and
  `->next` at pointer offsets, which V cannot express (no `ptradd`, no struct
  casts off a `voidptr`), and the shim's output is deliberately the same
  NUL-separated buffer the Windows shim produces so the shared `parse_paths`
  splits it on both platforms.

A fourth, found while writing the proof: the message text is passed to GTK as a
literal argument against a `"%s"` format, because a frontend's message is
arbitrary text and passing it as the format string would turn a `%s` in a
message into a read of a garbage pointer.

### 3. A call with no display is an error, not a segfault

Every GTK entry point requires a successful `gtk_init`. Calling one without it
is undefined behaviour that in practice crashes inside the library, with no
message and no V frames in the backtrace. A service can legitimately be called
before the webview is up, or from a process with no `DISPLAY` at all.

`gtk_init_check` (not `gtk_init`, which would open a display as a side effect of
asking) runs first, and all three commands refuse with a message naming the
cause. This was not speculative: the moment the backend became real, the test
suite died this way.

### 4. A modal dialog cannot be unit-tested, and the coverage splits instead

The stub-era test asserted `not implemented`. Once a real backend existed, that
test had exactly two possible outcomes and **both are wrong**: with no display it
returns an error, and with a display it opens a real modal dialog and parks in
`gtk_dialog_run` forever. A hang is not a test, and an error that depends on
whether the machine has a display is not a contract.

So the coverage is split, and both halves are real:

- **The response-id mapping** — the full rejection matrix — is pure V in
  `services/dialog_test.v`, and runs on every platform.
- **The widget, the nested loop and the real response** are proven end to end in
  `tests/e2e_linux` with `VAILS_SERVICES_PROBE=dialog`, which answers the dialog
  from a `g_timeout_add` callback. A screenshot then shows the real button the
  probe pressed arriving as the right `button` value, which is the whole claim:
  the real response id travelled through the real nested loop and the real
  mapping.

The proof lives in the **example**, not in `services/`. It finds the dialog via
`gtk_window_list_toplevels` and answers whichever modal toplevel is open, so the
service needs no test hook, no probe flag, and no cooperation whatsoever — the
only arrangement under which the proof means anything. `services/` never learns
it is being observed.

`message` is the one command that can be fully proven this way: it needs no file
system, so nothing has to be typed or chosen.

### 5. What the Windows side does not need

Nothing. `dialog.open`/`save`/`message` are unchanged on Windows, and the
Common Item Dialog still owns those three commands there. The buttons, the
result shape, the ids and the parse are shared; only the widget differs.

## Alternatives rejected

- **Keep the test calling the native path on Linux.** Rejected in decision 4: it
  hangs or it is environment-dependent.
- **Stub the GTK calls in the test layer.** Would have kept a test green while
  proving nothing — the response mapping is the easy half to get wrong and the
  nested loop is the hard half to notice.
- **An injectable backend in the service** (a function pointer the test
  replaces). More machinery than the problem needs, and it would have left the
  native path unproven.
- **Have the E2E proof click the dialog with `xdotool`,** as the menu-bar proof
  does. A modal dialog under headless Xvfb needs the window manager to give it
  focus first, which is exactly the flakiness the other probes avoid. A timer
  inside the GTK main loop is deterministic.
- **Non-blocking dialogs** (show now, await an event). The better long-term API
  and not this one: it changes the manifest contract for every existing caller,
  and ADR-0014 already recorded `blocking: true` as the deliberate choice.
- **Hand-declare a GList struct in V and walk it.** Pointer arithmetic in a
  service file, which is the one thing AGENTS.md §2 keeps out of V. A three-line
  shim is the honest shape.

## Consequences

- `dialog` is real on both platforms. `README.md`'s platform table and its
  "known differences" row change accordingly.
- The Linux `dialog` commands refuse with a named error when there is no display.
  That is new behaviour on a path that previously returned `not implemented`, so
  a frontend that matched on that string must stop — it was never a contract.
- `services/list_shim.h` exists and is Linux-only by filename. The Windows shim
  keeps its own buffer; both produce the same shape for the shared parser.
- `examples/services` gained three buttons and a `dialog` probe, and needed a
  `dialogs` capability grant. A generated `.d.ts` that is stale will leave
  `window.vails.dialog` undefined, which is a loud failure in the page rather
  than a silent one.

## Verification

- **Pure V:** `services/dialog_test.v` — the four-way "no" collapse, `ACCEPT`
  mapping to `ok`, unknown ids not guessed, only `ok`/`yes` counting as accepted,
  `button` always one of five names, and only `ACCEPT` meaning the chooser took
  files. Runs on Windows too, where there is no GTK.
- **Linux, proven end to end:** the probe run recorded in
  `tests/e2e_linux/README.md` — a real `GtkMessageDialog` answered by a timer,
  reporting the button the probe pressed. **Erratum (2026-10-05):** this bullet
  cited `tests/e2e_linux/dialog.png` as its evidence, and that file has never
  existed in this repository — `git log --all -- tests/e2e_linux/dialog.png`
  returns no commits. The run itself is not in doubt; the *artifact* was. The
  claim rests on the probe's stdout, and the linked section now says so.
- **Linux, deliberately not unit-tested:** the native path, per decision 4. The
  test that would have done it is replaced by one that asserts the gate rejects
  bad input *before* the widget is built.
- **Windows:** unchanged, previously manual, still documented as such in
  `tests/e2e_windows/README.md`.
- Linux and Windows `v test .` are 32/32.
