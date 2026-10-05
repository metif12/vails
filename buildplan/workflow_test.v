module buildplan

import os

// workflow_test.v - guards `.github/workflows/ci.yml` against the exact defect
// that shipped on 2026-10-03, when CI reported "No jobs were run" and no red step
// anywhere pointed at the cause.
//
// ## What happened
//
// One step lost its indentation:
//
//     -      - name: v test .        <- what every other step looks like
//     - name: v test .               <- what shipped
//
// At column 0 that line stops being a *step* and becomes a sequence entry in the
// workflow's top-level mapping, which is not a legal YAML document at all. GitHub
// then has no jobs to run, and says so in the least helpful way available: the
// workflow exists, the name looks right, and the run reports that nothing ran.
//
// ## Why a textual check and not a YAML parser
//
// Because the failure IS textual. In this file every YAML list item is nested - a
// step, a matrix entry, a key - so a non-blank, non-comment line at column 0 must
// be one of a handful of known top-level keys. That is a property of the text, it
// holds for every valid version of this file, and checking it needs no parser
// (this repository has no YAML dependency and adding one to a test would be a
// heavier answer than the problem).
//
// The invariant is deliberately STRICTER than "no `- ` at column 0". The broken
// step took its `- name:` out of the job and left its `run:` behind at step-body
// indentation, so a check that only looked for list markers would have seen the
// remaining `run:` lines as legitimately indented and passed. This one asks the
// other question: is this line *allowed* to be at column 0 at all.

// repo_root is absolute (derived from @FILE) so the check does not depend on the
// runner's working directory. The same idiom as buildinfo_test.v.
const repo_root = os.join_path(os.dir(@FILE), '..')

// ci_path is the workflow this module guards.
const ci_path = os.join_path(repo_root, '.github', 'workflows', 'ci.yml')

// top_level_keys are the only keys allowed to sit at column 0. A workflow file's
// top level is a mapping, so this list is short by construction.
const top_level_keys = ['name:', 'on:', 'env:', 'jobs:']

// ci_text reads the workflow, and fails the test rather than skipping when it is
// missing.
//
// The choice is the point. A guard that quietly passes because its subject is
// absent is a guard that reports "CI is fine" for a repository with no CI, which
// is the same class of over-read as a `doctor` line that says ok for something
// that does not work.
fn ci_text() string {
	if !os.exists(ci_path) {
		panic('buildplan: cannot find ' + ci_path + ' - the CI workflow is the ' +
			'subject of these tests, so its absence is a failure and not a skip')
	}
	return os.read_file(ci_path) or {
		panic('buildplan: cannot read ' + ci_path + ': ' + err.msg())
	}
}

// column_zero_offenders returns the lines that are neither blank, nor a comment,
// nor indented - i.e. the ones sitting at column 0 that are not a top-level key.
fn column_zero_offenders(text string) []string {
	mut bad := []string{}
	for line in text.split_into_lines() {
		t := line.trim_space()
		if t == '' || t.starts_with('#') {
			continue
		}
		if line.len > 0 && (line[0] == ` ` || line[0] == `\t`) {
			continue // indented: inside a key, so fine
		}
		mut known := false
		for k in top_level_keys {
			if t.starts_with(k) {
				known = true
			}
		}
		if !known {
			bad << line
		}
	}
	return bad
}

fn test_the_ci_workflow_has_only_nested_list_items() {
	// The regression test for "No jobs were run". See the header for the whole
	// story; the short version is that one step's indentation was lost and the
	// file stopped being a valid workflow.
	bad := column_zero_offenders(ci_text())
	assert bad.len == 0, 'these lines of .github/workflows/ci.yml are at column 0 ' +
		'and are not a known top-level key (' + top_level_keys.join(', ') + '): ' +
		bad.join(' | ') + ' - a list item or key at the top level makes the whole ' +
		'file invalid YAML, and GitHub reports that as "No jobs were run"'
}

