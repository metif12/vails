# Docs Site Plan — Vails intro + documentation (Phase 7)

> Status: **planned, not built**. This file holds the plan and whatever
> information the build will need; not a line of the site exists yet, and
> `docs/site/` contains only this file.
> Locked decisions: site content is **English LTR**, output is a **static export
> (GitHub Pages)**, v1 scope is the **full docs** (not a cut-down MVP), and
> publishing is **automatic from CI** (§7).

> **History of this file (2026-10-04).** It was Persian until this revision,
> which was the only non-English document in the repository — everything else
> (README, ROADMAP, CHANGELOG, AGENTS.md, every ADR) is English, and a docs
> site about an English-language framework should not be the one document that
> is not. Translating it also fixed three defects the previous version had: it
> said the build starts "after all phases/tracks are done", a condition that can
> never be met (§1); its ADR range read `0001–0011` when 37 files exist up to
> `0039` (§4); and it said `dist/` goes to GitHub Pages without saying **what
> carries it there** (§7, newly added).

## 1. Entry criteria

Before the build starts (see `ROADMAP.md`):

- Phase 3 (assets/dev) through Phase 7 (hardening), plus tracks T3/T4/T5,
  M0–M4, C0–C4.
- The service catalogue (S1/S2/S3) is final, because every service needs a docs
  page.
- `generator` and `vails.json` have settled, so the CLI/API reference is
  generated from real `--help` and real source rather than from guesswork.

### A precondition this file did not have before

§7 is new and it carries a prerequisite the file lacked: **publishing behind a
`ci.yml` that has never reported a green job is publishing behind an untested
gate.** Until `ci.yml` records one real green run, adding `docs.yml` means two
systems that are both unproven, which is worse than one.

The order is explicit, because AGENTS.md §3 says one phase at a time:

1. `ci.yml` has one green run on a real runner.
2. Then `docs.yml`.
3. Then the `veb` spike.

Skipping that order makes "the site is published" a claim that hides an
infrastructure dead end.

### And one precondition that was removed

The previous version said the build starts "after **all** phases and tracks are
done". That can never be satisfied: `ROADMAP.md` itself says ≈52 focused days
remain, and two tracks are parked on decisions that are not ours to make (X0
waits on a Vinix "yes", U1–U4 wait on a distribution channel). **Parking until
everything is finished is an expectation with no end.** The right condition is
*stability*, not completion:

> Building may start once `CONTEXT.md`, `cli/vails.v`, `vails.json` and their
> neighbours have **stopped moving** — because every change after a docs page is
> written means that page is stale. Building incrementally, alongside the tracks,
> is allowed; **waiting for "everything is finished" is not.**

In practice that means pages generated from stable source (`--help`, `v doc`,
`.d.ts`) arrive first and hand-written pages later — which is the same order §8
recommends.

## 2. Site structure (final IA)

```text
Home                    hero + Wails/Tauri/Vails comparison table + 10-line hello + CTA
/docs/getting-started   install (V 0.5.x, MSYS2 ucrt64, webkitgtk) + vails doctor
/docs/quickstart        init → run → ping→pong
/docs/concepts          app, window, bridge, IPC command-vs-event, events,
                        capabilities, config (from CONTEXT.md)
/docs/guides            assets dev/prod, generator d.ts, channels (T3),
                        state (T4), CSP (T7), mobile (M0–M4), CEF opt-in
/docs/cli               version/doctor/init/run/build [--target] + exit codes
/docs/services          one page per S1/S2 service + the T5 manifests
/docs/security          capability matrix + asset scope + threading rule
/docs/api               dry reference per module (signature + example)
/docs/examples          E0–E6 + hello
/docs/troubleshooting   GC `-gc none`, Wayland, WebView2, frontend not found + FAQ
/docs/adr               ADR-0001…0039 index + a summary per decision
/docs/roadmap           + changelog
/llms.txt               AI-friendly version (veb's markdown negotiation)
```

Visual standard (from the Examples track in ROADMAP): system type scale,
spacing rhythm, `focus-visible`, light+dark via `prefers-color-scheme`, vanilla
with no UI framework, English LTR.

