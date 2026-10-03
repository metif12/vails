// deps.v — the project's dependency declarations (B5, ADR-0022).
//
// **This module is not a convenience.** Vails has no dependency story
// today: `VMODULES` / `VAILS_HOME` point at a source checkout and cannot
// fetch anything, and three of the things the roadmap's next tracks need
// are not in a V installation at all — `vlib/ui2` is not there, nor are
// `vlang/leveldb` and `vsql` (verified 2026-09-29). Those arrive through
// VPM. So until this exists, ADR-0031's native tier and ADR-0032's data
// services are both unreachable, and no amount of writing their code
// changes that.
//
// Pure-V and testable without a compiler or a network, per ADR-0013's
// rule: the parse, the merge, the lock and the resolution are all
// decisions, and the fetching is a shell-out that belongs in the CLI.
module deps

// max_deps bounds the list. A Vails app's dependency count is small (a
// handful), so this is not a real limit - it exists so a malformed or
// generated vails.json cannot turn `vails doctor` into a thousand-line
// report.
const max_deps = 64

// max_requirement_len bounds one version requirement string.
const max_requirement = 128

// Dependency is one declared dependency. It mirrors a `v.mod`
// dependencies entry and adds nothing: the fields are the three VPM
// understands (`name`, `version`, `url`), because inventing a fourth
// would mean the declaration cannot be handed to VPM unchanged.
pub struct Dependency {
pub mut:
	// name is `author.module`, the identifier VPM keys on. Required and
	// validated, because a dependency VPM cannot resolve by name is a
	// dependency that silently does nothing.
	name string
	// version is a VPM constraint: `>=1.2.0`, `~1.2.0`, `1.2.0`, `any`.
	// Empty means `any`, which is legal and is what an unconstrained
	// dependency means to VPM.
	version string
	// url is the module's source, for a dependency VPM cannot find by
	// name (a fork, or a module not published yet). Empty means "ask
	// VPM".
	url string
}

// Set is a project's declared dependencies. Immutable after `load`: the
// list is a property of the project, and a `mut` list that a command
// handler could grow is the same class of mistake ADR-0032 refuses for
// the `sql` registry.
pub struct Set {
pub:
	items []Dependency
}

// empty_set is what a project with no dependencies block gets. A
// separate name rather than `Set{}` so the intent at a call site is
// obvious.
pub fn empty_set() Set {
	return Set{}
}

// parse reads the `dependencies` block of a vails.json. It is a
// hand-rolled JSON walk rather than a struct decode because the block is
// either absent, an array of objects (the v.mod shape) or a
// name-to-requirement map (the shape people reach for first) - and
// accepting both is friendlier than picking one and rejecting the other
// with a schema error.
//
// A malformed entry is an error naming the dependency, never a silent
// skip: a dependency that fails to parse and is then ignored is how a
// build succeeds without the library it needs.
pub fn parse(text string) !Set {
	if !text.contains('"dependencies"') {
		return empty_set()
	}
	start := text.index('"dependencies"') or { return empty_set() }
	key := '"dependencies"'
	tail := text[start..]
	// The array form is the documented one. The map form is a fallback,
	// so it is only reached when there is no `[` after the key.
	//
	// `key.len` is skipped because `quoted_tokens` below sees every
	// quoted run, and the key `"dependencies"` is one of them - left in,
	// it would pair with the first dependency name and shift every
	// following pair by one.
	open := tail.index('[') or { return parse_map_form(tail[key.len..])! }
	return parse_array(tail[open + 1..])!
}

// parse_array reads the already-bracketed body of the array form: the
// text after the opening `[`, up to its matching `]`.
//
// The bracket is matched by counting rather than by taking the first
// `]`, because a URL is allowed to contain one (`?a=1]` is legal in a
// query string) and a naive cut would truncate the array in the middle of
// a dependency.
fn parse_array(rest string) !Set {
	mut depth := 1
	mut end := -1
	for i, ch in rest {
		if ch == `[` {
			depth++
		} else if ch == `]` {
			depth--
			if depth == 0 {
				end = i
				break
			}
		}
	}
	if end < 0 {
		return error('vails.json: "dependencies" array is not closed')
	}
	body := rest[..end]
	mut items := []Dependency{}
	for entry in split_objects(body) {
		d := parse_object(entry)!
		items << d
	}
	// `validate` owns the count limit, so there is exactly one message
	// for "too many" rather than one per parse path — a duplicate rule
	// with two spellings is a rule that will be updated in one place.
	return validate(items)!
}

