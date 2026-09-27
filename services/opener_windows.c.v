// opener_windows.c.v - Windows backend of the opener service: one
// ShellExecuteW call, which asks the shell for whatever the user registered
// as the default handler. Compiled on Windows ONLY (V `_windows` suffix
// rule).
//
// The `with` form is the documented ShellExecute convention: verb "open",
// file = the application, parameters = the document. Both forms therefore fit
// one call.
//
// No COM here - the shell owns the launch, and ShellExecuteW is the flat C
// entry point to it (this is what keeps the Windows side of this service
// shim-free, unlike dialog).
module services

#include <windows.h>
#include <shellapi.h>
#flag windows -lshell32 -luser32

fn C.ShellExecuteW(hwnd voidptr, verb &u16, file &u16, params &u16, dir &u16, show int) voidptr

// SW_SHOWNORMAL, and ShellExecute's "> 32 means success" contract.
const sw_shownormal = 1
const shell_ok_min = 32

// launch_error_text names ShellExecute's failure codes. The numbers come
// straight from the SE_ERR_* set; an unnamed code is reported as the number
// so a frontend can log something actionable.
fn launch_error_text(code int) string {
	return match code {
		0 { 'the shell refused the request with no reason' }
		2 { 'the file was not found' }
		3 { 'the path was not found' }
		4 { 'too many files were open' }
		5 { 'access was denied' }
		8 { 'out of memory' }
		11 { 'the format of the request was invalid' }
		29 { 'the print spooler is not running' }
		30 { 'no application is registered for this file type' }
		31 { 'no application is registered for this file type' }
		else { 'the shell returned error ' + code.str() }
	}
}

// shell_open is the one call both commands use. `app` empty means "the
// default handler"; otherwise `app` is the program and `target` its
// parameter.
fn shell_open(app string, target string) ! {
	verb := 'open'.to_wide()
	handle := unsafe {
		C.ShellExecuteW(unsafe { nil }, verb, app.to_wide(),
			target.to_wide(), unsafe { nil }, sw_shownormal)
	}
	code := int(u32(handle))
	if code > shell_ok_min {
		return
	}
	return error('opener: ' + launch_error_text(code))
}

fn open_url_native(url string) ! {
	shell_open('', url)!
}

fn open_path_native(path string, with string) ! {
	if with == '' {
		shell_open('', path)!
	} else {
		shell_open(with, path)!
	}
}
