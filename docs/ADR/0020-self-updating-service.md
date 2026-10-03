# ADR-0020 — The self-updating app: an `updater` service with a helper-mode swap

Date: 2026-09-29. Status: planned (ROADMAP track U1–U7; no code yet).

## Context

Wails v3 ships an updater that checks GitHub Releases, downloads the right
asset, verifies a digest and an Ed25519 signature, shows release notes in a
framework-owned update window, and swaps the running binary — with no separate
helper executable, because the helper is the current binary re-executed with
sentinel environment variables and diverted at startup
(`application.New` → helper mode).

The request is to port that capability to Vails.

Two ROADMAP lines currently say no. `ROADMAP.md` listed a *signed* `updater`
under **"Out of scope (post-desktop, unchanged)"** alongside `sidecar`
binaries and `sql`/`stronghold`, and the Tauri-inspired track deferred it a
second time. Those lines are struck by this ADR, with the reason recorded in
the U track below rather than left to be re-litigated. What made it worth
reversing is not that it became easy, but that the parts Wails gets for free
from the Go standard library all exist in V's, and the two parts that do not
are small and local.

What Vails does not have, and what the port therefore has to answer:

- **There is no second window.** `webview.run` creates one window and blocks
  in the native event loop (`webview/webview_windows.c.v:90-131`). There is no
  window registry, no per-label router, no `app.Window.NewWithOptions`. Wails'
  "framework's default update window" is not reachable without building a
  window manager first, and `config.VailsConfig` having a `windows` list does
  not make one exist — `VailsConfig.window(label)` picks one out of it.
- **A worker cannot reach the page.** ADR-0010 requires slow work on a worker
  and the result as an event, but `Ctx.eval_fn` is main-thread-only and there
  is no way to post one. This is ADR-0019, and it is U0, and it is first.
- **There is no detached spawn.** `os.Process` has no `run` and `os.execute`
  blocks. The helper has to be spawned by a C shim.
- **There is no version stamping at all.** `vails build` sets `VMODULES` and
  nothing else; an app has no way to know what it was built as, which is the
  input every comparison needs.

## Decisions (planned, to be confirmed in U1)

- **The manifest is the core, and the providers are adapters.** Wails'
  Update Manifest protocol is a small open JSON contract: one document with
  `version`, `channel`, `notes`, and an `artifacts` array carrying `url`,
  `platform`, `arch`, `size`, `digest` and `signature` inline. It is parsed
  once into a `Manifest`, and *every* provider produces a `Manifest`. The
  GitHub Releases provider is then a thin adapter — the releases API, a
  `SHA256SUMS` sidecar, filename alias matching — that ends by handing a
  `Manifest` to the same code the static-endpoint provider uses. Verification is
  written once, tested once, and cannot drift per source. The Wails provider
  interface splits into `Check` (resolve the next release) and `Download`
  (stream bytes); Vails splits the same seam into the two, and a third source
  (keygen.sh, Sparkle AppCast) is a file, not a redesign.
- **GitHub Releases gets a signature sidecar, because Wails' provider has
  none.** Wails' GitHub provider can fetch `ChecksumAsset` for digests but its
  docs concede it does not fetch signatures, so the tutorial's step 9 has to
  point users at a custom provider or at keygen.sh. Vails reads an optional
  sibling asset `SHA256SUMS.sig`: a base64 Ed25519 signature over the asset's
  SHA-256 digest bytes. It is one extra fetch and one extra parse, and it makes
  the GitHub path as strong as the keygen path.
- **The trust anchor is pinned in the app, and a release cannot substitute
  it.** The public key comes from `vails.json`, read from disk at startup. A
  release that carries a signature and the app has no key **fails closed**; a
  signature with no `signatureAlgo` fails closed; a digest-only release is
  accepted and says out loud that it is integrity, not authenticity. There is
  no silent fallback from signature to digest, which is the failure mode that
  turns a "signed" release into a plain one.
- **The update UI is the app's own window.** The service answers
  `updater.state` and emits `updater:*` events; the frontend renders. The
  framework still ships the *look*: `updater.default_html()` returns a
  self-contained page (state icon, `v1.0.0 → v2.0.1 · 8.8 MB` version pill,
  Markdown notes, one primary action per state, `prefers-color-scheme`, the
  same CSS variable names Wails exposes) that an app injects into its document
  and overrides wholesale if it wants to. This is the whole reason the feature
  does not need a window manager, and it is a better fit for a
  capability-gated framework than a framework-owned window would be: the updater
  is granted `updater.*` like any other service, so an app that does not want
  a page reaching the filesystem does not grant it.
  **CONDITION, and it has changed — see "Reopened" below.** This decision was
  made *because* `webview.run` creates one window and blocks. That is the only
  reason, and ADR-0024's F0 removes it.
