// services/drop.v - the drop service: tell the page what the user dropped on
// this window (ROADMAP track F1).
//
// ## What the OS actually gives us, measured before anything was designed
//
// The ROADMAP asked the right question first, and it is worth keeping the answer
// because it decided the whole design: **is `EnableWebDrop` reachable at all?**
// No. The installed `webview` 0.12 header declares sixteen `WEBVIEW_API`
// functions and not one of them is about dropping:
//
//     create destroy run terminate dispatch get_window get_native_handle
//     set_title set_size navigate set_html init eval bind unbind return version
//
// `EnableWebDrop` is a WebView2 **host** setting - it lives on
// `ICoreWebView2Controller`, and the webview library does not hand the
// controller out. There is no `webview_set_drag*` either. So the only reachable
// native path on Windows is `WM_DROPFILES` on the HWND, which is a window
// message, which is exactly what `webview/host.v` already exists to deliver to
// V (ADR-0017). The seam is not an obstacle here; it is the mechanism.
//
// ## The trade-off this design accepts, stated up front
//
// `DragAcceptFiles(hwnd, TRUE)` on the **top-level** window means WebView2's own
// HTML5 drop handling does not fire for that window: the page gets no DOM
// `dragover` / `drop` events, because the drag never reaches the WebView2 child.
//
// That is a real loss and it is not hidden. The alternative - `IDropTarget` on
// the controller - needs the controller this library does not expose, so it is
// not a choice so much as the only exit. What the page gets instead is an
// explicit `drop:files` event carrying the paths, which is the shape a
// cross-platform service has to use anyway: on Linux a drop arrives as a
// GObject signal carrying URIs, not as a DOM event, so a frontend written
// against the DOM alone would already be Windows-only. One event, both
// platforms, is the same reasoning `tray:clicked` and `menu:clicked` are built
// on: the OS answers differently on each side and the page must not have to
// know which.
//
// ## The routing question F1 was blocked on
//
// ROADMAP F1 depends on F0 because "drop onto which window" is a routing
// question. It is answered, and not by anything new: **the seam is per-window
// and each hook closes over that window's own `Ctx`**, so a drop is reported to
// the page of the window it landed on. The same property that makes `emit_to`
// work (ADR-0035) makes a drop land in the right inbox - there is no global
// "current window" for a drop to be ambiguous about, which is the failure mode
// that made F0 worth doing first.
//
// ## Paths, never contents
//
// A drop hands the OS's *paths* to the page and nothing else. This service never
// reads a file: a page that wants the contents has to be given a way to ask for
// them, and that capability should be granted (or not) on its own, not inherited
// by every window that can receive a drop.
module services

import bridge
import json2
import webview

// Bounds. The count bound is the interesting one: `DragQueryFileCountW` reports
// whatever the shell was handed, so a drop of a whole directory tree can be tens
// of thousands of paths, and every one of them becomes a JSON string on the way
// to the page. The bound is applied to what is *reported*, not to what was
// dropped, so an over-large drop is a truncated report rather than a failure.
const max_dropped_paths = 64
const max_dropped_path_len = 1024

// The event this service emits. One event, not one per dropped path: a drop of
// twelve files is one thing the user did, and a frontend that has to
// deduplicate twelve events to learn that is a frontend with a bug.
pub const event_drop_files = 'drop:files'

// WM_DROPFILES. A plain window message, so unlike the tray's WM_APP+1 it is not
// a message Vails chose - it is the one Windows chose, which is why nothing here
// may assume a particular id range.
//
// (0x0233 is not declared in this module's namespace already; the menu and tray
// services use the notification-area and command ids, and a second `const` with
// the same name in one translation unit is a compile error - ADR-0018's note.)
const wm_dropfiles = i64(0x0233)

// DropState is the per-window drop state: the window seam on Windows, and
// whether dropping is on at all. One per window, created by install_drop, and
// captured by the hook, so the hook outlives the `drop.enable` call that
// installed it - exactly the TrayState arrangement (ADR-0017).
pub struct DropState {
mut:
	ctx webview.Ctx
	// hook is the window host seam, installed on the first `drop.enable` and
	// removed by `drop.disable`. Nil until then, so an app that never asks for
	// drops gets no subclass on its window.
	hook &webview.HostCtx = unsafe { nil }
	// enabled reports whether the window is accepting drops. It is the answer to
	// "why did nothing happen", which is the question a frontend asks when it
	// called `drop.enable` and no event ever arrived.
	enabled bool
}

// is_enabled reports whether this window is accepting drops. Not a command: the
// frontend's answer is the event, and the app that installed it is the one that
// needs to ask (the E2E probe does, for the same reason `tray.is_installed`
// exists - a drop that arrives before the page is listening has nothing to land
// on, and a fixed sleep loses that race on a slow first load).
pub fn (s &DropState) is_enabled() bool {
	return s.enabled
}

