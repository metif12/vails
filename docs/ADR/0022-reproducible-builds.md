# ADR-0022 — Reproducible builds: one container for Linux, one runner for Windows, and a version that is stamped in

Date: 2026-09-29. Status: planned (ROADMAP track B; no code yet).

## Context

The request: build the project's platforms through Docker and GitHub Actions.

There is no CI and no container anywhere in this repo today — no `.github/`,
no Dockerfile, no YAML. The `tests/e2e_linux/README.md` and
`tests/e2e_windows/README.md` proofs are all manual PowerShell and `sh`
invocations, run by a person who then has to believe the output. So this
track is not "containerise the build"; it is **the first CI**, and the bar it
has to clear is the one this repo already set for every other claim:
machine-checkable, with the negative results named.

Three findings from reading `cli/vails.v` and the e2e READMEs shape the
design, and two of them are the opposite of what a CI feature usually
discovers:

- **Windows cannot be built from a Linux container in this architecture, and
  should not be.** The Windows backend needs the MSYS2 ucrt64 toolchain and
  the *Windows* import library of `webview` (`webview/webview_windows.c.v:20-23`
  hard-codes `-IC:/msys64/ucrt64/include` and `-LC:/msys64/ucrt64/lib`), and
  that library is C++ linked against WebView2. Producing it for a foreign
  target is its own project. Any plan that claims a single Dockerfile builds
  both platforms is describing something that does not exist yet.
- **`vails build` does not produce a runnable Windows binary.** It shells
  out to `v -o <out> <dir>` with `VMODULES` set and prints *"packaging arrives
  in Phase 7"* (`cli/vails.v:184`). It does not copy the five side-by-side
  DLLs — those exist **only as `#` comments in the READMEs**
  (`README.md:155-159`, `tests/e2e_windows/README.md:6-7`); no script in the
  repo copies them. A first CI that uploaded that artifact would be worse than
  no CI: it would produce a green tick and an `.exe` that cannot start.
- **The CLI and an application are two different builds.** `vails` itself
  imports `net` for the dev server, so on gcc 16 it needs
  `-cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32'`
  (`tests/e2e_windows/README.md:30-31`), while an application needs only
  `v -cc gcc` — asserted at `tests/e2e_windows/README.md:41`. A CI that
  compiles both with one command is wrong about one of them.

There is also a version problem, and it is not only a missing feature.
`v.mod` says `version: '0.2.0'`; `cli/vails.v:18` says `'0.4.0'`;
`CHANGELOG.md:3-5` says versions follow *the CLI's own version*. There are
already two sources of truth and they are already out of sync. A release
pipeline that stamps a version has to decide which one it stamps, so this ADR
records the decision rather than inheriting the drift.

## Decisions (planned, to be confirmed in B0)

- **Linux in Docker, Windows on a native runner.** One job per target on a
  matrix, and the Linux job runs inside a container built from V's **own
  published base image**:

  ```dockerfile
  FROM thevlang/vlang:ubuntu-build
  RUN apt-get update && apt-get install -y \
        libgtk-3-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev \
        pkg-config xvfb x11-apps net-tools
  RUN make          # once, as a cached layer
  ```

  This is not an invention: V's own `.github/workflows/docker_ci.yml` builds
  in `thevlang/vlang:alpine-build` and `thevlang/vlang:ubuntu-build` with the
  checkout mounted at `/opt/vlang` and V compiled by `make`, and it passes
  `VFLAGS: -gc none`. The three Vails-specific additions on top are the GTK /
  WebKit / AppIndicator `-dev` packages (the two the backends `#pkgconfig`
  and one that `tray` links), and the Xvfb set that the e2e script already
  needs. `make` being inside a layer is the entire reason the container pays
  for itself: a from-source V build is slow once, not once per CI run.
- **Windows on `windows-latest` with MSYS2 installed by script** — the same
  `pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader`
  line that `README.md:144-153` and `vails doctor` already quote. No Windows
  container: a Windows-container host adds cost and makes the matrix slower to
  debug for no reproducibility gain over a pinned `pacman` step.
