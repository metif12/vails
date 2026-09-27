// store.v — managed app state, Tauri `.manage()` equivalent (T4).
// One store per App, read/written from inside validated command handlers.
// Values stay raw JSON strings so this module needs no reflection and no
// codegen; typed access is hand-written per key (V generics are limited —
// `$for` auto-derivation only if proven sufficient, same rule as the
// generator in Phase 7). Pure-V, OS-agnostic, no C.
module state

import json2

// Store holds one JSON value per key. Not thread-safe by itself: handlers
// run on the webview main thread (see ADR-0010), so same-thread access
// needs no locking; background `spawn` workers must send results back as
// events instead of touching the store directly.
pub struct Store {
mut:
	data map[string]string
}

// new_store returns an empty store.
pub fn new_store() Store {
	return Store{
		data: map[string]string{}
	}
}

// set records val_json under key. Empty keys are rejected; values are
// stored verbatim (validation, if any, is the caller's job — typically a
// bridge ParamsValidator in front of the handler).
pub fn (mut s Store) set(key string, val_json string) ! {
	if key == '' {
		return error('state: key must not be empty')
	}
	s.data[key] = val_json
}

// get returns the value stored under key, or an error when absent.
pub fn (s Store) get(key string) !string {
	return s.data[key] or { return error('state: unknown key "' + key + '"') }
}

// remove drops key. Unknown keys are a no-op.
pub fn (mut s Store) remove(key string) {
	s.data.delete(key)
}

// has reports whether key is present.
pub fn (s Store) has(key string) bool {
	return key in s.data
}

// len returns the number of stored keys.
pub fn (s Store) len() int {
	return s.data.len
}

// keys returns the stored keys in insertion order.
pub fn (s Store) keys() []string {
	return s.data.keys()
}

// set_string stores a plain string as JSON under key.
pub fn (mut s Store) set_string(key string, val string) ! {
	s.set(key, json2.encode(val))!
}

// get_string decodes a value stored via set_string.
pub fn (s Store) get_string(key string) !string {
	raw := s.get(key)!
	return json2.decode[string](raw)!
}
