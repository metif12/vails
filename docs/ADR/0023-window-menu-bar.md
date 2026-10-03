# ADR-0023 — `menu.set_menu`: the window menu bar, and a seam that takes two hooks

Status: accepted
Date: 2026-09-29
Supersedes: nothing. Amends ADR-0017 (which deferred the bar), and corrects two
claims in `webview/host_shim.h` and `webview/host.v`.

Numbering note: this started as 0019 and was renumbered to 0023 mid-work,
because ADR-0019 through 0022 were taken by other decisions while it was being
written. Nothing here depends on the number.

## Context

ADR-0017 shipped `menu` as a **popup only** and said why, in terms that were
right at the time:

> `menu.set_menu` is explicitly not part of the `menu` service: a window menu
> bar is `SetMenu` plus `WM_COMMAND` routing, a service of its own.

Two things had to exist before that could change, and neither did:

1. **A second listener on one window.** A bar's answer arrives as `WM_COMMAND`
   on the window; the tray's arrives as `WM_APP+1` on the same window. The seam
   installed by ADR-0017 had exactly one handler slot, so the two would have had
   to share it and dispatch by message — or one would have had to win.
2. **A way to say "not my message".** Whoever listens first would otherwise
   swallow every message, including the ones the webview library needs.

There was also a GTK3 problem nobody had hit yet, because the bar had never
been written: `gtk_window_set_menubar` does not exist.

## Decision

### 1. The seam takes a chain of subclasses, and each says what it consumed

`HostHandler` now returns `bool`:

```v
pub type HostHandler = fn (e HostEvent) !bool
```

`true` means "consumed, do not pass it on"; `false` means "not mine", and the
message continues down the chain to the next subclass and eventually to the
webview library's own procedure. An **error** is treated as consumed, because
it means the handler recognised the message and then failed — the frontend
notices as an event that never arrives, which is the same contract ADR-0017
documented.

`host_proc` no longer filters on a hardcoded id. It asks the handler about every
message. Filtering in `host_proc` was correct with one hook and is wrong with
two: a message the inner hook does not own would never reach the outer one.

Nothing else changed. `attach` already allocated a `HostCtx` per call and
already passed that address as the comctl32 `uIdSubclass`, so two attaches were
*already* two entries in a chain — the single-handler slot was the only thing
preventing it. The tray installs its hook on first `tray.set`; the bar installs
its own on first `set_menu`; neither knows the other exists.

**The false claim this corrects.** `host_shim.h` asserted "the subclass id IS
the context, and there is exactly one hook per window", and `host.v` repeated
it. That was true only because there was one caller. It is not a property of
the mechanism: comctl32 keeps subclasses in a chain, calls the most recently
installed first, and routes through `DefSubclassProc` to the next one down.
Because the id is a per-call heap address, `RemoveWindowSubclass` removes
exactly one and cannot take a neighbour with it. Both files now say this.

### 2. A window menu bar is the same service, not a new one

`menu.set_menu` takes the **same** `MenuItem` params as `menu.popup`, validates
them with the same `parse_popup` / `validate_items`, assigns ids from the same
`flatten_items` order, and answers on the **same `menu:clicked` event**. It is
not marked `blocking`: installing a bar is not modal, nothing waits for a user.

The reason to keep one service is the vocabulary. A frontend that has one
`menu:clicked` listener serves a right-click popup and a window menu bar with
the same code. Splitting them into two services would mean two prefixes, two
id rules and two event names for what the user experiences as one feature.

An **empty item list removes the bar.** `set_menu({items: []})` is the way to
take it away, so a frontend that shows and hides its own chrome does not have
to special-case "pass `{}` to mean no menu".

### 3. `bar_click` is the whole of the testable part

The Windows half owns exactly one fact — the `LOWORD` of a `WM_COMMAND` is the
command id the backend assigned, which is the item's 1-based position in the
flat list — and everything else is pure V in `services/menu.v`:

```v
pub fn bar_click(e webview.HostEvent, ids []string) ?string
```

