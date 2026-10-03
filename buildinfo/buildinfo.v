// buildinfo.v — the app's build identity, stamped in at compile time (B0,
// ADR-0022). Pure-V, no I/O, no C, so it is testable on every platform
// without a compiler — which is the whole reason it is a module and not a
// line inside the CLI.
//
// The problem it exists to solve: an app built with no version reports
// 'dev' forever, and 'dev' silently disables every update check, so a
// shipping release that nobody stamped looks exactly like a development
// build. V 0.5.2 supports both `-d ident=value` and the `$d` read, so
// stamping needs no generated file and no -ldflags.
//
// The identifier is `vails_version` rather than a bare `version` on
// purpose: `-d version=1.0` is a name any dependency could claim, and a
// collide silently hands one library another's constant.
module buildinfo

// ident is the compile-time key `vails build` passes as
// `-d vails_version=<semver>`.
pub const ident = 'vails_version'

// framework_version is the version of the *framework* — the CLI, this
// module, the services catalog — as opposed to the version of an app
// built with it. It is the single source of truth, and `CHANGELOG.md`
// names it as the authority (the CLI's own version, which is this
// constant since B0 moved it here).
//
// It used to live in `cli/vails.v:18` as a private const, which meant two
// editable-by-hand numbers described one thing: `v.mod` said 0.2.0 while
// the CLI said 0.4.0, and both were editable without either noticing.
// Now there is one constant, and `v_mod_version` + a test hold `v.mod`
// to it.
pub const framework_version = '0.4.0'

// v_mod_version extracts the `version:` field from a `v.mod` body. It is
// a hand-rolled scan rather than a TOML parse because `v.mod` is a
// single top-level block of `key: value` lines and V ships no TOML
// reader; the only thing this has to be right about is the one line.
//
// Returns none when the file carries no version, which is a legitimate
// state (an older v.mod) and not an error — the caller decides whether
// drift is a failure.
pub fn v_mod_version(text string) ?string {
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if !line.starts_with('version') {
			continue
		}
		rest := line['version'.len..].trim_space()
		if !rest.starts_with(':') {
			continue
		}
		mut v := rest[1..].trim_space()
		// Strip a trailing comment and the quotes v.mod writes.
		v = v.all_before('#').trim_space()
		if v.len >= 2 && v.starts_with("'") && v.ends_with("'") {
			v = v[1..v.len - 1]
		}
		if v.len >= 2 && v.starts_with('"') && v.ends_with('"') {
			v = v[1..v.len - 1]
		}
		return v
	}
	return none
}

// version_drift reports what is wrong between `v.mod` and the framework
// version, or an empty string when they agree. It returns the message
// rather than an error because both callers — the test and `doctor` —
// want to *show* the difference, and a test that has to parse an error
// string to assert on it is a worse test.
pub fn version_drift(v_mod_text string) string {
	declared := v_mod_version(v_mod_text) or {
		return 'v.mod declares no version; it should be ' + framework_version +
			' (the framework version, which CHANGELOG.md names as the authority)'
	}
	if declared == framework_version {
		return ''
	}
	return 'v.mod says ' + declared + ' but the framework is ' + framework_version +
		' (CHANGELOG.md names the framework version as the authority; ' +
		'v.mod must not be edited by hand)'
}

// dev_version is what an unstamped build reports. It is deliberately a
// value that cannot be mistaken for a release: it is not parseable as
// SemVer, so `is_release` is false and the updater's version comparison
// has nothing valid to compare against.
pub const dev_version = 'dev'

// version returns the version stamped in at compile time, or `dev_version`
// when the build carried none.
//
// The two-argument form of `$d` is the only one that works in V 0.5.2, and
// that is worth writing down rather than rediscovering: the one-argument
// `$d('ident')` — which is what ADR-0022 originally recorded and what the
// docs' phrasing ("`$d()` will return the default value provided as the
// *second* argument") only implies — crashes the parser outright
// (`array.get: index out of range (i,a.len):-1` in `call_args`), with and
// without a matching `-d`. A default is not optional here.
//
// The ident AND the default are both repeated as literals for the same
// class of reason: the compiler rejects `$d(ident, dev_version)` with
// "$d() values can only be pure literals", so a `$d` call can reference
// no constant at all. `ident` is the name the CLI passes on the command
// line and `dev_version` is what this reports without it;
// `test_ident_is_namespaced` and `test_version_matches_dev_marker` are
// what keep the duplicated spellings from drifting.
pub fn version() string {
	return $d('vails_version', 'dev')
}

