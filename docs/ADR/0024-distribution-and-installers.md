# ADR-0024 — Distribution: an installer, two Linux packages, and who is allowed to update the app

Date: 2026-09-29. Status: planned (ROADMAP track P; no code yet).

## Context

The request: build a Windows installer and a Linux package, especially an
AppImage.

Nothing in the repo produces a distributable today. `vails build` compiles and
prints *"packaging arrives in Phase 7"* (`cli/vails.v:184`); ADR-0005 left the
question of static link vs side-by-side DLLs recorded but **undecided**; the
Phase 7 line already names `nfpm` as a direction. So this is finishing a
commitment rather than starting a new one.

What makes it more than a list of output formats is one interaction that
ADR-0020 did not account for and that determines the whole design.

**The packaging format decides who updates the app.** ADR-0020 verifies the
download and swaps the running binary with `os.rename(target, target.old)`.
On Windows that works — but only if the process can write to the directory the
executable lives in. An app installed under `C:\Program Files` cannot, without
elevation, and so its self-updater cannot work. Tauri and Electron default to
per-user install directories for exactly this reason and it is rarely stated
as the reason. On Linux the same question has a different answer per format:
a Flatpak is updated by `flatpak`, an AppImage by zsync / `AppImageUpdate`, a
`deb` by `apt`. Shipping an installer without deciding this produces an app
that tries to update itself from inside a sandbox that will not let it, and
the symptom is a silent no-op the user can see but nobody can diagnose.

So the first item in this track is not a script. It is a **policy**, and
every format below is chosen partly by which answer it needs.

## Decisions (planned, to be confirmed in P0)

- **`vails.json` gains `bundle.update_channel`, and it is the single input to
  the updater's behaviour.** One of `in_app` (the app swaps itself),
  `external` (a package manager or AppImageUpdate owns it), or `system`
  (flatpak owns it and the in-app updater is refused outright). `doctor`
  reports the channel and says who owns updates under it, and the `updater`
  service reads it rather than guessing from the platform. A framework that
  tries to self-update inside a Flatpak is not helpful, it is broken, and the
  fix is a refusal at startup naming the channel.
- **Windows: Inno Setup, per-user, with a generated `.iss`.** Two reasons for
  Inno over WiX: it has no .NET dependency (WiX v3 is end-of-life and WiX v4+
  is .NET, which is awkward in a container), and it is the tool most open
  source Windows projects actually ship. The installer is **generated from
  `vails.json` in pure V** — `installer_script(cfg, version) string` — for the
  same reason `vails dts` is: a hand-maintained installer script drifts from
  the config that describes the app, and drift here is invisible until an
  upgrade leaves a stale DLL behind. Being pure V, the script is unit-tested
  on Windows with no compiler, following ADR-0013.
- **The Windows install is per-user and that is a requirement, not a
  preference.** `PrivilegesRequired=lowest` and a default directory of
  `{localappdata}\Programs\<App>`. A machine-wide install is still possible
  and is what an administrator wants, but it is a documented trade: the app
  installs, and the self-updater is refused with a message naming the reason.
  Saying that plainly beats an update check that fails with a permission
  error the user cannot act on.
- **The `.iss` owns the five side-by-side DLLs.** They are listed from
  `bundle.windows_dll_side_by_side` (a field that has existed since T6 and has
  never been acted on), the uninstaller removes them, and an upgrade replaces
  them. This is the specific thing ADR-0005 left open and the specific thing
  that currently nobody does — the five DLL names exist in this repo only as
  `#` comments in two READMEs.
- **The AppImage is hand-built and lightweight, and `linuxdeploy` is not
  used.** WebKitGTK is the hardest library to bundle into an AppImage and
  `linuxdeploy` is where the difficulty lives, not the format. Building the
  `AppDir` directly — `usr/bin/<app>`, a `.desktop`, an icon, an `AppRun` — and
  running `appimagetool` with no additional libraries produces a ~20 MB
  artifact. The cost is honest and stated in the artifact's own metadata
  rather than in a README: it requires `libwebkit2gtk-4.1-0` on the host.
- **Flatpak ships alongside, and it is the better artifact for a GTK/WebKit
  app.** The GNOME runtime already contains WebKitGTK, so a Flatpak is a few
  hundred kilobytes, sandboxed, with a real update story that Flathub owns.
  This is not a consolation prize — for this stack it is the format that
  solves the dependency problem instead of shipping around it. Both are
  produced from the same `vails.json`; the `.desktop`, the icon and the
  metadata are generated once and shared.
- **`deb` stays in scope only if it is cheap.** The Phase 7 line names `nfpm`
  and it is a one-file config against a `vails build` output, so it is likely
  the cheapest of the three. Its update story is `apt`, so it is
  `bundle.update_channel: external` with no in-app updater.
- **No macOS artifact.** Phase 6 has no backend. Saying so here rather than
  shipping a `.dmg` template for a platform Vails cannot build on is the
  difference between a plan and a wish.
- **Icons stay a Phase 7 concern except as a placeholder.** Every one of these
  formats wants an icon and none of them is what an app's icon *is*. A
  generated placeholder proves the plumbing; the real per-platform icon set is
  a separate piece of work and is not pretended at here.

## The three channels, stated once

| Channel | Format | Who updates | In-app updater |
|---|---|---|---|
| `in_app` | Windows installer, per-user | the app, via the ADR-0020 swap | **yes** |
| `external` | AppImage | zsync / `AppImageUpdate` | off by default, opt-in |
| `external` | `deb` | `apt` | off by default, opt-in |
| `system` | Flatpak | `flatpak` | **refused at startup** |

