// toolchain.v — where the Windows C toolchain lives (ADR-0038).
//
// ## What this module is for
//
// Three places still name `C:/msys64/ucrt64` in code: the webview backend's
// `#flag` lines, `buildplan.ucrt64_bin`, and CI. `vails doctor` was the fourth,
// and a toolchain that is only reachable by editing the files that happen to
// name it is a toolchain nobody can move, so this resolves it once, from one
// knob, and every caller asks here.
//
// ## What it deliberately does NOT do
//
// It does not make the include path dynamic, because it cannot: V's `#flag` is a
// literal with no interpolation, so `-IC:/msys64/ucrt64/include` cannot read an
// environment variable. That constraint is the reason ADR-0038 exists and the
// reason the generated-header half is unwritten rather than half-written. See the
// ADR; the short version is that `-I`/`-L` cannot move and everything else can.
//
// ## The shape of a root
//
// A root is a **ucrt64-shaped prefix**: `include/`, `lib/` and `bin/` beneath one
// directory. Not an MSYS2 installation, and that is the point — the existing flags
// already assume this shape, so the default is today's behaviour and a scoped
// install is a directory somebody assembles, not a layout this module invents.
//
// A scoped install therefore has to vendor three groups from MSYS2, because no
// standalone mingw ships any of them: `webview.h` (+ its headers), the import
// library `libwebview.dll.a`, and the five runtime DLLs. `problems` says which of
// those is missing, so the answer is "your scoped root has no webview" rather than
// a header error three minutes into a build.
module buildplan

import os

// toolchain_env is the one knob. A root, not a compiler: the compiler is on PATH
// as `gcc`, and what has to be agreed on is where the *libraries* are, because
// that is what four places disagreed about.
pub const toolchain_env = 'VAILS_TOOLCHAIN'

// default_toolchain_root is what an unset VAILS_TOOLCHAIN means.
//
// A default rather than a required variable, deliberately: every command in the
// README and every job in CI works unchanged on a machine that sets nothing, and
// the alternative (a hard error) would break all of them for a problem only a new
// machine has. `origin` says which of the two was used, so "why did it pick that"
// is answerable from `doctor` without reading source.
pub const default_toolchain_root = 'C:/msys64/ucrt64'

// Toolchain is one resolved Windows toolchain.
//
// `problems` is not diagnostics sugar. A toolchain that resolves but cannot
// actually build is the case that wastes an afternoon, and the three questions it
// answers — is there a webview header, an import library, a DLL directory — are
// all checkable without starting a compiler.
pub struct Toolchain {
pub:
	// root is the prefix, normalized to forward slashes because that is what the
	// `#flag` lines and the path helpers already use.
	root string
	// include, lib and bin are the three directories beneath root.
	include string
	lib     string
	bin     string
	// origin is toolchain_env or 'default', verbatim, so a doctor line can quote
	// the thing the user would have to change.
	origin string
	// problems is empty when the toolchain looks complete.
	problems []string
}

// resolve_toolchain reads the environment. Thin on purpose: the testable half is
// resolve_toolchain_from, and a function that both reads `os.getenv` and makes
// decisions can only be tested by arranging the environment.
pub fn resolve_toolchain() Toolchain {
	return resolve_toolchain_from(os.getenv(toolchain_env))
}

