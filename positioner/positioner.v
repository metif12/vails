// positioner.v — pure window positioning helpers (W3).
//
// Pure V, no C. Screen dimensions are an INPUT, so centering and clamping
// are testable without a display. The native "get the screen size" call
// lives in the window service; this module only does the arithmetic.
module positioner

// Point is a screen coordinate.
pub struct Point {
pub mut:
	x int
	y int
}

// Size is a width/height pair.
pub struct Size {
pub mut:
	width  int
	height int
}

// center returns the top-left coordinate that centres `win` on a screen of
// `screen` size. Negative or zero inputs are clamped to 0 so a mis-measured
// screen cannot produce a negative origin.
pub fn center(screen Size, win Size) Point {
	sw := if screen.width > 0 { screen.width } else { 0 }
	sh := if screen.height > 0 { screen.height } else { 0 }
	ww := if win.width > 0 { win.width } else { 0 }
	hh := if win.height > 0 { win.height } else { 0 }
	return Point{ x: (sw - ww) / 2, y: (sh - hh) / 2 }
}

// clamp keeps (x, y) so that a window of `win` size stays fully on a screen
// of `screen` size. A window larger than the screen is pinned to (0, 0).
pub fn clamp(screen Size, win Size, p Point) Point {
	mut x := p.x
	mut y := p.y
	mut max_x := screen.width - win.width
	mut max_y := screen.height - win.height
	if max_x < 0 { max_x = 0 }
	if max_y < 0 { max_y = 0 }
	if x < 0 { x = 0 }
	if y < 0 { y = 0 }
	if x > max_x { x = max_x }
	if y > max_y { y = max_y }
	return Point{ x: x, y: y }
}