- **A single binary is the only artifact in v1.** No `.zip`, no `.tar.gz`. A
  Vails app *is* one file — the frontend goes in through `assets.Bundle` — so
  there is no bundle to ship, and archive extraction would drag in zip-slip
  protection, symlink-escape checks, a 2 GiB uncompressed cap and a 50 000-entry
  cap for a case that does not arise. The one real exception is
  `bundle.windows_dll_side_by_side`, where the side-by-side DLLs may eventually
  need a `.zip`; that is recorded as a known future case, not a v1 requirement.
- **The swap is a helper mode of the same binary, and the sequence is a pure
  function.** `swap_plan(target, staged, stamp) ![]SwapStep` returns the
  ordered operations — backup aside, move into place, chmod — and the helper
  executes it. Making the plan a value is what makes the dangerous part
  testable: the tests assert the *plan*, and only one test actually moves
  bytes. The parent spawns itself with `VAILS_UPDATE_{HELPER,TARGET,STAGED,PID,
  TIMEOUT_MS}` set and exits; the helper waits for the parent PID to exit, and
  **aborts without touching the target** if the wait times out, so a shutdown
  dialog that keeps the app alive leaves the user with a working app rather
  than a half-swapped one.
- **A failed swap is reported on the next launch, not through a handshake.**
  Wails waits for the helper to reach `application.New` so `Restart` can return
  an error. There is nothing for a V helper to reach yet (see below), and the
  handshake buys one thing: a dialog before the app disappears. The helper
  writes a result file instead, and the next launch surfaces it. Honest, and it
  costs no protocol.
- **`helper_entry()` is line 1 of `main()` and that is a known ergonomic
  cost.** Wails hides this inside `application.New`; Vails has no
  `application.App.run` yet (`application.App` is a service-name registry and a
  state store, nothing more), so the app opts in explicitly. It is one line,
  it is the same line every self-updating app needs, and it disappears the
  moment `application` grows a lifecycle. Recorded here rather than papered
  over with a build tag.
- **Events use the repo's vocabulary, not Wails'.** `updater:check-started`,
  `updater:available`, `updater:no-update`, `updater:download-started`,
  `updater:download-progress`, `updater:downloaded`, `updater:verifying`,
  `updater:ready`, `updater:error`, `updater:skipped` — colon-namespaced
  kebab-case like `tray:clicked` and `menu:clicked`, not Wails'
  `wails:updater:*`. States keep Wails' names (`idle`, `checking`, `available`,
  `downloading`, `verifying`, `ready`, `up-to-date`, `error`) so the port is
  recognisable. Commands are capability names like every other service:
  `updater.is_supported`, `updater.state`, `updater.check`, `updater.download`,
  `updater.apply`, `updater.skip`, `updater.skipped_version`.
- **`check` and `download` return immediately and report as events.** They
  resolve `{"started": true}` after the worker is spawned, because ADR-0010
  forbids blocking the webview thread and a network call is the clearest
  possible violation. `updater.state` is the "what is true right now" call, so
  a page loading mid-download paints correctly — the same split ADR-0018 made
  between `is_supported` (compile-time) and `toast_available` (this machine).
- **The publisher and the client read the same manifest code.** `vails updater
  genkey|manifest|verify` calls the *same* `updater_manifest.v` builder the
  service parses with, so the two cannot disagree about the format, and
  `verify` is a CI gate between building and uploading. Keys are raw bytes
  (32/64), not PEM: V's `ed25519` takes raw keys, and a PEM layer would be
  encoding for its own sake.
- **Version stamping goes through V's own compiler, and is owned by the build
  track rather than this one.** `vails build --version 2.0.0` passes
  `-d vails_version=2.0.0`, and the app reads
  `const build_version = $d('vails_version') or { 'dev' }`. V 0.5.2 supports
  both `-d ident=value` and `$d`, so this needs no generated file and no
  `-ldflags`. `doctor` reports a release built without one, because a
  permanent `'dev'` version silently disables every update check. This started
  in U6 and moved to **B0 of the build & release track (ADR-0022)** on
  2026-09-29: CI needs a stamped version before any of this exists, both need
  it exactly once, and one shared implementation that lands first is the
  point.

## The proof is a loopback server, not GitHub and not a human

The one thing worth designing for is that **the whole chain is provable with
no network, no GitHub repository, no token and no human.** `services` already
depends on `net.http` (ADR-0013 chose it over `veb` specifically to keep
Windows tests gcc-free), so a test spins up a loopback server serving
`releases/latest`, `SHA256SUMS`, `SHA256SUMS.sig` and a fake binary, then runs
check → asset match → stream → SHA-256 → Ed25519 → staged against it. The two
tests that matter most are the negative ones: flip one byte of the fake binary
and the digest check must fail; corrupt one byte of the signature and verify
must fail. Those two are the difference between "there is an updater" and
"the updater refuses bad bytes".