fn test_the_ci_workflow_indents_with_spaces_never_tabs() {
	// Next to the defect above, and the classic YAML one: a tab used for
	// indentation is a hard parse error, and the message names neither the line
	// nor the tab. Cheap to check, and it is the failure a future editor is most
	// likely to introduce while fixing the one above.
	mut bad := []string{}
	for line in ci_text().split_into_lines() {
		if line.contains('\t') {
			bad << line
		}
	}
	assert bad.len == 0, 'these lines of .github/workflows/ci.yml contain a TAB: ' +
		bad.join(' | ') + ' - YAML forbids tabs for indentation and the resulting ' +
		'parse error names neither the line nor the tab'
}

// The SECOND cause of "No jobs were run", found 2026-10-05 after the three
// tests above had been green for two days while every run still failed.
//
// This file was invalid YAML for a reason no line-prefix check can see:
//
//     run: "C:\msys64\ucrt64\bin" | Out-File ...
//
// A YAML **double-quoted scalar** processes backslash escapes, and `\m` is not
// one. GitHub rejects the whole file, says "This run likely failed because of a
// workflow file issue", and runs zero jobs in 0s — the same symptom as the
// indentation break, from an unrelated cause. The shell command was fine; the
// YAML quoting around it was not.
//
// So the header's claim that "the failure is textual, so the property is textual
// too" was a FALSE GENERALISATION from one instance. Line position is textual;
// what happens INSIDE a scalar is not, and the second defect lived there.
//
// The fix is a `run: |` block with the path single-quoted, which is also what
// every neighbouring step already does. The check below is still textual and
// still needs no YAML dependency — it just asks the question the first three did
// not: is there a double-quoted scalar here at all?
//
// Scope, stated so it is not over-read: this catches backslashes in double-quoted
// scalars, which is the defect that actually shipped. It is not a YAML parser
// and does not claim to be. A file can still be invalid YAML without tripping it,
// and the honest end state is a real parse in CI - which, as it happens, is the
// first thing the workflow itself would have to survive to reach.
fn test_the_ci_workflow_has_no_backslash_in_a_double_quoted_scalar() {
	mut bad := []string{}
	for i, raw in ci_text().split_into_lines() {
		line := raw.trim_space()
		if line.starts_with('#') {
			continue
		}
		// Only a `key: "value"` position is a YAML scalar. A double quote inside
		// a `run: |` block is shell text - PowerShell string quoting - and
		// backslashes there are exactly what the author meant.
		if !line.contains(': "') {
			continue
		}
		if line.contains('\\') {
			bad << 'line ' + (i + 1).str() + ': ' + line
		}
	}
	assert bad.len == 0, 'these lines of .github/workflows/ci.yml have a ' +
		'backslash inside a DOUBLE-QUOTED YAML scalar: ' + bad.join(' | ') +
		' - YAML interprets \\m and \\u as escape sequences there, so the file ' +
		'does not parse, GitHub rejects it and runs zero jobs in 0s. Use a ' +
		'`run: |` block (backslashes are literal there) or single quotes'
}

fn test_the_ci_workflow_still_declares_every_job() {
	// The same "No jobs were run" symptom, one cause further out: a workflow whose
	// `jobs:` block was emptied, renamed or truncated reports identically to one
	// that failed to parse. This pins the three jobs by name, and `workflow_dispatch`
	// because a run that can only be triggered by a push is not the workflow this
	// repository documents running by hand.
	text := ci_text()
	assert text.contains('workflow_dispatch:'), 'ci.yml should keep ' +
		'workflow_dispatch, so a run can be started by hand'
	mut jobs := []string{}
	for job in ['linux:', 'windows:', 'release:'] {
		assert text.contains(job), 'ci.yml no longer declares the ' + job +
			' job - three jobs are documented in ADR-0022 (B3) and the release job ' +
			'is what the updater consumes (ADR-0020 U6)'
		jobs << job.trim_right(':').trim_space()
	}
	assert jobs.len == 3
}
