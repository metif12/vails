// drop_linux.c.v - Linux backend of the drop service: **unwritten on purpose**.
// Compiled on Linux ONLY (V `_linux` suffix rule).
//
// The GTK half is a `GtkDropTarget` on the window, reading `drag-data-received` /
// `dropped-data` and turning `text/uri-list` into paths.
//
// **The reason this file is still empty expired on 2026-10-05, and it is
// recorded here precisely so nobody keeps inheriting it.** This header used to
// say "this machine has no Linux runner, so a `GtkDropTarget` written today
// would be GTK nobody has run" - which was true when written, and is now false:
// `Dockerfile` builds V from source and runs the **whole suite, 45/45 green,
// with GTK C compiled in**, and `tests/e2e_linux/run_headless.sh` runs a real app
// under Xvfb and screenshots it. So the environment that was missing exists, and
// the remaining gap is the code, not the ability to prove it.
//
// What is still true, and is the reason this is a gap rather than a bug: the V
// in the image is **pinned**, and the pinned commit is the one the Windows host
// was verified against - see the Dockerfile header for the cache-staleness
// failure that led to pinning. Write the GtkDropTarget against that toolchain and
// it is tested on every build, which is the property AGENTS.md 2 asks for.
//
// What IS written is everything that is not native: the bounds, the payload, the
// message policy (services/drop.v), all pure V and all tested on both platforms.
// So the Linux gap is one function's worth of C, not a service that does not
// exist - and `drop_support()` says "unwritten", not "unsupported", because those
// are different claims and only one of them is true.
//
// The Linux shape is also the reason the service reports an event rather than
// relying on the DOM. GTK delivers a drop as a selection of URIs on a
// destination widget, and which widget is "the window" is GTK's answer to give;
// the page still needs one event name that means the same thing on both
// platforms.
module services

import webview

// enable_drop_native refuses by name.
//
// The message says which half is missing and what is not, because a Linux app
// that gets this has to be able to tell the difference between "Vails cannot do
// this" and "Vails has not written this yet" - and only the second is true.
fn enable_drop_native(mut st &DropState) ! {
	_ = st
	// Referenced so the import is not unused on this platform: webview is what
	// the real implementation will need (the seam for the reporting side, and
	// DragAcceptFiles' GTK analogue is a property of the window).
	_ = webview.host_message
	return error('drop: the GTK drop-target half is unwritten (no GtkDropTarget ' +
		'yet - the bounds, the payload and the policy are done and tested, and ' +
		'drop:files is the shape this will emit). See ROADMAP F1.')
}

// disable_drop_native is a genuine no-op rather than an error: nothing was ever
// enabled, so there is nothing to undo, and an app that clears defensively on a
// platform where the feature never armed must not get an error for it.
fn disable_drop_native(mut st &DropState) ! {
	_ = st
}
