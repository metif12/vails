# ADR-0002 — Linux-first (WebKitGTK), Windows/macOS deferred

Date: 2026-09-26. Status: accepted.

Wails backends: Windows = WebView2 over COM (`go-ole`, `go-webview2`),
macOS = WKWebView over ObjC, Linux = WebKitGTK over plain C.

V's C-interop (`#pkgconfig` + `fn C.*`) maps 1:1 onto WebKitGTK but has no
COM projection and no ObjC bridge, so Windows/macOS need extra C wrapper
layers (Phase 6 risk). Linux is also the only backend verifiable without
paid tooling.

Decision: Phase 1–5 target Linux/WebKitGTK only. `webview/` facade keeps
all C behind `run_linux`; every other module stays OS-agnostic and
Windows-testable so development continues on the Windows machine.
