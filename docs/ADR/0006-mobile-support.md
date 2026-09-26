# ADR-0006 — Mobile support strategy (Android + iOS)

Date: 2026-09-26. Status: accepted as plan (no test env yet; M0 is pure-V).

## Findings

- **V Android today**: `vab` (347 stars) packages Sokol/gg graphical apps to
  APK/AAB (NDK compile + packaging + signing). It has NO WebView story, no
  Java host, no JavascriptInterface — a helper, not a solution for Vails.
- **V iOS today**: `v -os ios` / `-simulator` emits a Mach-O via xcrun/clang
  as Objective-C, but bundling (.app, Info.plist), code-signing and install
  are all manual. No bootstrapper exists. (Plus: `ui2` ships `uikit/` with
  native iOS controls.)
- **Wails v3 (model to copy)**: both platforms ✅ with one core idea — the
  SAME desktop code, no fork: platform files via `//go:build android/ios`
  (= our `$if android` + `_android.c.v` files), rest shared. Android =
  `libwails.so` (c-shared, NDK) + tiny Java host (WebView +
  WebViewAssetLoader + JavascriptInterface); iOS = C archive + UIKit
  bootstrap + `wails://` scheme. Key principles: in-process asset serving
  (no localhost), mobile = fullscreen so window geometry/menus/tray are
  INTENTIONAL no-ops, one `application.Mobile` entry dispatching to
  Android / IOS / desktop no-op stub, platform-neutral `events.Common.*`.
- **Tauri mobile** confirms the same pattern (wry backend, per-platform
  capabilities, mobile plugins) — no second reference needed.

## Decisions

- vab is NOT an architectural dependency: Gradle scaffold à la Wails;
  reuse vab pieces (NDK/ABI flags, keystore/AAB logic) only where they fit.
- V JNI story (`@[export]` + shared lib loaded by a Java host) is UNPROVEN
  — the first M1 spike validates exactly this; if it fails, the Android
  architecture changes.
- M3 (iOS) ships as "ready to test on a Mac", verified only via external
  CI/help — no macOS machine here.
- M0 (pure-V: `mobile/` stubs, `capabilities.platforms`, `events.Common.*`)
  proceeds with zero prerequisites.