// drop_manifest is the service manifest (T5). Neither command is blocking: the
// drop arrives later as `drop:files`, so `drop.enable` returns as soon as the
// window has been told to accept drops.
//
// There is no `drop.read` or `drop.open`, and the absence is the design: this
// service reports, the page decides, and the deciding is done with capabilities
// the app already has (ADR-0015's reasoning - the OS must not be asked to act on
// something a page supplied).
pub fn drop_manifest() Service {
	return Service{
		name:     'drop'
		version:  '0.1.0'
		summary:  'report files dropped on this window'
		commands: [
			Command{
				name:    'drop.enable'
				result:  'string'
				summary: 'starts accepting drops on this window; a drop arrives ' +
					'as drop:files'
			},
			Command{
				name:    'drop.disable'
				result:  'string'
				summary: 'stops accepting drops and removes the window hook'
			},
		]
		ts_types: [
			// Neither type describes a command's params (both commands take
			// none), so these exist for the *event* payload - the same reason
			// TrayClick is in the tray manifest (ADR-0015). snake_case, because a V
			// struct field name IS the wire name.
			'\texport interface DropFiles { paths: string[]; count: number; }',
		]
	}
}

// is_drop_message reports whether a window message is a drop this service owns.
//
// One line, and it is the whole reason the service cannot misfire: 0x0233 is a
// real window message that any window procedure may see, so "not ours" has to be
// settled before anything touches the DROPFILES handle in lParam - including the
// handle release, which is why this is asked first in on_drop_message rather than
// after the read.
pub fn is_drop_message(e webview.HostEvent) bool {
	return e.msg == wm_dropfiles
}

// DropAction is what the host handler should do about one window message.
//
// Two outcomes here, where `tray.decide` needed three. The difference is
// deliberate and it is the reason this is not a `bool`: **a drop that carried
// nothing usable is still reported**, with zero paths, because the user did
// something and silence reads as a bug. The two failures this avoids are the
// pair the tray service had to learn about separately - a swallowed drop (the
// page waits forever) and a phantom event (the page reacts to a drag that never
// happened). Reporting `paths: []` is the answer that is neither.
pub enum DropAction {
	// not ours: keep travelling down the subclass chain to the menu bar's hook
	// and on to the webview library (ADR-0023's chaining rule).
	pass_on
	// ours, and the page should hear about it.
	emit_files
}

// decide_drop is the whole of the drop policy, as one pure function.
//
// Named for the service because the module namespace is flat and `tray.decide`
// already has it — the same reason `validate_tray_options` is not called
// `validate` (ADR-0015's codegen note, and V rejects a redefinition outright).
//
// `valid` is the number of paths that survived validate_dropped_paths - passed
// in rather than read from the OS, because the point of this function is that a
// test can ask what it would do without dropping anything.
pub fn decide_drop(e webview.HostEvent, valid int) DropAction {
	if !is_drop_message(e) {
		return .pass_on
	}
	return .emit_files
}

// validate_dropped_paths bounds one drop's worth of paths, in the order the rules
// are cheapest to apply:
//
//   - at most `max_dropped_paths` are kept. Truncation is silent on purpose: the
//     payload carries the count that was *reported*, so a page can tell it was
//     truncated by comparing against the bound, and an error here would throw
//     away forty good paths because the sixty-fifth was too many.
//   - an empty path is dropped. `DragQueryFileW` returns 0 for a format it cannot
//     express as a name (a dropped shortcut or a virtual item), and a JSON array
//     with `""` in it is worse than one without it.
//   - a path longer than `max_dropped_path_len` is dropped, for the same reason
//     `opener` bounds its path input (ADR-0015): the string crosses into JSON and
//     then into a page, and an unbounded one is a payload nobody chose.
//   - a path containing a NUL is dropped. It cannot arrive from
//     `DragQueryFileW` (it is NUL-terminated by construction), and a path with an
//     embedded NUL is a truncation bug in whatever produced it - silently
//     truncating it here would hand the page a different path than the user's.
//
// It returns the surviving paths rather than an error, so the caller always has
// something to report, and `decide` gets a count either way.
pub fn validate_dropped_paths(paths []string) []string {
	mut out := []string{}
	for p in paths {
		if out.len >= max_dropped_paths {
			break
		}
		if p == '' || p.len > max_dropped_path_len || p.contains('\x00') {
			continue
		}
		out << p
	}
	return out
}

// drop_files_data is the payload of `drop:files`.
//
// Built from the *validated* list, so `count` is the number of paths actually in
// the array rather than the number the OS offered. A page that wants to know it
// is looking at a truncated drop compares `count` with its own bound; a page that
// does not care reads `paths`. Two fields rather than one because the array's
// length is redundant with the array.
pub fn drop_files_data(paths []string) string {
	mut items := []string{}
	for p in paths {
		items << json2.encode(p)
	}
	return '{"paths":[' + items.join(',') + '],"count":' + paths.len.str() + '}'
}

