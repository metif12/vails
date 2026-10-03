# Dockerfile — the Linux build environment (ADR-0022 B2).
#
# Two things about this file are decisions rather than setup, and both
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
# 2. **`make` is inside a layer.** V's own `docker_ci.yml` builds V from
#    source with `make`, and that build is slow. Running it once as its
#    own layer is the entire reason the container pays for itself: every
#    later layer reuses the cached compiler instead of paying for it
#    again on a cache miss. `thevlang/vlang:ubuntu-build` is V's own
#    published base image, not an invention here.
#
# Build:  docker build -t vails-ci -f Dockerfile .
# Test:   docker run --rm vails-ci v test .
# Note `VFLAGS: -gc none` in CI, matching ADR-0005: Boehm GC crashes when
# WebKit spawns subprocesses. `buildplan.app_flags(.linux)` applies the
# same flag to real builds, so the two cannot drift.

FROM thevlang/vlang:ubuntu-build

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
