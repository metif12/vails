# ADR-0026 — `tray.set_menu`: a menu on the tray icon, and what a right click no longer means

Status: accepted
Date: 2026-09-29
Supersedes: nothing. Amends ADR-0017 (which shipped the tray as click-only) and
depends on the two-hook seam from ADR-0023.

Numbering note: this is 0026 because ADR-0024 through 0025 were taken by the
distribution and showcase tracks while this was being written. `services/tray_test.v`
referred to it as ADR-0024 while it was still a draft, and that reference was wrong
— 0024 is the distribution ADR. It is fixed there.

## Context

ADR-0017 shipped `tray` with one output: a click on the icon arrives as
`tray:clicked {button}`. That is enough to build "click to show, click to hide",
and it is all that shipped.

It is not enough to build anything users expect from a tray icon. A tray icon
with a menu is the near-universal convention — it is how an app offers
Open / Settings / Quit without a window. Wails needs it; so does every other
desktop toolkit in the comparison matrix.

The blocker was never the menu itself. ADR-0017 said the menu "is explicitly not
part of the `menu` service" and left it there; ADR-0023 then made the window host
seam take a chain of subclasses and gave each one a way to say "not my message",
which is the only thing a second listener on the same window needs. The
precondition for a tray menu was satisfied by work written for a different
reason, which is the usual way these dependencies actually resolve.

## Decision

### 1. It is the `menu` service's items, on the `tray` service's icon

`tray.set_menu` takes the **same** `MenuItem` array as `menu.popup` and
`menu.set_menu`, validates it with the same code, assigns ids with the same
`flatten_items` order, and the choice arrives on the **same `menu:clicked`
event**. A frontend that already has a menu listener serves a right-click
popup, a window menu bar and a tray menu from one handler.

This is the same argument ADR-0023 made for the window bar, and it is why this
is not a fourth `MenuItem` type or a `tray:menu-clicked` event. The user
experiences one feature; three event names for it would be a vocabulary
decision made by the module layout rather than by the user.

One menu at a time, as everywhere else: a second `set_menu` replaces the first.

### 2. With a menu attached, a right click emits nothing — the menu wins

**This changes the meaning of an event that already shipped**, which is why it
is written down rather than left to the diff.

Before: right click → `tray:clicked {button:"right"}`.
After, with a menu attached: right click → the menu opens, and no event fires.

The alternative — open the menu *and* still emit `tray:clicked {right}` — was
rejected. It makes one physical click deliver two independent signals, and every
app then has to decide whether its existing right-click handler should also fire.
The chosen rule has a property the other does not:

> **An app that never calls `tray.set_menu` sees no behaviour change at all, on
> either platform.**

Only the presence of the new command changes what a right click does. That is
the property that makes the change safe to ship into a released API.

A **left click is never taken by the menu**, even with one attached. The menu is
a context menu; eating the click that opens whatever the app wants a left click
for would be the more damaging half of a wrong rule here.

An **empty item list removes the menu** and restores the old behaviour, as in
ADR-0023.

### 3. `decide` is the policy, and it has three answers

The whole host-message policy is one pure function:

```v
pub enum TrayAction {
	pass_on
	emit_clicked
	show_menu
}

pub fn decide(e webview.HostEvent, has_menu bool) TrayAction
```

**This function exists because a `bool` could not carry the policy, and the
first attempt used one and shipped a bug.** Recorded in full, because the shape
of the mistake is more useful than the fix:

The handler branched on `!tray_menu_click(e, has_menu)` and treated `false` as
"the attached menu owns this". But that `false` also covers "this message is not
the tray's at all" — a different question, answered with the same value. So any
message the tray did not own was answered by **opening the tray menu and being
consumed**.

In practice: an installed tray icon swallowed the window menu bar's
`WM_COMMAND` on the same window. Tray plus menu bar is exactly the combination
the `examples/services` window offers, and ADR-0023 had just added a second hook
specifically so the two would not collide.

Every predicate test passed while the handler was wrong. The tests covered
`tray_click` and `tray_menu_click` one at a time; nothing covered the
*composition*, and the bug was entirely in the composition. `decide` exists so
that the composition is the tested unit:

