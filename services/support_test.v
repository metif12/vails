module services

fn test_every_catalog_service_reports_its_backend() {
	// The invariant this file exists for: a service in the catalog must say
	// whether it works here. A service added to the catalog without a
	// `*_support()` fails to compile (supports() calls it), and one that
	// forgets to be listed is caught here.
	names := status_names(supports())
	catalog := manifests().map(it.name)
	assert names == catalog
}

fn test_status_entries_are_well_formed() {
	for s in supports() {
		assert s.name != ''
		// a stub without a reason is useless in a doctor report
		assert s.note != '', s.name + ' must explain itself'
	}
}

fn test_os_info_is_always_ready() {
	// The reference case: no native half, so nothing can be missing.
	s := os_info_support()
	assert s.ready
	assert s.name == 'os_info'
}

fn test_support_matches_the_dispatch_branch() {
	// is_supported() and notification_support() are two answers to the same
	// question; if they ever disagree, one of them is lying to a frontend.
	assert is_supported() == notification_support().ready
	$if windows {
		assert clipboard_support().ready
		assert opener_support().ready
		assert dialog_support().ready
		assert notification_support().ready
	} $else $if linux {
		// clipboard and opener got real backends in wave 2; dialog is still
		// the GTK stub and notification has no backend at all
		assert clipboard_support().ready
		assert opener_support().ready
		assert !dialog_support().ready
		assert !notification_support().ready
	} $else {
		assert !clipboard_support().ready
		assert !opener_support().ready
	}
}

fn test_status_of_resolves_by_name() {
	if s := status_of('clipboard') {
		assert s.name == 'clipboard'
	} else {
		assert false, 'clipboard must have a status'
	}
	// a name that is not a service is reported as such, not guessed
	assert status_of('not_a_service') == none
	assert status_of('nonsense') == none
}

fn test_report_marks_state_before_the_explanation() {
	lines := report([
		ServiceStatus{
			name:  'ready_one'
			ready: true
			note:  'some backend'
		},
		ServiceStatus{
			name:  'stub_one'
			ready: false
			note:  'lands in Phase 5b'
		},
		ServiceStatus{
			name:  'bare'
			ready: true
		},
	])
	assert lines.len == 3
	// both marks are the same width, so the names line up in a terminal
	assert lines[0] == 'ok   ready_one - some backend'
	assert lines[1] == 'stub stub_one - lands in Phase 5b'
	// a note is optional; the state is not
	assert lines[2] == 'ok   bare'
}

fn test_ok_count_summarizes_the_backends() {
	list := [
		ServiceStatus{
			name:  'a'
			ready: true
		},
		ServiceStatus{
			name:  'b'
			ready: false
		},
		ServiceStatus{
			name:  'c'
			ready: true
		},
	]
	assert ok_count(list) == 2
	assert ok_count([]) == 0
}
