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
# **A green suite is not a compiler check.** Both of the pins above ran 45/45,
# and one of them had a linker bug. The check worth adding to any bump is the
# container's `grepped` output for `collect2` / `undefined reference`, not the
# summary line.
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
ARG V_SHA=60542b9904a3a0102575ec1104e548996f650a83
WORKDIR /opt/vlang
RUN git init -q . \
    && git remote add origin https://github.com/vlang/v.git \
    && git fetch --depth 1 origin $V_SHA \
    && git checkout -q FETCH_HEAD \
    && make \
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
