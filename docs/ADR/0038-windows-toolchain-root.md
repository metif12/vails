# ADR-0038 — the Windows toolchain becomes a resolved root, and MSVC stops at the webview boundary

Date: 2026-10-03. Status: **accepted; the resolver is written, the `#flag` half is
blocked and named.**

## Context

The Windows build is pinned to one machine's MSYS2 install by four pieces of code
and about a hundred pieces of prose:

| | |
|---|---|
| `webview/webview_windows.c.v` | `#flag windows -IC:/msys64/ucrt64/include` and `-LC:/msys64/ucrt64/lib` |
| `buildplan/buildplan.v` | `pub const ucrt64_bin = 'C:/msys64/ucrt64/bin'`, asserted by `buildplan_test.v` |
| `cli/vails.v` | `doctor` hard-codes the header path and the DLL directory |
| `.github/workflows/ci.yml` | `pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader` |

The request behind this ADR is to stop depending on MSYS2 and use a scoped,
self-contained toolchain instead, with MSVC as a second option. The survey that
prompted it, measured on this machine:

- **MSVC Build Tools 18 is installed** —
  `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\cl.exe`.
- **There is no gcc outside MSYS2.** No winlibs, no standalone mingw, no LLVM, no
  Strawberry Perl. So the "scoped gcc" does not exist yet.
- **MSYS2's webview package ships `libwebview.dll.a` and nothing else.** There is
  no `webview.lib`.

That last line decides the MSVC half before any code is written, and it is the
reason this ADR is mostly about a boundary.

## The finding that decides the design: `#flag` cannot read the environment

The obvious design for "one knob" is an environment variable holding a toolchain
root, with the four sites reading it. **Three of the four can.** The fourth
cannot, and this is worth stating plainly because it is not obvious and it is not
a V bug:

```v
#flag windows -IC:/msys64/ucrt64/include
```

`#flag` is a literal. V performs no interpolation in it — there is no `$env()`,
no `$var`, nothing. So `-I`/`-L` **cannot** be made dynamic, and any design that
promises "set one variable and the include path follows" is promising something
the language does not do.

This is the same class of finding as ADR-0035's COM apartment: the constraint is
in the tool, not in the plan, and finding it before writing code is the whole
value of writing it down.

### What follows from it

The include path can only be made dynamic by moving it *out of `#flag` and into C*,
because C's `#include` accepts an absolute path:

- a **generated header** whose contents are `#include "C:/…/webview/webview.h"`,
  pulled in by `#insert` at the top of the file so the `fn C.` prototypes still
  see it;
- and for the **linker**, the `-L` cannot move at all, so `-lwebview` resolves
  against whatever search path the compiler has — which means a scoped install has
  to put `libwebview.dll.a` where gcc looks by default, or the user passes
  `-ldflags "-L<root>/lib"` once.

That is doable and it is *not yet written*, because it cannot be compiled on the
machine this was written on (see Verification). The half that **is** written is the
part that needs no compiler trick: the resolver.

## Decisions

- **One knob: `VAILS_TOOLCHAIN`, holding a *ucrt64-shaped prefix*, not an MSYS2
  install.** `include/`, `lib/`, `bin/` beneath it. That shape is chosen because it
  is what the existing flags already assume, so the default is today's behaviour
  and a scoped install is a directory, not a layout to invent.
- **The default is `C:/msys64/ucrt64`**, so nothing breaks on a machine that sets
  nothing. `doctor` reports *which* root it resolved and *why* — "from
  `VAILS_TOOLCHAIN`" or "default" — because a toolchain that silently came from
  somewhere else than expected is how a DLL ends up next to a binary it was never
  built against (`buildplan.v`'s own note on `ucrt64_bin`).
- **A scoped install must vendor webview.** A standalone mingw gcc does not ship
  `webview.h`, `libwebview.dll.a` or the five runtime DLLs. So "scoped" means
  *gcc + a copy of those three groups taken from MSYS2*, and the resolver's
  `problems` list says which of them is missing rather than letting the build fail
  later with a header error.
- **MSVC goes as far as it can and refuses by name at the boundary.** Pure-V
  modules (`buildinfo`, `buildplan`, `deps`, `sqlreg`, `jsesc`, `events`, `state`,
  `capabilities`, `assets`, `mobile`) compile under `-cc msvc` today with no
  changes. Anything that links `webview` **cannot**, because MSVC needs an
  MSVC-format import library and only `libwebview.dll.a` exists — so `cc_supported`
  refuses, names `webview.lib`, and says which modules are affected.
- **The CLI is not a way out.** It is tempting to think `vails.exe` is webview-free
  — it is not: `cli/vails.v` imports `services` and `webview`, so it links
  `webview_windows.c.v` too. Every real entry point in this repo crosses the
  boundary. That is worth recording because "the CLI can use MSVC" was the obvious
  first hope and it is false.

## Rejected alternatives

- **Hardcode the new scoped path** instead of an env var. Rejected: it trades one
  stale path for another, and the four sites still have to agree.
- **Auto-detect a list of candidate roots.** Rejected: a silent fallback can pick
  a toolchain the user did not mean, and then a DLL from one toolchain ships next
  to a binary from another — the exact mismatch `ucrt64_bin`'s comment warns about.
  An unset variable that means "the default" is inspectable; a probe is not.
- **Build `webview.lib` from webview's source with MSVC.** Not rejected on merit —
  it is the real fix if a Windows GUI build under MSVC is ever wanted — but it is a
  vendoring project of its own (CMake, WebView2 SDK, version pinning), so it is not
  smuggled in as a flag change. It belongs in its own ADR when someone wants it.
- **Keep `-IC:/msys64/...` and just add a second `-I` for the scoped root.**
  Rejected: two include paths for one library means the header that wins is
  whichever the compiler searches first, and a `webview.h` from one toolchain
  against a `libwebview.dll.a` from another is a link error at best.

## Consequences

- `buildplan.ucrt64_bin` stops being a constant a test can assert on and becomes
  the resolved root's `bin`, with the old path kept as the documented default. The
  assertion changes shape: from "the path is this string" to "the default resolves
  to this string", which is the property that was actually wanted.
- `vails doctor` gains a line naming the resolved toolchain and its origin, so
  "why did it pick that" is answerable without reading source.
- CI keeps MSYS2 for now — it is the only toolchain that can build a GUI target
  today — and parameterising it is follow-up work rather than part of this ADR.

## Verification

- `buildplan/toolchain_test.v` — pure V: the default resolves to
  `C:/msys64/ucrt64`, an explicit root wins over the default, the three
  sub-directories are derived from the root, a missing `include/webview/webview.h`
  is reported as a problem rather than as a header error later, and
  `cc_supported('msvc', needs_webview)` refuses **by name** while
  `cc_supported('msvc', no_webview)` does not.
- **Not compiled.** V was being reinstalled while this was written, so even the
  pure-V half is unbuilt. That is the honest state and it is why the `#flag` half
  was left unwritten rather than written blind: a generated-header mechanism that
  has never been through a compiler is exactly the "GTK C nobody has run" mistake
  ADR-0015 exists to prevent.
