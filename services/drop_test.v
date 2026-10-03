module services

import json2
import webview

// Everything below is pure V, which is the point of where the policy was put: a
// drop's *decision* (is this message ours, what survives the bounds, what does
// the page get) is testable on any platform with no window, no human and no
// mouse. Only the four shell calls in drop_windows.c.v are not, and they are four
// calls with no policy in them at all.

// drop_event builds the window message the seam would hand the handler.
fn drop_event(msg i64) webview.HostEvent {
	return webview.HostEvent{
		msg: msg
	}
}

fn test_only_wm_dropfiles_is_a_drop() {
	// The mistake this pins: treating "a window message" as "our message". 0x0233
	// is a real message any window procedure can see, so a handler that reads
	// lParam as an HDROP without asking first hands the shell API a pointer to
	// whatever that message's lParam happened to contain.
	assert is_drop_message(drop_event(wm_dropfiles))
	// The seam's own message (the tray's clicks) and the job wakeup are the two
	// ids that DO travel on this same chain, so they are the realistic
	// confusions rather than an invented one.
	assert !is_drop_message(drop_event(webview.host_message))
	assert !is_drop_message(drop_event(webview.wakeup_message))
	// WM_COMMAND is the window menu bar's, on the same window (ADR-0023).
	assert !is_drop_message(drop_event(0x0111))
	assert !is_drop_message(drop_event(0))
}

fn test_decide_passes_on_every_message_that_is_not_a_drop() {
	// The chaining contract (ADR-0023): the menu bar installs its own hook on the
	// same window and depends on this one staying out of the way. A drop handler
	// that consumed WM_COMMAND would open something on every menu click.
	assert decide_drop(drop_event(webview.host_message), 3) == .pass_on
	assert decide_drop(drop_event(0x0111), 3) == .pass_on
	assert decide_drop(drop_event(wm_dropfiles + 1), 3) == .pass_on
}

fn test_decide_emits_even_when_the_drop_carried_nothing_usable() {
	// The rule, and the reason it is a rule: the user did something. Silence
	// reads as a bug - the page waits for an event this service decided not to
	// send - so a drop with nothing readable in it is reported with zero paths and
	// the page can say "nothing usable was dropped".
	//
	// The two failures this avoids are the pair the tray service had to learn
	// about separately: a swallowed event, and a phantom one.
	assert decide_drop(drop_event(wm_dropfiles), 0) == .emit_files
	assert decide_drop(drop_event(wm_dropfiles), 1) == .emit_files
	assert decide_drop(drop_event(wm_dropfiles), 12) == .emit_files
}

fn test_paths_are_kept_in_the_order_the_shell_gave_them() {
	// Order is the contract: a drop of a.png, b.png, c.png reported as c, b, a is
	// a service that reorders the user's selection, and a frontend that assumed
	// top-most-first would open the wrong file.
	got := validate_dropped_paths(['C:\\a.png', 'C:\\b.png', 'C:\\c.png'])
	assert got == ['C:\\a.png', 'C:\\b.png', 'C:\\c.png']
}

fn test_an_empty_path_is_dropped() {
	// DragQueryFileW returns 0 for a format it cannot express as a name - a
	// dropped shortcut, a virtual item - and a JSON array carrying "" is worse
	// than one that omits the item: a frontend would offer the user a file called
	// nothing.
	got := validate_dropped_paths(['C:\\real.txt', '', 'C:\\also-real.txt'])
	assert got == ['C:\\real.txt', 'C:\\also-real.txt']
}

fn test_a_path_with_a_nul_is_dropped_rather_than_truncated() {
	// It cannot arrive from DragQueryFileW (the shell NUL-terminates), so one
	// arriving means something truncated it already. Silently cutting it at the
	// NUL would hand the page a *different* path than the user's - a file that
	// exists, under the wrong name.
	got := validate_dropped_paths(['C:\\notes.txt\x00.png'])
	assert got.len == 0
}

fn test_an_over_long_path_is_dropped_not_truncated() {
	// The same bound `opener` applies to a path it is asked to open (ADR-0015):
	// the string crosses into JSON and then into a page, and an unbounded one is a
	// payload nobody chose. A truncated path is a *valid-looking* wrong answer, so
	// this has to be a rejection.
	long := 'C:\\' + 'x'.repeat(max_dropped_path_len)
	assert long.len > max_dropped_path_len
	got := validate_dropped_paths([long, 'C:\\short.txt'])
	assert got == ['C:\\short.txt']
}

fn test_a_path_exactly_at_the_bound_is_kept() {
	// The off-by-one that would make the test above pass for the wrong reason: if
	// the comparison were `>=`, this case would be dropped too and the bound would
	// quietly be one shorter than everything claims it is.
	at_bound := 'x'.repeat(max_dropped_path_len)
	assert at_bound.len == max_dropped_path_len
	got := validate_dropped_paths([at_bound])
	assert got.len == 1
	assert got[0] == at_bound
}

fn test_a_very_large_drop_is_truncated_to_the_bound() {
	// DragQueryFileCountW reports whatever the shell was handed, and dropping a
	// directory tree is tens of thousands of paths. Every one of them becomes a
	// JSON string on the way to the page, so the count is bounded - and the bound
	// truncates the *report* rather than failing the drop, because throwing away
	// forty good paths because the sixty-fifth was too many is the worse answer.
	mut many := []string{}
	for i in 0 .. max_dropped_paths * 2 {
		many << 'C:\\file' + i.str() + '.txt'
	}
	got := validate_dropped_paths(many)
	assert got.len == max_dropped_paths
	// Truncation keeps the FIRST paths, not an arbitrary or reversed selection -
	// the user's own order, which is the one the test above pins.
	assert got[0] == 'C:\\file0.txt'
	last := 'C:\\file' + (max_dropped_paths - 1).str() + '.txt'
	assert got[max_dropped_paths - 1] == last
}