// resolve_toolchain_from is resolve_toolchain with the environment handed in, so
// every branch is unit-testable on any OS.
//
// The webview checks are Windows-shaped and run everywhere, because the point of
// the check is to say something *before* a Windows build, and a test that only ran
// on Windows would be a test nobody runs.
pub fn resolve_toolchain_from(env_root string) Toolchain {
	mut root := if env_root == '' { default_toolchain_root } else { env_root }
	root = normalize_root(root)
	// `problems` is a local and is moved into the struct at the end, so a
	// resolved Toolchain is immutable: there is nothing to fix up after it has
	// been built, and a mutable field here would let a caller "repair" one half
	// of a value whose other half was derived from the same root.
	mut problems := []string{}
	// A header first: without it nothing compiles, and the message can say the
	// useful thing ("your scoped root has no webview.h") instead of leaving C to
	// say "webview/webview.h: No such file or directory" with no hint about which
	// root it searched.
	if !os.exists(root + '/include/webview/webview.h') {
		problems << 'no webview.h under ' + root +
			'/include (a scoped toolchain has to vendor it; a standalone gcc does ' +
			"not ship it, so copy it from MSYS2's include/webview)"
	}
	// The import library is the mingw-only half, and it is why `-cc msvc` cannot
	// build a GUI target at all — there is no webview.lib for MSVC to link
	// (ADR-0038).
	if !os.exists(root + '/lib/libwebview.dll.a') {
		problems << 'no libwebview.dll.a under ' + root +
			'/lib (this is a mingw import library; there is no webview.lib, so ' +
			'MSVC cannot link webview at all)'
	}
	if !os.is_dir(root + '/bin') {
		problems << 'no bin directory at ' + root +
			'/bin (the five side-by-side DLLs are copied from there)'
	}
	return Toolchain{
		root:     root
		include:  root + '/include'
		lib:      root + '/lib'
		bin:      root + '/bin'
		origin:   if env_root == '' { 'default' } else { toolchain_env }
		problems: problems
	}
}

// normalize_root turns a root into the one spelling the rest of the codebase uses.
//
// Backslashes become forward slashes and a trailing slash goes, because this
// string ends up inside a path helper and inside a doctor line, and
// `C:\msys64\ucrt64` printed next to `C:/msys64/ucrt64/include` is the kind of
// thing that gets read as two different toolchains.
//
// The length guard is load-bearing: `C:/` must survive. Stripping its slash gives
// `C:`, which on Windows is the *current directory on drive C* rather than the
// root of it — so a "harmless" normalization turns a valid root into a path that
// means something else entirely. The first version of this loop had that bug, and
// the test written alongside it caught it before anything was compiled — which is
// the cheapest possible time to catch it.
pub fn normalize_root(root string) string {
	mut out := root.replace('\\', '/')
	for out.len > 3 && out.ends_with('/') {
		out = out[..out.len - 1]
	}
	return out
}

// is_complete reports whether the toolchain can probably build a Windows GUI
// target. "Probably" is doing real work in that sentence: it is a check over three
// files, not a build.
pub fn (tc &Toolchain) is_complete() bool {
	return tc.problems.len == 0
}

// summary is the one line `vails doctor` prints. It names the root AND the
// origin, because a toolchain picked from the default on a machine that meant to
// set the variable is exactly the silent mismatch ADR-0038 is about.
pub fn (tc &Toolchain) summary() string {
	return tc.root + ' (from ' + tc.origin + ')'
}

// webview_links answers the question the MSVC decision turns on: does this build
// link the webview native library?
//
// It is a parameter rather than a lookup because the honest answer depends on the
// entry point, and getting that wrong in either direction is bad: claiming a GUI
// app is webview-free would send someone to `-cc msvc` for a build that cannot
// link, and claiming the pure-V modules need webview would hide the one thing MSVC
// *can* do today.
pub fn webview_links(imports_webview bool) bool {
	return imports_webview
}

// cc_supported says whether a C compiler can build a module graph, and refuses by
// name when it cannot.
//
// This is the ADR-0038 boundary in one function, and it exists so the refusal is
// a sentence a user can act on rather than a link error they have to interpret:
//
//     vails: msvc cannot build this target: it links webview 0.12, and only the
//     mingw import library (libwebview.dll.a) exists - MSVC needs webview.lib.
//     Pure-V modules (buildinfo, buildplan, deps, sqlreg, jsesc, events, state,
//     capabilities, assets, mobile) do build with -cc msvc.
//
// The `!` return is deliberate and so is the emptiness of the ok case: a caller
// that ignores the error gets a silent no-op, which is the outcome this repo keeps
// refusing. Callers must `or { return err }` or print it.
pub fn cc_supported(cc string, needs_webview bool) ! {
	if cc != 'msvc' {
		return
	}
	if !needs_webview {
		return
	}
	return error('msvc cannot build this target: it links webview 0.12 and only ' +
		'the mingw import library (libwebview.dll.a) exists - MSVC needs ' +
		'webview.lib, which no package ships. Pure-V modules (buildinfo, ' +
		'buildplan, deps, sqlreg, jsesc, events, state, capabilities, assets, ' +
		'mobile) do build with -cc msvc. See ADR-0038.')
}
