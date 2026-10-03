// sqlreg.v ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â the `sql` service's security policy as pure V (D0, ADR-0032).
//
// **The decision this module encodes: the `sql` service never takes SQL
// text from a page.** A frontend names a query; V owns the statement.
//
// That is not a style preference. A `sql` command that accepts a query
// string is remote code execution the moment the app loads remote
// content, and "the page asked nicely" is not a security model. It is the
// same argument that gave `opener` a scheme allowlist (ADR-0015) and put
// scoped `fs` last and riskiest, and it is the reason this module exists
// as code rather than as a line in an ADR: a policy that is only prose
// gets quietly widened the first time a feature needs an exception, and
// the exception is one line.
//
// The module has no database behind it and no I/O. D0 is the policy, so
// that D3 (the `vsql` service itself) cannot be written against a
// different model by accident ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â the ADR says an implementation written
// against the wrong security model is expensive to fix after the fact,
// and the way to make that impossible is to make the right model the one
// the tests exercise.
module sqlreg

// max_name bounds a query name. Names are identifiers an app author
// chooses, not user input, so this is generous; the point is that the
// error for a pathological name is a name error and not a stack trace
// from the database driver.
const max_name = 64

// max_sql bounds a statement. A few hundred KB is far above any real
// query and far below anything that should be in a source file.
const max_sql = 64 * 1024

// max_params bounds a single named placeholder's value. The reason a
// *value* gets a bound at all is that a page can supply one: bound
// parameters, not just bound statement text, or a page can still make
// the process allocate a gigabyte.
const max_param = 16 * 1024

// Kind classifies what a registered query is allowed to do, because the
// two are not equally safe to expose to a page.
pub enum Kind {
	// read returns rows and cannot change the database. This is the only
	// kind a page may run on a capability that is merely "can read".
	read
	// write changes the database. It is registrable because a real app
	// needs it, and separately grantable because "the page may read" and
	// "the page may write" are different permissions and conflating them
	// is how a read-only grant becomes data loss.
	write
}

// ParamStyle says how a statement takes its values. It is part of the
// registered query rather than a runtime choice because the *choice* is
// the security-relevant part: positional `?` binds by position, and
// named `:x` binds by name. Accepting both and picking at runtime would
// mean a statement written for one silently running under the other's
// rules.
pub enum ParamStyle {
	positional
	named
}

// Query is one registered statement: the name a page may use, the SQL V
// owns, and the two properties that decide what a page may do with it.
pub struct Query {
pub:
	name   string
	sql    string
	kind   Kind
	params ParamStyle
	// n_params is how many placeholders the statement expects. Checked
	// against what the page sent, so a mismatch is a named error instead
	// of a driver-level surprise three layers down.
	n_params int
}

// mutability is the word used in the error messages and in the
// capability discussion: a read is a `sql.read` grant, a write is
// `sql.write`. Two names because one grant would have to be the union.
pub fn (q Query) mutability() string {
	return if q.kind == .write {
		'write'
	} else {
		'read'
	}
}

// is_write is the predicate the capability check uses.
pub fn (q Query) is_write() bool {
	return q.kind == .write
}

// Registry is the V-side map from names to statements. It is immutable
// after construction on purpose: the whole threat model is that the set
// of statements is fixed by the app author at startup and nothing a page
// sends can add to it. A `mut` registry with a `register` command exposed
// to a page would be the vulnerability, so there is no mutating entry
// point here at all ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â `QueryRegistry` values are built once and handed
// around as values.
pub struct QueryRegistry {
pub:
	queries []Query
}

// new_registry builds a registry from a list of queries, refusing a
// duplicate name. The duplicate is refused rather than resolved
// last-wins because last-wins makes the *effective* statement depend on
// declaration order, and a security policy that depends on declaration
// order is a policy nobody can read off the source.
pub fn new_registry(queries []Query) !QueryRegistry {
	for q in queries {
		validate_name(q.name)!
		validate_statement(q.sql)!
		if q.n_params < 0 {
			return error('sql: query "' + q.name + '" declares a negative parameter count')
		}
	}
	for i, a in queries {
		for j, b in queries {
			if i < j && a.name == b.name {
				return error('sql: duplicate query name "' + a.name +
					'" (names must be unique so the effective statement does not ' +
					'depend on declaration order)')
			}
		}
	}
	return QueryRegistry{
		queries: queries.clone()
	}
}

// names returns the registered names in declaration order, for an error
// message and for `doctor`. Sorted rather than declaration-ordered would
// be tidier, but declaration order matches the source and an error that
// quotes the source is more useful than one that is alphabetical.
pub fn (r QueryRegistry) names() []string {
	mut out := []string{}
	for q in r.queries {
		out << q.name
	}
	return out
}

// get looks a query up by name.
pub fn (r QueryRegistry) get(name string) ?Query {
	for q in r.queries {
		if q.name == name {
			return q
		}
	}
	return none
}

// resolve is the whole security surface: name in, statement out, and an
// error for anything that is not a registered name. It is the function
// a future `sql.exec` calls and the one an attacker has to get past.
//
// The error deliberately names the registry rather than saying "not
// found": a page that asks for `DROP TABLE` should learn that the name is
// not registered and what is, because an error that says "unknown query"
// reads like a typo and sends the next attempt looking for a typo.
pub fn (r QueryRegistry) resolve(name string) !Query {
	q := r.get(name) or {
		return error('sql: no query named "' + name + '" is registered. ' +
			'Registered names: ' + r.names().join(', ') +
			'. A page cannot send SQL text; V owns every statement.')
	}
	return q
}

