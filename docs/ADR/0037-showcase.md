# ADR-0037 — `examples/showcase` replaces `examples/services` as the E2E vehicle

Date: 2026-10-03. Status: **accepted; the app exists, the proof run does not.**

## Context

`examples/services` was built for one job — call a service, print what came back
— and acquired a second: it became the thing every E2E proof is taken against.
That second job is what it is actually used for today, and it is why the ROADMAP
opened R3 this way:

> that example has outgrown its role by becoming five probe modes behind
> `VAILS_SERVICES_PROBE`, and two vehicles is how `services.png` and
> `notification.png` once ended up byte-identical.

Both halves of that sentence are measurable. `VAILS_SERVICES_PROBE` has grown
`clipboard`, `notification`, `menu`, `menu-bar`, `tray`, `traymenu`, `post` — one
environment variable whose value selects which proof runs, so a proof is a mode
rather than a thing. And two vehicles producing byte-identical screenshots is the
specific failure this repo's rules exist to prevent: a screenshot that cannot
distinguish two runs proves nothing about either.

The cost of the probe modes is not the modes. It is that they made a *human*
example into a *machine* one, and the two want opposite things: a human wants to
click things and read what happened, a probe wants a fixed sequence nobody has to
be present for.

## Decisions

- **One panel per capability, and every panel ends in a verdict.** Not a log line
  and not a toast: a badge reading `PASS`, `NEEDS YOU`, `FAIL` or `NOWHERE`.
  That vocabulary is the whole design, and it is three states plus one, each of
  which is a distinct claim:
  - `PASS` — exercised, and the result was *checked*. The clipboard panel writes,
    reads back and compares; the bridge panel asserts on the returned value, not
    on a resolved promise.
  - `NEEDS YOU` — works, but only a human can finish it: a drag, a right-click in
    the notification area, a file picker. `examples/showcase` will not report
    `PASS` for any of these, because that is ADR-0018's discipline applied to a
    demo instead of to a backend.
  - `NOWHERE` — this build has no backend for it, said by the framework.
  - `FAIL` — something broke.
- **The page does not decide what is supported.** It calls `demo.support`, which
  returns `services.supports()` — the same table `vails doctor` prints. A panel
  whose service is not ready shows `NOWHERE` with the framework's own note and
  **never calls the command**. The rejected version of this was the panel
  grepping the error text for "not implemented", which is a page that reports a
  working feature as broken the day the wording changes.
- **A tally line at the top counts all four verdicts.** `6 pass · 3 need a human ·
  1 not on this platform · 0 fail · 1 not run`. One number is the thing a
  screenshot has to contain, and it is a verdict on the whole framework rather
  than on whichever button somebody pressed. "10 panels" is not a verdict.
- **One inverted panel.** The capability-gate panel **passes when the call is
  refused**, and the opener panel tries a `file://` URL and passes when *that* is
  refused. Both are security properties whose failure mode is silence, so their
  panels are written the only way that can report it.
- **No probe modes, no auto-answer shim, no `VAILS_SHOWCASE_PROBE`.** The dialog
  panel blocks the window and says `NEEDS YOU` while it does. That is honest and
  it is also why a screenshot can never come out green by accident.
- **`examples/services` is kept, not deleted.** Its probes still work and its
  screenshots still exist. It stops being *the* vehicle; R4 moves the burden.
- **It is a reference, not a template.** `vails init` keeps scaffolding `hello`.
  Copying this to start a project means starting from eleven panels nobody asked
  for. What is worth copying is the shape: one `on_ready` that installs services
  against the window, a manifest that grants them, a page that calls them.
- **Multi-window is deliberately absent.** It is `examples/multiwindow`, it needs
  two windows to mean anything, and a panel inside a one-window window would be a
  lie by omission (ADR-0035).

## Amendment, 2026-10-03: there IS an automation seam, and R4 added it

This ADR said the showcase has no probe modes and no automation, and that R4
would have to find a way. It did, and the way is worth recording because the ADR's
reasoning was half right:

- **Still no probe modes.** `VAILS_SHOWCASE_PANEL` and `VAILS_SHOWCASE_VERIFY` are
  **unset** on a normal launch, no script is injected, and the page has no idea
  automation exists. The auto-answer shim is still refused, and the dialog panel
  still blocks the window and says `NEEDS YOU`.
- **But a seam exists, and the ADR's "nothing else was worse" was wrong about one
  thing.** R4 needs one verdict per process, and that needs the page to run
  panels without a human. The page is the only side that can see what a panel
  did — V cannot read the DOM — so `demo.verdict` is how a verdict becomes text.
- **And the reason is better than a screenshot.** A PNG cannot be diffed for "the
  clipboard panel passed". So `VAILS_SHOWCASE_VERIFY=1` makes every verdict print
  as a line and returns a **process exit code**: 0 when nothing failed, 1 on any
  `FAIL`, and 1 on "almost nothing reported" — because a run that exits 0 because
  nothing ran is the failure mode that matters most here.

Two consequences worth being honest about:

- **`NEEDS YOU` and `NOWHERE` do not fail a run.** A Linux box with no `drop`
  backend is not a broken box. Only `FAIL` is.
- **This logic is not unit-tested**, because it lives in an `examples/` module
  and `v test .` does not reach examples. That is a real gap and it is a
  consequence of putting it here rather than in a framework module, which would
  be the wrong home for logic only this app uses. The verify run *is* the test.

## Consequences

- `examples/showcase/frontend/vails.d.ts` is generated by `vails dts` and is the
  first checked-in `.d.ts` to contain a `DropFiles` shape (ADR-0036) — the event
  payload of a service with no command params, which is exactly the case
  `ts_types` exists for.
- The showcase needs **three app commands** and nothing else: `demo.ping` (the
  round trip), `demo.post` (the U0 proof — the event arriving *is* the result),
  and `demo.support`. Everything else is a service called by its own name.
- The page registers three OS-initiated listeners (`drop:files`, `menu:clicked`,
  `tray:clicked`) and each speaks only for its own panel — the discipline
  `emit_to` exists to enforce, restated in JS because a panel that updates
  another panel's status line is the same wrong-page bug with a different hat.
- **The runtime has no `off`.** `window.vails` is `call` / `emit` / `onEvent` and
  nothing else, so a listener cannot be removed; the U0 panel uses a `settled`
  flag instead. That gap was found by writing this page and is recorded here
  because the next panel that needs to unregister will hit it too.
- R3 stays **unchecked**. The app builds, the manifest validates, `vails doctor`
  reports all eight services, and the generated `.d.ts` carries the drop types —
  and nobody has watched a window with eleven verdicts in it, for the same reason
  F0 and F1 are unproven: the GUI proofs go through the `webview` module that
  crashes this host. R4 is what turns those panels into screenshots.

## Verification

- `v -cc gcc -o showcase.exe ./examples/showcase` builds.
- `vails doctor --config examples/showcase/vails.json` → `ok (1 window(s), 10
  capabilit(ies))`, and the granted list is clipboard, opener, notification, menu,
  dialog, tray, os_info, drop.
- `vails dts --config examples/showcase/vails.json --out frontend/vails.d.ts`
  writes 8 services and a `drop` namespace containing `DropFiles`; it also
  reports `demo.ping` / `demo.post` / `demo.support` / `app.not_granted` as app
  commands with no `.d.ts` entry, which is correct.
- **Not verified: the page's behaviour.** No browser has executed this HTML, so
  the verdict logic is reviewed rather than observed. The first run has to be
  interactive, and the two things to watch are the tally arithmetic and whether
  the `NOWHERE` gate fires before the buttons are usable.