fn test_an_empty_drop_is_an_empty_report_not_a_missing_one() {
	got := validate_dropped_paths([])
	assert got.len == 0
	assert drop_files_data(got) == '{"paths":[],"count":0}'
}

fn test_the_payload_carries_the_validated_paths_and_their_count() {
	data := drop_files_data(validate_dropped_paths(['C:\\a.txt', 'C:\\b.txt']))
	assert data == '{"paths":["C:\\\\a.txt","C:\\\\b.txt"],"count":2}'
}

// The payload crosses into a page as text, and a Windows path is full of
// backslashes, so the escaping is not a detail - it is the difference between a
// JSON string and a syntax error in every drop on the platform this service was
// written for first.
fn test_backslashes_are_escaped_not_eaten() {
	data := drop_files_data(['C:\\Users\\me\\notes.txt'])
	decoded := decode_drop_payload(data) or {
		panic('must decode: ' + err.msg())
	}
	// The decoded value is the original path...
	assert 'C:\\Users\\me\\notes.txt' in decoded
	// ...and the raw JSON doubled every backslash, which is what makes the
	// difference between a string and a syntax error.
	assert data.contains('\\\\')
}

fn test_the_payload_round_trips_through_json2() {
	// Because a payload only the builder can read is not a contract, it is an
	// implementation the frontend has to guess. json2 is the decoder both sides
	// use, so this is the check that the wire shape survives a real parse -
	// including a quote and a non-ASCII name, which are the two things a
	// hand-rolled encoder gets wrong.
	for path in ['C:\\a.txt', 'C:\\b b\\"q".txt', 'D:\\unicode.txt'] {
		data := drop_files_data([path])
		decoded := decode_drop_payload(data) or {
			panic('must decode: ' + err.msg())
		}
		assert path in decoded
	}
}

fn test_the_count_is_the_number_of_paths_actually_reported() {
	// Two fields rather than one because the array's length is redundant with the
	// array - but only if count agrees with it, which is what decode_drop_payload
	// refuses to hand back when it does not.
	data := drop_files_data(validate_dropped_paths(['C:\\a.txt']))
	decoded := decode_drop_payload(data) or {
		panic('must decode: ' + err.msg())
	}
	assert decoded.len == 1
	assert data.contains('"count":1')
}

// PayloadWrapper mirrors the event payload for the decode direction. A test-side
// struct rather than json2's own decode of a map, because the point is to read
// the TEXT back with an independent parse - if the test reused the struct the
// builder encodes from, a builder bug and a reader bug would agree.
struct PayloadWrapper {
pub mut:
	paths []string
	count int
}

// decode_drop_payload reads drop_files_data's output and refuses a payload whose
// count disagrees with its paths.
fn decode_drop_payload(data string) ![]string {
	wrapper := json2.decode[PayloadWrapper](data) or {
		return error(err.msg())
	}
	if wrapper.count != wrapper.paths.len {
		return error('count ' + wrapper.count.str() + ' does not match ' +
			wrapper.paths.len.str() + ' paths')
	}
	return wrapper.paths
}

fn test_the_manifest_describes_two_commands_and_takes_no_params() {
	s := drop_manifest()
	assert s.name == 'drop'
	assert s.prefix() == 'drop.'
	assert s.command_names() == ['drop.enable', 'drop.disable']
	// Neither command takes params: there is nothing to configure. A params type
	// on `drop.enable` would be a knob nobody has a use for yet, and the generated
	// .d.ts would promise it.
	enable := s.command('drop.enable') or { panic('missing') }
	assert enable.params == no_params
	assert s.has_command('drop.disable')
	assert !s.has_command('drop.read')
}

fn test_the_payload_shape_is_in_the_manifest_for_the_d_ts() {
	// The same reason TrayClick is in the tray manifest (ADR-0015): the shape the
	// frontend needs is the shape of an EVENT, and no command signature mentions
	// it, so the generated .d.ts would otherwise not describe the one thing this
	// service emits.
	mut found := false
	for line in drop_manifest().ts_types {
		if line.contains('DropFiles') && line.contains('paths') && line.contains('count') {
			found = true
		}
	}
	assert found
}

fn test_a_fresh_state_accepts_nothing_and_has_no_hook() {
	// A DropState before `drop.enable`: no subclass on the window (an app that
	// never asks for drops gets no hook at all - the ADR-0017 rule), and
	// is_enabled answering false, so the E2E probe can tell "not armed" from
	// "armed and nothing dropped yet".
	st := DropState{}
	assert !st.is_enabled()
	assert st.hook == unsafe { nil }
}

fn test_support_answers_for_this_platform_and_names_the_gap() {
	s := drop_support()
	assert s.name == 'drop'
	// A note is not optional. "ready" with no explanation is how a half-written
	// backend reads as a finished one.
	assert s.note != ''
	$if linux {
		// The distinction this service exists to keep: unwritten is not
		// unsupported, and only one of them is true.
		assert !s.ready
		assert s.note.contains('unwritten')
	} $else $if windows {
		assert s.ready
		// The note has to carry the trade-off, not just the mechanism: a page on
		// this platform does NOT get the DOM's dragover/drop, and a doctor line
		// that said only "ok" would be the over-read this repo's rules forbid.
		assert s.note.contains('WM_DROPFILES')
		assert s.note.contains('drop:files')
	} $else {
		assert !s.ready
	}
}
