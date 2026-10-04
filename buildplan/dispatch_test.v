module buildplan

import os

// repo_root is absolute (derived from @FILE) so the guard does not depend on the
// working directory `v test` happens to use.
//
// Declared here rather than reusing the identically-named const in
// workflow_test.v: V compiles each `_test.v` in a module as its own unit, so a
// module-level const in one test file is not visible from another. Measured, and
// the error names a const that is plainly right there on the next screen.
const repo_root = os.join_path(os.dir(@FILE), '..')

// dispatch_test.v - guards one line of C that has now cost two bugs and one
// process crash, and that no unit test can reach.
//
// ## Why this is not in `webview`
//
// The obvious home is `webview/`, next to the code it guards. It cannot go
// there: `v test webview` takes this host down (ROADMAP, measured five times),
// so a test placed there would be a test nobody can run - which is the same
// "passes because its subject is absent" failure `workflow_test.v` refuses. So
// it lives here, beside the other guard over a file this repository ships, and
// reads `webview/` from disk. `buildplan` is pure V and green on Windows, which
// is the only property that makes a guard worth having.
//
// ## What it guards
//
// `webview_dispatch` must not be called from this repository. Two measured
// reasons, and the second is the one that hurts:
//
//  1. It returns a `webview_error_t`, not a bool, with WEBVIEW_ERROR_OK == 0 and
//     success at `>= 0`. The version that shipped did `if
//     (!webview_dispatch(...))`, so the FAILURE branch ran ON SUCCESS: it freed
//     the job the window thread was about to execute and then reported the emit
//     as refused. An inverted check on a zero-is-success API.
//
//  2. With that corrected, it crashed anyway - 0xC0000005, access violation,
//     faulting module `libwebview-0.12.dll`, raised inside the library on the
//     CALLING thread. It needs a COM apartment where it is called, and the only
//     callers here are `spawn`ed workers, which have none. `com_enter` gives an
//     apartment to each window's thread and fixes window CREATION; it says
//     nothing about the caller.
//
// The cross-thread path therefore goes through `post_to_main` (jobs.v), which is
// pure Win32 - a queue plus a PostMessage to a comctl32 subclass - needs no
// apartment from either thread, and is already screenshot-proven (ADR-0019).
//
// ## What it does NOT check
//
// That the cross-thread emit still WORKS. Nothing here can know that; it is an
// end-to-end property, and the run that proves it is `examples/multiwindow` with
// `VAILS_MULTIWINDOW_PROBE=pings`, whose output belongs in
// `tests/e2e_windows/README.md`. This guard only makes sure the two known-broken
// ways back in cannot be reintroduced quietly.
fn test_webview_shim_never_dispatches() {
	shim := os.join_path(repo_root, 'webview', 'webview_shim.h')
	backend := os.join_path(repo_root, 'webview', 'webview_windows.c.v')
	for f in [shim, backend] {
		assert os.exists(f), 'cannot find ' + f + ' - the guard is looking in the ' +
			'wrong place, which would make it pass for the wrong reason'
	}
	assert_forbidden_dispatch(shim)
	assert_forbidden_dispatch(backend)
}

// assert_forbidden_dispatch fails if `file` calls webview_dispatch.
//
// The check is textual on purpose, for the same reason workflow_test.v's is: the
// property IS textual, and a C parser in a test would be a heavier answer than
// the problem. Comment lines are skipped so the header can go on EXPLAINING why
// the call is forbidden without tripping its own guard - which matters here more
// than usual, because the explanation is several paragraphs long and it is the
// first thing a future reader would delete as noise.
fn assert_forbidden_dispatch(file string) {
	lines := os.read_lines(file) or { panic('cannot read ' + file + ': ' + err.msg()) }
	for i, raw in lines {
		line := raw.trim_left(' \t')
		if line.starts_with('//') || line.starts_with('*') || line.starts_with('/*') {
			continue
		}
		// The declaration in the header's own extern block is not a call.
		if line.starts_with('fn C.webview_dispatch') {
			continue
		}
		assert !line.contains('webview_dispatch('), file + ':' + (i + 1).str() +
			' calls webview_dispatch, which cannot work here: it needs a COM ' +
			'apartment on the CALLING thread and every caller in this repository ' +
			'is a spawn()ed worker. Measured as 0xC0000005 inside ' +
			'libwebview-0.12.dll. Use post_to_main instead - see the header.'
	}
}

// The reverse direction, which is the one that actually shipped broken: a check
// for a `!` in front of a webview call. WEBVIEW_ERROR_OK is 0, so `if
// (!webview_...)` is always a bug in this library, and there is no reason for the
// next person to have to rediscover that from a crash dump.
fn test_no_bang_on_a_webview_error_code() {
	backend := os.join_path(repo_root, 'webview', 'webview_windows.c.v')
	lines := os.read_lines(backend) or { panic('cannot read ' + backend + ': ' + err.msg()) }
	for i, raw in lines {
		line := raw.trim_left(' \t')
		if line.starts_with('//') {
			continue
		}
		if !line.contains('webview_') {
			continue
		}
		// `webview_eval` and friends return webview_error_t: compare the result
		// against 0 explicitly. Anything of the form `!something_webview_` is the
		// inverted check this file already shipped once.
		assert !line.starts_with('if (!C.webview'), backend + ':' + (i + 1).str() +
			' negates a webview call. These return webview_error_t, where ' +
			'WEBVIEW_ERROR_OK is 0, so negating the result treats success as ' +
			'failure. Compare against WEBVIEW_ERROR_OK / 0 explicitly.'
	}
}
