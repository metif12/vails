// config.v — vails.json project config (T6, cf. Tauri tauri.conf.json).
// Pure-V, OS-agnostic, no C. This module only reads and validates the
// config file; enforcement (capability gating, asset scoping) stays in
// bridge/capabilities/assets and is wired up fully in T2+/Phase 3.
module config

import capabilities
import json2
import os

// WindowConfig is one entry of the windows list: the window's security
// identity (label), shown title and initial size. It maps 1:1 onto
// webview.Config, which the caller builds (config never imports webview
// so it stays free of the C-toolchain coupling).
pub struct WindowConfig {
pub mut:
	label  string = 'main'
	title  string = 'Vails App'
	width  int    = 1024
	height int    = 768
}

// CapabilitySpec mirrors capabilities.Capability for JSON decoding.
// A separate struct (not the Capability itself) because json decoding
// needs pub mut fields while Capability is intentionally immutable.
pub struct CapabilitySpec {
pub mut:
	id          string
	windows     []string
	commands    []string
	asset_roots []string
	platforms   []string
}

// BundleConfig holds packaging metadata. windows_dll_side_by_side
// records the Phase 1 lesson: the webview/WebView2 loader DLLs must sit
// next to the .exe on Windows.
//
// identifier is the app's stable identity, and on Windows it is the
// AppUserModelID: a desktop (unpackaged) app cannot raise a WinRT toast
// without one, so the notification service registers it and the toast is
// attributed to this app rather than to a bare .exe (ADR-0018). It is
// optional here because nothing except notification needs it, and an app
// that never notifies should not be forced to invent an identity.
pub struct BundleConfig {
pub mut:
	name                     string
	icon                     string
	identifier               string
	windows_dll_side_by_side bool = true
}

// AppUserModelID bounds. Windows accepts an AUMID up to 128 characters,
// and the shell matches one exactly, so an over-long or over-clever one
// silently produces a toast attributed to nothing.
const max_identifier = 128

// validate_identifier enforces the AppUserModelID rules in pure V, so a
// malformed identity is a `vails doctor` line instead of a toast that
// quietly does not appear.
//
// The rules are the shell's, not ours: ASCII alphanumeric plus '.', '-'
// and '_', at most 128 characters, and no leading or trailing period.
// Spaces matter most - a space in an AUMID is the classic reason a toast
// raises a notifier but shows nothing.
//
// Empty is allowed (see BundleConfig.identifier); a caller that needs one
// builds it with default_identifier.
pub fn validate_identifier(id string) ! {
	if id == '' {
		return
	}
	if id.len > max_identifier {
		return error('vails.json: bundle.identifier is longer than ' +
			max_identifier.str() + ' characters (it is the Windows AppUserModelID)')
	}
	for c in id {
		valid := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
			|| (c >= `0` && c <= `9`) || c == `.` || c == `-` || c == `_`
		if !valid {
			return error('vails.json: bundle.identifier may only use letters, ' +
				'digits, ".", "-" and "_" (Windows AppUserModelID); got "' + id + '"')
		}
	}
	if id.starts_with('.') || id.ends_with('.') {
		return error('vails.json: bundle.identifier must not start or end with "." ' +
			'(Windows AppUserModelID)')
	}
}

// default_identifier turns an app name into a valid AppUserModelID, so
// `vails init` can scaffold one without the author having to know the
// charset. It lowercases and drops every character the shell rejects,
// which is why the result is validated rather than assumed: an app named
// "My App!" becomes "myapp" and nothing more.
pub fn default_identifier(app_name string) string {
	mut out := []u8{}
	for c in app_name.to_lower() {
		valid := (c >= `a` && c <= `z`) || (c >= `0` && c <= `9`)
			|| c == `.` || c == `-` || c == `_`
		if valid {
			out << u8(c)
		}
		if out.len == max_identifier {
			break
		}
	}
	// A leading or trailing '.' is rejected by validate_identifier, so
	// strip them here rather than handing back something the shell would
	// refuse. trim takes a cutset and removes both ends in one call.
	s := out.bytestr().trim('.')
	// A name made entirely of rejected characters (e.g. "!!!") would
	// otherwise produce an empty - and therefore invalid - AUMID.
	if s == '' {
		return 'vails.app'
	}
	return s
}