// resolve_read is `resolve` plus the read-only check, for a capability
// that grants reading only. It exists as a separate function rather than
// a flag on `resolve` so a caller cannot forget the check: the safe
// thing and the explicit thing are the same call.
pub fn (r QueryRegistry) resolve_read(name string) !Query {
	q := r.resolve(name)!
	if q.is_write() {
		return error('sql: query "' + name + '" is a write and this capability ' +
			'grants reads only')
	}
	return q
}

// bind checks the parameter values a page supplied against the
// statement's declared style and count, and returns them in the order
// the driver will consume them.
//
// Three separate refusals, because each is a different mistake: too many
// values is a bug, too few is a bug, and a wrong style is a page using
// named parameters against a positional statement (or the reverse), which
// would otherwise bind position 0 to the wrong placeholder.
pub fn (q Query) bind(params map[string]string) ![]string {
	mut ordered := []string{}
	if q.params == .positional {
		if params.len != q.n_params {
			return error('sql: query "' + q.name + '" takes ' +
				q.n_params.str() + ' parameter(s) but ' + params.len.str() +
				' were supplied')
		}
		for i in 0 .. q.n_params {
			key := i.str()
			v := params[key] or {
				return error('sql: query "' + q.name + '" is missing parameter ' +
					key)
			}
			ordered << check_param(q.name, v)!
		}
		return ordered
	}
	if params.len != q.n_params {
		return error('sql: query "' + q.name + '" takes ' + q.n_params.str() +
			' named parameter(s) but ' + params.len.str() + ' were supplied')
	}
	for key, raw in params {
		// A named placeholder must actually exist in the statement.
		// Without this a page can send an extra key that a driver
		// ignores today and a different driver applies later.
		if !q.sql.contains(':' + key) {
			return error('sql: query "' + q.name + '" has no placeholder named "' +
				key + '"')
		}
		ordered << check_param(q.name, raw)!
	}
	return ordered
}

// bind_report is `bind` rendered as a message: '' when the parameters
// bound cleanly, otherwise the refusal. It exists because "did it bind,
// and if not, why" is a question callers ask in a `match` arm, and
// writing that with `bind(...) or { err.msg() }` inside a closure is a
// V 0.5.2 parser trap (a captured variable in a closure has to be
// listed as inherited, and the `or` form panics). One function here is
// cheaper than that lesson in every test.
pub fn bind_report(q Query, params map[string]string) string {
	q.bind(params) or { return err.msg() }
	return ''
}

// bind_ok is the boolean half of `bind_report`, for a caller that only
// wants to know whether the parameters were acceptable.
pub fn bind_ok(q Query, params map[string]string) bool {
	q.bind(params) or { return false }
	return true
}

// check_param is the one bound on a value, kept separate so both bind
// paths apply it identically.
fn check_param(name string, v string) !string {
	if v.len > max_param {
		return error('sql: parameter for "' + name + '" is ' + v.len.str() +
			' bytes, over the ' + max_param.str() + '-byte limit')
	}
	return v
}

// validate_name is the shape rule for a name. Names are author-chosen, so
// this is about catching a paste accident rather than an attack ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â but it
// has to exist, because a name is also what appears in an error message
// and in a capability grant, and an unvalidated string in both is a
// place for a newline to hide a second line.
pub fn validate_name(name string) ! {
	if name == '' {
		return error('sql: a query name must not be empty')
	}
	if name.len > max_name {
		return error('sql: query name is longer than ' + max_name.str() +
			' characters')
	}
	for c in name {
		ok := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
			|| (c >= `0` && c <= `9`) || c == `_` || c == `.`
		if !ok {
			return error('sql: query name "' + name + '" may only use letters, ' +
				'digits, "_" and "." (it appears in capability grants and error ' +
				'messages)')
		}
	}
}

// validate_statement refuses multiple statements and refuses a
// statement with no content. This is the "at an absolute minimum" clause
// of ADR-0032 and it is the reason the function is called during
// registry construction rather than at execution: a statement that got
// past registration is a statement a page can only reach by name, and a
// statement that could smuggle a second one should never have been
// registered at all.
//
// The parameter is `text` rather than `sql` because `sql` is a V keyword
// (it starts `$sql` compile-time queries) and naming a parameter after
// it is a parse error rather than a shadowing warning.
//
// Counting is deliberately conservative ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â a `;` inside a string literal
// is counted as a terminator, so `'a;b'` is refused. A false positive
// costs an author a workaround they can see immediately; a false
// negative here is the vulnerability.
pub fn validate_statement(text string) ! {
	s := text.trim_space()
	if s == '' {
		return error('sql: a statement must not be empty')
	}
	if s.len > max_sql {
		return error('sql: statement is longer than ' + max_sql.str() + ' bytes')
	}
	// A trailing semicolon is idiomatic and harmless, so it is allowed ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â
	// but only at the very end. `SELECT 1; SELECT 2` has an interior one.
	trimmed := s.trim_right(';').trim_space()
	if !trimmed.contains(';') {
		return
	}
	return error('sql: a registered statement may not contain more than one ' +
		'statement (found an interior ";") - sql refuses multiple statements ' +
		'even for a registered name')
}

// summary describes the registry for `doctor` and for a startup log: how
// many queries, how many of each mutability. A service that is granted
// but has no queries registered is worth naming, because a page calling
// it gets an error that reads like a typo.
pub fn (r QueryRegistry) summary() string {
	mut reads := 0
	mut writes := 0
	for q in r.queries {
		if q.is_write() {
			writes++
		} else {
			reads++
		}
	}
	return r.queries.len.str() + ' quer' + (if r.queries.len == 1 {
		'y'
	} else {
		'ies'
	}) + ' (' + reads.str() + ' read, ' + writes.str() + ' write)'
}
