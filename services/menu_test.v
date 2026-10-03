module services

import webview

fn test_menu_manifest_declares_three_commands() {
	m := menu_manifest()
	assert m.name == 'menu'
	assert m.command_names() == ['menu.popup', 'menu.close', 'menu.set_menu']
	// `popup` is the modal command: the flag is the ADR-0014 exception, and it
	// is asserted here so dropping it would show up as a contract change.
	popup := m.command('menu.popup') or { panic('menu.popup must be declared') }
	assert popup.blocking
	close := m.command('menu.close') or { panic('menu.close must be declared') }
	// close takes no params, so install wires bridge.validate_empty: a stray
	// payload must not reach the handler.
	assert close.params == no_params
	assert !close.blocking
	// set_menu takes the SAME params as popup, on purpose: the item model, the
	// id rules and the bounds are one contract, and a frontend that builds a
	// popup can hand the identical array to the window bar. It is not blocking
	// because installing a bar is not modal - nothing waits for a user.
	bar := m.command('menu.set_menu') or { panic('menu.set_menu must be declared') }
	assert bar.params == 'MenuPopup'
	assert !bar.blocking
}

fn test_menu_commands_stay_in_the_menu_namespace() {
	m := menu_manifest()
	for c in m.commands {
		assert c.name.starts_with('menu.'), c.name
	}
	// A foreign command is refused, so the service cannot claim another
	// service's wire names.
	assert m.own_command('menu.popup')
	assert !m.own_command('tray.set')
}

fn test_menu_ts_types_are_snake_case() {
	// ADR-0015: a V struct field name IS the wire name, so a camelCase key in
	// the .d.ts would type-check and then be silently dropped by json2. Every
	// MenuItem field is optional in the interface and spelled the way the
	// struct has it.
	joined := menu_manifest().ts_types.join('\n')
	assert joined.contains('interface MenuItem')
	assert joined.contains('interface MenuPopup')
	assert joined.contains('interface MenuClicked')
	assert joined.contains('interface MenuCanceled')
	for field in ['id', 'label', 'enabled', 'separator', 'children'] {
		assert joined.contains(field + '?:'), field
	}
	// The two event payloads the service actually emits.
	assert joined.contains('id: string; }')
	assert joined.contains('canceled: true; }')
	assert !joined.contains('camelCase')
}

fn test_ids_are_a_whitelist_not_a_blacklist() {
	// The point of the whitelist: an id also travels as a Windows HMENU command
	// id, so allowing arbitrary text would mean letting a frontend put a NUL
	// into a native menu handle.
	assert is_valid_id('open')
	assert is_valid_id('file/open')
	assert is_valid_id('Edit.Copy.v2')
	assert is_valid_id('a')
	assert !is_valid_id('')
	assert !is_valid_id('with space')
	assert !is_valid_id('semi;colon')
	assert !is_valid_id('amp&ersand')
	assert !is_valid_id('nul\x00byte')
	assert !is_valid_id('quote"')
	assert !is_valid_id('a'.repeat(max_menu_id + 1))
}

fn test_labels_reject_the_mnemonic_marker() {
	assert is_valid_label('Open file')
	assert is_valid_label('Enregistrer…')
	assert !is_valid_label('')
	// "&" is the Windows mnemonic marker: a label carrying it would render
	// differently from the string the frontend sent, which is why it is
	// refused rather than stripped.
	assert !is_valid_label('Save & close')
	assert !is_valid_label('two\nlines')
	assert !is_valid_label('a'.repeat(max_menu_label + 1))
}

fn test_parse_popup_accepts_the_object_and_the_bare_array() {
	from_object := parse_popup('{"items":[{"id":"a","label":"Alpha"}]}') or {
		panic(err.msg())
	}
	assert from_object.len == 1
	assert from_object[0].id == 'a'
	// A minimal frontend has an array and sends it as it is.
	from_array := parse_popup('[{"id":"a","label":"Alpha"}]') or { panic(err.msg()) }
	assert from_array[0].label == 'Alpha'
	// Defaults are filled by the struct, not by the parser: an item with no
	// `enabled` is enabled.
	assert from_array[0].enabled
}

fn test_parse_popup_rejects_nothing_to_show() {
	for params in ['', 'null'] {
		mut failed := ''
		parse_popup(params) or { failed = err.msg() }
		assert failed.contains('no items'), params
	}
	mut failed := ''
	parse_popup('{"items":[]}') or { failed = err.msg() }
	assert failed.contains('at least one item')
	mut broken := ''
	parse_popup('{"items": [') or { broken = err.msg() }
	assert broken.contains('invalid items')
}

