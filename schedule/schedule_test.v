module schedule

fn test_in_window_basic() {
	r := Rule{ name: 'work', days: [1, 2, 3, 4, 5], start_hour: 9, start_min: 0, end_hour: 17, end_min: 0, limit: 100, enabled: true }
	assert in_window(r, 1, 9, 0)
	assert in_window(r, 1, 12, 30)
	assert !in_window(r, 1, 8, 59)
	assert !in_window(r, 1, 17, 0)
	assert !in_window(r, 0, 12, 0) // sunday not in days
}

fn test_wrap_midnight() {
	r := Rule{ name: 'night', start_hour: 22, start_min: 0, end_hour: 6, end_min: 0, limit: 50, enabled: true }
	assert in_window(r, 3, 23, 0)
	assert in_window(r, 3, 2, 0)
	assert !in_window(r, 3, 12, 0)
	assert !in_window(r, 3, 6, 0)
}

fn test_disabled_or_zero_limit_inactive() {
	r := Rule{ name: 'off', start_hour: 0, start_min: 0, end_hour: 23, end_min: 59, limit: 0, enabled: true }
	assert !in_window(r, 1, 12, 0)
	r2 := Rule{ name: 'off2', start_hour: 0, start_min: 0, end_hour: 23, end_min: 59, limit: 10, enabled: false }
	assert !in_window(r2, 1, 12, 0)
}

fn test_active_and_most_restrictive() {
	r1 := Rule{ name: 'a', start_hour: 9, start_min: 0, end_hour: 17, end_min: 0, limit: 100, enabled: true }
	r2 := Rule{ name: 'b', start_hour: 12, start_min: 0, end_hour: 13, end_min: 0, limit: 50, enabled: true }
	rules := [r1, r2]
	assert active(rules, 1, 10, 0).len == 1
	assert active(rules, 1, 12, 30).len == 2
	mr := most_restrictive(rules, 1, 12, 30) or { Rule{} }
	assert mr.name == 'b'
	assert mr.limit == 50
	assert most_restrictive(rules, 1, 8, 0) == none
}
