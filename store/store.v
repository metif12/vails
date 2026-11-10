// store.v — a small durable key/value store with atomic writes.
//
// Pure V, OS-agnostic, no C. Backed by a single JSON file on disk: the
// whole map is rewritten on every `save`, so this is for small, slowly
// changing state (settings, window geometry, last-used paths) — not for
// high-frequency writes or large blobs. A write goes to a temporary file
// first and is then renamed over the target, so a crash mid-write leaves
// the previous file intact rather than a half-written one.
//
// This is the Phase 3 `store/` module the ROADMAP said did not exist yet.
// It is the seed of a fuller typed store later (D1/D2/D3): today it
// stores strings and leaves typing to the caller, which is enough for
// settings and history to survive a restart.
module store

import json2
import os

// Store is a string key/value map persisted to `path`.
pub struct Store {
pub mut:
	path string
	data map[string]string
}

// open reads `path` if it exists and returns a Store holding its contents.
// A missing file is not an error: it yields an empty store that will create
// the file on the first save. A present-but-unreadable or malformed file IS
// an error, because silently dropping data is worse than failing loudly.
pub fn open(path string) !Store {
	mut s := Store{
		path: path
		data: map[string]string{}
	}
	if !os.exists(path) {
		return s
	}
	text := os.read_file(path) or {
		return error('store: cannot read ' + path + ': ' + err.msg())
	}
	if text.trim_space() == '' {
		return s
	}
	decoded := json2.decode[map[string]string](text) or {
		return error('store: cannot decode ' + path + ': ' + err.msg())
	}
	s.data = decoded
	return s
}

// get returns the value for `key`, or none if it is absent.
pub fn (s &Store) get(key string) ?string {
	if key in s.data {
		return s.data[key]
	}
	return none
}

// has reports whether `key` is present.
pub fn (s &Store) has(key string) bool {
	return key in s.data
}

// set records `value` for `key`. It does not touch disk; call save().
pub fn (mut s Store) set(key string, value string) {
	s.data[key] = value
}

// delete removes `key`. Missing keys are a no-op.
pub fn (mut s Store) delete(key string) {
	s.data.delete(key)
}

// keys returns the stored keys in unspecified order.
pub fn (s &Store) keys() []string {
	mut out := []string{}
	for k, _ in s.data {
		out << k
	}
	return out
}

// len returns the number of stored entries.
pub fn (s &Store) len() int {
	return s.data.len
}

// save writes the store to disk atomically: a temp file is written and
// renamed over the target, so a crash mid-write cannot corrupt the
// previous contents. The parent directory must already exist.
pub fn (s &Store) save() ! {
	tmp := s.path + '.tmp'
	text := json2.encode(s.data, prettify: true)
	os.write_file(tmp, text) or {
		return error('store: cannot write ' + tmp + ': ' + err.msg())
	}
	// Replace any existing target. On Windows, rename over an existing
	// file can fail, so remove first and accept a tiny non-atomic window
	// between remove and rename — still far better than a half-written file.
	if os.exists(s.path) {
		os.rm(s.path) or {
			os.rm(tmp) or {}
			return error('store: cannot remove old ' + s.path + ': ' + err.msg())
		}
	}
	os.rename(tmp, s.path) or {
		return error('store: cannot rename ' + tmp + ' to ' + s.path + ': ' + err.msg())
	}
}