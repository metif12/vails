# ADR-0015 — Phase 5 S1 wave 2: clipboard, opener, notification, and the Linux toolchain that was there all along

Date: 2026-09-27. Status: accepted (Windows E2E-proofed; Linux E2E-proofed
for clipboard, with honest stubs where a backend does not exist).

## Context

ADR-0014 finished the service model with one service that had a real OS
backend (`dialog`, Windows) and one that did not (`os_info`), and it stubbed
`clipboard` behind a command surface. Its stated reason for not writing the
Linux backends was that the machine had no Linux toolchain: "an uncompiled C
file is a liability, not progress".

That reason had expired. The WSL image has had V built from source
(`/root/vsrc/v`, 0.5.2), gcc 15.2, GTK 3.24 and webkit2gtk-4.1 (2.52) since
Phase 1 — `v` was simply never put on `PATH`, and nobody re-checked. This
wave therefore did two things at once: it shipped the three services the
ROADMAP had queued, and it used the toolchain to compile and *run* them,
which is what turned up five defects that no amount of reading would have.

Verification for this batch: 29/29 `v test .` green on **Windows and Linux**;
`v -o vails ./cli` and `v -gc none -o dialog ./examples/dialog` compile on
Linux for the first time; the clipboard round trip proven by screenshot on
both platforms (`tests/e2e_windows/services.png`,
`tests/e2e_linux/services.png`); `opener` and `notification` proven on
Windows by screenshot and by their status lines; `vails doctor` reporting
5/5 native backends on Windows and the honest stub list on Linux.

## Decisions

- **A Linux backend is compiled and proven, not stubbed.** The rule from
  ADR-0014 (pure-V seam first, never write native code you cannot compile)
  stays; only the excuse is gone. `clipboard` uses the GTK clipboard rather
  than xclip/xsel: the webview already owns the display connection and links
  GTK, so it is no extra package and no extra process per read (neither xclip
  nor xdg-utils is installed in the image). `opener` uses GIO's
  `g_app_info_launch_default_for_uri` for the same reason, after
  `g_canonicalize_filename` + `g_filename_to_uri` turn a path into a URI.
  Each OS file is reached through a `$if` in the service's own file, so a
  platform with no backend gets an explicit "not implemented on this platform"
  error and macOS needs no stub file it could never compile.
- **`clipboard` needs no C shim, and writing needs a parent handle.** The
  clipboard is flat C: `OpenClipboard`/`SetClipboardData`/
  `GetClipboardData` + `MultiByteToWideChar` into a `GMEM_MOVEABLE` block
  the clipboard takes ownership of (`string.to_wide()` allocates memory we
  must *not* hand over — vlib/clipboard hit the same trap). `OpenClipboard`
  is a global lock, so it is retried a bounded five times, 25 ms total.
  `EmptyClipboard` makes the opening window the clipboard owner and a NULL
  window leaves the data unowned, so `write_text` requires `Ctx.parent`; that
  rule lives in pure V (`require_parent`) where it is unit-tested. An empty
  clipboard resolves with `""` — a normal state, not a failure.
- **`opener`'s validation is the security boundary.** This is the one
  service whose job is making the OS act on a frontend string, so
  `open_url` accepts only `http`/`https`/`mailto`/`tel` and `open_path` only
  a local path with no `://` and no NUL. `url_scheme` needs two characters
  before the colon, which is what keeps `C:\notes.txt` a path and not the
  scheme "c". Rejections are wrapped in `bad params:` *inside* the service,
  so the wire contract is the same whether a command arrived through the
  router or was called directly. `with` (an application override) is
  Windows-only; the Linux backend refuses it with a readable error instead of
  faking parity.
- **`notification` is a tray balloon, and `is_supported` exists.** A WinRT
  toast needs the WinRT/COM stack reached by hand (RoActivateInstance,
  IToastNotificationManagerStatics, an XML payload as HSTRING) — exactly what
  ADR-0014 keeps behind a shim and no test can check.
  `Shell_NotifyIconW` with `NIF_INFO` is two flat C calls and the shell
  renders it as a real notification. The cost is ownership: a tray icon
  outlives its balloon, so a V worker removes it after the clamped timeout
  (`clamp_timeout`, 1.5–60 s) — the ADR-0010 spawn rule applied to a shell
  resource, and the reason this service needs no window procedure.
  `notification.is_supported` exists because a service that quietly does
  nothing on a platform it has no backend for is worse than one that says so.
  The validated byte bound is deliberately wider than the shell's fixed
  fields: a long body is shown clipped, not refused.
- **`vails doctor` reports backends, not just grants.** A `vails.json` grant
  is not a promise — `notification.*` is a valid grant on a machine where
  notification is a stub. `services/support.v` collects one
  `ServiceStatus{name, ready, note}` per catalog service, each answered by
  the same `$if` its dispatch uses, so report and implementation cannot
  drift; a stub always carries a note, and a test asserts the list matches
  the catalog so a new service cannot forget to answer.
