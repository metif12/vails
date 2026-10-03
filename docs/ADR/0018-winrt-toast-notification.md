# ADR-0018 — `notification` shows a real Windows 10/11 toast

Date: 2026-09-28. Status: accepted (Windows compile- and link-verified; the
runtime proof could not be taken on this machine — see "Verification status").

## Context

ADR-0015 shipped `notification` as a tray balloon and named the alternative as
the recorded follow-up: "a toast needs the WinRT/COM stack reached by hand
(RoActivateInstance, IToastNotificationManagerStatics, an XML payload as
HSTRING) — exactly what ADR-0014 keeps behind a shim and no test can check".
ADR-0017 then built the window host seam, which turned out not to be the
missing piece; this is the piece that was.

The balloon was never a real Windows 10/11 notification. It is
`Shell_NotifyIconW` with `NIF_INFO`, and on Windows 11 it is routed to the
Action Center under the name of the bare `.exe`, cannot carry an app name or
icon, and needs a tray icon that outlives the message — which is why the
balloon needed a V worker to delete the icon again, and why a single stray
worker would have left a row of dead icons (the ADR-0017 `uId` hazard, in
miniature).

An unpackaged desktop app has one hard prerequisite the balloon never had: a
**WinRT toast cannot be raised without an AppUserModelID.** The shell keys
notifications on it, and without one the toast is either refused or attributed
to nothing. That is why this ADR is not only about C.

## Decisions

- **The AppUserModelID is app config: `vails.json` `bundle.identifier`.** It
  is a Tauri-shaped field and it is the honest home for an app identity.
  The alternatives were worse: deriving it from the executable name makes two
  apps built from the same template share one Action Center entry, and a
  hard-coded constant means every Vails app on the machine shares one. The
  charset rules (ASCII alphanumeric plus `.`, `-`, `_`; at most 128
  characters; no leading or trailing period) are enforced in **pure V**
  (`config.validate_identifier`), because the failure they prevent is a toast
  that silently does not appear, and `vails doctor` should say so rather than
  a user staring at an empty notification area. `vails init` scaffolds a
  working one via `default_identifier`, and `doctor` names the field
  whenever `notification` is granted without it.
- **The whole WinRT stack is behind `toast_shim.h`, values are UTF-8.** Same
  pattern and the same rule as `dialog_shim.h` (ADR-0014): V has no COM *or*
  WinRT projection, so `RoInitialize`, the three `RoGetActivationFactory`
  calls, the HSTRING plumbing, the `IXmlDocumentIO` `QueryInterface` and the
  AUMID registration are all C behind two functions.
  `vails_toast_show(aumid, display, xml)` returns 0 or negative, and
  `vails_toast_last_error()` carries the HRESULT. The C file is ~200 lines of
  straightforward WinRT and no policy.
- **The document is built in pure V.** `toast_xml` + `escape_xml` live in
  `notification.v` where `v test` reaches them. This is the highest-value
  seam in the change: an unescaped `<` from a frontend produces a document
  the shell refuses to parse, and the symptom — nothing appears — points
  nowhere near the cause. The C side is then a byte pump.
- **The balloon is deleted, not kept as a fallback.** A notification that
  changes mechanism depending on the machine is harder to reason about and
  harder to support than one that fails loudly, and a real toast plus a real
  error is a better answer than a toast on Tuesday and a balloon on Friday.
  So `notify_native` no longer calls `require_parent` (a toast is not owned by
  a window, so demanding an HWND would be a lie about what the backend needs),
  `notification_icon_id` is gone, and the `NIF_INFO`/`NIIF_*` constants left
  `trayicon_windows.c.v`. That file is now the tray's primitive rather than a
  primitive two services happened to share; its `uId` contract is unchanged
  and still the thing to read before adding a second shell icon.
- **`notify` resolves with the mechanism that ran** (`'toast'`), where it used
  to resolve with `''`. A toast's only machine-checkable evidence is what the
  caller can report, so the result names the path — which is also what makes
  the E2E proof possible at all. The `.d.ts` is unchanged (`Promise<string>`
  held), and the value is a closed set of one today.
- **`is_supported` stays compile-time, and that is now a sharper distinction.**
  It answers "is there a backend on this platform", which is still true; the
  separate question "does *this machine* have the WinRT runtime" is answered
  by `vails_toast_available()`, which `doctor` can use. Keeping them apart is
  what lets a stripped app image compile and link the toast and still be told,
  honestly, that it cannot raise one.
- **`timeout_ms` becomes a hint and says so.** A WinRT toast's on-screen
  duration is chosen by the shell from the user's notification settings; no
  API overrides it. What the request still controls is the toast's `duration`
  attribute (short vs long), so the clamp is kept, the field is kept, and
  `toast_duration` is the honest mapping. The bounds also stopped being about
  shell fields: a toast has no fixed-width text field to clip against, so
  128/512 bytes is now a frontend-facing limit rather than a truncation point.
- **A NUL is rejected in the title and body.** The balloon silently truncated
  at one inside the shell's fixed field; a C string does the same thing, and a
  truncation the frontend did not ask for is worse than a rejection. `tray`
  already had this rule (ADR-0015).

## Verification status — read this before trusting a green run

- `v test .` green on **Windows**: 32/32 files, including the new
  `toast_xml` / `escape_xml` / `toast_duration` cases and
  `config.validate_identifier`.