// VailsConfig is the root of vails.json: app identity, window list,
// granted capabilities, asset root and bundle settings.
pub struct VailsConfig {
pub mut:
	name         string
	version      string
	asset_root   string = 'frontend'
	windows      []WindowConfig
	capabilities []CapabilitySpec
	bundle       BundleConfig
}

// default_config returns a minimal single-window config for `vails init`.
// Capabilities stay empty (deny by default, same as an empty Registry).
pub fn default_config(app_name string) VailsConfig {
	return VailsConfig{
		name:       app_name
		version:    '0.1.0'
		asset_root: 'frontend'
		windows:    [
			WindowConfig{
				label: 'main'
				title: app_name
			},
		]
		bundle:     BundleConfig{
			name:       app_name
			// Scaffolded rather than left empty: an app that later grants
			// notification.notify needs an AppUserModelID, and the author
			// is better served by a working one they can edit than by a
			// field that is empty until the toast mysteriously does not
			// appear (ADR-0018).
			identifier: default_identifier(app_name)
		}
	}
}

// load reads and validates the config file at path.
pub fn load(path string) !VailsConfig {
	text := os.read_file(path) or {
		return error('vails.json: cannot read ' + path + ': ' + err.msg())
	}
	return load_text(text)!
}

// load_text parses and validates config JSON. It is the testable core:
// all validation is reachable without touching the filesystem.
pub fn load_text(text string) !VailsConfig {
	cfg := json2.decode[VailsConfig](text) or {
		return error('vails.json: invalid JSON: ' + err.msg())
	}
	cfg.validate()!
	return cfg
}

// validate rejects misconfiguration fail-fast so mistakes surface in
// `vails doctor`/`run`/`build` instead of at window-open time.
pub fn (c VailsConfig) validate() ! {
	if c.name == '' {
		return error('vails.json: name must not be empty')
	}
	if c.windows.len == 0 {
		return error('vails.json: at least one window is required')
	}
	if c.asset_root == '' {
		return error('vails.json: asset_root must not be empty')
	}
	mut seen := []string{}
	for w in c.windows {
		if w.label == '' {
			return error('vails.json: window label must not be empty')
		}
		if w.label in seen {
			return error('vails.json: duplicate window label "' + w.label + '"')
		}
		seen << w.label
		if w.title == '' {
			return error('vails.json: window "' + w.label + '" title must not be empty')
		}
		if w.width <= 0 || w.height <= 0 {
			return error('vails.json: window "' + w.label + '" size must be positive')
		}
	}
	for spec in c.capabilities {
		if spec.id == '' {
			return error('vails.json: capability id must not be empty')
		}
		if spec.commands.len == 0 {
			return error('vails.json: capability "' + spec.id + '" grants no commands')
		}
	}
	validate_identifier(c.bundle.identifier)!
}

// window returns the config of the window with the given label.
pub fn (c VailsConfig) window(label string) !WindowConfig {
	for w in c.windows {
		if w.label == label {
			return w
		}
	}
	return error('vails.json: unknown window label "' + label + '"')
}

// to_registry converts the granted capabilities into a
// capabilities.Registry for bridge.Router.call_from (enforced from T2).
pub fn (c VailsConfig) to_registry() capabilities.Registry {
	mut reg := capabilities.new_registry()
	for spec in c.capabilities {
		reg.grant(capabilities.Capability{
			id:          spec.id
			windows:     spec.windows.clone()
			commands:    spec.commands.clone()
			asset_roots: spec.asset_roots.clone()
			platforms:   spec.platforms.clone()
		})
	}
	return reg
}

// encode renders the config as pretty JSON for `vails init`.
pub fn (c VailsConfig) encode() string {
	return json2.encode(c, prettify: true)
}