It rejects three things rather than guessing, because each would otherwise
report a choice the user never made: a message that is not `WM_COMMAND` (the
hook is asked about *every* message, so the window's own commands arrive too), a
non-zero `HIWORD` (a control notification, not a menu command), and an id of 0
or past the end of the list. `wm_command` lives in the shared file, not in
`menu_windows.c.v`, so the filter is unit-tested on every platform.

### 4. Linux: `Ctx.toplevel`, and a box in the window

Three GTK3 facts, all verified by compiling and running before they were written
down rather than after:

- **`gtk_window_set_menubar` does not exist in GTK 3.24.** It was a GTK2
  function. Only `gtk_application_set_menubar` remains and that is a
  `GtkApplication` API for the app menu. The GTK3 spelling is a `GtkMenuBar`
  packed into the window's box.
- **A `GtkWindow` is not a `GtkBox`.** You cannot pack into the window; the bar
  goes into a container the window owns.
- **The webview was added straight to the window.** A `GtkWindow` holds exactly
  one child, so a bar installed later had nowhere to go. `run_linux` now always
  puts the webview in a vertical box, reserving row 0. With no bar ever set the
  view still gets the full client area (expand + fill, no padding) — verified,
  not assumed.

The box is reached through the new **`Ctx.toplevel`**: on Windows it is the same
HWND as `Ctx.parent`, on Linux it is the `GtkWindow` that owns the GdkWindow.
There is no way to recover one from the other, so it is a field rather than
something a service derives. The GTK dialog waiting in Phase 5b needs the same
handle, so this is not a menu-bar-only field.

The bar is packed and then moved to index 0 with `gtk_box_reorder_child` — the
box is already full of the webview, so appending would put the bar underneath
the page. It is `show_all`-ed *before* packing, because a widget packed while
unrealized has no size request and the bar ends up 1px tall.

## Alternatives rejected

- **One hook with a message table in `HostCtx`.** Keeps "one hook per window"
  literally true, but changes the seam's public shape and forces the tray to
  register into a structure it does not own. comctl32 already provides the
  chain; reimplementing it in V would be the same mechanism with more code and
  one more place to get `DefSubclassProc` wrong.
- **A second `menu` service (`menubar.*`).** Two prefixes, two id rules and two
  event names for one user-facing feature. See decision 2.
- **`gdk_window_get_user_data` instead of `Ctx.toplevel`.** Avoids a field, but
  the GdkWindow's user data belongs to the GTK library, not to us, and relying
  on it is undocumented.
- **`menu.set_menu` Windows-only for now.** Would have left the roadmap item
  half-done, which ADR-0017 explicitly avoided.

## Consequences

- `HostHandler` changed signature. The only implementer is `services/tray.v`,
  and its change is two lines: return `false` for a message `classify_click` does
  not recognise, `true` after a successful emit.
- `run_linux`'s window layout changed for every Linux app, not just ones with a
  menu bar. It is visually identical with no bar, and it is what makes the bar
  possible at all.
- `menu.set_menu` needs a new capability grant per window, like every command.
  An app that upgrades and calls it without the grant gets `forbidden:`, which
  is the same answer as any other ungranted command.

## Verification

- **Linux, proven end to end** (`tests/e2e_linux/menubar.png`): the bar renders
  (`File  Edit  Help`), a click on `File` produces `bar chose: menu:clicked
  file`. The id mapping is machine-proven here, which the *popup* is not: the
  bar is a normal widget in the window, while the popup is an override-redirect
  one that under Xvfb takes the first click as a focus click.
- **Windows, compiled and linked**, not run — the E2E window would not come up
  in the capture session. `menu.set_menu` on Windows is therefore unproven at
  runtime, and the state is written down in `tests/e2e_windows/README.md` rather
  than assumed. The one-command manual check is there.
- Pure V: `bar_click`'s whole rejection matrix in `services/menu_test.v`, and the
  chaining contract in `webview/host_test.v`. Linux `v test .` is 32/32.

## Notes

- The `-w` in V's default C flags hid a latent `g_signal_connect_data` type
  error for the whole of ADR-0017's Linux work: declaring the callback parameter
  as `voidptr` is *not* the same as glib's `GCallback`, and gcc's
  `-Wincompatible-pointer-types` is an error in gcc 15. It only surfaced when
  the fallback compiler ran without `-w`. `menu_linux.c.v` now declares a
  `GCallback` type and the declaration is honest. Worth remembering: a warning
  suppressed by `-w` is not a warning that has been dealt with.
