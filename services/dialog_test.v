module services

import bridge
import capabilities
import webview

// sample_ctx is a headless window context: no native handle, a no-op eval
// sink. Enough to exercise the pure-V half of the service (option
// validation, result encoding, capability gating) on any OS; the native
// picker itself is proven by hand (see tests/e2e_windows/README.md).
fn sample_ctx() webview.Ctx {
	return webview.Ctx{
		label:   'main'
		eval_fn: fn (_ string) ! {}
	}
}

fn grant(names []string) capabilities.Registry {
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'test'
		windows:  ['main']
		commands: names
	})
	return reg
}

fn test_manifest_shape() {
	m := dialog_manifest()
	assert m.name == 'dialog'
	assert m.command_names() == ['dialog.open', 'dialog.save', 'dialog.message']
	for c in m.commands {
		assert m.own_command(c.name)
		// every dialog command is a modal native call
		assert c.blocking
	}
}

fn test_manifest_is_in_the_catalog() {
	assert find('dialog') != none
	assert (service_of('dialog.open') or { panic('missing') }).name == 'dialog'
	// bare grant names resolve too
	assert (service_of('message') or { panic('missing') }).name == 'dialog'
}

fn test_parse_options_from_object() {
	opts := parse_options(kind_open, '{"title":"Pick","multi":true}') or {
		panic(err.msg())
	}
	assert opts.title == 'Pick'
	assert opts.multi
}

fn test_parse_options_from_bare_string() {
	// "Open a file" is the minimal payload a frontend can send.
	opts := parse_options(kind_save, '"Save as"') or { panic(err.msg()) }
	assert opts.title == 'Save as'
}

// Every multi-word field the .d.ts promises has to be spelled exactly as the
// V struct field, because json2 drops keys it does not recognize. This test
// is the guard for that: the camelCase spellings decode to nothing, the
// snake_case ones decode, and the ts_types block promises the latter.
fn test_promised_wire_names_are_the_struct_field_names() {
	opts := parse_options(kind_save,
		'{"title":"Save","default_path":"C:\\\\tmp\\\\","default_name":"notes.txt"}') or {
		panic(err.msg())
	}
	assert opts.default_path == 'C:\\tmp\\'
	assert opts.default_name == 'notes.txt'
	// the camelCase spelling the .d.ts used to promise: accepted as valid
	// JSON, ignored by the decoder - which is exactly the silent failure
	// this test exists to prevent
	camel := parse_options(kind_save, '{"defaultName":"notes.txt"}') or {
		panic(err.msg())
	}
	assert camel.default_name == ''
	// and the ts_types block agrees with the struct
	ts := dialog_ts_types().join(' ')
	assert ts.contains('default_path?: string')
	assert ts.contains('default_name?: string')
	assert !ts.contains('defaultPath')
}

fn test_parse_options_rejects_garbage() {
	mut failed := ''
	parse_options(kind_open, 'not json') or { failed = err.msg() }
	assert failed.contains('invalid options')
}

fn test_parse_options_rejects_empty_payload() {
	mut failed := ''
	parse_options(kind_open, '') or { failed = err.msg() }
	assert failed.contains('no options')
}

fn test_kind_must_match_the_command() {
	// A granted dialog.open must not be usable to run a save or a box.
	mut failed := ''
	parse_options(kind_open, '{"kind":"save"}') or { failed = err.msg() }
	assert failed.contains('does not accept kind "save"')
}

fn test_kind_defaults_to_the_command() {
	// `{}` means "the dialog this command is": the frontend does not have
	// to repeat the kind, and cannot smuggle another one in.
	mut opts := parse_options(kind_save, '{}') or { panic(err.msg()) }
	assert opts.kind == kind_save
	opts = parse_options(kind_open, '{"title":"x"}') or { panic(err.msg()) }
	assert opts.kind == kind_open
}

fn test_message_requires_text() {
	mut failed := ''
	parse_options(kind_message, '{"title":"hi"}') or { failed = err.msg() }
	assert failed.contains('message is required')
}

fn test_message_accepts_buttons() {
	opts := parse_options(kind_message, '{"message":"ok?","buttons":"yesnocancel"}') or {
		panic(err.msg())
	}
	assert opts.buttons == buttons_yes_no_cancel
}

