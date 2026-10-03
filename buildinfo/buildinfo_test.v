module buildinfo

import os

// repo_root is absolute (derived from @FILE) so the drift test does not
// depend on the runner's working directory.
const repo_root = os.join_path(os.dir(@FILE), '..')

fn v_mod_text() string {
	path := os.join_path(repo_root, 'v.mod')
	if !os.exists(path) {
		eprintln('cannot find v.mod next to buildinfo/')
		return ''
	}
	return os.read_file(path) or { '' }
}

fn version_or(text string, fallback string) string {
	if v := v_mod_version(text) {
		return v
	}
	return fallback
}

fn test_unstamped_build_reports_dev() {
	// This test binary is compiled without -d, so it IS the unstamped
	// case the doctor warning is about. That is the whole reason the
	// assertion lives in a test rather than in a comment.
	assert version() == dev_version
	assert !is_release()
	assert !is_release_version('')
	assert !is_release_version('dev')
	assert is_release_version('1.0.0')
	assert is_release_version('2.0.0-rc.1')
}

fn test_describe_names_the_problem_not_just_the_value() {
	// 'dev' on its own reads like a version number. describe() must say
	// what is wrong and what to do about it.
	d := describe()
	assert d.contains('unstamped')
	assert d.contains('--version')
}

fn test_v_mod_version_parses_the_forms_vmod_writes() {
	assert version_or("Module {\n\tname: 'vails'\n\tversion: '0.4.0'\n}",
		'<none>') == '0.4.0'
	assert version_or('version: "1.2.3"', '<none>') == '1.2.3'
	assert version_or("version: '1.2.3'  # trailing comment", '<none>') == '1.2.3'
	assert v_mod_version("Module {\n\tname: 'x'\n}") == none
	// A key that merely starts with the same letters is not the field:
	// reading `versions:` as `version` is how a build ends up stamping
	// the wrong number.
	assert v_mod_version("min_version: '9.9.9'") == none
	assert v_mod_version("versions: '9.9.9'") == none
}

fn test_version_drift_is_silent_when_agrees() {
	assert version_drift("Module {\n\tversion: '" + framework_version +
		"'\n}") == ''
}

fn test_version_drift_names_both_numbers() {
	msg := version_drift("Module {\n\tversion: '0.2.0'\n}")
	assert msg.contains('0.2.0')
	assert msg.contains(framework_version)
}

fn test_version_drift_reports_a_missing_version() {
	assert version_drift("Module {\n\tname: 'x'\n}").contains('no version')
}

fn test_repo_v_mod_agrees_with_the_framework_version() {
	// The drift this catches is real and pre-existing: v.mod said 0.2.0
	// while the CLI said 0.4.0, and both were editable by hand. This is
	// the assertion that stops it happening twice.
	drift := version_drift(v_mod_text())
	assert drift == '', drift
}

fn test_ident_is_namespaced() {
	// `-d version=1.0` is a name any dependency could claim; a collide
	// silently hands one library another's constant.
	assert ident == 'vails_version'
	assert ident.contains('_')
}

fn test_version_matches_dev_marker_and_ident() {
	// `version()` repeats both of these as literals because `$d` accepts
	// no constant arguments at all, so this test is what stops the
	// duplicated spellings from drifting apart.
	assert version() == dev_version
	// The literal inside $d must be the same key the CLI passes on the
	// command line, or every build stamps a value nothing reads.
	assert version() != ident
}

fn test_validate_version_accepts_semver() {
	assert validate_version('1.0.0')! == '1.0.0'
	assert validate_version('0.4.0')! == '0.4.0'
	assert validate_version('10.20.30')! == '10.20.30'
	assert validate_version('1.2.3-beta.1')! == '1.2.3-beta.1'
	assert validate_version('1.2.3+build.5')! == '1.2.3+build.5'
	// A git tag carries a leading v; refusing it would just be pedantry
	// that gets worked around with a second flag.
	assert validate_version('v1.2.3')! == '1.2.3'
	assert validate_version(' 1.2.3 ')! == '1.2.3'
}

fn test_validate_version_rejects_shapes_that_break_comparison() {
	// Each of these is a *different version* to the updater, which is why
	// they are refused at the command line instead of after release.
	assert validate_version('1.0') or { return } != ''
	assert validate_version('1') or { return } != ''
	assert validate_version('1.2.3.4') or { return } != ''
	assert validate_version('') or { return } != ''
	assert validate_version('v') or { return } != ''
	assert validate_version('a.b.c') or { return } != ''
	assert validate_version('1.x.0') or { return } != ''
	assert validate_version('1.2.') or { return } != ''
	assert validate_version('..') or { return } != ''
	// A leading zero in a numeric component is invalid SemVer and is the
	// kind of thing that only shows up as a wrong comparison later.
	assert validate_version('01.2.3') or { return } != ''
	assert validate_version('1.02.3') or { return } != ''
	// A prerelease is allowed to contain dots (1.2.3-beta.1), so the
	// multi-dot case is only an error BEFORE the '-' is seen.
	assert validate_version('1.2.3-beta.1+build.9')! == '1.2.3-beta.1+build.9'
	// An empty suffix after the separator is a typo, not a version.
	assert validate_version('1.2.3-') or { return } != ''
	assert validate_version('1.2.3+') or { return } != ''
}

fn test_validate_version_error_names_the_value_and_the_rule() {
	// The error is part of the contract: an argument a user typed has to
	// come back naming what they typed and the rule they missed, or the
	// next attempt at the same typo is a guess.
	mut msg := ''
	if res := validate_version('1.0') {
		msg = 'expected a rejection, got ' + res
	} else {
		msg = err.msg()
	}
	assert msg.contains('1.0'), msg
	assert msg.contains('MAJOR.MINOR.PATCH'), msg
}