- **Version stamping is B0, before anything else, and it is shared with the
  updater.** `vails build --version 2.0.0` passes `-d vails_version=2.0.0`,
  and an app reads `const build_version = $d('vails_version') or { 'dev' }`.
  V 0.5.2 supports both `-d ident=value` and the `$d` compile-time read
  (`doc/docs.md`), so this needs no generated file and no `-ldflags`. It was
  previously listed inside the updater's U6; it moves **out** of U6 and into
  B0, because CI needs it immediately and the updater needs it no less, and
  one shared implementation that lands once is the point.
- **`-gc none` goes inside `build_app`, not into a CI command.** ADR-0005
  recorded that GUI apps *must* build with it on Linux (Boehm GC crashes with
  WebKit's subprocesses). A build flag a developer has to remember is a build
  flag that CI will get wrong on the first run, so it is applied by the
  platform branch of `build_app` — alongside the existing `-cc gcc` branch
  that already does exactly this for Windows.
- **B1 makes the Windows output runnable before any CI exists.** The five
  DLLs are staged next to the `.exe` when `bundle.windows_dll_side_by_side` is
  set (the field has existed since T6 and has never been acted on), the two
  build recipes are separate code paths behind a flag rather than one
  hand-assembled command line, and `vails doctor` stops hard-coding
  `vails.json` so it honours `--config` — it currently does
  `cfg_path := 'vails.json'` (`cli/vails.v:356`), which makes `doctor` useless
  in a workspace that has more than one project in it, which is exactly what a
  build matrix looks like.
- **`webview` is pinned to 0.12.** `doctor` reports the version (the header
  exposes `webview_version()`) and the CI script installs a specific MSYS2
  package build. For a 0.2 project the cost of one extra `doctor` line is
  smaller than the cost of a CI that can break with no code change; the
  alternative is recorded as rejected below.
- **Per push: `v test .` on both platforms plus a smoke build each. On a tag:
  a version-stamped build per platform, a `vails updater manifest` run, and
  the manifest attached to the GitHub Release.** The single pipeline serves
  both tracks, and that is the real reason the two were worth planning
  together: the updater's GitHub provider needs exactly the assets this
  workflow uploads (ADR-0020, U6), so the publisher stops being a separate
  manual chore and becomes the build's own last step.
- **Packaging is B4 and stays small: AppImage and `deb` for Linux, the
  side-by-side folder for Windows, nothing else.** `nfpm` is named in the
  Phase 7 packaging line already, so this is finishing an existing commitment
  rather than a new one. macOS waits for Phase 6, which has no backend.

## Waves

`B0` (version stamping + the `v.mod`/`cli` version-truth decision) →
`B1` (a `vails build` that produces a runnable binary, plus `doctor
--config`) → `B2` (the Dockerfile) → `B3` (the matrix workflow) → `B4`
(Linux packaging + release on a tag). ~5 focused days.

## Rejected alternatives

- **One Dockerfile for both platforms.** Not possible without cross-compiling
  the `webview` C++ library for a foreign target, which is a project of its
  own and is not what was asked for. Recorded so nobody re-derives it.
- **A Windows container for the Windows job.** Costs more, runs slower,
  needs a Windows-container host, and is no more reproducible than a pinned
  `pacman` step on a normal runner.
- **Docker only for packaging, builds on native runners.** Smallest container
  surface, and the most duplication: the Linux toolchain setup would exist
  twice, once in the build job and once in the packaging job, drifting.
- **An unpinned `webview`.** A C++ dependency resolved by a rolling
  `pacman -S` can change underneath a green CI between two runs, and the
  failure mode is a link error deep in a generated `src.c` (ADR-0015's
  five-defect class). The pin costs one `doctor` line.
- **CI as the first thing, tests later.** The Linux build failed for a week
  and nobody noticed until a person went looking, which is the argument for
  the test job: a green run that nobody reads is a green run that is not
  evidence of anything.
- **A `permalinks`-style pinned action set for the Windows job.** Not decided
  here; B3 records whatever the first working version uses, and pinning the
  toolchain is what actually protects reproducibility, not pinning the action.

## Consequences

- The build matrix can go green as it stands. `v test .` is **already green on
  both platforms** (32/32 on Linux as of 2026-09-28, once the wave-3 build
  failure turned out not to be a V codegen problem at all), and
  `examples/services` builds on Linux. What a container cannot supply is the
  one thing Linux still cannot prove — the `menu:clicked {id}` mapping needs a
  real desktop session — and that stays where it is, in the manual checklist,
  rather than becoming a CI job that needs a display to exist.
- `vails build` grows real responsibilities (platform flags, DLL staging,
  version, output layout) and its test surface with it. The parts that are
  pure V — deciding the flag set, the DLL list, the output name — are
  extracted as functions so they can be unit-tested on Windows without a
  compiler, following ADR-0013's rule that Windows tests stay gcc-free.
- `vails.json`'s `version` field and the CLI's `const version` stop being
  independent. B0 picks one source and makes the other derive from it, or
  documents which is which; leaving both editable by hand guarantees they
  disagree again.
- No code in this track touches `webview/`, `bridge/` or `services/`, so
  nothing here can affect the Phase 5 service work.

## Open decisions (not taken here)

- **How much of Phase 7 packaging moves into B4.** AppImage and `deb` are
  committed above; icons, `.msi`/NSIS and the icon-per-platform work stay in
  Phase 7 unless B4 turns out to be cheap. This is the one real open question
  the track has, and it is a scoping one rather than a correctness one.
- **Which actions get pinned.** Not the toolchain — that is decided above —
  but the action versions themselves. Whatever the first working workflow
  uses should be pinned so a green run stays green; recorded here because it
  is easy to leave implicit and annoying to retrofit.

## Notes (verified against the repo and V 0.5.2 while planning this)

- **V publishes official Docker base images and its own CI uses them.**
  `thevlang/vlang:alpine-build` and `thevlang/vlang:ubuntu-build`, checked out
  to `/opt/vlang` and compiled with `make` — read out of
  `C:\Users\xman\v\.github\workflows\docker_ci.yml` on this machine. The
  recipe above is that image plus four `-dev` packages.
- **The five Windows DLLs**, from `README.md:155-159` and
  `docs/ADR/0005-windows-webview-backend.md:19-22`:
  `libwebview-0.12.dll`, `WebView2Loader.dll`, `libgcc_s_seh-1.dll`,
  `libstdc++-6.dll`, `libwinpthread-1.dll`, all from `C:\msys64\ucrt64\bin`.
  The `0.12` in the first name is why pinning matters.
- **`-gc none` is not optional on Linux.** ADR-0005: *"Apps MUST build with
  `-gc none`: Boehm GC crashes (`GC_noop1_ptr`, fork-unsafe) when WebKit
  spawns subprocesses."* Restated at `AGENTS.md:21-24` and
  `README.md:425`. The headless run also needs
  `unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11` and
  `WEBKIT_DISABLE_COMPOSITING_MODE=1`, which is why the container installs
  Xvfb rather than trusting a runner to have a display.
- **Two build recipes, quoted from the e2e README.** The CLI:
  `v -cc gcc -cflags '-Wno-incompatible-pointer-types' -ldflags '-lws2_32' -o vails.exe ./cli`.
  An app: `v -cc gcc -o services.exe ./examples/services`, and the README
  explicitly asserts the app build needs no extra flags
  (`tests/e2e_windows/README.md:41`).
- **`C:\msys64\ucrt64\bin` must be on `PATH`** or even `cc1` cannot find its
  own DLLs, which fails as a silent gcc failure rather than a missing-symbol
  error (ADR-0005). A CI step that forgets `PATH` produces a green job and an
  empty binary, so the workflow sets it explicitly and the build step is
  allowed to fail loudly.
- **The version drift is real and pre-existing:** `v.mod` `0.2.0` versus
  `cli/vails.v:18` `0.4.0`, with `CHANGELOG.md:3-5` naming the CLI as the
  authority. B0 has to reconcile this before it can stamp anything.
- **`VMODULES` and `VAILS_HOME` already solve the module resolution that a
  container needs.** `vails_home()` (`cli/vails.v:264-286`) accepts
  `VAILS_HOME` first, then walks up from the CLI binary and the cwd looking
  for `v.mod` + `webview/` + `bridge/`, and `is_vails_root` requires all
  three. A CI job that checks out the app *and* the vails checkout and exports
  `VAILS_HOME` needs no new resolution code — which is why B0–B4 do not
  include a "how does a CI job find the framework" item.