fn test_message_rejects_unknown_buttons() {
	mut failed := ''
	parse_options(kind_message, '{"message":"x","buttons":"maybe"}') or {
		failed = err.msg()
	}
	assert failed.contains('buttons must be')
}

fn test_open_accepts_multi() {
	opts := parse_options(kind_open, '{"multi":true}') or { panic(err.msg()) }
	assert opts.multi
}

fn test_multi_is_rejected_for_save() {
	mut failed := ''
	parse_options(kind_save, '{"multi":true}') or { failed = err.msg() }
	assert failed.contains('multi is only valid for kind "open"')
}

fn test_default_name_is_rejected_for_open() {
	mut failed := ''
	parse_options(kind_open, '{"default_name":"a.txt"}') or { failed = err.msg() }
	assert failed.contains('default_name is only valid for kind "save"')
}

fn test_length_limits() {
	mut long_title := '{"title":"'
	long_title += 'x'.repeat(max_title + 1) + '"}'
	mut failed := ''
	parse_options(kind_open, long_title) or { failed = err.msg() }
	assert failed.contains('title is longer')
}

fn test_filter_validation() {
	validate_filter(Filter{
		name:       'Images'
		extensions: 'png,jpg'
	}) or { panic(err.msg()) }
	validate_filter(Filter{
		name:       'All'
		extensions: '.PNG'
	}) or { panic(err.msg()) }
	mut failed := ''
	validate_filter(Filter{
		name:       'Bad'
		extensions: 'png;j'
	}) or { failed = err.msg() }
	assert failed.contains('invalid extension')
}

fn test_filter_rejects_empty_name_and_extension() {
	mut no_name := ''
	validate_filter(Filter{
		name:       '  '
		extensions: 'png'
	}) or { no_name = err.msg() }
	assert no_name.contains('name must not be empty')

	mut no_ext := ''
	validate_filter(Filter{
		name:       'Images'
		extensions: 'png,'
	}) or { no_ext = err.msg() }
	assert no_ext.contains('empty extension')

	mut sep := ''
	validate_filter(Filter{
		name:       'Images|Text'
		extensions: 'png'
	}) or { sep = err.msg() }
	assert sep.contains('must not contain')
}

fn test_too_many_filters() {
	mut filters := []Filter{}
	for i in 0 .. max_filters + 1 {
		filters << Filter{
			name:       'f' + i.str()
			extensions: 'txt'
		}
	}
	mut failed := ''
	parse_options(kind_open, json_of(filters)) or { failed = err.msg() }
	assert failed.contains('at most ' + max_filters.str() + ' filters')
}

// json_of renders a filter list as the params payload (keeps the test free
// of hand-written JSON escaping).
fn json_of(filters []Filter) string {
	mut parts := []string{}
	for f in filters {
		parts << '{"name":"' + f.name + '","extensions":"' + f.extensions + '"}'
	}
	return '{"filters":[' + parts.join(',') + ']}'
}

fn test_native_filter_string_format() {
	assert native_filter_string([Filter{ name: 'Images', extensions: 'png,jpg' }, Filter{
		name:       'Text'
		extensions: 'txt'
	}]) == 'Images (*.png;*.jpg)|Text (*.txt)'
}

fn test_native_filter_string_normalizes() {
	assert native_filter_string([Filter{
		name:       'All'
		extensions: ' .PNG , jpg '
	}]) == 'All (*.png;*.jpg)'
}

fn test_native_filter_string_of_nothing_is_empty() {
	assert native_filter_string([]) == ''
}

fn test_parse_paths_splits_on_nul() {
	assert parse_paths('C:\\a.txt\x00D:\\b.txt\x00') == ['C:\\a.txt', 'D:\\b.txt']
	assert parse_paths('') == []string{}
	assert parse_paths('\x00') == []string{}
}

fn test_encode_result_shape() {
	out := encode_result(Result{
		canceled: true
	})
	assert out.contains('"canceled":true')
	assert out.contains('"paths":[]')
	assert !out.contains('null')
}

fn test_encode_result_carries_paths() {
	out := encode_result(Result{
		paths:  ['C:\\a.txt']
		button: 'ok'
	})
	assert out.contains('"canceled":false')
	assert out.contains('C:\\\\a.txt')
	assert out.contains('"button":"ok"')
}

