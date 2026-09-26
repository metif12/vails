// capabilities.v — Tauri-style capability allowlist (T1).
// Pure-V, OS-agnostic, no C. Secure by default: empty commands grant
// nothing; empty Registry denies everything.
module capabilities

import os

// Capability grants a set of commands to a set of windows, optionally
// restricted to a set of platforms. Empty windows means all windows;
// empty platforms means all OSes; empty commands means no commands
// (explicit grant required — deny by default).
pub struct Capability {
pub:
	id          string
	windows     []string
	commands    []string
	asset_roots []string
	platforms   []string
}

// Registry holds the granted capabilities of one App.
pub struct Registry {
mut:
	caps []Capability
}

// new_registry returns an empty Registry (denies everything until grants).
pub fn new_registry() Registry {
	return Registry{}
}

// grant records one capability. No dedup: overlapping grants are merged
// by is_allowed_on (union semantics).
pub fn (mut r Registry) grant(c Capability) {
	r.caps << c
}

// is_allowed checks window_label + command against the current OS.
pub fn (r Registry) is_allowed(window_label string, command string) bool {
	return r.is_allowed_on(window_label, command, os.user_os())
}

// is_allowed_on is the testable core: target_os is injected
// ('windows', 'linux', …) so platform filtering is unit-testable on any OS.
pub fn (r Registry) is_allowed_on(window_label string, command string, target_os string) bool {
	os_name := target_os.to_lower()
	for c in r.caps {
		if c.platforms.len > 0 && os_name !in c.platforms {
			continue
		}
		if c.windows.len > 0 && window_label !in c.windows {
			continue
		}
		if command !in c.commands {
			continue
		}
		return true
	}
	return false
}

// asset_roots_of returns the union of asset roots granted to a window on
// the given OS. Used by assets.Server wiring (Phase 3+).
pub fn (r Registry) asset_roots_of(window_label string, target_os string) []string {
	os_name := target_os.to_lower()
	mut out := []string{}
	for c in r.caps {
		if c.platforms.len > 0 && os_name !in c.platforms {
			continue
		}
		if c.windows.len > 0 && window_label !in c.windows {
			continue
		}
		for root in c.asset_roots {
			if root !in out {
				out << root
			}
		}
	}
	return out
}