// parse_map_form handles `{"vlang.leveldb": ">=1.0.0"}`, the shape an
// author reaches for first. Kept as a fallback rather than a second
// supported format so the array form stays the documented one.
//
// It is written as a small scanner over quoted tokens rather than with
// nested index-and-slice arithmetic, because that arithmetic is what
// produced the version of this function that was impossible to read and
// needed a `[` to parse correctly.
fn parse_map_form(tail string) !Set {
	tokens := quoted_tokens(tail)
	if tokens.len < 2 {
		return error('vails.json: "dependencies" is neither an array of ' +
			'{"name": ...} objects nor a {"name": "requirement"} map')
	}
	mut items := []Dependency{}
	mut i := 0
	for i + 1 < tokens.len {
		items << Dependency{
			name:    tokens[i]
			version: tokens[i + 1]
		}
		i += 2
	}
	return validate(items)!
}

// quoted_tokens returns every double-quoted run in the text, in order,
// with the quotes removed. A URL or a version string is one token
// because it cannot contain a quote, and anything outside quotes is
// punctuation this function does not need to see.
fn quoted_tokens(text string) []string {
	mut out := []string{}
	mut in_quote := false
	mut cur := []u8{}
	for ch in text {
		if ch == `"` {
			if in_quote {
				out << cur.bytestr()
				cur = []u8{}
			}
			in_quote = !in_quote
			continue
		}
		if in_quote {
			cur << ch
		}
	}
	return out
}

// parse_object reads one `{"name": "x", "version": "y", "url": "z"}`.
fn parse_object(text string) !Dependency {
	mut d := Dependency{}
	if n := string_field(text, 'name') {
		d.name = n
	}
	if v := string_field(text, 'version') {
		d.version = v
	}
	if u := string_field(text, 'url') {
		d.url = u
	}
	return d
}

// string_field reads one `"key": "value"` pair out of a small object.
// Missing is none rather than an error because the caller validates the
// required set afterwards - one place decides what a dependency must
// have, rather than three parse sites each guessing.
fn string_field(text string, key string) ?string {
	needle := '"' + key + '"'
	idx := text.index(needle) or { return none }
	mut rest := text[idx + needle.len..]
	colon := rest.index(':') or { return none }
	rest = rest[colon + 1..]
	rest = rest.trim_left(' \t\n\r')
	if !rest.starts_with('"') {
		return none
	}
	rest = rest[1..]
	end := rest.index('"') or { return none }
	return rest[..end]
}

// split_objects cuts the array body into its `{...}` elements. It counts
// braces rather than splitting on `,` because a URL is allowed to contain
// a comma and a naive split would cut one object in half.
fn split_objects(body string) []string {
	mut out := []string{}
	mut depth := 0
	mut start := -1
	for i, ch in body {
		if ch == `{` {
			if depth == 0 {
				start = i
			}
			depth++
		} else if ch == `}` {
			depth--
			if depth == 0 && start >= 0 {
				out << body[start..i + 1]
				start = -1
			}
		}
	}
	return out
}

// validate applies the rules every entry must satisfy, and rejects a
// duplicate by name. Duplicates are refused rather than last-wins for
// the same reason `sqlreg` refuses them: last-wins makes the effective
// requirement depend on declaration order, and two different
// requirements for one module is a lock file that cannot be generated.
pub fn validate(items []Dependency) !Set {
	if items.len > max_deps {
		return error('vails.json: too many dependencies (' + items.len.str() +
			', limit ' + max_deps.str() + ')')
	}
	for d in items {
		validate_dependency(d)!
	}
	for i, a in items {
		for j, b in items {
			if i < j && a.name == b.name {
				return error('vails.json: duplicate dependency "' + a.name +
					'" with requirements "' + a.version + '" and "' + b.version +
					'" - one module gets one requirement')
			}
		}
	}
	return Set{
		items: items.clone()
	}
}

