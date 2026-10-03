module buildplan

// Every case here is pure: the resolver takes the environment root as an
// argument, so none of this depends on the machine it runs on — which is the
// point, because the machine this was written on has MSYS2 and a machine without
// it would otherwise be the only one able to prove the default.

fn test_an_unset_variable_means_the_documented_default() {
	// The compatibility guarantee: a machine that sets nothing gets exactly what
	// it got before ADR-0038, because otherwise every command in the README and
	// every CI job breaks for a problem only a new machine has.
	tc := resolve_toolchain_from('')
	assert tc.root == default_toolchain_root
	assert tc.root == 'C:/msys64/ucrt64'
	assert tc.origin == 'default'
}

fn test_an_explicit_root_wins_over_the_default_and_says_so() {
	// `origin` is not decoration: "why did it pick that" has to be answerable from
	// `doctor` without reading this file, and a toolchain that came from somewhere
	// other than the default is exactly the silent mismatch the ADR is about.
	tc := resolve_toolchain_from('D:/tools/vails-mingw')
	assert tc.root == 'D:/tools/vails-mingw'
	assert tc.origin == toolchain_env
	assert tc.origin == 'VAILS_TOOLCHAIN'
}

fn test_the_three_directories_are_derived_from_the_root() {
	// A root is a ucrt64-shaped PREFIX, not a path to one directory: this is what
	// makes a scoped install a directory somebody assembles rather than a layout
	// the module has to invent, and it is the shape the existing `#flag` lines
	// already assume.
	tc := resolve_toolchain_from('D:/tools/vails-mingw')
	assert tc.include == 'D:/tools/vails-mingw/include'
	assert tc.lib == 'D:/tools/vails-mingw/lib'
	assert tc.bin == 'D:/tools/vails-mingw/bin'
}

fn test_a_backslash_root_is_normalized_rather_than_mixed() {
	// Windows users type backslashes and the env var is theirs to type into. The
	// string ends up in a path helper and in a doctor line, and `C:\\msys64\\ucrt64`
	// printed next to `C:/msys64/ucrt64/include` is the kind of thing that gets
	// read as two different toolchains.
	tc := resolve_toolchain_from('D:\\tools\\vails-mingw')
	assert tc.root == 'D:/tools/vails-mingw'
	assert tc.include == 'D:/tools/vails-mingw/include'
}

fn test_a_trailing_slash_does_not_double_up() {
	// `root + '/include'` is how the directories are built, so a trailing slash
	// would produce `.../ucrt64//include`. Harmless to most readers, wrong in a
	// line somebody compares against another.
	tc := resolve_toolchain_from('D:/tools/vails-mingw/')
	assert tc.root == 'D:/tools/vails-mingw'
	assert tc.include == 'D:/tools/vails-mingw/include'
}

fn test_a_root_with_nothing_in_it_reports_every_missing_piece() {
	// The case this module exists for: a scoped install that was assembled
	// incompletely. All three problems are named at once, because fixing them one
	// build at a time is the afternoon this is meant to save.
	tc := resolve_toolchain_from('/definitely/not/a/toolchain')
	assert !tc.is_complete()
	assert tc.problems.len == 3
	// Each one says WHERE it looked and WHAT is missing, which is the difference
	// between this and a header error from C with no root named.
	mut text := ''
	for p in tc.problems {
		text += p + '\n'
	}
	assert text.contains('no webview.h')
	assert text.contains('/definitely/not/a/toolchain/include')
	assert text.contains('no libwebview.dll.a')
	assert text.contains('no bin directory')
}

fn test_the_missing_import_library_names_the_msvc_consequence() {
	// The single most useful sentence in the module: MSYS2 ships
	// libwebview.dll.a and nothing else, so there is no webview.lib and `-cc
	// msvc` cannot link a GUI target. A toolchain report is where someone finds
	// that out, so it is where it is said.
	tc := resolve_toolchain_from('/definitely/not/a/toolchain')
	mut text := ''
	for p in tc.problems {
		text += p + '\n'
	}
	assert text.contains('webview.lib')
	assert text.contains('MSVC')
}

fn test_a_scoped_root_that_vendored_webview_has_no_problems() {
	// The shape a correct scoped install has, asserted without needing one to
	// exist: the checks are about the three groups, not about MSYS2. That is what
	// makes "copy these three things next to your gcc" a checkable instruction
	// instead of folklore — and note it needs a directory that really has them, so
	// this case uses the machine's own toolchain when it has one and skips
	// otherwise rather than asserting a path that may not exist.
	tc := resolve_toolchain()
	if !tc.is_complete() {
		// This machine has no complete toolchain, which is exactly the situation
		// ADR-0038 describes. Skipping is honest; asserting would be a fake green.
		return
	}
	assert tc.problems.len == 0
	assert tc.include.len > 0
}

fn test_summary_names_the_root_and_where_it_came_from() {
	// A doctor line that prints the path but not the origin leaves the reader
	// unable to tell a deliberate choice from a default they did not know about.
	tc := resolve_toolchain_from('D:/tools/vails-mingw')
	assert tc.summary() == 'D:/tools/vails-mingw (from VAILS_TOOLCHAIN)'
	assert resolve_toolchain_from('').summary().contains('(from default)')
}

fn test_a_non_msvc_compiler_is_supported_without_asking_about_webview() {
	// The normal case, and it must stay free of ceremony: `cc_supported` is on
	// the path of every build, and a function that made everybody wait on a
	// webview question would be removed by the first person it annoyed.
	cc_supported('gcc', true) or { panic('gcc must be supported: ' + err.msg()) }
	cc_supported('clang', true) or { panic('clang must be supported: ' + err.msg()) }
}

fn test_msvc_is_supported_for_a_pure_v_module_graph() {
	// The half of MSVC that works today, and the reason this function is not just
	// "refuse": ten modules build with -cc msvc unchanged, and a refusal that
	// ignored that would be over-cautious in the direction that costs people
	// things.
	cc_supported('msvc', false) or {
		panic('pure V must build under msvc: ' +
			err.msg())
	}
}

fn test_msvc_refuses_a_webview_build_by_name() {
	// The boundary. What matters is not that it returns an error but that the
	// error is actionable: it names the missing artifact (webview.lib), the
	// artifact that exists (libwebview.dll.a), and the modules that DO work, so a
	// reader can act without opening a file.
	mut why := ''
	cc_supported('msvc', true) or { why = err.msg() }
	assert why.contains('msvc')
	assert why.contains('webview.lib')
	assert why.contains('libwebview.dll.a')
	assert why.contains('ADR-0038')
	// And it names the way out, which is a list rather than a shrug.
	assert why.contains('buildplan')
	assert why.contains('sqlreg')
}

fn test_webview_links_is_the_parameter_it_claims_to_be() {
	// A thin function with a test is still worth it here, because the *claim* is
	// the thing being pinned: whether a given entry point links webview is a fact
	// about the import graph, and the CLI is the counter-example people reach for
	// ("surely the CLI is webview-free") — it is not, it imports services and
	// webview.
	assert webview_links(true)
	assert !webview_links(false)
}

fn test_normalize_root_leaves_a_bare_root_alone() {
	// Guarding the loop: `C:/` must not be trimmed to `C:`, which is a different
	// path meaning "current directory on drive C".
	assert normalize_root('C:/') == 'C:/'
	assert normalize_root('C:/msys64/ucrt64//') == 'C:/msys64/ucrt64'
}
