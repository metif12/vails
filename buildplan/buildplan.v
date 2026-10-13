// buildplan.v — what `vails build` runs and what it stages, as data
// (B1, ADR-0022). Pure-V, no os.execute, no filesystem: every decision
// the build makes is a function of (target OS, target, config flags), so
// all of it is unit-tested on Windows without a compiler and without the
// MSYS2 toolchain.
//
// The reason it is a module and not a longer `build_app` is the failure
// it exists to prevent. `build_app` used to assemble one command line and
// print "DLLs stay side-by-side on Windows; packaging arrives in Phase 7",
// so the five DLLs the binary cannot start without were copied by nobody
// and a green CI would have shipped an .exe that fails on launch. The
// flag set, the DLL list and the output name were all inside the string
// that shelled out, which means none of them could be asserted on.
//
// The one thing this module deliberately does NOT do is decide *how* to
// copy the DLLs: that is I/O, and it lives in the CLI. What is here is
// the decision — which files, from where, under which condition — held
// separately from the doing of it.
module buildplan

import os

// side_by_side_dlls are the five DLLs a Windows GUI app cannot start
// without, all from the MSYS2 ucrt64 `bin` directory (ADR-0005).
//
// `libwebview-0.12.dll` carries the ABI version in its *name*, which is
// the reason `webview` is pinned: an unpinned `pacman -S` that moves to
// 0.13 produces a `libwebview-0.13.dll`, this list stops matching, and
// the resulting `.exe` fails to start with a loader error that names
// neither the DLL nor the version.
pub const side_by_side_dlls = [
	'libwebview-0.12.dll',
	'WebView2Loader.dll',
	'libgcc_s_seh-1.dll',
	'libstdc++-6.dll',
	'libwinpthread-1.dll',
]

// ucrt64_bin is where the DLLs come from on Windows. It is a constant
// rather than a probe because `webview/webview_windows.c.v:20-22`
// hard-codes the same path for `-I` and `-L`, so a build that found the
// DLLs somewhere else would still compile against this toolchain — and
// shipping a DLL from one toolchain next to a binary from another is a
// mismatch that only shows up as a crash on someone else's machine.
pub const ucrt64_bin = 'C:/msys64/ucrt64/bin'

// Target is the platform a build is for. It is an enum rather than
// `os.user_os()` sprinkled through the code because the whole point of
// this module is that the decisions are testable: a Linux plan is
// asserted on a Windows CI run and a Windows plan is asserted on a Linux
// one, which is only possible if "which platform" is an argument.
pub enum Target {
	other
	windows
	linux
}

// Recipe is everything `vails build` decided, as one value. `vails build`
// prints it before running it, so a wrong build is diagnosable from the
// transcript without re-deriving what the flags were for.
//
// `pub mut` on `output` only: the CLI's `--output` overrides the name the
// recipe derived from `bundle.name`, and a struct whose every field is
// writeable invites a caller to edit a decision the tests hold. The rest
// is read-only by construction, which is what makes the flag set and the
// DLL list a guarantee rather than a convention.
pub struct Recipe {
pub mut:
	// output is the binary name, including `.exe` on Windows (V does not
	// add it, and a CI artifact named `services` with no extension is
	// one more thing to remember).
	output string
pub:
	target Target
	// flags are the extra V compiler flags, in the order they go on the
	// command line. They are separate from the base `v` invocation
	// because the base differs too (see `app_flags` vs `cli_flags`).
	flags []string
	// stage_dlls says whether the five side-by-side DLLs are copied next
	// to the output. False whenever the target is not Windows or
	// `bundle.windows_dll_side_by_side` was turned off.
	stage_dlls bool
	// dll_source is the directory the DLLs are copied from; empty when
	// stage_dlls is false, so a caller has nothing to do.
	dll_source string
	// warnings are things the build will still do but that the user
	// should know: a missing DLL source is the big one, because it turns
	// a runnable binary into one that fails on first launch.
	warnings []string
}

