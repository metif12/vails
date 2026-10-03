module sqlreg

// err_msg returns the error message of a call that failed, or '' when it
// succeeded.
//
// Written as a generic function taking the value as an argument rather
// than the usual `f() or { return err.msg() }` because that form panics
// the V 0.5.2 parser inside a void test fn (recorded in buildinfo.v,
// where the same compiler bug was found from the other direction).
fn err_msg[T](f fn (T) !, v T) string {
	mut msg := ''
	f(v) or {
		msg = err.msg()
		return msg
	}
	return msg
}

fn registry() !QueryRegistry {
	return new_registry([
		Query{
			name:   'list_notes'
			sql:    'SELECT id, body FROM notes ORDER BY id'
			kind:   .read
			params: .positional
		},
		Query{
			name:     'note_by_id'
			sql:      'SELECT id, body FROM notes WHERE id = :id'
			kind:     .read
			params:   .named
			n_params: 1
		},
		Query{
			name:     'add_note'
			sql:      'INSERT INTO notes (body) VALUES (?)'
			kind:     .write
			params:   .positional
			n_params: 1
		},
	])!
}

// reg is `registry` for the tests that are not themselves about a
// failure, so a `!` does not have to be propagated through them.
fn reg() QueryRegistry {
	return registry() or { panic(err.msg()) }
}

fn test_an_unregistered_name_is_refused_and_names_the_registry() {
	// The error text is the policy. "not found" reads like a typo and
	// sends the next attempt looking for a typo; this one states the rule
	// and lists what IS allowed.
	f := fn (r QueryRegistry) ! {
		r.resolve('drop_everything')!
	}
	msg := err_msg(f, reg())
	assert msg.contains('no query named "drop_everything"')
	assert msg.contains('list_notes')
	assert msg.contains('add_note')
	assert msg.contains('V owns every statement')
}

fn test_sql_text_from_a_page_is_not_a_query_name() {
	// The actual attack: a page sends the statement itself. It is not a
	// registered name, so it never becomes SQL, and the error says why.
	for attempt in ['SELECT * FROM notes', 'DROP TABLE notes; --', '  delete from notes  ',
		'1; DELETE FROM notes'] {
		if q := reg().resolve(attempt) {
			assert false, 'SQL text must never resolve: ' + attempt
		}
	}
}

fn check_statement(text string) string {
	return err_msg(fn (s string) ! { validate_statement(s)! }, text)
}

fn test_multiple_statements_are_refused_even_for_a_registered_name() {
	// ADR-0032's "at an absolute minimum". This is checked at
	// REGISTRATION, not at execution, so a statement that could smuggle
	// a second one is never in the registry at all.
	assert check_statement('SELECT 1; SELECT 2').contains('more than one')
	assert check_statement('SELECT 1;\nDELETE FROM notes').contains('more than one')
	// ...including the trick of hiding it after a comment.
	assert check_statement('SELECT 1 /* ; */ ; DROP TABLE notes').contains('more than one')
	// A trailing semicolon is idiomatic and is allowed.
	assert check_statement('SELECT id FROM notes;') == ''
	assert check_statement('SELECT id FROM notes') == ''
}

fn test_the_semicolon_count_is_conservative_on_purpose() {
	// `'a;b'` counts as two statements and is refused. A false positive
	// costs an author a visible workaround; a false negative is the
	// vulnerability the function exists to prevent.
	quoted := "SELECT * FROM t WHERE body = 'a;b'"
	assert check_statement(quoted).contains('more than one')
}

fn test_an_empty_statement_is_refused() {
	assert check_statement('').contains('must not be empty')
	assert check_statement('   \n\t ').contains('must not be empty')
}

fn test_oversized_statements_are_refused() {
	assert check_statement('SELECT ' + 'x'.repeat(max_sql)).contains('longer than')
}

fn check_name(name string) string {
	return err_msg(fn (s string) ! { validate_name(s)! }, name)
}

fn test_names_are_validated_because_they_reach_error_messages() {
	// A name is author-chosen, so this catches a paste accident - but it
	// also reaches capability grants and error text, and a newline there
	// hides a second line.
	for bad in ['', 'has space', 'has\nnewline', 'semi;colon'] {
		assert check_name(bad) != '', bad
	}
	assert check_name('a'.repeat(max_name + 1)) != ''
	validate_name('list_notes')!
	validate_name('note.by.id')!
	validate_name('q2')!
}