// is_release reports whether this build carries a real version, i.e.
// whether an update check can compare anything. `doctor` prints this, and
// it is the difference between "a development build" and "a release that
// nobody stamped" — the two look identical to a user and mean opposite
// things to an updater.
pub fn is_release() bool {
	return is_release_version(version())
}

// is_release_version is the testable core: a stamped version is one that
// is not the dev marker. Kept separate so the rule can be asserted
// without compiling a build either way.
pub fn is_release_version(v string) bool {
	return v != '' && v != dev_version
}

// describe is the one-line summary `doctor` prints. It says which of
// the two things is true rather than leaving the reader to infer it: a
// release states its version, an unstamped build states that it is one
// and what to do about it.
pub fn describe() string {
	v := version()
	if !is_release_version(v) {
		return 'unstamped (' + dev_version + ') - built without --version; ' +
			'update checks are disabled for this binary'
	}
	return 'stamped ' + v
}

// validate_version checks a `--version` argument before it is stamped
// into a binary, so a typo becomes an error at the command line rather
// than a permanent string in every shipped copy of the app.
//
// The rules are SemVer 2.0.0's, and they are enforced here rather than
// deferred to the updater because of what a bad value costs: the updater
// *compares* this string, so `1.0` and `1.0.0` are different versions
// and a `v1.2.3-beta` slipping through unvalidated is a precedence bug
// discovered after release. Leading `v` is accepted and stripped, since
// every git tag in this repo's own history carries one and refusing it
// would be pedantry that gets worked around with a second flag.
pub fn validate_version(v string) !string {
	mut s := v.trim_space()
	if s.len >= 2 && (s[0] == `v` || s[0] == `V`) {
		s = s[1..]
	}
	if s == '' {
		return error('--version is empty; pass a SemVer like 1.2.3')
	}
	// Split build metadata off first, then the prerelease, so the
	// numeric core is checked without either suffix in the way. `-` is
	// the separator for prerelease, so it must be found first: a
	// prerelease may legally contain `+`, but the reverse is not true.
	mut core := s
	build := s.all_before('+')
	if s.contains('+') {
		if build == '' {
			return error('--version "' + v + '" has empty build metadata after "+"')
		}
		core = build
	}
	if core.contains('-') {
		pre := core.all_after('-')
		if pre == '' {
			return error('--version "' + v + '" has an empty prerelease after "-"')
		}
		core = core.all_before('-')
	}
	parts := core.split('.')
	if parts.len != 3 {
		return error('--version "' + v + '" is not MAJOR.MINOR.PATCH; ' +
			'the updater compares versions, so 1.0 and 1.0.0 would be ' +
			'different versions')
	}
	for p in parts {
		if p == '' || !is_numeric(p) {
			return error('--version "' + v + '" has a non-numeric component "' +
				p + '"; use digits for MAJOR.MINOR.PATCH')
		}
		// A leading zero in a numeric identifier is invalid SemVer ("01"),
		// and it is the kind of thing that only shows up as a wrong
		// comparison, so it is refused here.
		if p.len > 1 && p[0] == `0` {
			return error('--version "' + v + '" has a leading zero in "' + p +
				'"; SemVer forbids it (01 != 1 for comparison)')
		}
	}
	return s
}

// is_numeric reports whether a string is one or more ASCII digits. V's
// `.is_digit` would also accept Unicode digits, and a version made of
// them sorts wrong against a parsed one.
fn is_numeric(s string) bool {
	if s == '' {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// help is the CLI usage string for the flag, kept next to the code that
// consumes it so the two cannot drift.
pub const help = '--version <semver>   stamp the build (-d ' + ident +
	'=); also the version the updater compares against'