fn test_validate_items_collects_ids_and_bounds_depth() {
	items := parse_popup('{"items":[{"id":"file","label":"File","children":[' +
		'{"id":"file/open","label":"Open"},{"separator":true},' +
		'{"id":"file/quit","label":"Quit","enabled":false}]},' +
		'{"id":"help","label":"Help"}]}') or { panic(err.msg()) }
	validate_items(items)!
	// The flat order is the order the Windows backend assigns command ids in,
	// so it is pinned: a submenu's parent comes before its children.
	assert flatten_items(items) == ['file', 'file/open', 'file/quit', 'help']
}

fn test_validate_items_rejects_bad_shapes() {
	cases := [
		['{"items":[{"id":"a","label":"A"},{"id":"a","label":"A again"}]}', 'duplicate'],
		['{"items":[{"id":"a b","label":"A"}]}', 'not a valid menu id'],
		['{"items":[{"id":"a","label":""}]}', 'needs a label'],
		['{"items":[{"id":"a","label":"A & B"}]}', 'without "&"'],
		['{"items":[{"separator":true,"label":"x"}]}', 'separator carries no'],
		['{"items":[{"id":"a","label":"A","children":[]}]}', ''],
	]
	for case in cases {
		mut failed := ''
		parse_popup(case[0]) or { failed = err.msg() }
		if case[1] == '' {
			assert failed == '', case[0] + ' should be valid'
		} else {
			assert failed.contains(case[1]), case[0] + ' -> "' + failed + '"'
		}
	}
}

fn test_validate_items_bounds_the_item_count() {
	mut many := '['
	for i in 0 .. max_menu_items + 1 {
		if i > 0 {
			many += ','
		}
		many += '{"id":"i' + i.str() + '","label":"I"}'
	}
	many += ']'
	mut failed := ''
	parse_popup(many) or { failed = err.msg() }
	assert failed.contains('at most ' + max_menu_items.str() + ' items')
}

fn test_validate_items_bounds_the_nesting() {
	// A menu four levels deep is a design choice; a fifth is refused rather
	// than flattened, so the native side's recursion is bounded by data that
	// was checked (the Windows build_menu has no depth parameter).
	mut items := '[{"id":"a","label":"A","children":[{"id":"b","label":"B",' +
		'"children":[{"id":"c","label":"C","children":[{"id":"d","label":"D",' +
		'"children":[{"id":"e","label":"E"}]}]}]}]}]'
	mut five := ''
	parse_popup(items) or { five = err.msg() }
	assert five.contains('nest at most ' + max_menu_depth.str() + ' levels')
	// Four levels is accepted: a, b, c, d.
	four := '[{"id":"a","label":"A","children":[{"id":"b","label":"B",' +
		'"children":[{"id":"c","label":"C","children":[{"id":"d","label":"D"}]}]}]}]'
	parse_popup(four) or { panic(err.msg()) }
}

fn test_flatten_skips_separators() {
	items := parse_popup('[{"separator":true},{"id":"a","label":"A"},' +
		'{"id":"b","label":"B","children":[{"id":"b1","label":"B1"}]},' +
		'{"separator":true}]') or { panic(err.msg()) }
	assert flatten_items(items) == ['a', 'b', 'b1']
}

fn test_event_payloads_are_the_wire_contract() {
	// The two events are the whole answer mechanism, so their payloads are
	// pinned: a frontend switches on the shape, not on a message.
	assert menu_clicked_data('file/open') == '{"id":"file/open"}'
	assert canceled_data() == '{"canceled":true}'
	// An id with a quote in it cannot happen (is_valid_id), and the encoder
	// would escape it anyway - a defense that costs nothing to keep.
	assert menu_clicked_data('a"b').contains('\\"')
}

fn test_menu_backend_binds_only_its_own_commands() {
	// The backend is what install() walks, so its keys are the manifest's
	// names: a mismatch here is what install() refuses at runtime.
	backend := menu_backend(webview.Ctx{
		label: 'main'
	})
	mut keys := backend.keys()
	keys.sort()
	assert keys == ['menu.close', 'menu.popup', 'menu.set_menu']
}

fn test_menu_backend_wraps_bad_params() {
	// A rejected payload is 'bad params: …' from inside the service, like
	// opener does, so the contract does not depend on the route the command
	// took (ADR-0010).
	backend := menu_backend(webview.Ctx{
		label: 'main'
	})
	handler := backend['menu.popup'] or { panic('menu.popup must be bound') }
	mut failed := ''
	handler('not json at all') or { failed = err.msg() }
	assert failed.starts_with('bad params:')
}

fn test_menu_backend_resolves_with_an_empty_string() {
	// The command's result is always '': the choice is an event, on both
	// platforms. A frontend that awaited a result here would get a truthy
	// string and think it had an answer.
	backend := menu_backend(webview.Ctx{
		label: 'main'
	})
	close := backend['menu.close'] or { panic('menu.close must be bound') }
	// A Ctx with no window and no open menu: close_native answers from its
	// no-op path, before the require_parent check - which is the contract for a
	// frontend that closes defensively.
	res := close('') or { panic(err.msg()) }
	assert res == ''
}