- classify **first**, settling "is this ours" before "whose click is it";
- return all **three** outcomes, so the handler cannot infer a fourth;
- `show_menu` is unreachable for a message the tray does not own, which
  `test_decide_passes_on_every_message_that_is_not_a_tray_click` pins directly.

`tray_menu_click` survives as a documented predicate with tests of its own, but
it is no longer load-bearing for the handler.

### 4. Windows: version 4, and the foreground dance

`NOTIFYICON_VERSION_4` is now set on every `tray.set`. It is not cosmetic: a
version-4 icon with an attached menu receives **`WM_CONTEXTMENU`**, which is
what a legacy icon does not get. Without the bump the menu opens on some right
clicks and not others depending on shell state, which is worse than not having
it.

Showing an HMENU also needs the documented dance — `SetForegroundWindow` on the
owning window, then `TrackPopupMenu`, then `PostMessage(WM_NULL)` — because a
menu shown by a window that is not foreground is dismissed immediately by the
shell. The commands are built by the menu service's existing `build_menu`, so
the id space is identical to a `menu.popup` on the same items.

### 5. Linux: the host opens the menu, so nothing comes back

`app_indicator_set_menu` hands the menu to the **StatusNotifierItem host** (GNOME
Shell, KDE's Plasma, etc.). The host opens it; the app is not in the click path
at all. So on Linux:

- there is no `tray:clicked` for a right click with a menu, for the same reason
  as Windows — and here it is not even a decision we make;
- there is nothing to simulate, which is why the E2E probe can only assert that
  the command resolved.

The GTK menu itself is persistent state in `TrayState`, freed on `tray.destroy`
and replaced on a second `set_menu`, with each item's `activate` carrying the
item's id to the shared `emit_menu_clicked`.

## Alternatives rejected

- **A new `tray:menu-clicked` event.** Rejected with the `MenuItem` reuse above:
  three ways to pick a menu item should not mean three event names.
- **Emit `tray:clicked` *and* open the menu.** Rejected in decision 2.
- **A right-click-only menu, leaving double-click alone.** Inconsistent across
  shells; the double click is the same user intent. All three right-click shapes
  are claimed (see `test_decide_shows_the_menu_only_for_a_right_click_with_a_menu`).
- **`tray_menu_click` fixed in place** (add a third return value, or an
  `is_tray_message` pre-check at the call site). Both leave the two questions
  sharing one return value, which is what caused the bug. Splitting the function
  is the cheaper change.
- **`menu.set_menu` on the tray icon** (one command, one service). Rejected: the
  icon is the tray's and the menu is not; a frontend that wants both a window bar
  and a tray menu would have to decide which is "the" menu.

## Consequences

- `HostHandler` consumers: the tray is the only implementer, and its handler now
  returns `false` for every message `decide` does not own — strictly more
  messages reach the menu bar's hook than before.
- `tray.set_menu` needs a new capability grant per window, like every command.
- An app that upgrades, attaches a menu, and still listens for
  `tray:clicked {right}`, sees that event stop. That is decision 2, and it is the
  one breaking behaviour change in this ADR.
- Linux gains no new runtime behaviour a frontend can observe from inside the app
  — the host owns the click. The E2E proof is correspondingly weaker, and says so.

## Verification

- **Pure V**, on every platform: `decide`'s full three-way behaviour plus the
  complement invariant in `services/tray_test.v`; `tray_click` and
  `tray_menu_click` kept as separately tested predicates.
- **Linux, partially proven end to end** (`tests/e2e_linux/traymenu.png`): the
  command resolves and the menu is attached to the indicator. There is no
  screenshot of the menu *open*, and there cannot be one without a real
  StatusNotifier host, which a headless Xvfb run does not have.
- **Windows, compiled and linked only** — the E2E window would not come up in
  the capture session. `tray.set_menu` on Windows is therefore unproven at
  runtime and the manual check is written down in `tests/e2e_windows/README.md`.
- Linux `v test .` and Windows `v test .` are 32/32.
