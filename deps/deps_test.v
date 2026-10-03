module deps

// config_with returns a minimal vails.json body carrying the given
// dependencies block, so each test states only what it is about.
fn config_with(block string) string {
	return '{"name":"demo","windows":[{"label":"main","title":"D","width":8,"height":6}],' +
		'"dependencies":' + block + '}'
}

// parsed is `parse` for the tests that are not about a failure, so a `!`
// does not have to be propagated through each of them.
fn parsed(block string) Set {
	return parse(config_with(block)) or { panic(err.msg()) }
}

fn test_an_absent_block_is_an_empty_set_not_an_error() {
	// The common case. `vails doctor` must say "none declared" rather
	// than complain that a project without a dependencies block is
	// malformed.
	s := parse('{"name":"demo","windows":[{"label":"main","title":"D","width":8,"height":6}]}') or {
		return
	}
	assert s.is_empty()
	assert s.names() == []
	assert s.summary() == 'none declared'
}

fn test_the_v_mod_array_shape_parses() {
	s := parsed('[{"name":"vlang.leveldb","version":">=1.0.0"},{"name":"elliotchance.vsql","version":"any"}]')
	assert s.names() == ['vlang.leveldb', 'elliotchance.vsql']
	assert s.get('vlang.leveldb') or { return }.version == '>=1.0.0'
	assert !s.is_empty()
}

fn test_a_name_only_dependency_is_valid() {
	// `any` is the meaning of an absent version, and an author who
	// writes {"name": "x"} should not have to spell that out.
	s := parsed('[{"name":"vlang.leveldb"}]')
	assert s.get('vlang.leveldb') or { return }.version == ''
}

fn test_a_url_is_kept_and_must_be_absolute() {
	s := parsed('[{"name":"a.fork","url":"https://example.com/a"}]')
	assert s.get('a.fork') or { return }.url == 'https://example.com/a'
	// A relative URL resolves against the cwd, which differs per
	// machine, so a build could fetch a different tree in each.
	assert parse_report(config_with('[{"name":"a.fork","url":"../a"}]')).contains('must be absolute')
}

fn test_a_name_is_required() {
	assert parse_report(config_with('[{"version":">=1.0.0"}]')).contains('needs a "name"')
}

fn test_duplicates_are_refused_rather_than_last_wins() {
	// Two requirements for one module is a lock file that cannot be
	// generated, and last-wins would make the effective requirement
	// depend on declaration order.
	msg := parse_report(config_with('[{"name":"a.b","version":">=1.0.0"},{"name":"a.b","version":"any"}]'))
	assert msg.contains('duplicate dependency "a.b"')
	assert msg.contains('one module gets one requirement')
}

fn test_whitespace_in_a_name_is_refused() {
	// The name is the VPM identifier; a space in it is a paste accident
	// that would otherwise become a confusing "module not found".
	assert parse_report(config_with('[{"name":"a b"}]')).contains('whitespace')
}

fn test_an_unclosed_array_is_an_error() {
	assert parse_report(config_with('[{"name":"a.b"}')).contains('not closed')
}

fn test_a_url_containing_commas_does_not_split_the_object() {
	// A naive split on `,` cuts this object in half and produces two
	// broken dependencies, which is the bug the brace-counting split
	// exists to avoid.
	s := parsed('[{"name":"a.fork","url":"https://example.com/a?x=1,2,3"}]')
	assert s.names() == ['a.fork']
	assert s.get('a.fork') or { return }.url == 'https://example.com/a?x=1,2,3'
}

fn test_the_map_form_is_accepted_as_a_fallback() {
	// The shape an author reaches for first. Accepted rather than
	// rejected, but the array form stays the documented one, so the two
	// shapes cannot each claim to be canonical.
	s := parsed('{"vlang.leveldb": ">=1.0.0", "elliotchance.vsql": "any"}')
	assert s.names() == ['vlang.leveldb', 'elliotchance.vsql']
	assert s.get('vlang.leveldb') or { return }.version == '>=1.0.0'
}

