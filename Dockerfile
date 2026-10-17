# Dockerfile — the Linux build environment (ADR-0022 B2).
#
# Three things about this file are decisions rather than setup, and all three
# are argued in ADR-0022:
#
# 1. **Linux only.** A single Dockerfile that built both platforms would
#    need the *Windows* import library of `webview` (a C++ library linked
#    against WebView2) cross-compiled for a foreign target, which is a
#    project of its own. `webview/webview_windows.c.v:20-22` hard-codes
#    `C:/msys64/ucrt64/{include,lib}` for exactly this reason. The
#    Windows job is a native runner with MSYS2 (see
#    `.github/workflows/ci.yml`).
#
# 2. **`make` is inside a layer.** V's build is slow. Running it once as
#    its own layer is the entire reason the container pays for itself:
#    every later layer reuses the cached compiler instead of paying for it
#    again on a cache miss.
#
# 3. **The base is `ubuntu:24.04`, pinned, and NOT V's published image.**
#    This one changed on 2026-10-05 and the reason is a measured CI failure.
#    The file said `FROM thevlang/vlang:ubuntu-build`, on the reasoning that
#    it is "V's own published base image, not an invention here". That
#    reasoning was sound and the conclusion was wrong: the tag is a
#    third-party artifact whose lineage runs back to `buildpack-deps:buster-
#    curl` (vlang/v's own Dockerfile) and Debian 10 **Buster**, which reached
#    end-of-life in June 2024. Its apt archive has no
#    `libwebkit2gtk-4.1-dev`, so the very first RUN failed with
#    `E: Unable to locate package libwebkit2gtk-4.1-dev` — and a webview2gtk-4.0
#    downgrade is NOT the fix, because `webview_linux_shim.h` and the Dockerfile's
#    own assertion below both target the 4.1 API.
#
#    Two reasons this is now explicit rather than inherited, and the second is
#    the one that matters:
#      - correctness: the package we need is in noble and not in what we had;
#      - **reproducibility**: an unpinned third-party tag can change its
#        contents under a fixed name, which makes a green CI run meaningless.
#        Note this cost the base's V, and that turned out not to matter: the
#        image overwrites `/opt/vlang` by cloning and building V anyway (see
#        point 2), so the base was only ever supplying a distro.
#
# Build:  docker build -t vails-ci -f Dockerfile .
# Test:   docker run --rm vails-ci v test .
# Note `VFLAGS: -gc none` in CI, matching ADR-0005: Boehm GC crashes when
# WebKit spawns subprocesses. `buildplan.app_flags(.linux)` applies the
# same flag to real builds, so the two cannot drift.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# The toolchain V is built from source with. `build-essential` brings gcc, g++,
# make and libc headers; `git` brings ca-certificates as a dependency, which
# matters because the clone below is https and a bare ubuntu image has no
# trusted root store.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# GUI dependencies. Three of these are `#pkgconfig`'d or linked by the
# backends, so a missing one is a build failure deep in a generated C
# file rather than a clear error:
#   libgtk-3-dev + libwebkit2gtk-4.1-dev  -> webview_linux.c.v
#   libayatana-appindicator3-dev         -> services/tray_linux.c.v
# The Xvfb set is what tests/e2e_linux/run_headless.sh needs; it is
# installed here so the same image can run the e2e scripts, not just
# `v test`.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk-3-dev \
      libwebkit2gtk-4.1-dev \
      libayatana-appindicator3-dev \
      pkg-config \
      xvfb \
      x11-apps \
      net-tools \
    && rm -rf /var/lib/apt/lists/*

# V from source, as a cached layer (see point 2 in the header).
#
# **The commit is pinned, and this is a fix for a measured failure rather than
# tidiness.** This line used to clone whatever master pointed at on the day the
# layer was *first* built, and then never rebuild: a cached layer is content-
# addressed, so every later build reused a V from that day while the host moved
# on. Measured on 2026-10-10, the image carried V `e5ab344`, five days stale,
# against a host at `ef2ec06` and a master at `60542b9`.
#
# The consequence was concrete, and invisible from the test output: the stale V
# still had a `json2` defect the host's had fixed (AGENTS.md §1b — a module named
# `config` plus `net.http` in one binary decodes to a zero struct with no error).
# So in this container `vails doctor` reported `vails.json : INVALID` on a project
# whose config is valid, on a suite that was **45/45 green**. The same program
# decoded correctly on the host. Nothing in the test output could tell the two
# compilers apart, which is what makes a cached toolchain dangerous: the cache
# decides which compiler you are testing against, and it does not announce it.
#
# **The first pin was `ef2ec06`, and it was wrong for a measure I had not taken:
# it carries a Linux linker regression.** `undefined reference to
# closure__closure_try_destroy` from `vlib/os`'s `execve`/`execvp` paths, twice
# per suite run. V recovers by itself, so the suite still reports 45/45 — which is
# exactly the trap above, one layer down: a green run that hides a broken compiler.
# `10a210b` ("modulecache: own constants and emit cached declarations on demand")
# landed after it and is the likely fix, so the pin moved to `60542b9`, which is
# also current master. Verified on this commit: the `json2` repro decodes
# correctly both ways, **no linker errors anywhere in the run**, and
# `vails doctor` reports `vails.json : ok`.
#
# **A green suite is not a compiler check.** Both of the pins above ran 45/45+, and
# one of them had a linker bug. The check worth adding to any bump is the
# container's `grepped` output for `collect2` / `undefined reference`, not the
# summary line.
#
# **Latent, and re-triggered by the docs site (2026-10-11).** The pin at `60542b9`
# ran the suite clean, and then adding `docs/site/veb_site.v` and
# `buildplan/site_paths.v` brought the error back with no V change at all:
#
#     /usr/bin/ld: ....c:(.text+0xd...): undefined reference to
#     `closure__closure_try_destroy'
#
# Two results are green (46/46) either way, because V recovers, so this is exactly
# the "green suite hiding a broken compiler" case the paragraph above warns about.
# What it tells us is that `10a210b` fixed one reachable path and not the class:
# the failure depends on which modules the build links, so a change in *this
# repository* can turn it back on. **Do not read a clean run as a fixed compiler,
# and do not read this as "the site broke something" - the site only made an
# existing latent bug reachable.** Grep every Linux run until upstream says the
# class is closed.
#
# Pinning also gives this file the property it argues for in point 3 above: an
# unpinned ref can change its contents under a fixed name, which makes a green
# run meaningless. That argument was made for the base image and left unapplied
# to V, which is the thing that actually decides the test results.
#
# **Bump V_SHA deliberately.** Fetching by full sha works on GitHub for any
# reachable commit; a *short* sha is refused ("couldn't find remote ref").
# Before bumping, check current master (`gh api repos/vlang/v/commits/master`),
# then verify all three things in the container rather than one:
#   1. `vails doctor` reports `vails.json : ok` (the `json2` defect)
#   2. no `collect2` / `undefined reference` in a full `v test .` (the closure
#      regression) — grep for it; the summary line will not tell you
#   3. 45/45, obviously
# The first two are the failure modes that stayed green while being broken.
# The first three checks are V's. The fourth is the one that was missed.
#
# **`vc/` is a SEPARATE repository and `make` pulls it by default.** `vlang/v`
# does not contain its own bootstrap compiler: `GNUmakefile` defines
# `VCREPO ?= https://github.com/vlang/vc`, and `all: latest_vc latest_tcc
# latest_legacy` clones that repo and pulls its HEAD before compiling
# `$(VC)/v.c`. So pinning `V_SHA` pins the V *tree* and leaves the bootstrap
# compiler floating - the same unpinned-ref hole this file argues against for
# the base image, one level down, and in the component that decides whether the
# build happens at all.
#
# That hole is not hypothetical. vc HEAD `d4045d7f` (2026-10-16) ships a `v.c`
# whose Windows-only declarations sit outside their `_WIN32` guard:
#
#     ./vc/v.c:15660:28: error: unknown type name 'DWORD'
#     15660 | bool GetConsoleMode(void*, DWORD*);
#
# `DWORD` *is* typedef'd, at v.c:1010 - inside the guard. Every Linux build from
# vlang/v master dies on that line. Reproduced outside CI, in WSL, with plain
# `make`: same error, gcc 15.2.0.
#
# **Why the Linux job was green until 2026-10-17 anyway.** The `latest_vc` pull
# happens inside the V-build layer. While the apt layer was a cache hit, that
# layer was reused wholesale and the pull never executed - so those runs proved
# "the image builds" only in the sense that a cached layer still existed. When
# apt produced new package versions, the layer invalidated, the pull really ran,
# and the build broke on a commit whose Dockerfile had not changed by one byte.
# A green run that never ran the command is not evidence, which is the third
# point of this file's own header arriving late.
#
# **The snapshot must not be NEWER than `V_SHA`.** A newer v1 compiles an older
# V tree badly: snapshot `20e483a3` (from master `9e0c3e77`, 2026-10-14) builds
# the C fine and then fails with
# `cmd/v/v3_fallback_diagnostics.v:4:1: builder error: cannot import module
# "v.ansi" (not found)` - `v.ansi` does not exist in the 2026-10-10 tree. The
# snapshot has to be contemporary with the pin or older.
#
# **`VC_SHA=bcfdc7f3` is the newest snapshot that satisfies both halves**:
# generated from master `a60fb589` on 2026-10-10, the same day as `V_SHA`, and it
# compiles on Linux. Verified end-to-end in WSL: `make` succeeds, `./v version`
# reports `V 0.5.2 60542b9`, `vlib/json2` is present, and a `json2.encode` probe
# prints `{"a":1}`.
#
# **`GIT_ARGV_RUNNER=false` is what keeps the pin.** It overrides V's own hook
# (`cmd/tools/git_argv.sh`) with a command that does not exist, so the
# `latest_vc` recipe takes its documented else-branch - "git not found; using
# existing `vc/v.c`" - instead of `git pull`. Without it the clone below is
# undone a second later and the pin buys nothing.
#
# **Bump `VC_SHA` deliberately, and check both halves**, not just that it builds:
#   1. the snapshot's `v.c` compiles on Linux (`cc -std=c99 -w -o /dev/null v.c`)
#   2. the V master sha in its commit message is an ANCESTOR of `V_SHA`
# A snapshot can satisfy 1 and fail 2, and the failure then looks like a missing
# V module rather than a version skew.
ARG V_SHA=60542b9904a3a0102575ec1104e548996f650a83
ARG VC_SHA=bcfdc7f33e7b7908ee40f76d059c0e2894fb4a3b
WORKDIR /opt/vlang
RUN git init -q . \
    && git remote add origin https://github.com/vlang/v.git \
    && git fetch --depth 1 origin $V_SHA \
    && git checkout -q FETCH_HEAD \
    && git clone -q --filter=blob:none https://github.com/vlang/vc vc \
    && git -C vc fetch --depth 1 origin $VC_SHA \
    && git -C vc checkout -q FETCH_HEAD \
    && make GIT_ARGV_RUNNER=false \
    && ./v version

# The checkout under test. Copied rather than mounted so a `docker run`
# with no arguments does the obvious thing.
WORKDIR /opt/vails
COPY . /opt/vails

# A no-op that fails the build if the toolchain is not what the backends
# assume. `doctor` prints the same three lines, but doctor is something a
# person runs and this runs on every image build: a container that cannot
# compile the app is not a CI environment, it is a slower way to find out.
RUN set -eu; \
    /opt/vlang/v version; \
    pkg-config --modversion gtk+-3.0; \
    pkg-config --modversion webkit2gtk-4.1; \
    pkg-config --modversion ayatana-appindicator3-0.1

CMD ["sh", "-c", "cd /opt/vails && /opt/vlang/v test ."]