- **The Linux bridge was declared, not wired — now it is.** `run_linux`
  called neither `run_javascript` nor `register_script_message_handler`
  (both declared, neither used), so no `window.vails` was ever injected on
  Linux and every example rendered in preview mode. It now injects
  `bridge.runtime_js()` as a user script, connects
  `script-message-received`, and answers through the new
  `bridge.resolve_json` + `vails_run_javascript` — the raw-WebKitGTK path of
  ADR-0004, where the reply cannot ride a return value.
- **`menu` and `tray` are deferred, with the reason recorded.** Both need a
  hidden window, a `WndProc`, and a callback from C into a running V handler
  (tray: `NOTIFYICONDATA` + `WM_APP+1`; menu: `HMENU` + `TrackPopupMenuEx`).
  That is a new seam — a window procedure that can reach V — and it deserves
  its own ADR rather than riding along with three services that did not need
  it. The balloon already showed which half of it is reusable: the
  `NOTIFYICONDATA` field layout and the icon lifetime.

## Consequences

- **A V struct field name is the wire name.** json2 drops keys it does not
  recognize, and `@json:` attributes do not survive V's C codegen, so the
  shipped `dialog` types promised `defaultPath`/`defaultName` while the
  values were silently discarded. `ts_types` now uses snake_case, the
  `dialog` example page was fixed, and a test pins the two together. A
  TypeScript frontend that passed `defaultName` must rename it.
- `v test .` is green on Linux as well as Windows (29 files). It never was:
  `dialog_test.v` called a Windows-only helper, which moved to pure V so the
  mapping is testable everywhere. `dialog_rc(rc, buf, reason)` now takes the
  shim's message as an argument instead of reading it.
- Linux service availability is uneven by design, and visible:
  `clipboard` and `opener` work, `notification` is a stub, `dialog` is still
  the GTK stub (it is the last S1 item that needs a human answering a modal
  window). `vails doctor` and `notification.is_supported` both say so.
- The example that proves the wave is `examples/services`, and its clipboard
  probe needs no human — which is the only reason it is a repeatable proof and
  not a checklist item. `tests/e2e_windows/capture.ps1` and
  `tests/e2e_linux/run_services.sh` make the screenshots reproducible.

## Notes (V + WebKitGTK, cost real time)

- **`string.vstring()` does not copy.** It *reuses* the C block (V's own
  comment: "the memory block pointed by `cp` is reused, not copied"). Read
  one after `g_free` and you get garbage — and, because the print one line
  earlier looked perfect, the most confusing error in this project
  ("Invalid json: unknown value kind" on a body that had just printed).
  Use `cstring_to_vstring` (or `tos_clone`) whenever the C side owns the
  memory. This bit both the Linux bridge and the Linux clipboard read.
- **A GObject signal handler receives the emitting instance first.**
  `script-message-received` therefore takes
  `(manager, result, data)`, not `(result, data)`; getting it wrong passes
  the `WebKitUserContentManager` where the result belongs and
  `jsc_value_is_string` asserts `JSC_IS_VALUE(value) failed`. A five-line C
  probe with `g_signal_query` + `G_OBJECT_TYPE_NAME` settled it in a minute.
- **webkit2gtk 4.1 (2.52) does not export `WebKitScriptMessage` at all**, and
  its doc comment still shows a `WebKitScriptMessage` callback. What the
  signal really delivers is a `WebKitJavascriptResult`; `jsc_value_to_string`
  takes only the value (WebKit's own header example shows an older
  two-argument form), and `webkit_user_script_new` takes an
  injected-frames enum plus `WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START`.
  Read the installed headers; do not remember them.
- **gcc 14+ treats these as errors, not warnings**: passing a V function
  pointer where WebKit wants `GAsyncReadyCallback`, an implicitly declared
  function (`gdk_window_get_window` had no reachable declaration, so the link
  ended in an undefined reference), and `dialog`'s own `-Wno-
  incompatible-pointer-types` need on the CLI.
- **A top-level `validate` in the `services` module collides with the
  `validate` parameter of `bridge.Router.register_validated` in V's C
  codegen** — gcc rejects the generated function pointer. Name service-local
  validators after the service (`validate_notification`).
- **`u8(x).str()` is the decimal value, not the character** (118 → "118"), so
  building a string byte by byte needs a `[]u8` accumulator and `bytestr()`.
  A rune's `.str()` is its codepoint. Both bit the example's probe snippet.
- **The webview restores a scroll offset after load**, so a proof screenshot
  shows a random part of the page. The example scrolls its proof panel into
  view after the probe resolves; that is a real annoyance for anyone taking
  E2E screenshots on Windows, not just this example.
- `-gc none` is still required for GUI apps here (ADR-0005), and the Linux
  container has no emoji font, so the proof text's 🌱 renders as a box in
  `tests/e2e_linux/services.png` while the round trip itself is exact.
