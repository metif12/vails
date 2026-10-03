# ADR-0031 — A native UI tier: `ui2` as a third backend, VML, and an optional visual editor

Date: 2026-09-29. Status: planned (ROADMAP track N; no code yet).

## Context

The request: use V's `ui2` as the main cross-platform backend, design pages
fully natively with `ui2` and VML, and support that with a visual editor that
is optional — the app must work without it.

Both halves already exist upstream, and the shape of them decides this ADR:

- **`vlang/ui2`** is real and active — MIT, 62 stars, last pushed 2026-09-26 —
  and **created 2026-09-05**. It is roughly three weeks old. It is **not** in
  this machine's `vlib`, so it arrives through VPM, which means Vails needs a
  dependency story it does not have (ADR-0032, item B5).
- **VML is a compile-time construct, not a runtime parser.** `$vml('views/x.vml')`
  is expanded while the application is compiled; the resulting program
  constructs `ui2.Element` values directly and never reads the `.vml` file
  again. The documented element set is `Screen`, `View`, `Rectangle`, `Column`,
  `Row`, `Scroll`, `Label`, `Image`, `Button`, `Checkbox`, `Dropdown`,
  `TextField`, `TextArea`, `ProgressBar`, `Slider`, `Switch`, `Spinner`,
  `MessageBox`, plus `Repeater` delegates, `MenuItem` and `Option` entries —
  with `bind.text` / `bind.checked` / `bind.active` / `bind.value` two-way
  bindings to `app` fields, and `on_tap` / `on_change` / `on_active` / `on_text`
  / `on_submit` calling `app` methods, type-checked by the generated V.

The decision this ADR has to make is what a `ui2` app *is* inside Vails,
because the honest answer is not "another webview backend".

## The finding that shapes it: `ui2` is a different kind of tier

`os_webview` and the planned `chromium` backend both have a page, a
JavaScript runtime, and a message channel. `ui2` has **none of the three** —
it is a native element tree with no DOM, no CSS and no JS. So a `ui2` app does
not have `vails.call`, because there is no page to call it from, and it does
not have a `.d.ts`, because there are no wire types to generate.

| | tier 1 — webview | tier 2 — native (`ui2`) |
|---|---|---|
| `bridge/`, `transport`, `resolve_js` | yes | **unused** — no page |
| `assets/`, CSP, `$embed_file` | yes | meaningless |
| `vails dts` / generated `.d.ts` | yes | meaningless |
| `services/`, `capabilities` | yes | **yes — shared** |
| `application`, `config`, `cli`, `state` | yes | **yes — shared** |
| windows, frameless, tray, dialogs | yes | yes |

This has to be written down, or a reader will reasonably expect `vails.call`
to work in a `ui2` app and file a bug against a design that never promised it.
`ui_tier` is the config field, and `native` **means** "no bridge, no dts".

## Decisions (planned, to be confirmed in N0)

- **`ui_tier: "webview" | "native"`**, `webview` the default, with
  `webview.backend` (`os_webview` | `chromium`) nested underneath it. So the
  C-track's `Config.backend` seam — which is durable work and where a future
  engine would land anyway — is reused rather than duplicated, and `ui2`
  becomes the third value of the same family rather than a rival to it.
- **The two tiers are not mixed in v1.** One app picks one. `window` and
  `tray` both hang off the HWND of one window, and `ui2` builds its own
  windows; combining them means two window systems reconciling into one, which
  is a project of its own and not one to take on before either tier is proven.
- **A `native` app is a first-class Vails app, not a lesser one.** It installs
  services, it is capability-gated, `doctor` reports it, and the same
  `vails.json` drives it. What it does not get is the two modules that only
  make sense when a page is present.
- **The capability model still applies, and for a different reason.** There is
  no remote page to worry about, so the gate is not an XSS boundary; it is the
  boundary between what the app's own surface may do and what it may not, which
  is the same argument that kept `opener`'s scheme allowlist (ADR-0015) and put
  scoped `fs` last and riskiest.
- **VML is V's, and Vails uses it as-is.** No second markup language. The
  compile-time property is not incidental, it is what makes the editor
  question answerable: because `$vml` expands at build time, a visual editor
  is a **file manipulator**, not a runtime inspector, and therefore its output
  is *the same text a person would have typed*. Editor and hand-authoring stay
  one language by construction rather than by discipline.
- **The editor is a separate tool, optional, and last.** It reads and writes
  the same `.vml` files. An app built by hand and an app built by the editor
  differ only in who typed them, which is the property worth having; anything
  else would make the editor a second language with a serialiser attached.
- **N0 is a spike and it gates the track.** Three questions, none of which can
  be answered from documentation: does `ui2` build on Windows and Linux; what
  does it need for its window and event loop; and what does a Vails service
  (which wants a `webview.Ctx` to parent native UI to, and to emit events into)
  do in a tier with no `Ctx`? The third is the one that matters and it is
  unknowable until something runs.

