# ADR-0013 — Dev server + full CLI (closes Phase 3, Phase 4)

Date: 2026-09-27. Status: accepted (pure-V core + E2E-verified CLI on Windows).

## Context

Remaining Phase 3 was the `veb` dev server + livereload + `vails run`
dev mode; Phase 4 is `init/run/build/doctor` + the hello template.
They share one seam (`vails run` dev mode), so they shipped as one
batch: two commits, sequential steps. Verification: `v test .` green on
Windows, plus a real `init → doctor → run --serve-only → build` cycle
against a scaffolded project outside the checkout.

## Decisions

- `dev/` module, pure-V and OS-agnostic (no C, green without gcc):
  `DevServer{root, asset_root, port, build_id, registry, label}`.
  `root` is the project dir (vails.json dir); `asset_root` prefixes
  every path, so hello-style grants (`asset_roots: ['frontend']`)
  match served paths (`frontend/index.html` for `/`) with no special
  cases. All reads go through `assets.Server.resolve_for` — no grant
  for the window means deny, same rule as bridge dispatch and prod.
  `/` and trailing slashes map to `index.html`; missing file → 404,
  traversal/outside-grant/no-grant → 403 (denied paths never leak
  existence). `frontend_version()` fingerprints path:size:mtime
  (sorted); `current_version()` prefixes the process `build_id`, so
  the marker moves on frontend edits AND server restarts.
  `inject_livereload` inserts a 500ms poller before `</body>`
  (appended without one), idempotent via marker, silent on fetch
  failure (restarting server). Binds 127.0.0.1 only; busy port fails
  fast with a `--port` hint.
- NOT veb: veb pulls fasthttp's C files on Windows, which would force
  every `v test .` through gcc and break this repo's no-gcc Windows
  rule (AGENTS.md §1). `dev/serve.v` uses stdlib `net.http` instead
  (one catch-all handler, `Content-Type` from `assets.content_type`).
  Socket behavior verified with a throwaway live-server script
  (200 + MIME + injection + version + 404 + 403), then deleted.
- `vails run` (dev): spawns the server, opens the first window at its
  URL (both backends support `Config.url`: Windows `webview_navigate`,
  Linux `load_uri`). The window carries an EMPTY router, so JS→V
  calls fail with `unknown method` until the real app binary runs —
  this mode is frontend iteration, not bridge development.
  `--serve-only` skips the window (headless/CI).
- `vails init [name]`: `main.v` (config + frontend file + `ping`,
  capability-gated) + `vails.json` (default + `main-app` grant for
  `ping` and the asset root, otherwise dev would deny everything) +
  `frontend/index.html` (CSP meta verbatim from `default_csp()`,
  ping button that degrades visibly outside a Vails window).
- `vails build`: compiles the project dir. Scaffolded projects import
  vails modules by bare name, so build sets `VMODULES` to the vails
  source root: explicit `VAILS_HOME` wins, else walk-up from the CLI
  binary and the cwd (`vails_home()`); absent root fails fast telling
  the user to set `VAILS_HOME` (instead of cryptic import errors).
  `doctor` reports the resolved home, `v --version`, toolchain,
  `vails.json` validity and `asset_root` existence.
- Toolchain notes (MSYS2 gcc 16.1 + V 0.5.2, found while verifying):
  `net` hits `-Wincompatible-pointer-types` (error by default since
  gcc 14) → CLI builds need `-cflags
  '-Wno-incompatible-pointer-types'`; link needs `-lws2_32`
  (`-ldflags`). Scaffolded apps (no `net` import) build with plain
  `v -cc gcc`. CLI/GUI binaries need the side-by-side DLLs next to
  the exe (same Phase 1 lesson). `v -doc veb` is broken upstream
  (missing `markdown` module) — veb internals were read from
  `vlib/veb/*.v` directly.

## Consequences

- CSP text changes stay app-visible (scaffold ships `default_csp()`
  verbatim, like hello).
- V `if init; cond` (Go syntax) does NOT parse — the compiler fails
  at EOF with `expecting '}'`, far from the cause. Prefer plain
  statements (this exact trap cost real debugging time in `cli/`).
- CEF decision ADR planned as 0013 moves to 0014 (this batch took 0013).
- `v vet` warnings about unused `events.common_*` constants
  pre-date this batch; untouched.