The `AppImage` opt-in is worth a note: the file is writable and single, so the
swap would technically work, but AppImage users expect `AppImageUpdate` and a
`zsync|` entry in the metadata, and running both is how an app ends up with two
update mechanisms racing. Off by default, opt-in, and the reason is in
`doctor`.

## Waves

`P0` (the `update_channel` policy + config + `doctor`) → `P1` (the generated
`.iss`, Inno install step) → `P2` (AppDir + `appimagetool`) → `P3` (Flatpak
manifest) → `P4` (the updater honouring the channel, closing the loop with
ADR-0020's U5). ~8 focused days.

**P0 is independent of everything else and is decision-only.** It changes no
service and needs no backend, and it is the item that stops the rest of the
track from producing three artifacts with three contradictory update stories.
**P1 depends on B1** from the build track: staging the DLLs is what the
installer has to install.

## Rejected alternatives

- **WiX / MSI.** Faithful to what Wails does, and correct for GPO-managed
  enterprise deployment. Costs a .NET-dependent toolchain, a WiX version
  decision this project would inherit immediately, and an MSI that cannot do
  a per-user install without a different author. Rejected for a 0.2 project;
  recorded as the right answer if Vails ever needs to be deployed by an IT
  department.
- **`linuxdeploy` with the GTK/WebKit plugins.** The standard-looking path,
  and the one that produces a 250–400 MB artifact or a broken one, because
  WebKitGTK pulls in ICU, GStreamer, `gdk-pixbuf` loaders and fonts and the
  plugin chain does not reliably collect them. Building the `AppDir` by hand
  is about forty lines and is honest about what it does and does not bundle.
- **A fully self-contained AppImage (bundle WebKitGTK).** The only version
  that runs on a machine with no dependencies at all, at a size that makes
  the download absurd for an app whose binary is a few megabytes. Recorded as
  a deliberate non-goal with the number attached, because "we could bundle it"
  is a true sentence that answers a question nobody asked.
- **One updater that works everywhere.** The formats genuinely differ here;
  the failure mode of pretending otherwise is an app that updates itself in
  one channel and silently never updates in another.
- **A `.msix`.** Requires a signing identity and a packaged-app model, and
  Vails' build is an unpackaged exe with side-by-side DLLs (ADR-0005). Not a
  fit without a different build product.
- **Shipping a `.zip` and calling it a package.** It is what the updater
  artifact already is; a zip is not an install experience.

## Consequences

- The five side-by-side DLLs stop being a comment in a README and become a
  field the installer, the CI job and `doctor` all read.
- `bundle` in `vails.json` gains real content for the first time, and the
  generated `.iss` and the Flatpak manifest become derived artefacts of the
  config — the same relationship `vails dts` has with service manifests, and
  the reason they cannot drift.
- The `updater` service gains a refusal path, and refusal is a first-class
  outcome rather than an error: a Flatpak build that says "flatpak owns
  updates" has told the user something true and useful.
- Everything here is pure V except the three tool invocations, and the parts
  that decide *what* to invoke are testable without any of the tools
  installed.

## Open decisions (not taken here)

- **Does the AppImage bundle `libgcc_s_seh` / `libstdc++` equivalents?** A
  Vails Linux binary links libstdc++ and needs it present; the "light"
  AppImage either requires it on the host or carries it, and the answer
  changes the file size by a few megabytes. P2 measures it and decides.
- **Whether `rpm` joins `deb`.** Almost certainly a copy-paste of the `nfpm`
  config once `deb` works, and almost certainly not worth doing before anyone
  asks.

## Notes (verified against the repo and V 0.5.2 while planning this)

- **Per-user install is a functional requirement for the self-updater, not a
  preference.** The swap in ADR-0020 is `os.rename(target, target.old.<n>)`
  followed by `os.rename(staged, target)`, verified against
  `vlib/os/os.c.v:247` to be `MoveFileW` *without* `MOVEFILE_REPLACE_EXISTING`.
  Both calls need write access to the target directory. Under `Program Files`
  a standard user has none. This is the single most important sentence in the
  ADR and it is invisible in any comparison of installer features.
- **The five DLLs, from `README.md:155-159` and ADR-0005:19-22:**
  `libwebview-0.12.dll`, `WebView2Loader.dll`, `libgcc_s_seh-1.dll`,
  `libstdc++-6.dll`, `libwinpthread-1.dll`. Note `0.12` in the first name is
  the pinned `webview` version from ADR-0022's B2.
- **ADR-0005 never resolved static vs side-by-side**, and the field
  `bundle.windows_dll_side_by_side` defaults to `true` with nothing acting on
  it. This track is what resolves it, in the only direction the current build
  product supports.
- **The Linux binary's library set is small and known:** GTK 3 via
  `#pkgconfig gtk+-3.0`, WebKitGTK via `#pkgconfig webkit2gtk-4.1`, plus
  `libayatana-appindicator3` for `tray` (ADR-0017) and libstdc++ from the C
  backend. That is the complete dependency list an AppDir would have to
  consider, and it is short because a Vails app is a single file with an
  embedded frontend (`assets.Bundle`).
- **What either competitor uses for installers is NOT verified in this
  session** and no claim is made about it here. Web search was unavailable
  (403), `v3.wails.io/guides/packaging/` returned 404, and
  `v2.tauri.app/distribute/` did not load. `docs/COMPETITIVE-MATRIX.md`
  carries that caveat too. Re-check before writing any comparison into
  `README.md`.
