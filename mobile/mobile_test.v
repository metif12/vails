module mobile

fn test_is_mobile_matches_target() {
	$if android || ios {
		assert is_mobile()
	} $else {
		assert !is_mobile()
	}
}

fn test_apply_geometry_desktop_noop() {
	$if android || ios {
		mut failed := false
		apply_geometry(800, 600) or { failed = true }
		assert failed
	} $else {
		// Desktop: valid sizes are accepted no-ops.
		apply_geometry(800, 600)!
	}
}

fn test_apply_geometry_rejects_bad_size() {
	mut failed := 0
	apply_geometry(0, 600) or { failed++ }
	apply_geometry(800, -1) or { failed++ }
	assert failed == 2
}