// has_flag reports whether the recipe already carries a flag, so a
// caller adding one cannot end up with `-gc none -gc none`.
pub fn (r Recipe) has_flag(flag string) bool {
	return r.flags.any(it == flag)
}

// needs_gc_none reports whether this target requires `-gc none`.
//
// ADR-0005 is unambiguous and the reason is not subtle: the Boehm GC
// crashes (`GC_noop1_ptr`, fork-unsafe) when WebKit spawns its
// subprocesses, so every Linux GUI build needs it. It lives here rather
// than in a CI command for the reason ADR-0022 gives — a build flag a
// developer has to remember is a flag CI gets wrong on the first run.
pub fn needs_gc_none(target Target) bool {
	return target == .linux
}

// app_flags returns the extra compiler flags for an *application* build.
//
// The list is deliberately minimal. An app imports the webview backend,
// which already carries its own `#flag` lines for webview and the Windows
// system libraries, and which does NOT import `net`, so an app needs
// nothing from the compiler that is not already in the module tree. That
// claim is asserted in `tests/e2e_windows/README.md:41` and is why the
// two recipes differ.
//
// **It is a pure function of `target`, and that used to be false.** The `-cc gcc`
// branch was wrapped in `$if windows`, which made `app_flags(.windows)` return
// `[]` when it ran on Linux - so a Windows plan could only ever be checked on a
// Windows machine, which is the exact half-checking `Target` exists to prevent.
// The Linux CI run is what found it (2026-10-05), and it was found by the test
// that was written to catch precisely this.
//
// The `$if` was never load-bearing: the only production caller is
// `recipe(target_for_host(), ...)` (cli/vails.v), which always passes the host's
// own target, so `target == .windows` was already true whenever the `$if` was.
// Removing it changed no real build and made the function honest. `cli_flags`
// below adds its Windows flags with no `$if` at all and always did, which is the
// comparison that made the outlier obvious.
pub fn app_flags(target Target) []string {
	mut out := []string{}
	if needs_gc_none(target) {
		out << '-gc'
		out << 'none'
	}
	if target == .windows {
		// `-cc gcc` is two argv entries on purpose: `v` takes them
		// as separate words, and joining them into one flag with a
		// space is what `quote_if_needed` exists to handle for the
		// hand-assembled case, not for this list.
		out << '-cc'
		out << 'gcc'
	}
	return out
}

// cli_flags returns the extra compiler flags for building *this* CLI.
//
// The difference from an app is `net`: the CLI embeds the dev server
// (ADR-0013), so it pulls in `net.http` and, on gcc 16, needs
// `-lws2_32` to link. `-Wno-incompatible-pointer-types` is the other
// gcc-16 warning V's own socket code trips.
//
// **A caveat that cost a day and belongs here:** that `-lws2_32` cannot
// be supplied by a `#flag` in the importing module. V 0.5.2's
// `dependency_scan_fallback` link path emits the `-l` flags from
// `#flag` BEFORE most object files, and GNU ld only resolves an archive
// against the objects that precede it, so a `#flag` there produces a
// link error that no amount of repetition on the same line fixes. It
// has to arrive as `-ldflags`, which is emitted last. The same ordering
// bug is why `v test .` needs `-ldflags "-lws2_32"` on gcc 16 — see
// AGENTS.md §1.
pub fn cli_flags(target Target) []string {
	mut out := app_flags(target)
	if target == .windows {
		out << '-cflags'
		out << '-Wno-incompatible-pointer-types'
		out << '-ldflags'
		out << '-lws2_32'
	}
	return out
}

