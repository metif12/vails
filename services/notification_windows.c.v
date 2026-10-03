// notification_windows.c.v - Windows backend of the notification service: a
// real WinRT toast (Windows.UI.Notifications). Compiled on Windows ONLY (V
// `_windows` suffix rule).
//
// This file used to raise a shell balloon - `Shell_NotifyIconW` with
// `NIF_INFO`, a tray icon, and a V worker to delete it again. It now hands a
// document to the shell's toast stack and is a thin glue layer over
// toast_shim.h; ADR-0018 records why, and the short version is that a
// balloon is not a Windows 10/11 notification: Windows 11 routes it to the
// Action Center under the name of the .exe, it needs a tray icon that
// outlives the message, and it cannot carry an app name or icon.
//
// What is left here is deliberately only policy: which strings go into the
// document (services/notification.v builds it, in pure V, where it is
// unit-tested) and how the shim's return code becomes a V error. The WinRT
// stack, the HSTRING plumbing and the AppUserModelID registration are all
// behind the shim's C ABI, the same way dialog's COM is.
//
// No lifetime worker any more. A toast is owned by the shell from the
// moment Show returns, so there is nothing for the app to clean up - which
// is the whole reason the balloon needed the spawn.
module services

import webview

#insert "@VMODROOT/services/toast_shim.h"

// runtimeobject: RoInitialize / RoGetActivationFactory / WindowsCreateString
// shell32:     SetCurrentProcessExplicitAppUserModelID
// ole32:       the COM apartment the WinRT activation runs in
// advapi32:    the HKCU AppUserModelId registration
#flag windows -lruntimeobject -lshell32 -lole32 -ladvapi32

fn C.vails_toast_show(aumid &char, display &char, xml &char) int
fn C.vails_toast_last_error() &char
fn C.vails_toast_available() int

// is_supported_native answers "does this build have a backend", which is a
// compile-time fact: the toast code is linked in, so yes.
//
// It is deliberately NOT the same question as vails_toast_available, which
// asks whether the *machine* has the WinRT runtime. An app image without the
// WinRT component DLLs compiles and links this file perfectly and still
// cannot raise a toast, and pretending otherwise is precisely what
// `is_supported` is supposed to prevent.
fn is_supported_native() bool {
	return true
}

// toast_available reports whether this machine can activate the toast
// classes right now. Not exposed as a command: `is_supported` is the
// frontend-facing question, and a runtime probe behind it would make a
// compile-time fact impure (and cost a native call per frontend check).
// `vails doctor` is where a machine-specific answer belongs.
pub fn toast_available() bool {
	unsafe {
		return C.vails_toast_available() == 1
	}
}

// notify_native raises one toast. The document is built in pure V
// (toast_xml) and the identity comes from the app's config, so this is
// three string arguments and an error mapping.
//
// There is no `require_parent` here any more, and that is a real change: a
// balloon needed an HWND because a tray icon is owned by a window, and a
// toast is not. A service that no longer needs the window should not keep
// demanding it, or a headless app could never notify.
fn notify_native(_ctx webview.Ctx, id AppIdentity, opts NotificationOptions) !string {
	if id.id == '' {
		// Fail rather than guess: an app with no AppUserModelID gets a
		// toast the shell will not attribute, which is the silent failure
		// this service is supposed to avoid existing.
		return error('notification.notify: no app identity. Set bundle.identifier ' +
			'in vails.json - it is the Windows AppUserModelID the toast is ' +
			'attributed to (ADR-0018)')
	}
	xml := toast_xml(opts)
	unsafe {
		if C.vails_toast_show(id.id.str, id.display_name.str, xml.str) == 0 {
			return backend_toast
		}
		reason := C.vails_toast_last_error().vstring()
		return error('notification.notify: the Windows toast could not be shown (' +
			reason + '). Is the notification area enabled for this app, and does ' +
			'bundle.identifier ("' + id.id + '") pass validate_identifier?')
	}
}
