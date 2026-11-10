module windowstate

import store
import os

fn tmp_path(name string) string {
	return os.join_path(os.vtmp_dir(), 'vails_ws_' + name + '.json')
}

fn test_load_missing_is_unrecorded() {
	p := tmp_path('missing')
	os.rm(p) or {}
	s := store.open(p)!
	g := load(&s)
	assert !g.recorded
	assert g.width == 0
}

fn test_save_load_roundtrip() {
	p := tmp_path('roundtrip')
	os.rm(p) or {}
	mut s := store.open(p)!
	g := WindowGeometry{ width: 800, height: 600, x: 10, y: 20, recorded: true }
	save(mut s, g)
	s.save()!
	s2 := store.open(p)!
	g2 := load(&s2)
	assert g2.recorded
	assert g2.width == 800
	assert g2.height == 600
	assert g2.x == 10
	assert g2.y == 20
}

fn test_unrecorded_does_not_write() {
	p := tmp_path('unrec')
	os.rm(p) or {}
	mut s := store.open(p)!
	save(mut s, WindowGeometry{})
	assert s.len() == 0
}