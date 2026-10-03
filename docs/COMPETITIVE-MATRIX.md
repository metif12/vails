# COMPETITIVE-MATRIX.md — Wails v3 examples and Tauri plugins, against Vails

This file exists because **"better than every sample app in Wails and Tauri" is
not a checkable goal.** It is a wish. What is checkable is a row per
capability: does the framework have it, and if not, which tracked item adds
it. Read it next to `ROADMAP.md`; a row that says `—` with no planned item is
a gap someone chose, and a row that says `—` with no reason is a gap nobody
looked at.

Referenced by `docs/ADR/0024-missing-platform-features-and-the-showcase.md`.

## How this was gathered — and how far to trust it

Three different confidence levels, because they are not equal and pretending
they are would be the exact failure mode this repo's Verification-status
sections exist to avoid.

- **verified 2026-09-29** — transcribed from the GitHub contents API in this
  session: `wailsapp/wails` at `v3/examples` (66 entries listed, the listing
  was truncated at the end) and `tauri-apps/tauri` at `examples` (13 example
  directories).
- **from knowledge, not verified** — the Tauri *plugin* list and what either
  framework uses to build installers. Web search was unavailable this session
  (403) and `v3.wails.io/guides/packaging/` and `v2.tauri.app/distribute/` both
  failed to load, so nothing in this document should be quoted as a verified
  claim about a competitor's toolchain. Re-check before writing a comparison
  into `README.md`.
- **verified in this repo** — every "Vails today" cell, from the source and
  the ADRs named in it.

## Where Vails actually stands

Two rows are **platform** gaps — a missing capability of the shell rather than
a missing service. They are the ones that matter, because every other row is
either small, already in S2, or deliberately out of scope.

| Capability | Wails | Tauri | Vails today | Planned |
|---|---|---|---|---|
| **drag & drop (files, text, images)** | `drag-n-drop` | `drag` | `drop` - `WM_DROPFILES`, **Windows only, unobserved**; the page gets `drop:files`, **not** the DOM's drop events | Linux `GtkDropTarget` (ADR-0036) |
| **multi-window / multi-webview** | `multiwindow` | `multiwindow`, `multiwebview` | routing + registry **proven**; the second Windows window is **written, unobserved** | **F0** (ADR-0035) |
| frameless window / custom title bar | `frameless` | drag decorator + config | `webview.Config` has no chrome field | W1–W4 (ADR-0021) |
| native popup menu | `menu`, `contextmenus` | `menu` plugin | `menu.popup` — no right-click trigger yet | `menu.set_menu`, S1 wave 4 |
| tray | 6 examples (`systray-*`) | — | `tray` + `tray.set_menu` (ADR-0017/0026) | `window-state`, `positioner` |
| dialogs | `dialogs`, `dialogs-basic` | `dialog` plugin | `dialog`, E2E-proven on both platforms (ADR-0027) | non-blocking dialogs |
| notifications | `notifications`, `notch-notification` | `notification` plugin | `notification`, real WinRT toast (ADR-0018) | Linux half, Phase 5b |
| clipboard | `clipboard` | `clipboard-manager` | `clipboard` (E2E both OSes) | — |
| open a URL / path | — | `opener` plugin | `opener` with a scheme allowlist (ADR-0015) | `with` override |
| self-update | `updater` | `updater` plugin | — | U1–U7 (ADR-0020) |
| single instance | `single-instance`, `single-instance-url-scheme` | `single-instance` | — | S2 |
| autostart at login | `autostart` | `autostart` plugin | — | S2 |
| global shortcut | `global-shortcuts` | `global-shortcut` plugin | — | S2 (Wayland risk) |
| file association / deep link | `file-association`, `custom-protocol-example` | `file-associations`, `deep-link` | `opener` with an allowlist, the other direction | S2 |
| keychain / secrets | — | `stronghold` plugin | — | S2 `keychain`; `stronghold` out of scope |
| persisted key-value store | — | `store` plugin | `state.Store` is **in-memory only** | S2 `store` |
| scoped filesystem | — | `fs` plugin + scope | capability-scoped asset reads only | S2, last, riskiest |
| window size / position memory | `window-api` | `window-state` plugin | — | W4 |
| screen / monitor enumeration | `screen` | `Window` API | — | arrives with the `window` service (W3) |
| print | `print` | `print` plugin | — | not planned (small) |
| dock / taskbar badge | `badge`, `badge-custom`, `dock` | — | — | not planned (small) |
| splash screen | — | `splashscreen` plugin | — | not planned (small) |
| cancel in-flight async work | `cancel-async`, `cancel-chaining` | — | `!T` errors, no cancellation token | not planned |
| panic / error boundary | `panic-handling` | — | errors as values, no panic in libraries (AGENTS.md §2) | not needed by design |
| alternative transports | `websocket-transport`, `raw-message`, `gin-*`, `server` | `http` / `websocket` plugins | one transport (ADR-0004) | not planned |
| events | `events`, `events-bug` | built into the runtime | T2 contract, `events.Bus` | — |
| streaming to the page | `streams` | `Channel` / `streaming` | T3 `ChannelHub` (ADR-0011) | — |
| managed state | `binding` | `state` plugin | T4 `state.Store` | — |
| keybindings | `keybindings` | — | — | not planned |
| hide window / ignore mouse | `hide-window`, `ignore-mouse` | — | — | arrives with the `window` service (W3) |
| mobile | `android`, `ios`, `ios-poc`, `mobile` | — | M0 pure-V prep only (ADR-0012) | M1–M4 |
| MCP server | `mcp` | — | — | not planned |
| window effects | `liquid-glass`, `mac-window-tabs` | — | — | macOS, Phase 6 |

## What the matrix says, in prose

**Two platform gaps, and they are the whole argument.** Drag & drop and
multi-window are the only two rows where Vails lacks a capability *of the
shell* that both competitors ship as a worked example. Everything else in the
table is a service (S2 territory), a small platform nicety, or a deliberate
non-goal with a reason attached.

**Drag & drop is the most under-rated gap in the table.** `WM_DROPFILES` /
`IDropTarget` on Windows, `drag-data-received` in GTK, and — the part that is
invisible until it fails — WebView2's `EnableWebDrop` host setting, without
which the webview swallows every drop and nothing reaches the window. For any
app whose users have files on disk, a window that cannot accept a dropped file
is not a demo, it is a prototype.

**Multi-window is load-bearing for three other plans,** which is why
ADR-0024 pulls it out of the showcase track and gives it its own item (F0):
it is a prerequisite for the window-chrome track's per-window tests, for
`tray.set_menu`'s window menu bar, and — the interesting one — it reopens a
decision ADR-0020 made under a condition that no longer holds.

**The count is not the goal.** Wails has ~66 example directories and Tauri
13; a framework is not better for having more directories. A framework is
better when a developer can do the thing they need without reading three
examples and writing platform calls themselves. The `data-ta-drag-region`
contract in ADR-0021 and the `bundle.update_channel` policy in ADR-0023 are
attempts at that bar, not at a row count.

## Maintaining this file

- When a plan item lands, change its cell from a plan reference to `done` and
  name the ADR. A `done` with no ADR is not a claim this repo can support.
- When a row is marked `not planned`, leave the reason. `not planned` without
  a reason is how "we never looked" becomes indistinguishable from "we
  decided", and that is the failure this file was written to prevent.
- Re-verify the two competitor columns before using them in anything public.
  They were gathered on 2026-09-29 and the Wails listing was truncated.