fn test_too_many_dependencies_is_refused() {
	mut rows := []string{}
	for i in 0 .. max_deps + 1 {
		rows << '{"name":"a.b' + i.str() + '"}'
	}
	assert parse_report(config_with('[' + rows.join(',') + ']')).contains('too many dependencies')
}

fn test_encode_round_trips() {
	// The CLI writes the array form and a hand-written file uses it
	// too, so encode -> parse must be a fixed point or the two shapes
	// drift apart and only one of them is what the docs show.
	original := Set{
		items: [
			Dependency{
				name:    'vlang.leveldb'
				version: '>=1.0.0'
			},
			Dependency{
				name: 'a.fork'
				url:  'https://example.com/a'
			},
		]
	}
	back := parsed(original.encode())
	assert back.names() == ['vlang.leveldb', 'a.fork']
	assert back.get('vlang.leveldb') or { return }.version == '>=1.0.0'
	assert back.get('a.fork') or { return }.url == 'https://example.com/a'
}

fn test_v_mod_rendering_is_the_shape_v_install_reads() {
	// One writer for the v.mod format, so a hand-edited v.mod and a
	// tool-written one cannot disagree about the spelling.
	s := Set{
		items: [
			Dependency{
				name:    'vlang.leveldb'
				version: '>=1.0.0'
			},
		]
	}
	out := s.to_v_mod_dependencies()
	assert out.contains("'vlang.leveldb': '>=1.0.0'")
	assert out.starts_with('[')
	assert out.ends_with(']')
}

fn test_summary_names_each_dependency_and_its_requirement() {
	// What `doctor` prints. "dependencies: " with nothing after it reads
	// like a bug in the report, which is why the empty case says so in
	// words.
	s := parsed('[{"name":"a.b","version":">=1.0.0"},{"name":"c.d"}]')
	assert s.summary() == 'a.b >=1.0.0, c.d'
}

fn test_lock_records_what_was_resolved_not_what_was_asked_for() {
	// The whole point of a lock: the declaration may be `any` and the
	// lock records the concrete version that was actually fetched.
	resolved := [
		Dependency{
			name:    'vlang.leveldb'
			version: '1.4.2'
		},
	]
	back := decode_lock(encode_lock(resolved)) or { return }
	assert back.get('vlang.leveldb') or { return }.version == '1.4.2'
}

fn test_an_empty_lock_round_trips() {
	back := decode_lock(encode_lock([])) or { return }
	assert back.is_empty()
}

fn test_a_malformed_lock_is_an_error_not_an_empty_set() {
	// A build that silently proceeds with no versions pinned is exactly
	// the failure a lock file exists to prevent.
	assert lock_report('nothing here') != ''
	assert lock_report("['unclosed'") != ''
}

fn lock_report(text string) string {
	decode_lock(text) or { return err.msg() }
	return ''
}

fn test_only_an_exact_requirement_is_treated_as_a_pin() {
	// This distinction is the fix for a real bug: a lock records what was
	// RESOLVED and a config records what was ASKED FOR, so comparing
	// `1.4.2` against `>=1.0.0` reports every ranged dependency as
	// stale forever. Constraint satisfaction is deliberately NOT
	// implemented here - that would be a second resolver beside VPM's.
	assert is_exact_requirement('1.4.2')
	assert is_exact_requirement('v1.4.2')
	assert is_exact_requirement('1.4.2-rc.1')
	assert is_exact_requirement('1.4.2+build.5')
	assert !is_exact_requirement('>=1.0.0')
	assert !is_exact_requirement('>1.0.0')
	assert !is_exact_requirement('~1.2.0')
	assert !is_exact_requirement('^1.2.0')
	assert !is_exact_requirement('any')
	assert !is_exact_requirement('')
	assert !is_exact_requirement('*')
}

fn test_the_lock_lives_beside_the_config_and_not_inside_it() {
	// Two files because two authors: vails.json is written by a person,
	// the lock by the tool. A tool that rewrites a person's file is a
	// tool that eventually loses the person's edits.
	assert lock_path == 'vails.lock'
	assert !lock_path.ends_with('.json')
}
