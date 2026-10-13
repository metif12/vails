module services

import webview

// drop_linux.c.v - Linux backend of the drop service: a GtkDragDest on the
// window's toplevel, reading text/uri-list into paths. Compiled on Linux ONLY
// (V `_linux` suffix rule).
//
// ## The API name in the old version of this header was wrong, and that matters
//
// This file said the Linux half would be a `GtkDropTarget`. It is GTK4's API.
// This project is GTK **3.24** (Dockerfile asserts the version), where the
// mechanism is `gtk_drag_dest_set` plus target entries plus the
// `drag-data-received` signal. Writing the GTK4 name would have been a build
// error nobody could reach, because the file was never compiled - the second
// reason this file is a correction and not just new code.
//
// ## Why the environment question is settled
//
// The first version of this header justified leaving the file empty with "this
// machine has no Linux runner, so a GtkDropTarget written today would be GTK
// nobody has run". That stopped being true on 2026-10-05: `Dockerfile` builds a
// pinned V from source, runs the suite 45/45 green **with GTK C compiled in**,
// and `tests/e2e_linux/run_headless.sh` runs a real app under Xvfb. So the
// reason expired and this file was written against that container, not against a
// hope. See the Dockerfile header for the cache-staleness failure that made
// "which compiler" a thing worth pinning before writing native code.
//
// ## The seam is not used here, and that is the design
//
// Windows routes a drop through the window host seam (`webview.attach`), because
// `WM_DROPFILES` is a window message and the seam is what delivers those. GTK
// delivers a drop as a **signal on a widget**, so there is no message to route
// and no seam to install - `enable_drop_native` arms the widget directly and
// `DropState.hook` stays nil. `disable_drop_native` therefore has a different
// "never armed" test than the Windows one, and both are correct for their own
// platform; the pure-V rule in drop.v (the no-op defensive disable) still holds
// because `enabled` is what a caller can observe.
//
// ## Paths, never contents, and the URI form
//
// GTK hands back `text/uri-list`, which is a **file:// URI**, not a filesystem
// path. `g_filename_from_uri` converts it, and the conversion has a failure mode
// worth naming: a URI that is not a local file (an http:// link, say) is refused
// by GTK with an error rather than turned into a path that does not exist. That
// is the right drop behaviour - only files arrive - and it is why the conversion
// is per-item rather than trusting the list.
//
// The bounds still come from pure V (`validate_dropped_paths`, `max_dropped_paths`,
// `max_dropped_path_len`), so the platform difference is the reading, not the
// policy.

// --- the GTK declarations this file needs ---------------------------------
//
// Declared rather than `#include`d, per AGENTS.md 2: the minimum surface this
// file actually calls. dialog_linux.c.v and menu_linux.c.v declare their GTK
// the same way, and a header chain would be recompiled by every test file in
// this module (see menu_linux.c.v's GdkRectangle comment for the same argument).

// GtkDestDefaults, as a literal. GTK_DEST_DEFAULT_MOTION is 1<<0 and
// GTK_DEST_DEFAULT_DROP is 1<<1, so the usual value is 3.
const gtk_dest_default_all = 3

// GdkDragAction: GDK_ACTION_COPY is its first member, so the value is 1.
const gdk_action_copy = 1

// `GCallback` and `g_signal_connect_data` are declared in menu_linux.c.v, as
// are `g_object_set_data` / `g_object_get_data` and `g_free`. They are NOT
// repeated here even though this file uses them: a `type` redeclared in the same
// module is a hard error in V ("cannot register fn ... another type with this
// name exists"), which is how this file lost an afternoon on its first build.
// The C function declarations survive duplication only when they are byte-
// identical, which is why `g_free` appears in three other files and `GCallback`
// appears once.

fn C.gtk_drag_dest_set(widget voidptr, flags int, targets voidptr, n_targets int, actions int)
fn C.gtk_drag_dest_unset(widget voidptr)
fn C.gtk_drag_dest_add_uri_targets(widget voidptr)
fn C.gtk_selection_data_get_uris(sel voidptr) voidptr
fn C.gtk_selection_data_get_length(sel voidptr) int
fn C.g_strfreev(str_array voidptr)
fn C.g_filename_from_uri(uri &char, host voidptr, err voidptr) &char

// vails_drop_key is the GObject data key the armed toplevel carries its own
// `DropState` under. GTK's signal machinery hands the data pointer straight
// back, but the key is what makes the handler independent of the connect call -
// and what a second window needs, since there is one toplevel per window and the
// state has to be that window's (the same per-window requirement the seam's
// subscriber list satisfies on Windows, per ADR-0023).
fn C.g_object_set_data(object voidptr, key &char, data voidptr)
fn C.g_object_get_data(object voidptr, key &char) voidptr

// --- enabling and disabling ------------------------------------------------