## 3. veb notes (researched against V 0.5.x, from modules.vlang.io/veb.html)

- Skeleton: `App { veb.StaticHandler }` + `Context { veb.Context }` +
  `veb.run[App, Context](mut app, 8080)`.
- Static: `app.handle_static('static', true)!` to mount at the root;
  `index.html` is served automatically. Official example:
  `examples/veb/static_website`.
- Two modes: dev with `v -d veb_livereload watch run .` (only for pages
  containing `</html>`), prod with `v -prod` → a single binary with the templates
  compiled in (so a template error is a **build** error, not a runtime one).
- Available already: `enable_static_compression` (zstd/gzip, pre-compress with
  `zstd -k`), `enable_markdown_negotiation` (serves `path.md` to
  `Accept: text/markdown` — the basis for `llms.txt`), a custom `not_found()`
  for 404, middleware (`app.use` / `route_use`), and controllers for grouping.
- veb's only role in this project is **SSG + preview server**: one export command
  crawls every route and writes `dist/*.html`; `dist/` goes to GitHub Pages
  (gitignored, or a separate branch).

## 4. Content inventory (where the content comes from — re-verify at build time)

- `README.md`: comparison table, prerequisites, install, troubleshooting.
- `CONTEXT.md`: every domain concept (App/Window/Bridge/IPC/Capability/Config).
- `docs/ADR/`: a summary per decision for `/docs/adr`. **The correct range is
  0001–0039** (37 files, counted 2026-10-04) — the previous version of this file
  wrote `0001–0011`, which would have ignored 28 recorded decisions. `/docs/adr`
  should **build the index itself** by scanning the directory rather than
  carrying a hand-written range in code, or the same staleness happens again.
- `CHANGELOG.md`: per release, for a releases page.
- `ROADMAP.md`: the priority table and checkboxes, for `/docs/roadmap`.
- `application/`: `AppOptions`, `new`, `register_service`, `has_service`.
- `bridge/`: `Request/Response/Notify`, `register`, `register_validated`,
  `call_from`/`call_json`, `notify`, `handle_envelope_from`,
  `runtime_js`/`runtime_js_bound`, `resolve_js`, the `err_*` prefixes.
- `events/`: `on`/`emit`, `to_js`.
- `assets/`: `Server.read`, `content_type`, embed vs dev.
- `generator/`: `MethodSpec`, `generate_dts`.
- `capabilities/`: `grant`, `is_allowed`, the allow/deny matrix.
- `config/`: `load`/`validate`/`to_registry`/`default_config`, the `vails.json`
  fields.
- `cli/vails.v`: the real behaviour of `version/doctor/init/run/build`.
- `examples/hello/`: `main.v` + `vails.json` + `frontend/index.html` (the code
  pattern that appears inside the docs).
- `tests/e2e_windows/README.md` and `tests/e2e_linux/README.md`: the evidence and
  the gotchas.

## 5. File layout (at build time)

```text
docs/site/
  PLAN.md            # this file (the plan; update it as the build proceeds)
  content/**/*.md    # one page per file + frontmatter (title, nav, order)
  templates/*.html   # veb layout (header/nav/footer, dark mode)
  static/css|js|img  # vanilla, no build step
  veb_site.v         # routes + handle_static + export to dist/
  config.json        # nav tree, version, GitHub link
dist/                # build output (published; not source)
```

## 6. Execution steps (at build time — each one is code + test + docs line)

1. Content inventory: extract each module's real API + an ADR summary.
2. IA + `config.json`: the §2 nav tree + frontmatter.
3. Scaffold `veb_site.v`: routes (`/`, a `/docs/:path...` fallback, `/llms.txt`)
   + `handle_static` + `not_found` + pure-V tests (green on Windows).
4. Templates + CSS: layout, hello-code highlighting, dark mode, `focus-visible`,
   client-side search over a static JSON index.
5. Port the content from §4 — only from real source, no guesswork.
6. Export + preview: `v run docs/site --export` → `dist/`;
   `v -d veb_livereload watch run docs/site` for authoring.
7. Verify + close: `v fmt -w .`, `v test .` green on Windows; wire up Pages;
   tick the ROADMAP box; one line in CONTEXT.md (the Definition-of-done rule).

