# ADR-0039 - notification stays WinRT-only; the balloon comes back as its own
# service, not as a fallback

Date: 2026-10-03. Status: **accepted; steps 0-3 written and unit-tested, step 4
deliberately gated behind a capability it does not yet have.**

## Context

ADR-0018 removed the tray balloon and made `notification` a WinRT toast with no
fallback, on the grounds that a notification which changes mechanism depending
on the machine is harder to reason about than one that fails loudly. That
argument was about *substitution inside one service*, and it was right.

It is now also the reason a decision that looked like a bug is not one. While
probing the toast path on a Windows 11 build `28000` machine, the toast classes
did not activate at all:

```
RoGetActivationFactory(ToastNotificationManager) -> hr=0x80040154
                                                       REGDB_E_CLASSNOTREG
```

The obvious conclusion was "the AUMID is wrong". Measuring the machine instead
of reasoning about it says otherwise, and the measurement is worth recording
because the wrong hive was checked first:

| key | value on a healthy Win11 | value here |
|---|---|---|
| `HKLM\...\Classes\CLSID` | thousands of COM classes | **7447** — fine |
| `HKLM\...\Classes\ActivatableClasses\ClassId` | thousands of system WinRT classes | **absent** |
| `HKLM\...\Classes\AppX` | present | **absent** |
| `C:\Windows\WinSxS` | ~20 000 entries | **19 799** — fine |

COM is intact and the component store is intact; the two registry branches that
back WinRT and the app model are gone. That is the signature of a
debloated/privacy-hardened image (scripts that strip WinRT because "nothing
uses it"), and it explains why `WpnService` runs - it is a service, not a WinRT
class - while *no* system WinRT class can be activated.

Two things follow, and they point in opposite directions:

1. The toast is correct as designed and will work on a healthy machine.
2. On *this* machine it cannot work at all, and no code change makes it.

So the honest options were: repair Windows, or give the framework a notification
mechanism that works without WinRT. Windows can only be repaired by the user, and
that a service's availability depended on an unrepairable-by-the-user OS was
never a good place to leave the product.

The balloon came up as the fallback, and it was rejected — for the same reason
ADR-0018 removed it. But the *objection* was never "balloons are bad". Reading
ADR-0018 again, its three objections are all about a balloon acting as *the
notification*: it is attributed to the bare `.exe`, it needs a tray icon that
outlives the message, and it cannot carry an app name or icon. None of those
apply to a service that a caller asks for by name, with its own icon and its own
lifetime.

## Decisions

- **`notification` is a WinRT toast and nothing else.** No fallback, no probing
  for an alternative, no second value in the mechanism it returns. If the
  classes do not activate, `notify` returns an error that says so.
- **`balloon` is an independent service** (`balloon.show`) with its own
  availability, its own manifest, its own `is_supported`, its own tray uid, and
  its own lifecycle. It is not reachable through `notification` and does not
  appear in its mechanism string. A frontend that wants a balloon asks for a
  balloon.
- **`Windows.Storage` file picking is rejected.** `dialog.open` already picks
  files over COM (`IFileOpenDialog`), which works on a machine whose WinRT does
  not; folder picking is the single `FOS_PICKFOLDERS` flag
  (`shobjidl.h:21513`), also COM. A `Windows.Storage.Pickers` backend would
  inherit exactly the breakage above, needs `IInitializeWithWindow` on top, and
  would be a second vocabulary for one job.
- **Toast action buttons are gated, not shipped.** Buttons are pure XML
  (`<actions>`), so they need no new WinRT API and no new IID — they can be
  built today. What is missing is *delivery*: a click has to reach the app as
  `IToastActivatedEventArgs`, and this machine has no source for that IID
  (see below). Buttons that render but do nothing are the same lie the balloon
  was removed for, so the service reports the capability as false and does not
  emit the element.
- **An unavailable toast reports *why*, in a sentence a reader can act on.** The
  activation failure alone is `REGDB_E_CLASSNOTREG`, which sends a reader to
  the AUMID. `toast_failure_note` names the missing registry branch and the two
  commands that repair it.

## The IID problem, because it decides what "later" means

The action-click delivery path needs the IIDs of
`IToastNotificationManagerStatics` (for the activated event) and
`IToastActivatedEventArgs` (for the argument string). Those are **not obtainable
on this machine**:

- `windows.ui.notifications.h` in the MSYS2 headers names
  `IToastNotificationManagerStatics` and `IToastActivatedEventArgs` but carries
  **zero** `__declspec(uuid)` declarations — no IID in the header text. This is
  exactly why every GUID in `toast_shim.h` is a hand-copied `static const`
  (comment 1 at the top of that file).
- The Windows SDK copy that is installed is `cppwinrt\winrt\…`, C++/WinRT
  templates, with no C-readable IIDs.
- `Windows.winmd` is not installed, and `UniversalApisContract.winmd` — the
  contract that holds `Windows.UI.Notifications` — is absent from the 93
  contract winmds present.
- The network is unreachable from the build environment.

Guessing a GUID would activate the wrong object, which is worse than having no
buttons. So step 4 is gated, and the gate is honest about why.

## Consequences

- `notification` is WinRT-only, which means **`notification` does not work on a
  debloated Windows image**, and that is now said plainly by `vails doctor`
  rather than surfacing as `REGDB_E_CLASSNOTREG` at call time.
- Windows repair is the user's to perform; the commands are documented in
  `tests/e2e_windows/README.md` rather than automated, because
  `DISM /RestoreHealth` is an admin operation on the user's machine.
- `balloon` works on machines where WinRT does not, which is the whole reason it
  exists — but it is a *secondary* service and must not be described as a
  notification backend.
- `toast_actions` is a capability that starts false and becomes true when the
  delivery path exists. It is expected to arrive with the IIDs, not with a
  rewrite.
