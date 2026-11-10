// windowstate.v — persisting window size and position (W4).
//
// Pure V, no C, no threading. This module owns the DATA: a WindowGeometry
// value and the (de)serialisation that turns it into the durable store's
// string values. The debounce timer and the worker that actually calls
// save() live in the service layer (Phase 6); keeping them out of here is
// what makes the geometry logic unit-testable without a window or a thread.
//
// Storage goes through `store.Store` so the file format, atomic write and
// crash safety are owned in one place.
module windowstate

import store

// WindowGeometry is one window's persisted size and position. Zero values
// mean "not recorded yet", which lets a caller tell "first run" from "the
// user really did put it at (0,0)".
pub struct WindowGeometry {
pub mut:
	width  int
	height int
	x      int
	y      int
	// recorded is false until a real geometry has been saved, so a missing
	// entry and a (0,0,0,0) entry are distinguishable.
	recorded bool
}

const key_width = 'window.width'
const key_height = 'window.height'
const key_x = 'window.x'
const key_y = 'window.y'
const key_recorded = 'window.recorded'

// load reads a geometry from `s`. A store with no entry returns an
// unrecorded geometry rather than an error.
pub fn load(s &store.Store) WindowGeometry {
	mut g := WindowGeometry{}
	if !s.has(key_recorded) {
		return g
	}
	g.recorded = s.get(key_recorded) or { '' } == '1'
	if !g.recorded {
		return g
	}
	g.width = (s.get(key_width) or { '0' }).int()
	g.height = (s.get(key_height) or { '0' }).int()
	g.x = (s.get(key_x) or { '0' }).int()
	g.y = (s.get(key_y) or { '0' }).int()
	return g
}

// save writes `g` into `s`. It does not call s.save(); the caller decides
// when to flush (the debounce timer in the service layer).
pub fn save(mut s store.Store, g WindowGeometry) {
	if !g.recorded {
		return
	}
	s.set(key_width, g.width.str())
	s.set(key_height, g.height.str())
	s.set(key_x, g.x.str())
	s.set(key_y, g.y.str())
	s.set(key_recorded, '1')
}