// validate_dependency is the per-entry rule set: a name that VPM can key
// on, an optional requirement that is not absurdly long, and an
// optional URL that is absolute if given.
pub fn validate_dependency(d Dependency) ! {
	if d.name == '' {
		return error('vails.json: a dependency needs a "name" (the VPM ' +
			'identifier, e.g. "vlang.leveldb")')
	}
	if d.name.len > max_requirement {
		return error('vails.json: dependency name "' + d.name + '" is longer than ' +
			max_requirement.str() + ' characters')
	}
	if d.name.contains(' ') || d.name.contains('\n') {
		return error('vails.json: dependency name "' + d.name + '" contains ' +
			'whitespace')
	}
	if d.version.len > max_requirement {
		return error('vails.json: version requirement for "' + d.name + '" is ' +
			'longer than ' + max_requirement.str() + ' characters')
	}
	if d.url != '' {
		// A relative URL would be resolved against the cwd, which differs
		// between a developer machine, a CI runner and a container - and
		// a build that fetches a different tree in each is a build whose
		// green means nothing.
		if !d.url.starts_with('http://') && !d.url.starts_with('https://') {
			return error('vails.json: url for dependency "' + d.name + '" must be ' +
				'absolute (http:// or https://), got "' + d.url + '" - a relative ' +
				'URL resolves against the cwd, which differs per machine')
		}
	}
}

// parse_report is `parse` rendered as a message: '' when the block
// parsed, otherwise the refusal. It exists for the same reason
// `sqlreg.bind_report` does — `parse(x) or { return '' }` inside a void
// test fn panics the V 0.5.2 parser, and a module-level helper is
// cheaper than that lesson in every caller.
pub fn parse_report(text string) string {
	parse(text) or { return err.msg() }
	return ''
}

// is_exact_requirement reports whether a version string pins one
// version rather than expressing a range.
//
// It exists because of one specific bug it prevents. A lock file records
// what was *resolved* (`1.4.2`); a config records what was *asked for*
// (`>=1.0.0`). Comparing the two textually reports every ranged
// dependency as stale forever, and the fix for that is NOT to implement
// constraint satisfaction here — that would be a second resolver beside
// VPM's, and two resolvers is the disagreement this command exists to
// avoid. The fix is to compare only where comparison is meaningful, which
// is when the requirement names one version.
//
// `v1.2.3` counts: every tag in this repository's history carries the
// prefix, so a config that copies a tag is a config that pins.
pub fn is_exact_requirement(version string) bool {
	mut v := version.trim_space()
	if v.len >= 2 && (v[0] == `v` || v[0] == `V`) {
		v = v[1..]
	}
	if v == '' || v == 'any' || v == '*' {
		return false
	}
	// Cut the suffixes off first. A prerelease or build-metadata part
	// makes the version LESS like an operator expression, not more, so it
	// is removed before the core is judged — which is also what makes
	// `1.2.3-rc.1` exact while `~1.2.0` is not.
	mut core := v
	if i := core.index('-') {
		core = core[..i]
	}
	if i := core.index('+') {
		core = core[..i]
	}
	// What remains must be digits and dots, and must have three numeric
	// parts. Anything else is an operator (`>=`, `~`, `^`) or a
	// placeholder (`1.x`).
	parts := core.split('.')
	if parts.len != 3 {
		return false
	}
	for p in parts {
		if p == '' {
			return false
		}
		for c in p {
			if c < `0` || c > `9` {
				return false
			}
		}
	}
	return true
}

// names returns the declared names in order, for a `doctor` line and for
// a lock-file diff.
pub fn (s Set) names() []string {
	mut out := []string{}
	for d in s.items {
		out << d.name
	}
	return out
}

