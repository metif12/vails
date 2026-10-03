// autoanswer_shim.h - answer a GTK modal dialog from a timer, for the E2E probe.
//
// This is the one piece of automation that had to be written in C, and it is in
// the EXAMPLE rather than in services/ on purpose. The thing being proven is
// services/dialog_linux.c.v: that a real GtkMessageDialog is created, that
// gtk_dialog_run's nested loop really runs, and that the response it returns
// maps to the right Result. Pressing a button programmatically exercises all
// three; stubbing the backend out would exercise none of them.
//
// It finds the dialog with gtk_window_list_toplevels instead of being handed
// the pointer, which is the point: the service needs no test hook, no probe
// flag and no cooperation whatsoever. An example can therefore prove the
// service works without the service knowing it is being observed - which is the
// only arrangement under which this proof means anything.
//
// Why a timer rather than a click: the dialog is modal and its nested loop is
// spinning, so a timer scheduled before the dialog opened is the mechanism that
// actually gets to run. An xdotool click would depend on the window manager
// giving the dialog focus in a headless Xvfb run, which is exactly the kind of
// flakiness the other probes were built to avoid.
#ifndef VAILS_AUTOANSWER_SHIM_H
#define VAILS_AUTOANSWER_SHIM_H

#include <gtk/gtk.h>

// The dialog this shim answers, found by scanning the toplevel list for a
// modal window that is not the app's own main window. A C static rather than a
// V global because AGENTS.md §2 forbids globals in V; it is only ever touched
// from the GTK main thread, so it needs no lock.
static int vails_probe_answered = 0;

static gboolean vails_probe_answer_dialog(gpointer data) {
	int response_id = GPOINTER_TO_INT(data);
	GList *toplevels = gtk_window_list_toplevels();
	GtkWidget *target = 0;
	for (GList *node = toplevels; node != 0; node = node->next) {
		GtkWidget *w = GTK_WIDGET(node->data);
		// Modal is the discriminator that matters: the app's main window is a
		// toplevel too, and a GtkMenu popup (the menu probes) is not a window
		// at all, so neither can be mistaken for the dialog. GTK3 spells the
		// getter gtk_window_get_modal — there is no gtk_window_is_modal.
		if (gtk_window_get_modal(GTK_WINDOW(w))) {
			target = w;
			break;
		}
	}
	g_list_free(toplevels);
	// G_SOURCE_REMOVE either way: this answers one dialog. A probe that ran
	// again would be answering a *second* dialog, and the caller re-arms.
	if (target != 0) {
		gtk_dialog_response(GTK_DIALOG(target), response_id);
	}
	return G_SOURCE_REMOVE;
}

static inline void vails_probe_auto_answer(int response_id, guint delay_ms) {
	vails_probe_answered = 0;
	g_timeout_add(delay_ms, vails_probe_answer_dialog,
		GINT_TO_POINTER(response_id));
}

#endif
