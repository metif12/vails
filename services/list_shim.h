// list_shim.h — a GList of filenames to one NUL-separated UTF-8 buffer.
//
// Why this exists: walking a GList means reading `->data` and `->next` at
// pointer offsets, and V has no way to express that (no ptradd, no typed
// struct casts off a voidptr). The alternative — hand-declaring a GList struct
// and reimplementing the traversal in V — would put raw pointer arithmetic in
// the service rather than in a shim, which is the one thing AGENTS.md §2 keeps
// out of the V files.
//
// The output shape is not arbitrary: it is the SAME NUL-separated buffer the
// Windows dialog shim produces, so `dialog.parse_paths` (pure V, shared, and
// covered by dialog_test.v) splits it on both platforms. That is the reason
// this shim is three lines of C rather than a V-side list walk.
//
// Ownership: the caller owns `out`. The strings inside the GList belong to GTK
// and are freed here, because gtk_file_chooser_get_filenames hands over a list
// the caller is required to free and a file dialog is opened often enough that
// leaking it would be a real leak, not a theoretical one.
#ifndef VAILS_LIST_SHIM_H
#define VAILS_LIST_SHIM_H

#include <glib.h>

// g_filename_to_utf8 is a five-argument MACRO, not a two-argument function:
// (opsysstring, len, error, itemsize, offset). Declaring it from V with two
// arguments compiles to a call the header static-asserts against, so the
// conversion gets its own wrapper here. itemsize -1 and offset 0 is the
// documented spelling for "the whole NUL-terminated string", and NULL for
// both out-params means the caller cannot tell a conversion failure from a
// conversion that produced nothing - which is why this returns NULL on
// failure, same as the macro does.
//
// The returned string is newly allocated; the caller still owns it and must
// g_free it, exactly as with the macro.
static inline gchar *vails_filename_to_utf8(const gchar *filename) {
	if (filename == 0) {
		return 0;
	}
	return g_filename_to_utf8(filename, NULL, NULL, -1, 0);
}

static inline int vails_list_to_utf8(GList *list, char *out, int out_len) {
	if (out == 0 || out_len < 1) {
		return -1;
	}
	int written = 0;
	// No filename is allowed to be empty, and a NUL terminates the buffer, so
	// the last byte is reserved for it. A truncation is reported rather than
	// silently returning a partial path list.
	out[0] = '\0';
	for (GList *node = list; node != 0; node = node->next) {
		gchar *name = (gchar *)node->data;
		if (name == 0) {
			continue;
		}
		gchar *utf8 = vails_filename_to_utf8(name);
		if (utf8 != 0) {
			glong len = (glong)g_utf8_strlen(utf8, -1);
			if (written + len + 1 >= out_len) {
				g_free(utf8);
				g_list_free_full(list, g_free);
				return -1;
			}
			memcpy(out + written, utf8, (gsize)len);
			written += (int)len;
			out[written] = '\0';
			g_free(utf8);
		}
	}
	// The terminator that makes parse_paths stop, and that an empty list needs
	// in order not to look like a one-entry list of "".
	out[written] = '\0';
	g_list_free_full(list, g_free);
	return written;
}

#endif
