// toast_shim.h - a real Windows 10/11 toast notification behind a C ABI.
//
// V has no COM projection and no WinRT projection (ADR-0002, ADR-0014), so
// the Windows.UI.Notifications stack lives here in C and V sees two
// functions with plain UTF-8 strings. Same pattern as dialog_shim.h,
// included via `#insert "@VMODROOT/services/toast_shim.h"` so no -I flag is
// needed.
//
// ABI contract (UTF-8 in, ASCII out):
//   vails_toast_show  -> 0 = the toast was handed to the shell,
//                          negative = failure, message in vails_toast_last_error
//   vails_toast_last_error -> message for the last failure, never NULL
//   vails_toast_available -> 1 when the WinRT toast classes can be activated
//
// What the sequence actually is, because every step was necessary and the
// order is not obvious:
//   1. RoInitialize               the thread needs a COM/WinRT apartment
//   2. register the AUMID          an unpackaged desktop app cannot raise a
//                                  toast at all until the shell knows its
//                                  AppUserModelID (HKCU + the process)
//   3. RoGetActivationFactory x3  ToastNotificationManager statics, an
//                                  XmlDocument, the ToastNotification factory
//   4. LoadXml / CreateToastNotification / Show
//
// Five facts about the MSYS2 headers that cost real time and that the
// comment on each line records, because they are all invisible from the API
// documentation (ADR-0015 Notes, one layer deeper):
//
//   1. NO IID IN THIS TOOLCHAIN IS LINKABLE. Every GUID here is
//      `DEFINE_GUID` in a WIDL header, which in C mode is an `extern`
//      declaration with no definition in libuuid.a, libwindowsapp.a,
//      libole32.a or liboleaut32.a (verified with `nm` over all four).
//      Referencing one directly is an `undefined reference` at link time.
//      So each GUID is copied verbatim below as a `static const`, exactly
//      as dialog_shim.h does - the only reason those headers "work" at all.
//   2. THE SHORT TYPE NAMES DO NOT EXIST IN C. `IToastNotifier`,
//      `IToastNotificationManagerStatics`, `IXmlDocument` and
//      `IXmlDocumentIO` are all undefined; only the long
//      `__x_ABI_CWindows_...` spellings compile. The short names live in
//      `namespace ABI` blocks, which are C++-only.
//   3. RoGetActivationFactory TAKES AN HSTRING, not a wide string literal.
//      Passing `L"..."` directly is a pointer-type error; the class name
//      must go through WindowsCreateString first.
//   4. LoadXml IS NOT ON IXmlDocument. It lives on the separate
//      IXmlDocumentIO interface, so the document has to be
//      QueryInterface-ed before it can be parsed.
//   5. The UTF-8/UTF-16 helpers below are named vails_toast_* rather than
//      shared with dialog_shim.h. V concatenates every .c.v file of a
//      module into ONE translation unit, so dialog_shim.h and this file
//      end up in the same src.c - a shared name is a `redefinition`
//      error, not a duplicate-symbol link error. A third shared header
//      would need both shims to include it, which is a build-order
//      dependency; two uniquely-named 12-line copies cost less and cannot
//      be ordered wrongly.

// `Error` is an enumerator of `AsyncStatus` in asyncinfo.h, which
// windows.ui.notifications.h pulls in - and it collides with V's own
// `Error` type in the generated src.c. Renaming the enumerator is the
// standard escape and costs nothing, because nothing here uses
// AsyncStatus::Error. It has to be defined *before* the include and
// undefined after, or the macro would leak into unrelated headers.
#define Error vails_async_status_error
#include <windows.h>
#include <roapi.h>
#include <winstring.h>
#include <shobjidl.h>   // SetCurrentProcessExplicitAppUserModelID
#include <winreg.h>     // the AUMID registration
#include <windows.ui.notifications.h>
#include <windows.data.xml.dom.h>
#undef Error
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

// vails_toast_last_error's slot. Static and one-deep, like dialog_shim.h's:
// the handlers that reach this run one at a time on the webview main thread
// (ADR-0010/0014).
static char vails_toast_err[512];

static const char *vails_toast_last_error(void) {
	return vails_toast_err[0] ? vails_toast_err : "unknown toast error";
}

static void vails_toast_clear_error(void) { vails_toast_err[0] = 0; }

static void vails_toast_error(const char *what, HRESULT hr) {
	char msg[200];
	snprintf(msg, sizeof(msg), "%s failed (hr=0x%08lx)", what,
	         (unsigned long)hr);
	int i = 0;
	for (; msg[i] && i < (int)sizeof(vails_toast_err) - 1; i++) {
		vails_toast_err[i] = msg[i];
	}
	vails_toast_err[i] = 0;
}

