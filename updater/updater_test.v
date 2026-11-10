module updater

fn test_parse_version() {
	v := parse_version('1.2.3')!
	assert v.major == 1 && v.minor == 2 && v.patch == 3 && v.pre == ''
	v2 := parse_version('v2.0.0-rc1')!
	assert v2.major == 2 && v2.pre == 'rc1'
	parse_version('1.2') or { assert true; return }
	assert false
}

fn test_compare() {
	a := parse_version('1.0.0')!
	b := parse_version('1.0.1')!
	assert compare(a, b) == -1
	assert compare(b, a) == 1
	assert compare(a, a) == 0
	rc := parse_version('1.0.0-rc1')!
	assert compare(rc, a) == -1
	assert compare(a, rc) == 1
}

fn test_should_update_channel_gating() {
	cur := parse_version('1.0.0')!
	beta_rel := Release{ version: parse_version('1.1.0')!, channel: .beta, url: 'u', sha256: 's' }
	stable_rel := Release{ version: parse_version('1.1.0')!, channel: .stable, url: 'u', sha256: 's' }
	assert should_update(cur, beta_rel, .beta)
	assert !should_update(cur, beta_rel, .stable)
	assert should_update(cur, stable_rel, .stable)
	assert should_update(cur, stable_rel, .beta)
	// older never updates
	old_rel := Release{ version: parse_version('0.9.0')!, channel: .stable, url: 'u', sha256: 's' }
	assert !should_update(cur, old_rel, .stable)
}

fn test_pick_best() {
	cur := parse_version('1.0.0')!
	rels := [
		Release{ version: parse_version('1.0.1')!, channel: .stable, url: 'u1', sha256: 's' },
		Release{ version: parse_version('1.2.0')!, channel: .beta, url: 'u2', sha256: 's' },
		Release{ version: parse_version('1.1.0')!, channel: .stable, url: 'u3', sha256: 's' },
	]
	b := pick_best(cur, rels, .stable) or { Release{} }
	assert b.url == 'u3'
	b2 := pick_best(cur, rels, .beta) or { Release{} }
	assert b2.url == 'u2'
}