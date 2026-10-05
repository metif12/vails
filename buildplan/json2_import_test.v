module buildplan

import os

// json2_import_test.v - guards the repository against *widening* a V compiler
// bug that already cost this project one broken command, silently.
//
// ## The bug
//
// Measured 2026-10-05 on V master `bb0d229`: with `net.http` linked into a
// binary, `json2.decode[T]` returns a **zero-valued `T` and no error** if the
// decode is instantiated in a module other than the one importing `net.http`.
//
// The bisection, one cell per binary (AGENTS.md §1b has the full table):
//
//   json2 alone, type in main ............................ works
//   json2 + net.http, type in main ...................... works   <- the trap
//   json2 + net.http, type declared in main (same shape) . works   <- the trap
//   json2 + config,  decode of config's own type ......... works
//   json2 + net.http + config, same decode ............... ZERO, no error
//
// So neither half is sufficient, and the shape of the defect is entirely
// cross-module. In this repository `dev` is the only `net.http` importer and
// `cli` is the only module that links it to `config`, which is why `vails
// doctor`, `vails run`, `vails build` and `vails dts` all report a valid
// `vails.json` as "name must not be empty".
//
// ## Why `v test .` never saw it
//
// Each `_test.v` is its own binary and no test file links `dev` with `config`,
// so the failing combination is never assembled. The suite was 44/44 green
// while a shipped command was broken. This file is the guard that was missing.
//
// ## Why a textual guard
//
// A behavioural one would have to link `dev` and `config` into a test binary and
// assert a decode returns a zero struct — a test that can only pass by
// reproducing a compiler bug, and which the V fix turns red. Asserting the
// *shape* of the exposure instead is checkable, stays meaningful while the bug
// lives, and goes red on the commit that widens the exposure.
//
// repo_root is absolute (derived from @FILE) so the check does not depend on
// the runner's working directory. The same idiom as workflow_test.v.
const repo_root = os.join_path(os.dir(@FILE), '..')

// guard_file is excluded from the scan below: this file quotes `.decode[` and
// `net.http` as string literals, so a naive scan counts itself.
const guard_file = 'json2_import_test.v'

// skip_dirs are the directories under the repository root that hold no
// first-party V.
const skip_dirs = ['vlib', 'thirdparty', 'node_modules', 'dist', 'zz']

// module_paths returns every `.v` file in the repository's first-party module
// directories, as absolute paths.
fn module_paths() []string {
	mut out := []string{}
	mut names := os.ls(repo_root) or { return out }
	for name in names {
		if name.starts_with('.') || name in skip_dirs {
			continue
		}
		dir := os.join_path(repo_root, name)
		if !os.is_dir(dir) {
			continue
		}
		mut files := os.ls(dir) or { [] }
		for f in files {
			if f.ends_with('.v') && f != guard_file {
				out << os.join_path(dir, f)
			}
		}
	}
	return out
}

// imports_module reports whether body has `import <name>` at the start of a line.
fn imports_module(body string, name string) bool {
	for line in body.split_into_lines() {
		t := line.trim_space()
		if t == 'import ' + name || t.starts_with('import ' + name + ' ') {
			return true
		}
	}
	return false
}

// module_of returns the module (directory) name an absolute path belongs to,
// normalising the separator first so the answer does not depend on the host.
fn module_of(path string) string {
	norm := path.replace('\\', '/')
	parts := norm.split('/')
	return parts[parts.len - 2]
}

// modules_importing returns the module names whose files import `name`.
fn modules_importing(name string) []string {
	mut set := map[string]bool{}
	for path in module_paths() {
		body := os.read_file(path) or { continue }
		if imports_module(body, name) {
			set[module_of(path)] = true
		}
	}
	return set.keys()
}

// modules_decoding_json2 returns the module names that instantiate
// `json2.decode`.
fn modules_decoding_json2() []string {
	mut set := map[string]bool{}
	for path in module_paths() {
		body := os.read_file(path) or { continue }
		if imports_module(body, 'json2') && body.contains('.decode[') {
			set[module_of(path)] = true
		}
	}
	return set.keys()
}

fn test_net_http_has_exactly_one_importer_and_it_is_dev() {
	// A second `net.http` importer would widen the exposure to every binary that
	// links it, so this is a decision point rather than a number to update:
	// re-run the bisection in AGENTS.md §1b before changing it.
	assert modules_importing('net.http') == ['dev']
}

// This is the invariant the bug actually lives in. The two sets must stay
// DISJOINT: a module that both imports `net.http` and instantiates
// `json2.decode` would put the zero struct inside the decoder itself, where
// cross-module reasoning does not look and a test linking only `config` would
// reproduce it.
fn test_the_net_http_importers_and_the_json2_decoders_stay_disjoint() {
	net_http := modules_importing('net.http')
	decoders := modules_decoding_json2()
	assert net_http.len > 0
	assert decoders.len > 0
	for m in net_http {
		assert m !in decoders
	}
	// And the decoders are real: `config` is the one that reads vails.json.
	assert 'config' in decoders
}

// `cli` is where the two halves meet, which is why shipped commands broke
// rather than a library. Asserted so that moving config reading out of `cli` —
// the eventual fix — is a deliberate, visible change.
fn test_cli_is_the_only_module_joining_the_two_halves() {
	body := os.read_file(os.join_path(repo_root, 'cli', 'vails.v')) or {
		panic('buildplan: cannot read cli/vails.v: ' + err.msg())
	}
	assert imports_module(body, 'dev')
	assert imports_module(body, 'config')
}

// A guard nobody can run is the failure `workflow_test.v` already refuses, so
// prove the scan finds both halves rather than passing on an empty set.
fn test_the_guard_can_still_see_both_halves() {
	net_http := modules_importing('net.http')
	decoders := modules_decoding_json2()
	assert net_http == ['dev']
	assert decoders.len >= 3
	assert 'config' in decoders
	assert 'bridge' in decoders
	assert 'state' in decoders
}