## 7. CI and publishing to GitHub Pages

> Added 2026-10-04. The previous §7 said only that "`dist/` goes to GitHub
> Pages", without saying **what** carries it there. The answer is a new workflow,
> and since `ci.yml` already exists this section follows its conventions rather
> than inventing a new file's.

### Why a separate workflow and not a step in `ci.yml`

`ci.yml` has three jobs (`linux` / `windows` / `release`) and all three are
**gates**: if `v test .` goes red, publishing must not happen. But the site is a
by-product with two different properties:

- **It is fast.** An SSG that builds 20 pages takes seconds; paying for the
  whole V container image to do it is wasted runner time.
- **Its failure must not redden a green build.** A dead link in the docs has no
  reason to stop the desktop build — but inside one workflow it would, and the
  `required checks` would hold every PR hostage.

So: `docs.yml` is separate, with a `paths:` filter over `docs/site/**` plus the
files the docs are built from.

### Workflow shape

```yaml
name: Docs

on:
  push:
    branches: [main]
    paths: ['docs/site/**', 'CONTEXT.md', 'docs/ADR/**', 'v.mod', '.github/workflows/docs.yml']
  pull_request:
    paths: [same list as above]   # a docs change must check the PR too
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write          # required for artifact deployment

concurrency:
  group: pages
  cancel-in-progress: true # two concurrent deployments of one branch is meaningless

jobs:
  build:
    # No container: the site compiles no C (pure-V veb only), so a V with a
    # vlib is enough. Deliberately not folded into the linux job.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-v@v2
        with: { version: 'v0.5.2' }
      - run: v -prod run docs/site -- --export     # writes dist/
      - uses: actions/configure-pages@v5
      - uses: actions/upload-pages-artifact@v3
        with: { path: docs/site/dist }
```

### Four decisions that have to be made deliberately

1. **`v -prod` in the build, not `v run`.** The reason is in §3: with `-prod` the
   templates are compiled, so **a template error breaks CI** rather than a
   visitor. That is the only justification for the step, and it must not be
   re-justified as "it is faster".
2. **`dist/` is not committed.** Two options: gitignore (simple) or a separate
   branch such as `gh-pages`. A branch is better for SEO (a stable URL) but costs
   an extra deployment setting; **default: gitignore + artifact deployment**, and
   if indexing is ever needed, moving to a branch is a change rather than a
   rewrite.
3. **`404.html` is required.** GitHub Pages serves `404.html` for an unknown
   path, so veb's custom `not_found()` must produce exactly that filename —
   otherwise Pages' own 404 is shown, with broken navigation.
4. **`llms.txt` must be in the artifact**, not only left to a live
   `enable_markdown_negotiation`. Pages is a CDN and header negotiation is not
   dependable behind one: if `/docs/x` answers `Accept: text/markdown` but `/x.md`
   does not, that capability behaves differently on Pages than it did in preview.
   **Both must be produced.**

### What is still unproven

None of this has been run. `ci.yml` in this repository still has **no green job**
(ROADMAP records B2+B3 as "executed, fixed, unproven"), so "Pages deploys it" is
a claim only a real run can falsify. The right order: add `docs.yml`, then
**push to `main` for real and read the output**, then write one line in
`ROADMAP.md` saying what happened.

`veb` itself is unproven too: `handle_static` and `--export` have **never been
compiled** in this repository on V 0.5.2 (old §7, risk one). A ten-line spike
before anything else.

## 8. Risks

- `veb`'s API changes across 0.5.x → spike `handle_static` small first.
- Pure-V Markdown rendering (`x.markdown`) is limited → md→HTML at build time
  using veb's own template, with no new dependency.
- If Phase 7 runs late: ship Home + getting-started + quickstart + one API
  reference first, the rest incrementally.
- **The docs and the site go stale together.** A hand-written docs page is wrong
  after any release. The recommended rule: anything that *can* be generated from
  source (`vails --help`, `v doc`, `--out d.ts`) is generated, and hand-written
  prose survives only where generation is impossible. That is a decision, not an
  optimisation.
