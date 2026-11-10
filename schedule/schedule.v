// schedule.v — a pure evaluator for time-based rules (Phase 7 scheduler).
//
// Pure V, no C, no clock. The clock is an INPUT: a caller reads the real
// time and hands (day, hour, minute) in, which is what makes every rule
// testable against a table of times without a fake clock or a sleep.
//
// A Rule is a day window plus an action value (here a byte rate limit;
// 0 means "no limit / inactive"). Multiple rules may be active at once;
// the caller decides which one wins (typically the most restrictive).
module schedule

// Rule describes one time window in which an action applies.
pub struct Rule {
pub mut:
	name       string
	days       []int // 0 = Sunday .. 6 = Saturday; empty means every day
	start_hour int
	start_min  int
	end_hour   int
	end_min    int
	limit      int // action value; 0 means inactive/disabled
	enabled    bool = true
}

// minutes_of converts an hour/minute pair into minutes since midnight.
fn minutes_of(hour int, minute int) int {
	return hour * 60 + minute
}

// in_days reports whether `day` is covered by `r.days` (empty = every day).
fn in_days(r Rule, day int) bool {
	if r.days.len == 0 {
		return true
	}
	for d in r.days {
		if d == day {
			return true
		}
	}
	return false
}

// in_window reports whether (day, hour, minute) falls inside r's window.
// Windows that cross midnight (start > end) are supported.
pub fn in_window(r Rule, day int, hour int, minute int) bool {
	if !r.enabled || r.limit <= 0 {
		return false
	}
	if !in_days(r, day) {
		return false
	}
	now := minutes_of(hour, minute)
	start := minutes_of(r.start_hour, r.start_min)
	end := minutes_of(r.end_hour, r.end_min)
	if start <= end {
		return now >= start && now < end
	}
	// wraps past midnight
	return now >= start || now < end
}

// active returns the rules that apply at (day, hour, minute), in input order.
pub fn active(rules []Rule, day int, hour int, minute int) []Rule {
	mut out := []Rule{}
	for r in rules {
		if in_window(r, day, hour, minute) {
			out << r
		}
	}
	return out
}

// most_restrictive returns the active rule with the smallest non-zero limit,
// or none if no rule is active.
pub fn most_restrictive(rules []Rule, day int, hour int, minute int) ?Rule {
	act := active(rules, day, hour, minute)
	if act.len == 0 {
		return none
	}
	mut best := act[0]
	for r in act {
		if r.limit > 0 && r.limit < best.limit {
			best = r
		}
	}
	return best
}