fn test_duplicate_names_are_refused_rather_than_last_wins() {
	// Last-wins would make the effective statement depend on declaration
	// order, and a policy that depends on declaration order is a policy
	// nobody can read off the source.
	dupes := [
		Query{
			name: 'dup'
			sql:  'SELECT 1'
		},
		Query{
			name: 'dup'
			sql:  'SELECT 2'
		},
	]
	msg := err_msg(fn (qs []Query) ! { new_registry(qs)! }, dupes)
	assert msg.contains('duplicate query name "dup"')
}

fn test_a_read_capability_refuses_a_write() {
	// The reason mutability is a property of the query and not of the
	// call site: a page granted "can read" must not reach a write by
	// naming it.
	r := reg()
	assert r.resolve_read('list_notes')!.name == 'list_notes'
	f := fn (rr QueryRegistry) ! { rr.resolve_read('add_note')! }
	msg := err_msg(f, r)
	assert msg.contains('is a write')
	assert msg.contains('grants reads only')
	// The full resolve still allows it - a write capability gets it.
	assert r.resolve('add_note')!.is_write()
}

// bind_err reports what `Query.bind` says about a page's parameters.
// It is a one-line delegation to `sqlreg.bind_report` because a closure
// capturing `q` has to declare it as inherited in V 0.5.2, and the
// module already exports the answer for exactly this reason.
fn bind_err(q Query, params map[string]string) string {
	return bind_report(q, params)
}

fn test_positional_parameters_bind_by_index() {
	q := reg().get('add_note') or { return }
	assert q.bind({
		'0': 'hello'
	})! == ['hello']
	// Wrong count is a named error, not a driver surprise.
	assert bind_err(q, {}) != ''
	assert bind_err(q, {
		'0': 'a'
		'1': 'b'
	}) != ''
	// A missing index is distinct from a wrong count.
	assert bind_err(q, {
		'1': 'a'
	}) != ''
}

fn test_named_parameters_must_actually_exist_in_the_statement() {
	// Without this a page can send an extra key that today's driver
	// ignores and a different driver applies - a bug that only shows up
	// after a dependency upgrade.
	//
	// The shape that matters is a count that MATCHES but a key that is
	// not a placeholder, because that is the one the count check cannot
	// catch: the page sends two values for a two-placeholder statement,
	// one of which is named something the statement never mentions.
	two := new_registry([Query{
		name:     'search'
		sql:      'SELECT id FROM notes WHERE body LIKE :body AND tag = :tag'
		kind:     .read
		params:   .named
		n_params: 2
	}]) or { return }
	q := two.get('search') or { return }
	// The legitimate call binds.
	assert q.bind({
		'body': '%x%'
		'tag':  'a'
	})!.len == 2
	// The count is right, the name is not.
	assert bind_err(q, {
		'body': '%x%'
		'evil': '1'
	}).contains('no placeholder named "evil"')
	// And the simple one-placeholder case still binds by name.
	one := reg().get('note_by_id') or { return }
	assert one.bind({
		'id': '7'
	})! == ['7']
}

fn test_parameter_values_are_bounded() {
	// A bound on the statement is not a bound on the value: a page can
	// still make the process allocate a gigabyte through a legal query.
	q := reg().get('add_note') or { return }
	ok := 'x'.repeat(max_param)
	assert q.bind({
		'0': ok
	})! == [ok]
	assert bind_err(q, {
		'0': 'x'.repeat(max_param + 1)
	}).contains('over the')
}

fn test_the_registry_is_a_value_and_cannot_be_grown_at_runtime() {
	// The threat model in one test: the statement set is fixed by the
	// author at startup, so there is deliberately no `register` entry
	// point for a page to reach. If a mutating API is ever added here,
	// this is the place to make the addition argue for itself.
	r := reg()
	r2 := r
	assert r2.names().len == 3
	assert r.names() == ['list_notes', 'note_by_id', 'add_note']
}

fn test_summary_counts_both_mutabilities() {
	// `doctor` needs "3 queries (2 read, 1 write)", and just as usefully
	// "0 queries" for a service that is granted but empty.
	assert reg().summary() == '3 queries (2 read, 1 write)'
	empty := new_registry([]) or { return }
	assert empty.summary() == '0 queries (0 read, 0 write)'
	one := new_registry([Query{
		name: 'only'
		sql:  'SELECT 1'
	}]) or { return }
	assert one.summary() == '1 query (1 read, 0 write)'
}
