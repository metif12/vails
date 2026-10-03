// appstate.v — managed app state, Tauri `.manage()` equivalent (T4).
// One AppState per App, read/written from inside validated command handlers.
//
// The name is deliberate and was a correction (ADR-0026). This type was
// `state.Store`, and the ROADMAP has a separate `store` service planned for
// *persisted* key-value data. Two things named the same word, differing only
// in the case of one letter, in a language whose house style is snake_case:
// indistinguishable at a call site and actively confusing in prose. The bare
// word "store" went to the thing that persists (matching Tauri, where
// `tauri-plugin-store` is exactly that), and this in-memory type took the
// name its own comment already claimed — "managed app state". The wire never
// carried the old name: the public surface is `application.App`'s
// set_state / get_state / has_state, so only a direct `state.Store` import
// was affected.
// Values stay raw JSON strings so this module needs no reflection and no
// codegen; typed access is hand-written per key (V generics are limited —
// `$for` auto-derivation only if proven sufficient, same rule as the
// generator in Phase 7). Pure-V, OS-agnostic, no C.
module state

import json2

// AppState holds one JSON value per key. Not thread-safe by itself: handlers
// run on the webview main thread (see ADR-0010), so same-thread access
// needs no locking; background `spawn` workers must send results back as
// events instead of touching the AppState directly.
pub struct AppState {
mut:
	data map[string]string
}

// new_appstate returns an empty AppState.
pub fn new_appstate() AppState {
	return AppState{
		data: map[string]string{}
	}
}

// set records val_json under key. Empty keys are rejected; values are
// stored verbatim (validation, if any, is the caller's job — typically a
// bridge ParamsValidator in front of the handler).
pub fn (mut s AppState) set(key string, val_json string) ! {
	if key == '' {
		return error('state: key must not be empty')
	}
	s.data[key] = val_json
}

// get returns the value stored under key, or an error when absent.
pub fn (s AppState) get(key string) !string {
	return s.data[key] or { return error('state: unknown key "' + key + '"') }
}

// remove drops key. Unknown keys are a no-op.
pub fn (mut s AppState) remove(key string) {
	s.data.delete(key)
}

// has reports whether key is present.
pub fn (s AppState) has(key string) bool {
	return key in s.data
}

// len returns the number of stored keys.
pub fn (s AppState) len() int {
	return s.data.len
}

// keys returns the stored keys in insertion order.
pub fn (s AppState) keys() []string {
	return s.data.keys()
}

// set_string stores a plain string as JSON under key.
pub fn (mut s AppState) set_string(key string, val string) ! {
	s.set(key, json2.encode(val))!
}

// get_string decodes a value stored via set_string.
pub fn (s AppState) get_string(key string) !string {
	raw := s.get(key)!
	return json2.decode[string](raw)!
}