The swap gets its own harness (`tests/swap/`, after the `run_headless.sh`
precedent): two builds of a tiny two-version program, the real helper path run
against a temp directory, asserting the bytes on disk changed and the
relaunch reported v2. That converts "the swap works" from a checklist item
into a machine-checkable claim, which is the standard this repo has held since
the tray click (ADR-0017).

## Reopened: the framework-owned update window (recorded 2026-09-29)

The decision above rejects Wails' framework-owned update window, and the
reason it gives is that building one is a phase-scale project — "the same
machinery is what `menu.set_menu` needs, so it will happen — but making the
updater wait on it means the feature that is nearly free today is blocked
behind the one that is not."

**That condition no longer holds.** ADR-0024 (track R) adds F0, a real
multi-window implementation: a window registry keyed by label, a `Ctx` per
window and per-label event routing. Once F0 ships, `updater.default_html()`
can be a genuine second window rather than markup an app injects into its own
document, and that is the more faithful port.

The rejection is therefore **conditional, not withdrawn**, and the
conditionality is the point:

- Until F0 exists, U4 builds the in-app UI. Nothing in the U track waits.
- Once F0 exists, the framework window becomes available and this section is
  re-opened as its own decision — a second `webview.run` call, a label for it,
  and the event routing that F0 has to be correct about anyway.
- What does **not** change: `updater.default_html()` is still the framework's
  look, an app can still replace it wholesale, and the updater is still
  capability-gated. Those three are what make this framework's answer better
  than a window the framework owns on the app's behalf, and they survive
  multi-window.

Recorded here rather than in ADR-0024 so that a reader of the updater track
finds the condition without having to know that a different track changed it.

## Waves

`U0` (ADR-0019) → `U1` pure-V core → `U2` providers → `U3` downloader and
staging → `U4` the service → `U5` the swap and helper mode → `U6` the CLI →
`U7` the example and the proofs. Each ends green: `v fmt -w .`, `v test .` on
Windows, one ROADMAP checkbox, one CHANGELOG line, one CONTEXT line, one E2E
README entry.

## Rejected alternatives

- **Build multi-window first, then give the updater a framework window.** It
  is the literal port, and it is a phase. The same machinery is what
  `menu.set_menu` needs, so it will happen — but making the updater wait on it
  means the feature that is nearly free today is blocked behind the one that is
  not, for a window the app can render itself in five lines.
- **Ship `vails updater` only, and let users script the publishing side with
  `openssl` + `sha256sum`.** Faster to build, and it puts two writers on one
  format with nothing proving they agree. `manifest` and `verify` are the same
  pure-V builder the service reads; sharing it is nearly free and is the only
  thing keeping the format stable.
- **GitHub Releases only, no manifest.** Diverges from the tutorial's spirit
  and makes the digest/signature code GitHub-specific. The manifest parse is
  ~100 lines and it is what makes a second source a file instead of a project.
- **Run the download on the main thread** (smallest possible diff). Forbids the
  page from rendering a progress bar, i.e. makes the feature's own UI
  impossible. ADR-0010 says no; recorded so nobody re-derives it.
- **`ed25519ph`, `ecdsa-p256`, `sha512`, delta/blockmap downloads, keygen.sh,
  Sparkle AppCast, Authenticode, macOS.** All reachable later and none of them
  a different architecture. `ed25519` + `sha256` covers the tutorial; the
  manifest's `signatureAlgo` field is where the others plug in.

## Consequences

- `ROADMAP.md` gains a U track and its two "out of scope" updater lines are
  struck, with the reason here.
- The schedule is ~14 focused days, which does not fit the ROADMAP's current
  "~2 focused weeks" claim for S1 wave 4 + Phase 5b. That claim needs
  re-baselining rather than being quietly exceeded; this ADR does not decide
  which item slips.
- The Linux proof is in better shape than expected: `v test .` is green there
  (32 files, 2026-09-28) and `examples/services` builds, so a Linux updater
  proof is a matter of *adding* evidence rather than unblocking a broken
  build. What a container cannot ever prove carries over unchanged — the
  Linux `menu:clicked {id}` mapping still needs a real desktop session, and
  every Linux updater entry will be recorded in that file's
  Verification-status table rather than quietly skipped.