- `v -cc gcc -o services.exe ./examples/services` builds and **links** on
  Windows; `nm` confirms `RoGetActivationFactory`, `WindowsCreateString`,
  `SetCurrentProcessExplicitAppUserModelID` and `RegCreateKeyExW` all resolve
  in the binary, and the three new GUIDs are compiled in rather than left as
  undefined externs.
- The **runtime toast could not be proven on this machine.** Running the shim
  standalone gives
  `RoGetActivationFactory(ToastNotificationManager) failed (hr=0x80040154)`
  (`CLASS_E_CLASSNOTAVAILABLE`), and `vails_toast_available()` returns 0.
  This is the machine, not the code, and it was confirmed three ways:
  PowerShell's own WinRT activation fails identically for
  `Windows.Foundation.Uri`; `Windows.Foundation.dll` and
  `Windows.UI.Notifications.dll` are absent from both `System32` and
  `WinSxS`; and `HKLM\SOFTWARE\Classes\ActivatableClasses` contains only
  `CLSID` and `Package`. This is a stripped Windows 11 26H1 (build 28000)
  image with no WinRT component DLLs.
- What *was* proven at runtime is the half that does not need WinRT: the AUMID
  registration wrote `HKCU\Software\Classes\AppUserModelId\com.vails.spicheck`
  with `DisplayName = "Vails Spike Check"`, and the failure surfaced as a
  rejected promise with the real HRESULT rather than a silent no-op — which
  is the "fail loudly" half of the decision above.
- **A toast is therefore unproven end to end.** What still needs a human, on
  a machine with a normal Windows image: press **Notify** in
  `examples/services` and confirm a toast carries the app's name
  (`Vails Services Demo`, from `bundle.identifier`/`bundle.name`) and lands in
  the Action Center. `tests/e2e_windows/README.md` has the steps.

## Consequences

- `notification.notify` has a **new required input** for any app that uses it:
  `bundle.identifier` in `vails.json`. An app with an empty one gets
  `notification.notify: no app identity…` naming the field — it does not
  guess, because a guessed AUMID produces exactly the unattributed toast this
  change exists to eliminate. `vails init` writes one, so a scaffolded app is
  unaffected; an app upgrading an older `vails.json` must add it.
- `install_notification` gained a parameter (`AppIdentity`). The other six
  services are unchanged.
- `notification.notify`'s **result changed** from `''` to the mechanism name.
  The generated type is still `Promise<string>`, so no frontend needs a
  re-generated `.d.ts`, but a caller that compared the result to `''` must
  stop.
- The `services` module's C now links four more libraries on Windows
  (`runtimeobject`, `shell32`, `ole32`, `advapi32`) and drags in the
  1.2 MB `windows.ui.notifications.h` for **every** `services` test compile.
  Measured cost: the `services` test files went from ~13.5 s to ~14 s each,
  which is noise against the 1.3 s the whole toast sequence costs to compile.
  If that ever stops being noise, the fix is the one ADR-0017 already used for
  `appindicator`: hand-declare the vtbls instead of including the header.
- **Linux is unchanged and still a stub**, and `is_supported` answers `false`
  there. The Linux *app* build is broken in this working tree, but not by
  this change: `menu_linux.c.v` and `tray_linux.c.v` fail to compile with
  missing `fn C.*` prototypes, and that reproduces with the committed
  services and none of this work (see `tests/e2e_linux/README.md`).

## Notes (MSYS2 + WinRT, cost real time)

Five facts about the installed headers that no amount of API documentation
tells you, each found by compiling and reading the error:

1. **No WIDL IID in this toolchain is linkable.** `nm` over `libuuid.a`,
   `libwindowsapp.a`, `libole32.a` and `liboleaut32.a` finds none of them, and
   in C mode `DEFINE_GUID` is an `extern` declaration, so referencing one is
   an `undefined reference` at link time. Four GUIDs are therefore copied
   verbatim into the shim as `static const` — the same thing `dialog_shim.h`
   does, and the reason that file works at all.
2. **The short type names do not exist in C.** `IToastNotifier`,
   `IToastNotificationManagerStatics`, `IToastNotificationFactory`,
   `IXmlDocument` and `IXmlDocumentIO` are all undeclared; only the long
   `__x_ABI_CWindows_…` spellings compile. The short names live in
   `namespace ABI` blocks, which are C++-only.
3. **`RoGetActivationFactory` takes an `HSTRING`, not a wide string literal.**
   `L"…"` is a pointer-type error; every class name goes through
   `WindowsCreateString` first.
4. **`LoadXml` is not on `IXmlDocument`.** It is on the separate
   `IXmlDocumentIO`, so the document must be `QueryInterface`-ed before it can
   be parsed.
5. **`asyncinfo.h` (pulled in by the notifications header) declares an
   enumerator called `Error`**, which collides with V's own `Error` type in
   the generated `src.c` — `typedef struct Error Error;` versus
   `enum AsyncStatus { …, Error = 3 }`. `#define Error …` around the include
   is the escape, and it has to be `#undef`ed after so the macro does not
   leak into unrelated headers.

And one about V, not the SDK:

- **V concatenates every `.c.v` file of a module into ONE translation unit.**
  So `dialog_shim.h` and `toast_shim.h` land in the same `src.c`, and two
  shared helper names are a `redefinition` *error* at compile time, not a
  duplicate-symbol error at link time. The toast shim's UTF-16 helpers are
  therefore named `vails_toast_*` rather than reused from the dialog shim's
  `vails_*`: a third shared header would need both shims to include it, which
  is a build-order dependency, and two uniquely-named 12-line copies cost
  less and cannot be ordered wrongly.