static void vails_toast_error_text(const char *msg) {
	int i = 0;
	for (; msg && msg[i] && i < (int)sizeof(vails_toast_err) - 1; i++) {
		vails_toast_err[i] = msg[i];
	}
	vails_toast_err[i] = 0;
}

// The four IIDs, copied verbatim from the installed MSYS2 headers because
// none of them link (fact 1 above). Values, for reference:
//   ToastNotificationManagerStatics  50ac103f-d235-4598-bbef-98fe4d1a3ad4
//   IXmlDocument                     f7f3a506-1e87-42d6-bcfb-b8c809fa5494
//   IXmlDocumentIO                   6cd0e74e-ee65-4489-9ebf-ca43e87ba637
//   ToastNotificationFactory         04124b20-82c6-4229-b109-fd9ed4662b53
static const GUID vails_iid_toast_manager = {0x50ac103f, 0xd235, 0x4598,
                                             {0xbb, 0xef, 0x98, 0xfe, 0x4d, 0x1a, 0x3a, 0xd4}};
static const GUID vails_iid_xml_document = {0xf7f3a506, 0x1e87, 0x42d6,
                                            {0xbc, 0xfb, 0xb8, 0xc8, 0x09, 0xfa, 0x54, 0x94}};
static const GUID vails_iid_xml_io = {0x6cd0e74e, 0xee65, 0x4489,
                                      {0x9e, 0xbf, 0xca, 0x43, 0xe8, 0x7b, 0xa6, 0x37}};
static const GUID vails_iid_toast_factory = {0x04124b20, 0x82c6, 0x4229,
                                             {0xb1, 0x09, 0xfd, 0x9e, 0xd4, 0x66, 0x2b, 0x53}};

// The three activatable class names, in the
// "namespace.type, assembly, ContentType=WindowsRuntime" form the Windows
// Runtime resolver requires. Passed to RoGetActivationFactory as HSTRINGs
// (fact 3).
#define VAILS_CLS_TOAST_MANAGER                                                      \
	L"Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, "  \
	L"ContentType=WindowsRuntime"
#define VAILS_CLS_XML_DOCUMENT                                                      \
	L"Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, "                      \
	L"ContentType=WindowsRuntime"
#define VAILS_CLS_TOAST_NOTIFICATION                                                \
	L"Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, "        \
	L"ContentType=WindowsRuntime"

// vails_toast_wide / vails_toast_wide_free: UTF-8 -> UTF-16, named apart
// from dialog_shim.h's pair for the reason in fact 5 above. NULL for
// NULL/empty input, so a caller can pass an optional display name through
// without branching.
static wchar_t *vails_toast_wide(const char *s) {
	if (!s || !s[0]) {
		return NULL;
	}
	int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
	if (n <= 0) {
		return NULL;
	}
	wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
	if (!w) {
		return NULL;
	}
	if (MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n) <= 0) {
		free(w);
		return NULL;
	}
	return w;
}

static void vails_toast_wide_free(wchar_t *w) {
	if (w) {
		free(w);
	}
}

// vails_register_aumid teaches the shell who this app is.
//
// This is the step that makes an unpackaged app's toasts work at all, and
// it is why the service takes an identity instead of guessing one: without
// a registered AppUserModelID the shell refuses to attribute a toast to the
// process, and the notification either does not appear or appears under the
// bare .exe name. The two halves are both required:
//   - the HKCU key gives the AUMID a display name (what the Action Center
//     shows) and makes it discoverable at all;
//   - SetCurrentProcessExplicitAppUserModelID binds it to this process, and
//     the docs require it to happen before the process presents any UI.
//
// HKCU, not HKLM: no elevation, and it is the per-user scope the shell
// actually reads for a desktop app. Idempotent - rewriting the same values
// costs one registry write, so this runs on every notify rather than
// carrying a "did we already do this" global (AGENTS.md §2 forbids them).
static int vails_register_aumid(const wchar_t *aumid, const wchar_t *display) {
	// The process-level binding first: the docs ask for it before any UI,
	// and doing it before the registry write means a registry failure is
	// the only thing that can stop us.
	HRESULT hr = SetCurrentProcessExplicitAppUserModelID(aumid);
	// S_FALSE is "the same value is already set", which is the normal
	// case for the second notify onwards.
	if (FAILED(hr)) {
		vails_toast_error("SetCurrentProcessExplicitAppUserModelID", hr);
		return -1;
	}

	wchar_t key[320];
	_snwprintf(key, sizeof(key) / sizeof(key[0]),
	           L"Software\\Classes\\AppUserModelId\\%s", aumid);
	HKEY h = NULL;
	LONG rc = RegCreateKeyExW(HKEY_CURRENT_USER, key, 0, NULL, 0, KEY_WRITE,
	                          NULL, &h, NULL);
	if (rc != ERROR_SUCCESS) {
		char msg[160];
		snprintf(msg, sizeof(msg),
		         "could not register the AppUserModelID under HKCU (error %ld)",
		         (long)rc);
		vails_toast_error_text(msg);
		return -1;
	}
	// REG_SZ, not REG_EXPAND_SZ: DisplayName is a literal here, and the
	// shell compares it as one.
	RegSetValueExW(h, L"DisplayName", 0, REG_SZ, (const BYTE *)display,
	               (DWORD)((wcslen(display) + 1) * sizeof(wchar_t)));
	RegCloseKey(h);
	return 0;
}