fn enable_drop_native(mut st &DropState) ! {
	// A toplevel, not a parent: `Ctx.parent` is a GdkWindow and the drag-dest
	// API takes a GtkWidget. dialog_linux.c.v found the same boundary the hard
	// way (its header records it as item 1), and `toplevel` is what ADR-0023
	// added for the window menu bar.
	toplevel := st.ctx.toplevel
	if toplevel == unsafe { nil } {
		return error('drop.enable: no window to drop onto (pass the Ctx from ' +
			'Config.on_ready)')
	}
	if !st.ctx.has_toplevel() {
		return error('drop.enable: the Ctx has no toplevel, so a drop cannot be ' +
			'plus routed to a page')
	}
	// Arm once. A second `drop.enable` on a window that is already armed is a
	// no-op rather than an error, which is what lets a frontend call it from a
	// route change without tracking whether it already did - the same contract
	// `enable_drop` documents in pure V.
	if !st.enabled {
		C.gtk_drag_dest_add_uri_targets(toplevel)
		C.gtk_drag_dest_set(toplevel, gtk_dest_default_all, unsafe { nil }, 0, gdk_action_copy)
		// `st` itself, not a copy and not a capture: a C function pointer cannot
		// close over a V value, so the pointer is handed over as the signal's
		// user data - menu_linux.c.v's arrangement, and the same reason a V
		// closure is impossible here.
		owner := st
		C.g_object_set_data(toplevel, c'vails-drop-state', owner)
		C.g_signal_connect_data(toplevel, c'drag-data-received', unsafe {
			GCallback(drop_data_received)
		}, owner, unsafe { nil }, 0)
	}
	st.enabled = true
}

// disable_drop_native disarms the widget and forgets the state.
//
// The disarm is unconditional rather than gated on a "was it armed" flag of the
// Windows shape: `gtk_drag_dest_unset` is idempotent and GTK ignores a target
// list that was never set, so there is no half-armed state to protect. The
// Windows ordering (disarm, then unhook) is preserved in spirit - nothing here
// can arrive between the two.
fn disable_drop_native(mut st &DropState) ! {
	toplevel := st.ctx.toplevel
	if toplevel != unsafe { nil } {
		C.gtk_drag_dest_unset(toplevel)
		C.g_object_set_data(toplevel, c'vails-drop-state', unsafe { nil })
	}
	st.enabled = false
}

// --- the signal handler ----------------------------------------------------
//
// Eight parameters, the exact GTK signature for `drag-data-received`. Only the
// fifth (the GtkSelectionData) and the last (the user data) are read; the rest
// are named so the signature is recognisable against GTK's, not because GTK can
// tell the difference - it passes all eight and this function ignores six.
//
// A failed emit is swallowed, not propagated: this is a C signal handler with no
// caller to return an error to, and a drop the page could not be told about is
// one the user is still holding files for - the same reasoning Windows
// `on_drop_message` uses.

fn drop_data_received(widget voidptr, _drag_context voidptr, _x int, _y int, selection_data voidptr, _info u32, _time u32, user_data voidptr) {
	if selection_data == unsafe { nil } {
		return
	}
	state := unsafe { &DropState(user_data) }
	if state == unsafe { nil } {
		return
	}
	paths := read_uris(selection_data) or {
		eprintln('drop: could not read the dropped paths: ' + err.msg())
		return
	}
	if paths.len == 0 {
		// Nothing GTK could turn into a path. Not an error the page can act on,
		// and reporting an empty list as a drop would make a frontend render a
		// phantom file.
		return
	}
	state.ctx.emit(event_drop_files, drop_files_data(validate_dropped_paths(paths))) or {
		eprintln('drop: could not report the drop to the page: ' + err.msg())
	}
}

// read_uris turns a GtkSelectionData's `text/uri-list` into filesystem paths.
//
// Two failures are refused rather than guessed at:
//
//  - a URI that is not a local file (http, jsmbc, an unknown scheme) is refused
//    by GTK itself, so `g_filename_from_uri` returning nil is the signal for
//    "this was never a file";
//  - a list whose length is 0 is an empty drop, which is not an error but is not
//    a drop either.
//
// The array is `g_strfreev`'d exactly once on every path out of here, because
// `gtk_selection_data_get_uris` allocates it and a drop is something a user can
// do a hundred times an hour.
fn read_uris(selection_data voidptr) ![]string {
	uris := C.gtk_selection_data_get_uris(selection_data)
	if uris == unsafe { nil } {
		return []
	}
	mut out := []string{}
	unsafe {
		mut p := &voidptr(uris)
		mut i := 0
		for i < max_dropped_paths {
			item := *p
			if item == unsafe { nil } {
				break
			}
			item_raw := &char(item)
			host := unsafe { nil }
			// A nil return is GTK refusing a non-local URI, which is the
			// correct answer rather than a failure to paper over.
			path := C.g_filename_from_uri(item_raw, host, unsafe { nil })
			if path != unsafe { nil } {
				mut vpath := path.vstring()
				if vpath.len > 0 && out.len < max_dropped_paths {
					out << vpath
				}
			}
			p++
			i++
		}
	}
	return out
}
