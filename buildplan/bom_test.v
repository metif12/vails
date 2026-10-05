module buildplan

import os

// bom_test.v — guards every V source file in this repository against a leading
// UTF-8 BOM.
//
// ## Why this guard exists
//
// On 2026-10-05, four V test files written with PowerShell 5.1's
// `Set-Content -Encoding utf8` picked up a BOM, because on 5.1 `utf8` means
// "UTF-8 **with** BOM". That flag is the one AGENTS.md §2a recommends, so the
// documented fix is also the hazard — which is worth knowing before assuming a
// rule and a trap can be kept apart.
//
// ## What V does with it, and why it is worth a guard
//
// The BOM is not silently ignored and it is not cleanly reported. Measured on
// master `bb0d229` with an ordinary three-line `hello.v`:
//
//     hello.v:1:1: notice: script mode started here
//     hello.v:3:4: error: all definitions must occur before code in script mode
//     hello.v:1:1: error: invalid character `﻿`
//
// The file is not a script and `fn main()` is not a definition-after-code. Only
// the LAST message is true. On a larger file the cascade is worse: three
// `script mode started here` notices, three `all definitions must occur before
// code` errors, and a fourth `unexpected token '}'` that is collateral damage
// from a parser that had already lost sync.
//
// So the cost of a BOM here is not "an error" — it is that the first messages
// describe a file that does not exist, and the real one is last. Reported
// upstream as vlang/v#29485; the fix there is one function
// (`read_source_file_raw`, `vlib/v/parser/parser.v`).
//
// ## What this does and does not check
//
// It checks `.v` files, because those are the ones V compiles and the ones the
// cascade makes undiagnosable. A BOM in a `.md` or `.yml` is a cosmetic diff
// nuisance and is deliberately not this guard's business.
//
// `buildplan` is the home rather than `webview`, for the reason
// `workflow_test.v` gives: `v test webview` takes this host down, so a guard
// placed there is a guard nobody can execute.

// repo_root is absolute (derived from @FILE) so the check does not depend on the
// runner's working directory. Declared here rather than reused from
// workflow_test.v: V compiles each `_test.v` in a module as its own unit.
const repo_root = os.join_path(os.dir(@FILE), '..')

// utf8_bom is the three bytes to look for. Named, not inlined, so a reader
// scanning this file for the magic number finds the intent next to it.
const utf8_bom = [u8(0xEF), 0xBB, 0xBF]

// dirs_skipped are the two places a `.v` file under this repository is not
// repository source: git's own object store, and build output. Neither can
// contain a tracked `.v` file, and walking the object store is slow and
// pointless.
const dirs_skipped = ['.git', 'bin']

// v_files collects every `.v` file under the repository.
//
// `os.walk_ext` rather than `os.walk_dir`, and the reason is measured rather
// than stylistic. `walk_dir` needs a callback, and appending to an outer local
// from inside that callback silently loses every append in this V — the closure
// writes to its own copy (AGENTS.md §2c's capture rule) — so `v_files` returned
// an empty list and the guard reported "no BOM anywhere" **while a BOM'd file
// was sitting in the repository**. It was green on a planted canary, which is
// the one state a guard must never be in.
//
// `walk_ext` returns the list, so there is no closure and nothing to capture.
// Its only option is `hidden`, left false so `.git` is not walked.
fn v_files(root string) []string {
	return os.walk_ext(root, '.v', os.WalkParams{})
}

// has_utf8_bom reports whether `data` opens with a UTF-8 BOM.
//
// Reads three bytes rather than the whole file: this is called for every `.v` in
// the repository, and the question is only ever asked of the first three bytes.
fn has_utf8_bom(path string) bool {
	data := os.read_bytes(path) or {
		panic('buildplan: cannot read ${path}: ${err.msg()}')
	}
	if data.len < 3 {
		return false
	}
	return data[0] == utf8_bom[0] && data[1] == utf8_bom[1] && data[2] ==
		utf8_bom[2]
}

fn test_no_v_file_starts_with_a_utf8_bom() {
	files := v_files(repo_root)
	mut bad := []string{}
	for f in files {
		if has_utf8_bom(f) {
			rel := f.replace(repo_root + os.path_separator, '')
			bad << rel
		}
	}
	assert bad.len == 0, 'these .v files start with a UTF-8 BOM (EF BB BF): ' +
		bad.join(', ') + '\n  V will not tell you this is the cause - it reports ' +
		'"script mode started here" and "all definitions must occur before code ' +
		'in script mode" first, and the real "invalid character" error last ' +
		'(vlang/v#29485).\n  On PowerShell 5.1, -Encoding utf8 ADDS a BOM; write ' +
		'with [System.IO.File]::WriteAllText($path, $s, (New-Object ' +
		'System.Text.UTF8Encoding($false))) instead.'
}

// The guard is only worth anything if it can fail, and the only honest way to
// know that is to see it fail on a file that really has a BOM. A test that has
// never been red is a test nobody has checked, and this one guards a property
// that is invisible in every diff, every review, and every `git status`.
//
// It writes a real BOM'd `.v` file into the OS temp directory — never into the
// repository — so the property under test is exercised end to end rather than
// re-implemented here. A re-implementation would be a second thing that can be
// wrong; this way the thing under test is the one the other test uses.
fn test_the_bom_detector_actually_detects_a_bom() {
	dir := os.join_path(os.temp_dir(), 'vails_bom_guard')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	clean := os.join_path(dir, 'clean.v')
	withbom := os.join_path(dir, 'withbom.v')
	os.write_file(clean, 'module main\n')!
	// EFBBBF + the same content. Assembled with `<<` rather than `+` because V
	// does not add two `[]u8`. Writing U+FEFF as text would also produce
	// EF BB BF, but a reader should not have to work that out to trust the
	// fixture.
	mut bommed := utf8_bom.clone()
	bommed << 'module main\n'.bytes()
	os.write_bytes(withbom, bommed)!

	assert !has_utf8_bom(clean), 'the fixture without a BOM was reported as ' +
		'having one, so this guard cannot fail and proves nothing'
	assert has_utf8_bom(withbom), 'the fixture WITH a BOM was not detected, so ' +
		'this guard cannot fail and proves nothing'
}

// A `.v` file shorter than three bytes cannot hold a BOM, and asking anyway
// would be an out-of-bounds read. Worth its own case because the check is a
// `data[0] == … [2]` chain and that is exactly the shape of bug that only
// appears on a truncated file.
fn test_the_bom_detector_handles_a_file_shorter_than_the_bom() {
	dir := os.join_path(os.temp_dir(), 'vails_bom_guard_short')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	tiny := os.join_path(dir, 'tiny.v')
	os.write_file(tiny, '')!
	assert !has_utf8_bom(tiny)
	one := os.join_path(dir, 'one.v')
	os.write_file(one, 'm')!
	assert !has_utf8_bom(one)
	two := os.join_path(dir, 'two.v')
	os.write_file(two, 'mo')!
	assert !has_utf8_bom(two)
}