// ## Where the message handler lives, and why it is not in this file
//
// `on_drop_message` used to be here, and it could not be: the one thing it does
// that this file cannot is read an HDROP, and `read_dropped_paths_native` exists
// only in `drop_windows.c.v`. A platform-neutral module may not name a platform
// function at all, so this was not one broken function - it was the whole `services`
// module failing to compile on Linux.
//
// It lives in `drop_windows.c.v` now, beside its only caller and its only platform
// dependency. `menu_windows.c.v`'s `on_bar_command` is the same arrangement for the
// same reason: a handler that reads a Windows message belongs to that platform's
// backend.
//
// `tray.v` looks like the counter-example and is not. Its `on_host_message` can
// stay neutral because a tray backend *exists on Linux*, so there is a message to
// handle on both sides. The drop service has no Linux half by choice (see
// `drop_linux.c.v`), so a neutral handler would have nothing to be neutral about.
//
// Everything testable stayed here on purpose. `decide_drop`,
// `validate_dropped_paths` and `drop_files_data` are the entire policy, all three
// are pure V, and all three stay covered on both platforms by `drop_test.v`. What
// moved is the one function that needs an HDROP - and so cannot be tested on a
// machine without one, which is the honest reason it was the wrong side of the
// line to begin with.

// enable_drop starts accepting drops on this window and installs the seam.
//
// Needs a window, and the rule lives in pure V so a hand-built `Ctx` cannot
// reach the native call: `DragAcceptFiles` takes an HWND, and the value 0 would
// be accepted by the API and mean nothing.
pub fn enable_drop(mut st &DropState) ! {
	$if windows {
		return enable_drop_native(mut st)
	} $else $if linux {
		return enable_drop_native(mut st)
	} $else {
		return error('drop.enable: not implemented on this platform yet (Phase 6, ' +
			'macOS)')
	}
}

// disable_drop stops accepting drops and removes the seam. A no-op when none was
// installed, because an app that clears defensively must not get an error for it.
pub fn disable_drop(mut st &DropState) ! {
	$if windows {
		return disable_drop_native(mut st)
	} $else $if linux {
		return disable_drop_native(mut st)
	} $else {
		return error('drop.disable: not implemented on this platform yet ' +
			'(Phase 6, macOS)')
	}
}

// drop_backend builds the handler set for one window. The state is heap
// allocated and captured, so the hook installed by `drop.enable` outlives the
// call that installed it.
//
// The captured name is a local copy of the pointer, not the parameter itself: V
// 0.5.2 types a `mut` closure capture of a `mut` *parameter* as a pointer to the
// pointer and gcc rejects the generated assignment (ADR-0017's note, and the
// same workaround as `tray_backend`).
pub fn drop_backend(mut st &DropState) Backend {
	mut state := st
	mut backend := Backend{}
	backend['drop.enable'] = fn [mut state] (_ string) !string {
		enable_drop(mut state)!
		return ''
	}
	backend['drop.disable'] = fn [mut state] (_ string) !string {
		disable_drop(mut state)!
		return ''
	}
	return backend
}

// install_drop binds the drop service on router for one window and returns the
// state it created, for the same reason install_tray returns its state: the E2E
// probe needs to ask whether drops are on without a human doing a drag.
pub fn install_drop(mut router bridge.Router, ctx webview.Ctx) !&DropState {
	mut st := &DropState{
		ctx: ctx
	}
	install(mut router, drop_manifest(), drop_backend(mut st))!
	return st
}

// drop_support answers "can this platform report a drop?" (see support.v).
//
// The Windows note carries the trade-off rather than hiding it: a page on this
// platform gets `drop:files` and NOT the DOM's dragover/drop, because
// `DragAcceptFiles` on the top-level window takes the drop away from WebView2's
// child. A service whose `doctor` line said only "ok" would be the kind of
// over-read this repo's rules exist to prevent.
pub fn drop_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'drop'
			ready: true
			note:  'WM_DROPFILES on the window seam (paths only, never contents); ' +
				'the page gets drop:files and NOT the DOM dragover/drop, because ' +
				'DragAcceptFiles on the top-level window takes the drop from the ' +
				'WebView2 child'
		}
	} $else $if linux {
		// Not a stub by accident: the GTK half is a GtkDropTarget on the window,
		// and writing GTK C that has never been compiled is how the wave-3 Linux
		// build broke for four ordinary reasons while being blamed on V
		// (ADR-0015). The pure-V half - the bounds, the payload, the policy -
		// is written and tested on both platforms, so only the native read is
		// missing.
		return ServiceStatus{
			name:  'drop'
			ready: false
			note:  'the GTK drop-target half is unwritten (no GtkDropTarget yet - ' +
				'ADR-0015 lesson: no native code that has never compiled); the ' +
				'bounds, the payload and the policy are done'
		}
	} $else {
		return ServiceStatus{
			name:  'drop'
			ready: false
			note:  'no backend on this platform yet (Phase 6, macOS)'
		}
	}
}