- `services` is a flat namespace and its top-level names collide (ADR-0017
  renamed `parse_options` → `parse_tray_options`, `validate_options` →
  `validate_tray_options`, `clicked_data` → `tray_clicked_data`). Everything
  new is named for the service from the start: `parse_manifest`,
  `verify_digest`, `verify_signature`, `swap_plan`, `default_asset_matcher`.
  `Manifest` and `State` are free; a bare `verify` or `digest` is not.
  The `window` service (ADR-0021) claims the same naming discipline.

## Open decisions (not taken here)

- **Re-baseline the ROADMAP, or stage U1+U2 as a self-contained milestone.**
  U1+U2 — semver, the manifest parse, digest and Ed25519 verification, both
  providers, the loopback proof — is a complete, useful, provable unit that
  ships an `updater.verify` capability with no swap and no UI. The alternative
  is to spend 14 days and keep the current two-week claim for wave 4 intact,
  which is not a real option; the schedule needs to say something.
- **Whether U0 blocking delays S1 wave 4.** `menu.set_menu` and
  `window-state` both want the seam's subscriber list. Building U0 first makes
  them cheaper, but inserts a concurrency item in front of two feature items
  that are otherwise ready.

## Notes (verified against V 0.5.2 while planning this)

These are the facts that decided the architecture. Each was checked in the V
source on this machine, not recalled.

- **`vlib/crypto/ed25519` exists and is complete** — `verify(publickey,
  message, sig) !bool`, `sign`, `generate_key`, plus `new_key_from_seed`. The
  whole signing plan rests on this, and the expectation going in was that V
  would have nothing and the feature would need a C dependency. Keys are
  **raw** `[]u8` (32-byte public, 64-byte private), not PEM.
- **`vlib/net/http` in 0.5.2 has explicit streaming download support.** The
  `FetchConfig` docs say it outright: `stop_copying_limit` lets
  `on_progress_body` / `on_progress` "implement streaming downloads, without
  keeping the whole big response in memory", with
  `on_finish(request &Request, final_size u64)`. Signature:
  `fn (request &Request, chunk []u8, body_read_so_far u64, body_expected_size
  u64, status_code int) !` — `body_expected_size` is the progress total for
  free. This removed the largest unknown in the plan: a 200 MB artifact
  downloads to a file without a WinHTTP shim, a libcurl dependency, or the
  whole response in memory. `vlib/net/http/body_reader.v` does **not** exist
  in this version; this is the replacement.
- **`crypto.sha256` streams**: `Digest.write([]u8) !int` + `sum()`, so the
  digest is computed in the same pass that writes the file. No second read of
  a multi-hundred-megabyte artifact.
- **`os.rename` is the correct Windows swap primitive, by accident of how V
  implements it** (`vlib/os/os.c.v:247`): it is `MoveFileW` **without**
  `MOVEFILE_REPLACE_EXISTING`, so it *renames* a running `.exe` — which Windows
  permits — and refuses to overwrite an existing one. That is precisely
  rename-aside: `os.rename(target, target.old.<stamp>)` succeeds on a mapped
  image, then `os.rename(staged, target)` succeeds because the name is free.
  On Linux it is `rename(2)`, which *does* replace, so the backup step is
  redundant there and kept anyway, because the backup is what makes the failure
  path restorable.
- **`os.Process` cannot spawn anything** — `vlib/os/process.v` exposes
  `new_process`, `set_args`, `set_work_folder`, `set_environment`,
  `set_stdin_path` and no `run`; `os.execute` blocks. The helper needs a C
  shim (`CreateProcessW` / `posix_spawn`), and it is the *only* native code
  the updater requires. The shim must use the `vails_updater_*` prefix: V
  concatenates every `.c.v` of a module into one translation unit, so a name
  shared with `dialog_shim.h` or `toast_shim.h` is a redefinition error, not a
  link error (ADR-0018, note 5).
- **Version stamping is a one-flag change.** V 0.5.2 supports `-d ident=value`
  and the `$d` compile-time read (`doc/docs.md`), so `vails build --version`
  needs no generated file and no `-ldflags`.
- **`os.data_dir()` and `os.temp_dir()` both exist** for the persisted skip
  state and the staging directory. The skip state is a small JSON file behind
  a seam, because `state.Store` is in-memory by design and the persisted
  `store` service is S2 and unbuilt — the seam is where a future `store` takes
  over.
- **The digest encoding is a real trap and gets a test.** Wails' manifest
  carries `digest` as **base64** of the raw bytes; `SHA256SUMS` carries it as
  **hex**. Both must parse, or the GitHub path fails verification against a
  manifest the endpoint path accepts.
- **Ed25519 signs the digest, not the file.** Wails' `ed25519` algorithm
  signs the SHA-256 digest, `ed25519ph` signs the artifact with SHA-512
  internally. Vails takes the first: `ed25519.verify(pub, digest_bytes, sig)`,
  which is why the verification is one call and why the digest is computed
  anyway.
