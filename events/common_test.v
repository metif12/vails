module events

struct Collector {
mut:
	items []string
}

fn test_common_names_are_distinct() {
	names := [common_battery, common_network, common_theme, common_low_memory]
	for i, a in names {
		assert a.starts_with('common:')
		for j, b in names {
			if i != j {
				assert a != b
			}
		}
	}
}

fn test_common_events_flow_through_bus() {
	mut b := new_bus()
	// Heap-allocated so every handler closure shares one address
	// (value captures would fork the state per closure).
	mut got := &Collector{}
	b.on(common_battery, fn [mut got] (d string) {
		got.items << d
	})
	b.on(common_theme, fn [mut got] (d string) {
		got.items << d
	})
	assert b.emit(common_battery, '{"level":82,"charging":true}') == 1
	assert b.emit(common_theme, '{"mode":"dark"}') == 1
	assert b.emit(common_network, '{"online":true,"kind":"wifi"}') == 0
	assert got.items == ['{"level":82,"charging":true}', '{"mode":"dark"}']
}