fn test_menu_support_is_answered_per_platform() {
	// The `$if` in menu_support must be the same one popup dispatches on, or
	// doctor and the implementation would disagree (ADR-0015).
	$if windows {
		assert menu_support().ready
	} $else $if linux {
		assert menu_support().ready
	} $else {
		assert !menu_support().ready
	}
}

// --- window menu bar (ADR-0023) ---

// bar_ids_fixture is a small bar whose flat order is the one the native
// backends assign command ids in: depth-first, separators skipped, 1-based.
// It is written out here rather than derived through flatten_items so that
// bar_click is tested against a literal table, and a change to flatten_items
// cannot quietly make both sides agree on the wrong thing.
fn bar_ids_fixture() []string {
	return ['file', 'file/open', 'file/quit', 'help']
}

fn cmd(wparam u64) webview.HostEvent {
	return webview.HostEvent{
		msg:    wm_command
		wparam: wparam
	}
}

fn test_bar_click_maps_a_command_id_back_to_its_item() {
	ids := bar_ids_fixture()
	// 1-based, because 0 is reserved for "no command" on Windows and for "no
	// stamp" on a GTK widget.
	assert bar_click(cmd(1), ids) or { panic('id 1 must resolve') } == 'file'
	assert bar_click(cmd(2), ids) or { panic('id 2 must resolve') } == 'file/open'
	assert bar_click(cmd(3), ids) or { panic('id 3 must resolve') } == 'file/quit'
	assert bar_click(cmd(4), ids) or { panic('id 4 must resolve') } == 'help'
}

fn test_bar_click_agrees_with_the_flattened_order() {
	// The whole point of sharing flatten_items is that the table the native
	// backend fills and the table this decodes are the same list. If the two
	// ever drift, every click reports the wrong id — silently, and to a user
	// who cannot tell which item they pressed.
	items := parse_popup('{"items":[{"id":"file","label":"File","children":[' +
		'{"id":"file/open","label":"Open"},{"id":"file/quit","label":"Quit"}]},' +
		'{"separator":true},{"id":"help","label":"Help"}]}') or {
		panic(err.msg())
	}
	assert flatten_items(items) == bar_ids_fixture()
}

fn test_bar_click_rejects_id_zero() {
	// Windows uses 0 for "no command", and it is also what a separator reports.
	// Answering 'file' here would be a choice the user never made.
	assert bar_click(cmd(0), bar_ids_fixture()) == none
}

fn test_bar_click_rejects_an_id_past_the_end() {
	// A stale or foreign id means the window's menu changed without us being
	// told. Reading past the end of the slice would be a crash; guessing an id
	// would be worse.
	assert bar_click(cmd(5), bar_ids_fixture()) == none
	assert bar_click(cmd(0xFFFF), bar_ids_fixture()) == none
}

fn test_bar_click_rejects_an_empty_bar() {
	// With no bar installed the hook is still on the window (or has just been
	// removed), and every WM_COMMAND on it belongs to something else.
	assert bar_click(cmd(1), []string{}) == none
}

fn test_bar_click_rejects_a_message_that_is_not_wm_command() {
	// The hook is asked about EVERY message, because that is what a subclass
	// chain is (ADR-0023). The window's own WM_COMMANDs — a control
	// notification, an accelerator, the system menu — arrive here too, and
	// reporting one of our ids for them would be a fabricated click.
	other := webview.HostEvent{
		msg:    webview.host_message
		wparam: 1
	}
	assert bar_click(other, bar_ids_fixture()) == none
}

fn test_bar_click_rejects_a_control_notification() {
	// HIWORD(wParam) is the notification code and is 0 for a plain menu
	// command. BN_CLICKED (0) on a *button* is a different message, but a
	// stale id with a non-zero HIWORD is not a menu command either, and the
	// low word alone must not be enough to claim a click.
	notification := webview.HostEvent{
		msg:    wm_command
		wparam: (u64(2) << 16) | 1
	}
	assert bar_click(notification, bar_ids_fixture()) == none
}

fn test_bar_click_handles_the_highest_legal_command_id() {
	// max_menu_items bounds the item list, and a frontend is allowed to build
	// one that big. The id is a u16 in wParam, so the largest the backend can
	// ever assign is 64 and the top of the list must still resolve.
	mut ids := []string{}
	for i in 1 .. max_menu_items + 1 {
		ids << 'item' + i.str()
	}
	assert ids.len == max_menu_items
	assert bar_click(cmd(u64(max_menu_items)), ids) or { panic('the last id must resolve') } ==
		'item' + max_menu_items.str()
	// and one past it is still refused
	assert bar_click(cmd(u64(max_menu_items) + 1), ids) == none
}