// The gate is proven without ever calling the native picker: a granted
// call is covered by test_manifest_installs_against_a_fake_backend, and a
// real dialog must never run inside `v test` (it would block the suite on
// a modal window nobody can click - ADR-0014).
fn test_installed_dialog_command_is_capability_gated() {
	mut router := bridge.new_router()
	install_dialog(mut router, sample_ctx())!
	// no grant at all
	mut res := router.call_json('main', '1', 'dialog.open', '{}',
		capabilities.new_registry())
	assert res.err.starts_with('forbidden:')
	// the other window of the same app is not granted either
	mut reg := capabilities.new_registry()
	reg.grant(capabilities.Capability{
		id:       'main-only'
		windows:  ['main']
		commands: ['dialog.open']
	})
	res = router.call_json('other', '2', 'dialog.open', '{}', reg)
	assert res.err.contains('window "other"')
}

fn test_installed_dialog_rejects_bad_options_with_bad_params() {
	mut router := bridge.new_router()
	install_dialog(mut router, sample_ctx())!
	mut res := router.call_json('main', '1', 'dialog.open', '{"kind":"nope"}',
		grant(['dialog.open']))
	assert res.err.starts_with('bad params:')
}

// A modal dialog must never run in a unit test: the native picker blocks
// the main thread until a human answers (ADR-0014), so the tests wire the
// real manifest against a fake backend instead. The real pickers are
// proven by hand - see tests/e2e_windows/README.md.
fn test_manifest_installs_against_a_fake_backend() {
	mut router := bridge.new_router()
	mut backend := Backend{}
	backend['dialog.open'] = fn (_ string) !string {
		return '{"canceled":true,"paths":[],"button":""}'
	}
	backend['dialog.save'] = fn (_ string) !string {
		return '{"canceled":false,"paths":["C:\\\\out.txt"],"button":""}'
	}
	backend['dialog.message'] = fn (_ string) !string {
		return '{"canceled":false,"paths":[],"button":"ok"}'
	}
	install(mut router, dialog_manifest(), backend)!
	mut res := router.call_json('main', '1', 'dialog.open', '{}',
		grant(['dialog.open']))
	assert res.err == ''
	assert res.result.contains('"canceled":true')
	res = router.call_json('main', '2', 'dialog.save', '{"title":"x"}',
		grant(['dialog.save']))
	assert res.result.contains('out.txt')
	res = router.call_json('main', '3', 'dialog.message', '{"message":"hi"}',
		grant(['dialog.message']))
	assert res.result.contains('"button":"ok"')
}

// There is deliberately no unit test that dispatches dialog.open / dialog.save
// / dialog.message through the router on Linux, and there never was: the
// comment above test_manifest_installs_against_a_fake_backend already says why
// (ADR-0014, a modal dialog blocks until a human answers).
//
// The stub-era version of this test only passed because there was no backend
// behind it. Once the GTK backend became real, that test had exactly two
// possible outcomes and both are wrong: with no display the call returns an
// error, and with a display it opens a real modal dialog and parks in
// gtk_dialog_run. A hang is not a test, and an error is not a contract anyone
// can rely on - whether it comes back depends on the machine the suite runs on.
//
// So the coverage is split, and both halves are real:
//
//   - the response-id mapping, in this file, as pure V: GTK_RESPONSE_OK and
//     GTK_RESPONSE_ACCEPT both report "ok", the four ways GTK can say no all
//     report "cancel", and only ACCEPT means the chooser took the files.
//   - the widget, the nested loop and the real response, in
//     tests/e2e_linux (VAILS_SERVICES_PROBE=dialog), which answers the dialog
//     from a timer so the proof needs no human.
//
// What this test does check is the part that IS reachable headlessly: the
// service installs, and nothing gets past the gate into the native layer.
fn test_the_linux_dialog_native_path_is_e2e_only() {
	$if linux {
		mut router := bridge.new_router()
		install_dialog(mut router, sample_ctx())!
		// An unknown command is rejected by the router, before any backend.
		res := router.call_json('main', '1', 'dialog.nope', '{}',
			grant(['dialog.nope']))
		assert res.err.starts_with('unknown method:')
		// A granted call with bad options is rejected by validation, before
		// any backend. This is the assertion that matters: it proves the
		// native layer is not reached, without ever building a widget.
		mut reg := capabilities.new_registry()
		reg.grant(capabilities.Capability{
			id:       'main-only'
			windows:  ['main']
			commands: ['dialog.open']
		})
		bad := router.call_json('main', '2', 'dialog.open', '{"kind":"nope"}', reg)
		assert bad.err.starts_with('bad params:')
		assert bad.result == ''
	} $else {
		// Windows has a real backend that answers with no display at all;
		// dialog_rc/parse_paths are covered directly, the native call stays
		// manual.
		assert parse_paths('a\x00b\x00') == ['a', 'b']
	}
}