// vails_toast_available reports whether the WinRT toast classes can be
// activated at all.
//
// This is deliberately NOT what `is_supported` returns. That command answers
// "is there a backend on this platform", which is a compile-time fact and
// stays true here; this answers "does this machine have the runtime", which
// is the thing that actually varies. An app image without the WinRT
// component DLLs (a stripped Server-style image, for instance) can compile
// and link this file perfectly and still be unable to raise a toast - which
// is exactly the case a plain `true` would hide.
int vails_toast_available(void) {
	HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
	// S_OK / S_FALSE mean "initialized" (S_FALSE = already done);
	// RPC_E_CHANGED_MODE means the thread is COM-initialized in a
	// different apartment, which is still usable for WinRT.
	int uninit = (hr == S_OK);
	if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
		return 0;
	}
	HSTRING cls = NULL;
	int ok = 0;
	if (SUCCEEDED(WindowsCreateString(VAILS_CLS_TOAST_MANAGER, (UINT32)wcslen(VAILS_CLS_TOAST_MANAGER), &cls))) {
		__x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics *mgr = NULL;
		ok = SUCCEEDED(RoGetActivationFactory(cls, &vails_iid_toast_manager, (void **)&mgr)) && mgr != NULL;
		if (mgr) {
			mgr->lpVtbl->Release(mgr);
		}
		WindowsDeleteString(cls);
	}
	if (uninit) {
		RoUninitialize();
	}
	return ok;
}

// vails_toast_emit is the whole activation sequence, with the apartment
// already established and the identity already registered. Split out so
// vails_toast_show has exactly one cleanup path: a C function with a
// `goto done` ladder through six WinRT pointers is where a leak hides.
static int vails_toast_emit(const wchar_t *w_aumid, const wchar_t *w_xml) {
	HSTRING c_mgr = NULL, c_doc = NULL, c_toast = NULL, c_aumid = NULL, c_xml = NULL;
	__x_ABI_CWindows_CUI_CNotifications_CIToastNotificationManagerStatics *mgr = NULL;
	__x_ABI_CWindows_CUI_CNotifications_CIToastNotifier *notifier = NULL;
	__x_ABI_CWindows_CData_CXml_CDom_CIXmlDocument *doc = NULL;
	__x_ABI_CWindows_CData_CXml_CDom_CIXmlDocumentIO *io = NULL;
	__x_ABI_CWindows_CUI_CNotifications_CIToastNotificationFactory *factory = NULL;
	__x_ABI_CWindows_CUI_CNotifications_CIToastNotification *toast = NULL;
	int rc = 0;

	// Every HSTRING is created up front, so no early return can leak one.
	WindowsCreateString(VAILS_CLS_TOAST_MANAGER, (UINT32)wcslen(VAILS_CLS_TOAST_MANAGER), &c_mgr);
	WindowsCreateString(VAILS_CLS_XML_DOCUMENT, (UINT32)wcslen(VAILS_CLS_XML_DOCUMENT), &c_doc);
	WindowsCreateString(VAILS_CLS_TOAST_NOTIFICATION, (UINT32)wcslen(VAILS_CLS_TOAST_NOTIFICATION), &c_toast);
	WindowsCreateString(w_aumid, (UINT32)wcslen(w_aumid), &c_aumid);
	WindowsCreateString(w_xml, (UINT32)wcslen(w_xml), &c_xml);

	// The notifier is created WITH the AUMID, never with the parameterless
	// overload: the shell keys the notification on the id, and the
	// parameterless form is documented as not-for-desktop.
	HRESULT hr = RoGetActivationFactory(c_mgr, &vails_iid_toast_manager, (void **)&mgr);
	if (FAILED(hr) || !mgr) {
		vails_toast_error("RoGetActivationFactory(ToastNotificationManager)", hr);
		rc = -1;
	} else {
		hr = mgr->lpVtbl->CreateToastNotifierWithId(mgr, c_aumid, &notifier);
		if (FAILED(hr) || !notifier) {
			vails_toast_error("CreateToastNotifierWithId", hr);
			rc = -1;
		}
	}
	if (rc == 0) {
		hr = RoGetActivationFactory(c_doc, &vails_iid_xml_document, (void **)&doc);
		if (FAILED(hr) || !doc) {
			vails_toast_error("RoGetActivationFactory(XmlDocument)", hr);
			rc = -1;
		} else {
			// LoadXml lives on IXmlDocumentIO, not IXmlDocument (fact 4).
			hr = doc->lpVtbl->QueryInterface(doc, &vails_iid_xml_io, (void **)&io);
			if (FAILED(hr) || !io) {
				vails_toast_error("IXmlDocument::QueryInterface(IXmlDocumentIO)", hr);
				rc = -1;
			} else {
				hr = io->lpVtbl->LoadXml(io, c_xml);
				if (FAILED(hr)) {
					vails_toast_error("LoadXml (the notification document is malformed)", hr);
					rc = -1;
				}
			}
		}
	}
	if (rc == 0) {
		hr = RoGetActivationFactory(c_toast, &vails_iid_toast_factory, (void **)&factory);
		if (FAILED(hr) || !factory) {
			vails_toast_error("RoGetActivationFactory(ToastNotification)", hr);
			rc = -1;
		} else {
			hr = factory->lpVtbl->CreateToastNotification(factory, doc, &toast);
			if (FAILED(hr) || !toast) {
				vails_toast_error("CreateToastNotification", hr);
				rc = -1;
			}
		}
	}
	if (rc == 0) {
		hr = notifier->lpVtbl->Show(notifier, toast);
		if (FAILED(hr)) {
			vails_toast_error("Show", hr);
			rc = -1;
		}
	}

	if (toast) {
		toast->lpVtbl->Release(toast);
	}
	if (factory) {
		factory->lpVtbl->Release(factory);
	}
	if (io) {
		io->lpVtbl->Release(io);
	}
	if (doc) {
		doc->lpVtbl->Release(doc);
	}
	if (notifier) {
		notifier->lpVtbl->Release(notifier);
	}
	if (mgr) {
		mgr->lpVtbl->Release(mgr);
	}
	if (c_toast) {
		WindowsDeleteString(c_toast);
	}
	if (c_xml) {
		WindowsDeleteString(c_xml);
	}
	if (c_aumid) {
		WindowsDeleteString(c_aumid);
	}
	if (c_doc) {
		WindowsDeleteString(c_doc);
	}
	if (c_mgr) {
		WindowsDeleteString(c_mgr);
	}
	return rc;
}

