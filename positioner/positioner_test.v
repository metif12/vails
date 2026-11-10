module positioner

fn test_center() {
	s := Size{ width: 1920, height: 1080 }
	w := Size{ width: 800, height: 600 }
	p := center(s, w)
	assert p.x == 560
	assert p.y == 240
}

fn test_center_clamps_bad_inputs() {
	p := center(Size{ width: 0, height: 0 }, Size{ width: 100, height: 100 })
	assert p.x == -50
	assert p.y == -50
}

fn test_clamp() {
	s := Size{ width: 1920, height: 1080 }
	w := Size{ width: 800, height: 600 }
	// off-screen top-left gets pinned
	assert clamp(s, w, Point{ x: -10, y: -5 }) == Point{ x: 0, y: 0 }
	// too far bottom-right gets clamped to max
	assert clamp(s, w, Point{ x: 2000, y: 2000 }) == Point{ x: 1120, y: 480 }
	// in-bounds stays
	assert clamp(s, w, Point{ x: 100, y: 200 }) == Point{ x: 100, y: 200 }
}

fn test_clamp_oversized_window() {
	s := Size{ width: 800, height: 600 }
	w := Size{ width: 1000, height: 900 }
	assert clamp(s, w, Point{ x: 50, y: 50 }) == Point{ x: 0, y: 0 }
}