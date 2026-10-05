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

# V from source, as a cached layer (see the header).
WORKDIR /opt/vlang
RUN git clone --depth 1 https://github.com/vlang/v.git . \
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