// vails_toast_show raises one toast. `xml_utf8` is the document V built
// (see services/notification.v toast_xml) and `aumid`/`display` are the
// identity to attribute it to.
//
// Returns 0 once the shell has taken the toast, negative on failure with
// the reason in vails_toast_last_error. There is no "it might have worked"
// return: a toast either reached the notifier or it did not.
int vails_toast_show(const char *aumid, const char *display, const char *xml_utf8) {
	vails_toast_clear_error();

	wchar_t *w_aumid = vails_toast_wide(aumid);
	wchar_t *w_display = vails_toast_wide(display && display[0] ? display : aumid);
	wchar_t *w_xml = vails_toast_wide(xml_utf8);
	if (!w_aumid || !w_display || !w_xml) {
		vails_toast_error_text("out of memory converting the notification text");
		vails_toast_wide_free(w_aumid);
		vails_toast_wide_free(w_display);
		vails_toast_wide_free(w_xml);
		return -1;
	}

	// The apartment. RoInitialize is per-thread and must be paired with
	// RoUninitialize; the webview main thread may already be COM
	// initialized, in which case the call reports the apartment is already
	// set (S_FALSE) or disagrees with it (RPC_E_CHANGED_MODE). Both are
	// usable, and neither may be unbalanced, so `uninit` records whether
	// *we* are the ones who initialized.
	HRESULT hr = RoInitialize(RO_INIT_MULTITHREADED);
	int uninit = (hr == S_OK);
	if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
		vails_toast_error("RoInitialize", hr);
		vails_toast_wide_free(w_aumid);
		vails_toast_wide_free(w_display);
		vails_toast_wide_free(w_xml);
		return -1;
	}

	int rc = 0;
	// Identity first, or the shell will not attribute anything (and the
	// binding has to happen before any UI, which is why it is here rather
	// than lazily inside the notifier call).
	if (vails_register_aumid(w_aumid, w_display) != 0) {
		rc = -1;
	} else {
		rc = vails_toast_emit(w_aumid, w_xml);
	}

	if (uninit) {
		RoUninitialize();
	}
	vails_toast_wide_free(w_xml);
	vails_toast_wide_free(w_display);
	vails_toast_wide_free(w_aumid);
	return rc;
}
