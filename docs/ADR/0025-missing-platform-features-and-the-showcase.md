# ADR-0025 — The two platform gaps (multi-window, drag & drop) and the showcase app that proves them

Date: 2026-09-29. Status: planned (ROADMAP track R, plus item F0; no code yet).

## Context

The request: build a version that is better, more complete and more useful
than every sample app in Wails and Tauri.

Taken literally that is not a plan, it is a superlative — and a superlative
has no definition, so it cannot be started, cannot be finished and cannot be
disproved. The useful part of the request is a real and answerable question:
**what can a Vails app do today that a Wails or Tauri sample app can, and
what cannot it do?** The answer is in `docs/COMPETITIVE-MATRIX.md`, gathered
on 2026-09-29 with its confidence levels stated, and it comes down to two rows.

Across Wails' ~66 example directories and Tauri's 13 examples plus plugin set,
Vails has **exactly two gaps that are capabilities of the shell rather than
missing services**:

- **drag & drop** — Wails ships `drag-n-drop`, Tauri ships `drag`. Vails has
  nothing. For any app whose user has files on disk, a window that will not
  accept a dropped file is a prototype.
- **multi-window** — Wails ships `multiwindow`, Tauri ships `multiwindow` and
  `multiwebview`. Vails' `webview.run` creates one window and blocks in the
  native event loop; `config.VailsConfig` has a `windows` *list* that
  `VailsConfig.window(label)` picks one entry out of, which is a data model
  with no second window behind it.

Everything else in the matrix is a service (S2 territory), a small platform
nicety, or a deliberate non-goal with a reason attached. So "better than every
sample app" reduces, for now, to **these two, done properly** — plus a way to
show that they work.

## Decisions (planned, to be confirmed in F0)

- **Multi-window is F0 and it is not part of the showcase track.** It was
  first written as an item inside the showcase, which was wrong: it is on the
  critical path of three other plans, and inside a showcase it would be read as
  demonstration work that can be sequenced last. What it actually is:
  `application` growing the lifecycle it has never had (it is currently a
  service-name registry and an in-memory state store, nothing more), a window
  registry keyed by label, a `Ctx` per window, and per-label event routing —
  the last one is the half that is easy to get wrong, because `ctx.emit`
  currently resolves against a single `eval_fn` and a second window with the
  wrong one would deliver its events into the first window's page.
- **Multi-window reopens a decision ADR-0020 made.** That ADR rejected a
  framework-owned updater window, and the *reason* it gave was that building
  one is a phase-scale project. That condition no longer holds once F0 exists.
  `updater.default_html()` becomes a real second window rather than markup an
  app injects into its own document. The rejection is **conditional, not
  withdrawn**: until F0 ships, the in-app UI is what the updater uses, and the
  change is recorded rather than smuggled in.
- **Drag & drop is a service, not a webview setting.** A `drop` service
  reports *that* a drop happened and *what* it carried, and the page decides
  what to do with it. This is the same reasoning that made `opener` a
  capability-gated service with a scheme allowlist (ADR-0015): the OS is being
  asked to act on a string a page supplied, and a granted capability is the
  only thing standing between "the user dropped a file" and "the page named any
  path it liked". `drop.is_supported` follows the ADR-0018 split — a
  compile-time answer about a backend, kept separate from whether this machine
  can do it.
- **WebView2's `EnableWebDrop` is the part that is invisible until it
  fails.** Without the host setting, the webview consumes every drop and
  nothing reaches the window; the symptom is a drop that does nothing at all,
  with no error anywhere. It is called out here, and in the wave's Notes,
  because it is precisely the class of defect this repo's Notes sections
  exist to record.
- **The showcase is one multi-panel app, and it replaces `examples/services`
  as the E2E vehicle.** `examples/hello`, `examples/dialog` and
  `examples/services` were each built for one wave and `examples/services` has
  accumulated five probe modes behind `VAILS_SERVICES_PROBE`. A single
  `examples/showcase` with one panel per capability, each panel carrying a
  button, a status line, and a **machine-checkable** result, replaces that pile
  — the status line being the evidence, which is the convention ADR-0014's
  clipboard round trip established and ADR-0015 extended.
- **Every panel is one probe and one screenshot.** The existing
  `capture.ps1` / `run_services.sh` machinery carries over unchanged, including
  the per-probe output filename that stops one run from erasing another's
  proof. A showcase panel that cannot produce a screenshot is not a panel yet.
- **The showcase does not stub, and it does not fake.** A panel for a service
  that is a stub on this platform shows the platform's honest answer —
  `notification` on Linux says the mechanism that would run is unavailable, it
  does not render a fake toast. ADR-0018's "Not done in this release"
  discipline applies to the showcase the same way it applies to a release.
- **The showcase is a reference, not a template.** `vails init` keeps
  scaffolding the small `hello` app. A kitchen-sink reference is the right
  document for "what can this do" and the wrong starting point for "hello
  world", and conflating them would make both worse.

## Waves

**F0** multi-window (its own item, ahead of the showcase, and the single
highest-leverage change in this ADR) → **F1** drag & drop → **R3** the
showcase skeleton and one panel per existing capability → **R4** move the E2E
burden off `examples/services` and fold in the U and W proofs. ~12 focused
days for F0+F1+R3+R4.

