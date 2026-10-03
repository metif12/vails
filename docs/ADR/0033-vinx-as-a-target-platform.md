# ADR-0033 — Vinix as a target platform: a spike first, because nobody knows what it can host

Date: 2026-09-29. Status: planned (ROADMAP track X; no code yet).

## Context

The request: Vinix support.

`vlang/vinix` is real and active — **2,358 stars, GPL-2.0, last pushed
2026-09-29**, described as *"an effort to write a modern, fast, and useful
operating system in the V programming language"*. It is an **operating
system**, not a UI toolkit, so it is not a sibling of the `ui2` and VML work
in ADR-0031; it is a fourth thing, and that is worth being explicit about
before planning around it.

What is knowable about Vinix from here, and what is not:

- **Known:** it is a V-language OS; its flagship application is `vlang/ved`,
  *"1 MB text editor written in V with hardware accelerated text rendering"*
  (1,481 stars). So Vinix demonstrably has *some* GPU/compositing and window
  stack — an editor that draws text with hardware acceleration is not a console
  program.
- **Unknown, and decisive:** whether Vinix has a **webview**. A webview is
  the whole basis of Vails' existing architecture (ADR-0002, ADR-0005, every
  `.c.v` in `webview/`), and on a self-hosted OS with its own compositor it is
  the single most likely thing to be missing — building WebKitGTK or WebView2
  against a new GPU stack is not a small job for anyone, let alone us.

So the request is answerable, but only after one question is settled, and the
settling is cheap.

## Decisions (planned, to be confirmed in X0)

- **X0 is a spike, and it asks three questions and answers nothing else.**
  1. Does Vinix have a compositor / GPU presentation path?
  2. Does it have a window API V can call — create, move, resize, close,
     parent, and receive events?
  3. **Does it have a webview, or anything a webview could be built on?**

  Each answer has a different consequence, and that is why guessing is not
  available: a webview means a fourth `webview/` backend, which is
  tractable. No webview means Vails on Vinix is a **`ui2` native-tier app**
  (ADR-0031) or a service-only process, which is a different product and
  should be called that rather than dressed up.
- **The spike is timeboxed and its answer is the whole deliverable.** It is the
  same pattern as the Bundled Chromium track's C0, and it is the pattern
  because it works: a week of throwaway code that answers a question the rest
  of the design depends on beats a month of design that assumed an answer.
- **X1 does not exist until X0 says yes.** There is no half-designed Vinix
  backend sitting in the repo waiting to be finished, because an unimplementable
  backend is a lie in the directory listing.
- **A `doctor` probe for Vinix comes with X1, not before.** ADR-0015's
  per-service `*_support()` pattern means an unavailable platform should be
  reported rather than discovered at window-open time, and reporting a
  platform that has no backend yet would be reporting our own backlog.
- **The license is recorded and is a real consideration.** Vinix is GPL-2.0.
  That does not block *targeting* it — GPL governs distribution of the OS, not
  of applications built to run on it, in the same way targeting Linux does not
  make a Vails app GPL. It is recorded because it is a question someone will
  ask, and the answer should be a sentence in an ADR rather than a thread.

## Waves

`X0` the spike, three questions, throwaway code parked or deleted (~3 d).
Then **X1**, which only exists if X0's third answer is yes: a
`webview/host_vinx.c.v` alongside the Windows and Linux siblings, a
`run_vinx` dispatch in `webview.run`, a `*_support()` answer for every
service, and an E2E proof in a Vinix VM. ~5 d, and not scheduled.

**X0 is independent of every other track and depends on nothing.** That is why
it is worth doing early despite being unfashionable: it is three days, it needs
no Vails code, and it is the only thing standing between "Vinix support" as a
plan and a guess.

## Rejected alternatives

- **Plan the Vinix backend now, spike later.** The design's central question is
  whether a webview exists, and the plan would be written around an assumption
  about something nobody in this repository has checked.
- **Assume no webview and plan a `ui2` Vinix port.** Plausible, and it makes
  X0 unnecessary — except that "assume" is doing all the work, and a
  three-day check is cheaper than a wrong foundation. It is also the outcome
  X0 would reach *with evidence*.
- **A `vinix` service in the catalog with a stub backend.** A manifest that
  promises commands no platform can serve is the failure mode ADR-0014's
  `install` path exists to prevent: `services.install` refuses a handler the
  manifest does not declare and a manifest command with no handler, which is a
  good guardrail that a deliberately empty service would be arguing with.
- **Target Vinix only after Phase 6 (macOS).** No — Vinix is far more
  tractable than WKWebView/ObjC, and the spike costs a fraction of a macOS
  backend. The ordering is a consequence of the answers, not of habit.

## Consequences

- The ROADMAP gains one cheap item and, possibly, one expensive one. That
  asymmetry is the point: three days to avoid a wrong plan.
- Nothing in this track touches `application/`, `bridge/` or `services/`. A
  platform is a `webview/` backend, which is the same shape ADR-0005 gave
  Windows and ADR-0015 gave Linux.
- If X0's answer is "no webview", ADR-0031's native tier becomes the *only*
  route to Vinix, which raises the stakes on `ui2` working on a non-desktop
  stack. That is a reason to run X0 **before** N, and the two tracks'
  recorded order already does that.

## Open decisions (not taken here)

- **Does "support Vinix" mean "run a GUI on Vinix", or "build for Vinix as a
  compilation target" (a headless service, a CLI)?** The second is much
  cheaper and may be all that is needed. X0 should probably answer both.
- **Does anything else in the roadmap depend on this answer?** The `vox`
  horizon (ADR-0024's C5) and the CEF track both assume an embedded browser
  exists somewhere; a Vinix answer of "no webview anywhere" would be relevant
  to both. Noted, not pursued.

## Notes (verified 2026-09-29, via the GitHub contents API)

- **`vlang/vinix`**: 2,358 stars, 145 forks, 50 open issues, **GPL-2.0**,
  created 2019-11-15, **last pushed 2026-09-29** (the same day this ADR was
  written — it is an active project, not an abandoned one), default branch
  `master`, topics `operating-system`, `os`, `v`, `vlang`, 41 MB.
- **`vlang/ved`**: 1,481 stars, GPL-3.0, last pushed 2026-09-28, described as
  *"1 MB text editor written in V with hardware accelerated text rendering.
  Compiles in <1s."* This is the evidence that Vinix has a graphics path at
  all, and it is the reason question 1 of X0 is expected to be yes.
- **Vinix is not in this V installation** and there is nothing Vinix-specific
  in `vlib`, so nothing about its APIs could be verified from here. The three
  X0 questions are therefore genuinely open questions, not things this
  repository already knows and has not written down. That is the honest reason
  this ADR is 100 lines of plan and zero lines of design.