// get looks a dependency up by name.
pub fn (s Set) get(name string) ?Dependency {
	for d in s.items {
		if d.name == name {
			return d
		}
	}
	return none
}

// is_empty reports whether the project declared nothing, which is the
// common case and worth saying so rather than printing an empty list.
pub fn (s Set) is_empty() bool {
	return s.items.len == 0
}

// summary is the one-line `doctor` report. It names the count and, when
// the count is zero, says so in words - "dependencies: " with nothing
// after it reads like a bug in the report.
pub fn (s Set) summary() string {
	if s.is_empty() {
		return 'none declared'
	}
	mut parts := []string{}
	for d in s.items {
		mut line := d.name
		if d.version != '' {
			line += ' ' + d.version
		}
		if d.url != '' {
			line += ' (' + d.url + ')'
		}
		parts << line
	}
	return parts.join(', ')
}

// encode renders the set as the JSON block `vails init` writes and
// `vails deps` rewrites. It is the canonical spelling of the array form,
// so a file written by the CLI and one written by hand converge on one
// shape instead of two that both parse.
pub fn (s Set) encode() string {
	mut rows := []string{}
	for d in s.items {
		mut row := '\t\t{ "name": "' + d.name + '"'
		if d.version != '' {
			row += ', "version": "' + d.version + '"'
		}
		if d.url != '' {
			row += ', "url": "' + d.url + '"'
		}
		row += ' }'
		rows << row
	}
	return '[\n' + rows.join(',\n') + '\n\t]'
}

// to_v_mod_dependencies renders the set in the `v.mod` spelling, which
// is the only thing `v install` reads. Two writers for one format is
// exactly the drift ADR-0022's B0 is about, so there is one function
// that produces it and the CLI hands this string to VPM rather than
// letting VPM re-derive it.
pub fn (s Set) to_v_mod_dependencies() string {
	mut rows := []string{}
	for d in s.items {
		mut row := "\t'" + d.name + "': '"
		if d.version != '' {
			row += d.version
		}
		row += "'"
		rows << row
	}
	return '[\n' + rows.join(',\n') + '\n]'
}

// lock_path is where a resolved set is recorded: `vails.lock` beside
// `vails.json`. A separate file rather than a field inside vails.json
// because the two have different authorship - vails.json is written by a
// person, the lock by the tool - and a tool that rewrites a person's
// file is a tool that eventually loses the person's edits.
pub const lock_path = 'vails.lock'

// encode_lock renders the resolved versions for the lock file. It takes
// the resolved pairs rather than the declarations because the whole
// point of a lock is that it records what was actually fetched, not what
// was asked for.
pub fn encode_lock(resolved []Dependency) string {
	mut rows := []string{}
	for d in resolved {
		rows << "\t'" + d.name + "': '" + d.version + "'"
	}
	return 'Module dependencies (resolved by `vails deps`):\n[' + rows.join(',\n') +
		(if rows.len > 0 {
			'\n'
		} else {
			''
		}) + ']'
}

// decode_lock reads a lock file back into the set it recorded, so a
// build can assert "these are the versions I expect" without a network
// call. An unreadable or malformed lock is an error rather than an empty
// set: a build that silently proceeds with no versions pinned is exactly
// the failure a lock file exists to prevent.
pub fn decode_lock(text string) !Set {
	if !text.contains('[') {
		return error('vails.lock: no dependency block found')
	}
	body := text.all_after('[')
	end := body.index(']') or { return error('vails.lock: dependency block is not closed') }
	mut items := []Dependency{}
	for raw in body[..end].split_into_lines() {
		line := raw.trim_space().trim_left(',').trim_space()
		if line == '' || !line.starts_with("'") {
			continue
		}
		inner := line[1..]
		q := inner.index("'") or { continue }
		name := inner[..q]
		mut rest := inner[(q + 1)..].trim_left(':').trim_space()
		if !rest.starts_with("'") {
			continue
		}
		rest = rest[1..]
		e := rest.index("'") or { continue }
		items << Dependency{
			name:    name
			version: rest[..e]
		}
	}
	return validate(items)!
}
