// opener_linux.c.v - Linux backend of the opener service: GIO's default
// handler. Compiled on Linux ONLY (V `_linux` suffix rule).
//
// GAppInfo, not `xdg-open`: the portal-free GIO call is the desktop's own
// API, it needs no process spawn (so no argument-splitting surprises and no
// extra package - xdg-utils is not installed in the WSL image this was
// verified on), and it returns a GError we can turn into a real message
// instead of an exit code.
//
// `with` is not implemented here: on Linux "the application for this file
// type" is a .desktop file the desktop itself resolves, so an app *name* has
// no equivalent. The command rejects it with a readable error instead of
// pretending (ADR-0015).
module services

#include <gio/gio.h>
#pkgconfig gio-2.0

fn C.g_app_info_launch_default_for_uri(uri &char, context voidptr, error voidptr) int
fn C.g_filename_to_uri(filename &char, hostname &char, error voidptr) &char
fn C.g_canonicalize_filename(filename &char, relative_to &char) &char
fn C.g_error_free(err voidptr)
fn C.g_free(mem voidptr)

// GError is a public GLib struct. Redeclared (rather than including glib's
// headers) so the V side does not need the whole GLib type universe; the
// layout matches, which is all this service asks of it. `message` is mut
// because GIO writes through the pointer we hand it.
struct GError {
mut:
	domain  u32
	code    int
	message &char
}

// gerror_message renders a GError and frees it. Returns a fallback when the
// struct carries no message, because a GError without one is possible and
// an empty error string is worse than a vague one.
fn gerror_message(err &GError) string {
	mut out := 'the desktop declined without a reason'
	if err.message != unsafe { nil } {
		out = unsafe { err.message.vstring() }
	}
	unsafe { C.g_error_free(voidptr(err)) }
	return out
}

fn launch_uri(uri string) ! {
	mut gerr := GError{
		message: unsafe { nil }
	}
	// Hoisted out of the call: a nested `unsafe { nil }` inside another
	// `unsafe` block is a V error ("already inside unsafe block").
	no_context := unsafe { nil }
	ok := unsafe {
		C.g_app_info_launch_default_for_uri(uri.str, no_context, voidptr(&gerr))
	}
	if ok == 0 {
		return error('opener: could not open ' + uri + ': ' + gerror_message(&gerr))
	}
}

fn open_url_native(url string) ! {
	// The URL is already a URI (validate_url guaranteed the scheme), so it
	// goes to GIO as it is - no re-encoding, nothing to get wrong.
	launch_uri(url)!
}

fn open_path_native(path string, with string) ! {
	if with != '' {
		return error('opener: "with" is not supported on linux (the desktop ' +
			'decides which application opens a file) - omit it')
	}
	// g_filename_to_uri insists on an absolute path, and the contract allows a
	// relative one (the app may have a working directory it means), so the
	// path is canonicalized first - exactly what the shell would do.
	mut gerr := GError{
		message: unsafe { nil }
	}
	// Both nil arguments are hoisted out of the call: a nested
	// `unsafe { nil }` inside another `unsafe` block is a V error
	// ("already inside unsafe block", ADR-0015).
	no_base := unsafe { nil }
	abs := unsafe { C.g_canonicalize_filename(path.str, no_base) }
	if abs == unsafe { nil } {
		return error('opener: could not resolve the path ' + path + ': ' +
			gerror_message(&gerr))
	}
	uri := unsafe { C.g_filename_to_uri(abs, no_base, voidptr(&gerr)) }
	if uri == unsafe { nil } {
		return error('opener: could not turn the path into a URI: ' +
			gerror_message(&gerr))
	}
	launch_uri(unsafe { uri.vstring() })!
	unsafe { C.g_free(voidptr(uri)) }
}