fn test_dialog_rc_maps_shim_codes() {
	// 0 = canceled, n>0 = n paths, <0 = shim error (the message comes from
	// the backend, so the mapping is what matters here). Pure V, so this
	// test runs on Linux too.
	mut res := dialog_rc(0, '', '') or { panic('canceled is not an error') }
	assert res.canceled
	res = dialog_rc(2, 'C:\\a.txt\x00C:\\b.txt\x00', '') or { panic(err.msg()) }
	assert !res.canceled
	assert res.paths.len == 2
	// a negative code is an error carrying the backend's message
	mut failed := false
	dialog_rc(-1, '', 'the shell refused') or { failed = true }
	assert failed
}

fn test_installed_dialog_does_not_leak_other_namespaces() {
	mut router := bridge.new_router()
	install_dialog(mut router, sample_ctx())!
	// dialog.* must not answer to os_info's name
	res := router.call_json('main', '1', 'os_info.get', '', grant(['os_info.get']))
	assert res.err.starts_with('unknown method:')
}

// --- the GTK response mapping (Phase 5b) ---
//
// These are the tests that make the Linux dialog half testable at all. The
// native code answers with a GTK response id; everything the frontend sees is
// decided by these two functions, and they are pure V so they are checked on
// the machine CI runs on rather than only where a GTK loop can be spun up.

fn test_gtk_response_ids_map_to_the_same_buttons_windows_reports() {
	// The mapping the Windows MessageBoxW half hardcodes, in GTK's spelling.
	// Pinned as pairs because the point is that the two agree: an app that
	// switches platforms must not have to translate 'yes' into anything.
	assert gtk_button_name(gtk_response_ok) or { panic('ok') } == button_ok
	assert gtk_button_name(gtk_response_yes) or { panic('yes') } == button_yes
	assert gtk_button_name(gtk_response_no) or { panic('no') } == button_no
	assert gtk_button_name(gtk_response_cancel) or { panic('cancel') } == button_cancel
}

fn test_every_way_gtk_can_say_no_is_the_same_button() {
	// The window manager closing the window, the dialog's own close button, the
	// chooser rejecting a selection and the cancel button are one user intent.
	// Reporting them separately would push that distinction into every app.
	for rc in [gtk_response_reject, gtk_response_delete_event, gtk_response_close, gtk_response_cancel] {
		assert gtk_button_name(rc) or { panic(rc.str()) } == button_cancel, rc.str()
	}
}

fn test_gtk_accept_is_reported_as_ok_like_windows_idok() {
	// A file chooser answers ACCEPT where a message box answers OK, and the
	// frontend sees 'ok' for both - it asked for a file or for an answer, but
	// the button it pressed was the accepting one.
	assert gtk_button_name(gtk_response_accept) or { panic('accept') } == button_ok
}

fn test_an_unknown_gtk_response_is_not_guessed() {
	// A custom response id (a button this service did not add) must not be
	// turned into one of the four names. Reporting 'none' with canceled set is
	// the honest answer: the frontend sees that its dialog closed without a
	// choice it recognises.
	assert gtk_button_name(0) == none
	assert gtk_button_name(12345) == none
	res := gtk_message_result(4242)
	assert res.canceled
	assert res.button == button_none
}

fn test_only_ok_and_yes_count_as_accepted() {
	// The same rule the Windows half applies to IDOK/IDYES: an answer the user
	// gave is not the same as the absence of one, and 'no' is the interesting
	// case - it is a real answer and still not an acceptance.
	assert !gtk_message_result(gtk_response_ok).canceled
	assert !gtk_message_result(gtk_response_yes).canceled
	assert gtk_message_result(gtk_response_no).canceled
	assert gtk_message_result(gtk_response_cancel).canceled
}

fn test_gtk_message_result_always_reports_a_button_name() {
	// Whatever GTK answered, `button` is one of the five names - never empty.
	// An empty string in the Result would be a frontend comparing against ''.
	for rc in [gtk_response_ok, gtk_response_yes, gtk_response_no, gtk_response_cancel,
		gtk_response_reject, gtk_response_delete_event, gtk_response_close, 0] {
		res := gtk_message_result(rc)
		assert res.button != '', rc.str()
		assert res.button in [button_ok, button_cancel, button_yes, button_no, button_none], res.button
	}
}