**F0 depends on nothing and unblocks three things:** the window-chrome
track's per-window tests (W), `tray.set_menu`'s window menu bar (S1 wave 4),
and the updater's second window (U4). **F1 depends on F0** — "drop onto which
window" is a routing question.

## Rejected alternatives

- **Several small themed apps instead of one showcase.** More approachable
  than a demo, but each covers less, and the E2E burden multiplies with the
  app count. `examples/services` already outgrew that model by becoming five
  probes in one window.
- **One genuinely useful complete application (a note manager, say) with
  everything inside it.** The most valuable thing this plan could produce, and
  the hardest: a real app needs a real data model, persistence (`store` is S2
  and unbuilt), and error states, and none of that is the framework's job. It
  also means the framework's coverage is invisible — a reader cannot tell
  which panel exists because the framework supports it and which because the
  app wanted it. Recorded as the right follow-up *after* the showcase proves
  the features, not instead of it.
- **Drag & drop as a raw webview flag the app reads itself.** Smaller diff,
  and it hands every app the same unprotected path the capability model exists
  to close. The `opener` precedent is the argument.
- **Only drag & drop, deferring multi-window.** Tempting, because drag & drop
  is more visible. But multi-window is the prerequisite for the updater's own
  UI, for per-window event routing that the window service needs to be
  correct, and for `tray.set_menu`. Doing drop first means doing it twice.
- **Copying Wails' or Tauri's example inventory file-for-file.** A framework
  is not better for having more example directories; a developer is better off
  when they can do what they need without reading three examples and writing
  platform calls themselves. The matrix exists to make that measurable, not to
  be a to-do list derived from someone else's.

## Consequences

- `application` stops being a stub. That is a real change of role for a
  module that has never had a lifecycle, and it is the first thing in this
  plan that is not a service.
- `examples/services` is retired rather than left alongside, so the E2E
  harness has exactly one vehicle. Two vehicles is how
  `services.png`/`notification.png` ended up byte-identical once (ADR-0015's
  own Notes record it).
- The matrix in `docs/COMPETITIVE-MATRIX.md` becomes a document that has to be
  maintained, which is the cost of making the goal checkable. A `—` with no
  reason is how "we never looked" becomes indistinguishable from "we
  decided".

## Open decisions (not taken here)

- **Does F0 land before or after the window-chrome track's W0?** W0 is
  really ADR-0019's seam work and does not need a window registry; F0 does.
  They can run in either order, and running ADR-0019 first keeps W's
  per-window tests on one window until F0 arrives. Not decided here.
- **Whether `multiwebview`-style per-window content is in F0 or later.** One
  window with several `WebView`s is a different feature from several windows,
  and Tauri ships them as two examples. F0 is scoped to several windows.

## Notes (verified while planning this)

- **`webview.run` is single-window and blocking**, and this is why F0 is a
  prerequisite rather than a convenience:
  `webview/webview_windows.c.v:90` calls `C.webview_create(0, unsafe { nil })`
  once, and `:126` blocks in `C.webview_run(w)`. There is no window registry,
  no `app.Window.NewWithOptions`, and no second `Ctx`. The Linux half is the
  same shape (`webview_linux.c.v:131` `gtk_window_new`, `:195` `gtk_main`).
- **`VailsConfig.windows` being a list is not multi-window.**
  `config/config.v:120-130` declares `windows []WindowConfig` and
  `VailsConfig.window(label)` returns **one** of them; every call site in the
  repo passes a single config to a single `webview.run`. The data model got
  there first, which is exactly why the gap is easy to misread as already
  closed.
- **Per-label event routing is the risky half of F0.** `webview/ctx.v` builds
  one `eval_fn` per window, and `Ctx.emit` resolves through it. Two windows
  with the wrong `eval_fn` deliver one window's events into the other's page —
  a failure that is invisible in a single-window test suite and obvious the
  moment a second window exists. It is called out as the thing to test first.
- **`EnableWebDrop` is a WebView2 host setting, not a webview API.** It is
  not reachable through the `webview` 0.12 surface at all (the full list is
  transcribed in ADR-0021's Notes), so it has to be set on the WebView2
  controller behind the library's window, or drag & drop has to go through
  `WM_DROPFILES` / `IDropTarget` on the HWND instead. **Which of the two is
  feasible is the single unknown in F1** and is the first thing to check,
  before writing any `drop` service — a service with no reachable native
  implementation is worse than no service, because the manifest would promise
  it.
- **The GTK half is easier and is not the unknown.** `drag-data-received` is a
  plain signal on the `GtkWidget` Vails already owns, reached through the same
  `g_signal_connect_data` style as ADR-0015's window-message wiring. V has no
  drag-and-drop clipboard format built in beyond what the OS provides, so
  anything richer than files and text is out of scope for F1.
- **The competitor inventory was gathered 2026-09-29** from the GitHub
  contents API for `wailsapp/wails` at `v3/examples` (66 entries, listing
  truncated) and `tauri-apps/tauri` at `examples` (13 example directories).
  Tauri's *plugin* list and either project's installer tooling are **not**
  verified — web search was unavailable (403) and
  `v2.tauri.app/distribute/` did not load. Re-check before publishing any
  comparison.