// stage_side_by_side reports whether the DLLs are copied for this
// target/config pair, and returns the source directory plus any warning
// worth printing. `windows_dll_side_by_side` is the config field that has
// existed since T6 and has never been acted on until now; honouring it
// is what turns it from documentation into behaviour.
pub fn stage_side_by_side(target Target, windows_dll_side_by_side bool) (bool, string, []string) {
	mut warnings := []string{}
	if target != .windows {
		return false, '', warnings
	}
	if !windows_dll_side_by_side {
		// Not a warning: turning it off is a legitimate choice for an
		// app that ships an installer which stages the DLLs itself
		// (ADR-0024's Inno Setup does exactly that).
		return false, '', warnings
	}
	if !dir_exists(ucrt64_bin) {
		warnings << 'cannot find ' + ucrt64_bin + ' to copy the side-by-side ' +
			'DLLs from; the binary will build but will not START until they ' +
			'are next to it (' + side_by_side_dlls.join(', ') + ')'
	}
	return true, ucrt64_bin, warnings
}

// missing_dlls lists the side-by-side DLLs absent from `dir`, so a build
// can report exactly which ones it could not stage rather than a generic
// failure at launch. A missing `libwebview-0.12.dll` and a missing
// `libstdc++-6.dll` are the same symptom to the user and completely
// different problems to fix, and the loader error names neither.
pub fn missing_dlls(dir string) []string {
	mut out := []string{}
	for name in side_by_side_dlls {
		if !file_exists(dir + '/' + name) {
			out << name
		}
	}
	return out
}

// recipe assembles the whole decision. `name` is the bundle name from
// vails.json; `exe_ext` is '.exe' on Windows and '' elsewhere (V does
// not add an extension, and the artifact name is what CI uploads).
pub fn recipe(target Target, name string, windows_dll_side_by_side bool, version string) Recipe {
	mut flags := app_flags(target)
	mut warnings := []string{}
	// The stamp is a `-d ident=value`, and the value is a compile-time
	// literal from the app's point of view, so it cannot be the string
	// 'dev': that would make `buildinfo.is_release` true for a binary
	// with nothing to compare against, and the doctor warning that
	// exists to catch exactly this would go quiet. The CLI validates the
	// argument as SemVer before it ever gets here; refusing 'dev' here
	// as well is what makes that guarantee testable rather than
	// dependent on a caller.
	if version != '' && version != 'dev' {
		flags << '-d'
		flags << 'vails_version=' + version
	}
	stage, source, stage_warnings := stage_side_by_side(target, windows_dll_side_by_side)
	warnings << stage_warnings
	ext := if target == .windows { '.exe' } else { '' }
	return Recipe{
		target:     target
		flags:      flags
		output:     name + ext
		stage_dlls: stage
		dll_source: source
		warnings:   warnings
	}
}

// command renders the compile line. Kept separate from `recipe` so a test
// can assert the exact string a build will run, quoting included — the
// Windows recipe is full of paths with no spaces, and the Linux one is
// run through a shell where a path with a space would break silently.
pub fn (r Recipe) command(root string) string {
	mut cmd := 'v'
	for f in r.flags {
		cmd += ' ' + quote_if_needed(f)
	}
	cmd += ' -o "' + r.output + '" "' + root + '"'
	return cmd
}

// quote_if_needed wraps a flag in double quotes when it contains a
// space. `v` takes `-cflags '-Wno-x'` as two argv entries, so a flag
// with a space inside it has to survive shell splitting as one word.
fn quote_if_needed(flag string) string {
	if flag.contains(' ') {
		return '"' + flag + '"'
	}
	return flag
}

// dll_targets returns the full paths the staging step copies to, in the
// order they are listed. Sorted by nothing and deduplicated by
// construction: the list is a constant, which is the point — a DLL list
// assembled from a directory scan would silently pick up whatever else
// is in `bin`.
pub fn (r Recipe) dll_targets() []string {
	mut out := []string{}
	for name in side_by_side_dlls {
		out << name
	}
	return out
}

// dir_exists / file_exists are the two filesystem questions this module
// is allowed to ask. They are functions rather than direct `os` calls so
// the module keeps a single, tiny surface over the filesystem: a build
// decision that has to be tested is a decision that has to be injectable,
// and everything else about this module is pure.
fn dir_exists(path string) bool {
	return os.is_dir(path)
}

fn file_exists(path string) bool {
	return os.exists(path)
}