fn test_only_accept_means_the_chooser_took_the_files() {
	// A chooser's ACCEPT is the only answer that carries filenames. Treating
	// CANCEL as acceptance is how a file dialog returns a path the user never
	// chose.
	assert gtk_chooser_accepted(gtk_response_accept)
	for rc in [gtk_response_cancel, gtk_response_delete_event, gtk_response_reject, gtk_response_close,
		0] {
		assert !gtk_chooser_accepted(rc), rc.str()
	}
}

// ## folder picking (ADR-0039)
//
// The Windows half of folder mode is one flag - FOS_PICKFOLDERS - and `v test`
// cannot see it; the real picker is proven by hand (tests/e2e_windows/README.md).
// What IS testable, and where the design decisions actually live, is the policy
// around it: which combinations are legal, and that the flag survives the real
// manifest and the real validation instead of only the direct parse.

// folder decodes from JSON like every other option: snake_case, because the V
// field name IS the wire name (json2 does not map camelCase onto it).
fn test_parse_folder_option() {
	opts := parse_options(kind_open, '{"title":"Pick a folder","folder":true}') or {
		panic(err.msg())
	}
	assert opts.folder
	assert !opts.multi
	assert opts.title == 'Pick a folder'
	// Default off. A new bool that defaulted true would silently repoint every
	// dialog.open in every app on the machine, which is why the test states the
	// negative rather than trusting the zero value.
	n := parse_options(kind_open, '{"title":"Pick"}') or { panic(err.msg()) }
	assert !n.folder
	assert !n.multi
}

// folder + multi is legal, and it is a third thing rather than either alone: a
// multi-select of DIRECTORIES. Worth pinning because the alternative failure is
// silent - one of the two flags lands on one OS flag and the user can only ever
// choose one.
fn test_folder_combines_with_multi() {
	opts := parse_options(kind_open, '{"folder":true,"multi":true}') or {
		panic(err.msg())
	}
	opts.validate(kind_open)!
	assert opts.folder
	assert opts.multi
}

// A filter selects files, so it cannot mean anything in folder mode. Rejected
// rather than ignored: a caller who asked for *.png and got a directory chooser
// back has been handed a dialog that cannot do what they asked for and looks
// like it worked.
//
// parse_options validates on the way out, so the rejection lands here rather
// than in a separate validate() call - which is the point: there is no route
// into the service that skips this.
fn test_folder_rejects_filters() {
	mut failed := ''
	parse_options(kind_open,
		'{"folder":true,"filters":[{"name":"Images","extensions":"png"}]}') or {
		failed = err.msg()
	}
	assert failed.contains('folder')
	assert failed.contains('filters')
}

fn test_folder_is_only_valid_for_open() {
	// save and message have no folder mode at all, and must say so rather than
	// ignoring the flag.
	mut failed := ''
	parse_options(kind_save, '{"folder":true}') or { failed = err.msg() }
	assert failed.contains('folder')
	mut failed2 := ''
	parse_options(kind_message, '{"folder":true}') or { failed2 = err.msg() }
	assert failed2.contains('folder')
}

// The generated TypeScript is the other half of the contract, and the half a
// frontend actually compiles against: a `folder` field that decodes in V but
// is missing from DialogOpenOptions is invisible to every test above and is
// reported by the user's editor as an unknown property.
fn test_ts_types_advertise_folder() {
	ts := dialog_ts_types().join(' ')
	assert ts.contains('folder?: boolean')
	// And it sits beside multi on the *open* params, not on save or message.
	assert ts.contains('multi?: boolean')
	// camelCase would decode to nothing (json2 does not map it), so its absence
	// is part of the contract, not a style preference.
	assert !ts.contains('folderPath')
}

// multi was silently accepted and dropped on a message dialog, because the
// kind-scoping checks sat below that kind's early return. `folder` would have
// inherited the hole. Pinned here because the shape of the bug is a change in
// *statement order*, which nothing else notices.
fn test_multi_is_refused_on_a_message_dialog() {
	mut failed := ''
	parse_options(kind_message, '{"multi":true}') or { failed = err.msg() }
	assert failed.contains('multi')
}