## Waves

`N0` spike (~3 d) → `N1` `ui_tier` config + validation + dispatch, and the
tier table above made explicit in the code (~2 d) → `N2` the service bridge:
prove the shipped services work in a native tier, with `ctx`-free fallbacks
where a service genuinely needs a window handle (~3 d) → `N3` VML: one
worked example plus a **pure-V test that the compiled output equals the
hand-written equivalent** (~3 d) → `N4` the visual editor, a V tool operating
on the same files (~8 d).

**N0 → N1 → N2 in order and alone.** N3 can proceed in parallel once `ui2`
builds, and N4 not before N3 has a file format people can read.

## Rejected alternatives

- **Replace webview with `ui2` as the default.** The literal reading of
  "main cross-platform backend", and a large reversal: ADR-0002 decided for
  webview, and the entire bridge, transport and capabilities layer assumes the
  page *is* a webview. A third tier that is opt-in gets used by the apps that
  want it; a replacement would be a rewrite of everything that already works.
- **A Vails-specific VML that compiles for both tiers.** More flexible for the
  web, and it would mean maintaining two markup languages plus two compilers.
  `$vml` already solves the hard half of the problem.
- **A runtime-evaluating editor that inspects a live `ui2` tree.** Would need
  the framework to expose its element tree for mutation, which couples the
  runtime to an editing tool it has no other reason to know about. The
  compile-time design is what makes this unnecessary.
- **Ship the editor first.** It would have to invent a format, and any format
  it invents that the compiler does not then accept is throwaway work.
- **Adopt `ui2` without a spike.** It is three weeks old; the cost of finding
  out it does not build on one of the two platforms should be one afternoon,
  not a wave.

## Consequences

- Vails gains a genuinely different kind of app, and the framework's value
  proposition widens: an app that needs native widgets and no web at all can
  still use services, capabilities, config, the CLI and the distribution work.
- Two of the framework's modules (`bridge`, `assets`) stop being universal and
  become tier-1. That is a real cost and it is the price of not pretending
  `ui2` is a webview.
- The distribution track (ADR-0024) applies unchanged — a native binary is
  still a single file with side-by-side DLLs or a system GTK. Which is worth
  noting, because it means the packaging work is not contingent on this track.
- `ui2`'s maturity is the track's biggest risk and is a fact, not a concern:
  three weeks old, 62 stars, not in `vlib`. That is why `native` is opt-in and
  why N0 is a spike rather than an integration.

## Open decisions (not taken here)

- **Does a `native` app get a `webview.Ctx` at all?** Services that parent
  native UI to a window (dialog, menu) need a parent handle; in a native tier
  the window exists but is not a webview's. N2 measures this; the design
  decision waits for the answer.
- **Does the visual editor ship inside this repository or as a separate tool?**
  Inside, it inherits the repo's test style and release discipline; separate,
  it can iterate on its own schedule. N4 is the wrong time to decide.

## Notes (verified 2026-09-29)

- **`ui2` is not in this V installation.** `vlib/ui2` does not exist under
  `C:\Users\xman\v\vlib`, and no directory in `vlib` matches `^ui` except
  `vlib/term/ui`. So `import ui2` cannot resolve here today, and the module
  has to come from VPM — which is what makes B5 (a `dependencies` block in
  `vails.json` plus VPM resolution in `vails build`/`run`) a prerequisite
  rather than a nicety.
- **The compiler half is present.** The strings `vml`, `ui2`, `Screen`,
  `Repeater`, `on_tap` and `bind.text` are all in `v.exe`, and `doc/docs.md`
  documents `$vml` in a section of its own. So the compile-time transform
  ships in V 0.5.2 even though the runtime module does not. Worth knowing
  before assuming the feature is imaginary: the split is real and it is the
  reason the spike starts by *installing* rather than by writing.
- **`vlang/ui2`: MIT, 62 stars, 7 forks, 5 open issues, created 2026-09-05,
  last pushed 2026-09-26.** Recorded because a roadmap line that says "V's own
  UI toolkit" and one that says "a three-week-old MIT module with 62 stars"
  lead to different decisions.
- **`$vml` resolves relative paths** in a defined order — the V source file,
  then a `templates` dir beside it, then up to the nearest `v.mod`, then that
  module's `templates` — and accepts string literals, constants,
  compile-time bindings and `+` concatenations. That path resolution is
  something `vails build` must not break by relocating files, and it is a
  constraint on the distribution track's staging, not just on the editor.
- **The two backends share no C, which is convenient.** `ui2` is pure V, so a
  `native` app links none of `webview` 0.12's five side-by-side DLLs. That
  makes `bundle.windows_dll_side_by_side` tier-dependent, and it is noted here
  so ADR-0024's installer does not assume every artifact is a webview app.
