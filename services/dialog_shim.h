// dialog_shim.h - Win32/COM file + message dialogs behind one C ABI.
//
// Vails needs a native file picker and V has no COM projection
// (ADR-0002), so the COM dance lives in C and V sees three functions with
// plain UTF-8 strings. Same pattern as webview_shim.h: no extra -I flag,
// included via `#insert "@VMODROOT/services/dialog_shim.h"`.
//
// ABI contract (UTF-8 in and out):
//   vails_dialog_message     -> IDOK / IDCANCEL / IDYES / IDNO, -1 on error
//   vails_dialog_open/save   -> 0 = canceled, n > 0 = n paths written to
//                               out as NUL-separated strings, -1 = error,
//                               -2 = the selection did not fit the buffer
//   vails_dialog_last_error  -> message for the last -1, never NULL
//
// The filter string follows the Windows convention
// "Images (*.png;*.jpg)|Text (*.txt)": a display name plus a
// parenthesized pattern list, segments separated by '|'.
//
// mingw note: the Common Item Dialog vtbls are per-interface, so reading a
// selection differs (IFileOpenDialog::GetResults vs IFileSaveDialog::GetResult)
// and stays in the callers; everything configurable lives on the IFileDialog
// base vtbl and is set by vails_config_dialog. COMDLG_FILTERSPEC in the MSYS2
// headers is {pszName, pszSpec} without cchName - a different SDK may differ,
// keep this file in sync when the toolchain changes.
#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

// GUIDs copied verbatim from the installed MSYS2 headers (shobjidl.h) so
// the shim needs no -luuid. SIGDN_FILESYSPATH is the same header's
// 0x80058000.
static const GUID vails_iid_file_open = {0xd57c7288, 0xd4ad, 0x4768,
                                         {0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9,
                                          0x60}};
static const GUID vails_iid_file_save = {0x84bccd23, 0x5fde, 0x4cdb,
                                         {0xae, 0xa4, 0xaf, 0x64, 0xb8, 0x3d, 0x78,
                                          0xab}};
static const GUID vails_iid_shell_item = {0x43826d1e, 0xe718, 0x42ee,
                                          {0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b,
                                           0xfe}};
static const GUID vails_clsid_file_open = {0xdc1c5a9c, 0xe88a, 0x4dde,
                                           {0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae,
                                            0xf7}};
static const GUID vails_clsid_file_save = {0xc0b4e2f3, 0xba21, 0x4773,
                                           {0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb,
                                            0x8b}};
static const int vails_sigdn_filesyspath = (int)0x80058000;

// Last error slot. Static and one-dialog deep, which is all the V side
// needs: handlers run one at a time on the main thread (ADR-0014).
static char vails_dialog_err[512];

static const char *vails_dialog_last_error(void) {
	return vails_dialog_err[0] ? vails_dialog_err : "unknown dialog error";
}

static void vails_dialog_set_error(const char *msg) {
	int i = 0;
	for (; msg && msg[i] && i < (int)sizeof(vails_dialog_err) - 1; i++) {
		vails_dialog_err[i] = msg[i];
	}
	vails_dialog_err[i] = 0;
}

static void vails_dialog_clear_error(void) { vails_dialog_err[0] = 0; }

static void vails_write_hresult(const char *what, HRESULT hr) {
	char msg[160];
	snprintf(msg, sizeof(msg), "%s failed (hr=0x%08lx)", what, (unsigned long)hr);
	vails_dialog_set_error(msg);
}

// vails_utf8_to_wide converts UTF-8 to a malloc'd UTF-16 string; NULL for
// NULL/empty input. The caller frees with vails_wide_free.
static wchar_t *vails_utf8_to_wide(const char *s) {
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

static void vails_wide_free(wchar_t *w) {
	if (w) {
		free(w);
	}
}

// vails_copy_utf8 appends a UTF-8 copy of w to out (including its NUL).
// Returns 0 when it would not fit.
static int vails_copy_utf8(const wchar_t *w, char *out, int out_len, int *at) {
	if (!w) {
		return 1;
	}
	int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
	if (n <= 0) {
		return 0;
	}
	if (*at + n > out_len) {
		return 0;
	}
	if (WideCharToMultiByte(CP_UTF8, 0, w, -1, out + *at, n, NULL, NULL) <= 0) {
		return 0;
	}
	*at += n; // includes the terminating NUL
	return 1;
}

static int vails_is_dir(const wchar_t *path) {
	if (!path || !path[0]) {
		return 0;
	}
	DWORD attrs = GetFileAttributesW(path);
	return (attrs != INVALID_FILE_ATTRIBUTES) && (attrs & FILE_ATTRIBUTE_DIRECTORY) ? 1
	                                                                              : 0;
}

// vails_message_flags maps 0=ok, 1=okcancel, 2=yesnocancel to MessageBox
// flags. MB_TOPMOST keeps the box above the webview window it is parented
// to (the webview owns no always-on-top window of its own).
static UINT vails_message_flags(int buttons) {
	UINT base = MB_OK | MB_SETFOREGROUND | MB_TOPMOST;
	if (buttons == 1) {
		return base | MB_OKCANCEL;
	}
	if (buttons == 2) {
		return base | MB_YESNOCANCEL;
	}
	return base;
}

static int vails_dialog_message(void *hwnd, const char *title, const char *message,
                                int buttons) {
	wchar_t *wtitle = vails_utf8_to_wide(title);
	wchar_t *wtext = vails_utf8_to_wide(message);
	int rc = (int)MessageBoxW((HWND)hwnd, wtext ? wtext : L"", wtitle ? wtitle : L"",
	                          vails_message_flags(buttons));
	vails_wide_free(wtitle);
	vails_wide_free(wtext);
	return rc;
}

typedef struct {
	COMDLG_FILTERSPEC *specs;
	int count;
	wchar_t **names;
	wchar_t **pats;
} vails_filter_set;

// vails_build_filter_set parses "Name (*.a;*.b)|Name2 (*.c)" into a
// COMDLG_FILTERSPEC array. Returns 1 on success (count may be 0 for an
// empty string: the dialog then shows every file, which the V side never
// produces because it validates the syntax first), 0 on failure.
static int vails_build_filter_set(const char *filters, vails_filter_set *set) {
	set->specs = NULL;
	set->count = 0;
	set->names = NULL;
	set->pats = NULL;
	if (!filters || !filters[0]) {
		return 1;
	}
	int count = 1;
	for (const char *p = filters; *p; p++) {
		if (*p == '|') {
			count++;
		}
	}
	COMDLG_FILTERSPEC *arr = (COMDLG_FILTERSPEC *)calloc((size_t)count, sizeof(*arr));
	wchar_t **names = (wchar_t **)calloc((size_t)count, sizeof(*names));
	wchar_t **pats = (wchar_t **)calloc((size_t)count, sizeof(*pats));
	if (!arr || !names || !pats) {
		free(arr);
		free(names);
		free(pats);
		vails_dialog_set_error("out of memory building file filters");
		return 0;
	}
	int i = 0;
	const char *seg = filters;
	while (seg && i < count) {
		const char *bar = strchr(seg, '|');
		int seg_len = bar ? (int)(bar - seg) : (int)strlen(seg);
		int name_len = seg_len;
		const char *open_p = memchr(seg, '(', (size_t)seg_len);
		if (open_p) {
			name_len = (int)(open_p - seg);
		}
		if (name_len > 127) {
			name_len = 127;
		}
		char name[128];
		memcpy(name, seg, (size_t)name_len);
		name[name_len] = 0;
		char pat[256];
		pat[0] = 0;
		if (open_p) {
			// the pattern is everything between the first '(' and the
			// last ')' (memchr for the open, manual scan for the close:
			// memrchr is a GNU extension)
			int tail = seg_len - name_len - 1;
			int pat_len = tail;
			for (int k = tail - 1; k >= 0; k--) {
				if (open_p[1 + k] == ')') {
					pat_len = k;
					break;
				}
			}
			if (pat_len > 255) {
				pat_len = 255;
			}
			if (pat_len > 0) {
				memcpy(pat, open_p + 1, (size_t)pat_len);
			}
			pat[pat_len] = 0;
		}
		names[i] = vails_utf8_to_wide(name);
		pats[i] = vails_utf8_to_wide(pat[0] ? pat : "*.*");
		if (!names[i] || !pats[i]) {
			vails_dialog_set_error("out of memory building file filters");
			break;
		}
		arr[i].pszName = names[i];
		arr[i].pszSpec = pats[i];
		i++;
		seg = bar ? bar + 1 : NULL;
	}
	set->specs = arr;
	set->count = i;
	set->names = names;
	set->pats = pats;
	return 1;
}

static void vails_free_filter_set(vails_filter_set *set) {
	for (int i = 0; i < set->count; i++) {
		vails_wide_free(set->names[i]);
		vails_wide_free(set->pats[i]);
	}
	free(set->names);
	free(set->pats);
	free(set->specs);
	set->specs = NULL;
	set->names = NULL;
	set->pats = NULL;
	set->count = 0;
}

// vails_config_dialog applies title, filters, options and the folder/file
// hint to an open or save dialog. It takes IFileDialog*, the base of both
// interfaces: every member it calls lives on the base vtbl (verified in
// the MSYS2 headers), and the vtbl is a single structure, so the cast is
// ABI-safe. Reading the selection differs per interface (GetResults vs
// GetResult), which is why that stays in the callers.
//
// Hints are advisory: a hint that cannot be applied must not fail the
// dialog.
static void vails_config_dialog(IFileDialog *dlg, int is_save, int multi,
                                const char *title, const char *filters,
                                const char *default_path, const char *default_name) {
	wchar_t *w_title = vails_utf8_to_wide(title);
	wchar_t *w_path = vails_utf8_to_wide(default_path);
	wchar_t *w_name = vails_utf8_to_wide(default_name);
	if (w_title) {
		dlg->lpVtbl->SetTitle(dlg, w_title);
	}
	if (filters && filters[0]) {
		vails_filter_set fs;
		if (vails_build_filter_set(filters, &fs) && fs.count > 0) {
			dlg->lpVtbl->SetFileTypes(dlg, (UINT)fs.count, fs.specs);
			dlg->lpVtbl->SetFileTypeIndex(dlg, 0);
		}
		vails_free_filter_set(&fs);
	}
	FILEOPENDIALOGOPTIONS opts = FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
	if (is_save) {
		opts |= FOS_OVERWRITEPROMPT;
	} else {
		opts |= FOS_FILEMUSTEXIST;
		if (multi) {
			opts |= FOS_ALLOWMULTISELECT;
		}
	}
	dlg->lpVtbl->SetOptions(dlg, opts);
	if (vails_is_dir(w_path)) {
		IShellItem *item = NULL;
		if (SUCCEEDED(SHCreateItemFromParsingName(w_path, NULL, &vails_iid_shell_item,
		                                          (void **)&item))) {
			dlg->lpVtbl->SetFolder(dlg, item);
			item->lpVtbl->Release(item);
		}
		if (is_save && w_name) {
			dlg->lpVtbl->SetFileName(dlg, w_name);
		}
	} else if (w_path) {
		dlg->lpVtbl->SetFileName(dlg, w_path);
	} else if (is_save && w_name) {
		dlg->lpVtbl->SetFileName(dlg, w_name);
	}
	vails_wide_free(w_title);
	vails_wide_free(w_path);
	vails_wide_free(w_name);
}

// vails_write_one_path appends one CoTaskMem path as NUL-terminated UTF-8.
// Returns 0 when it does not fit or the conversion failed.
static int vails_write_one_path(wchar_t *wpath, char *out, int out_len, int *at) {
	if (!vails_copy_utf8(wpath, out, out_len, at)) {
		vails_dialog_set_error("selected path does not fit the output buffer");
		return 0;
	}
	return 1;
}

static int vails_dialog_open(void *hwnd, const char *title, const char *filters,
                             const char *default_path, int multi, char *out,
                             int out_len) {
	vails_dialog_clear_error();
	// The common item dialog needs an STA. Handlers run on the main thread
	// (ADR-0010/0014), which is the thread that first touches COM here,
	// so this is the app's apartment; S_FALSE only means "already done".
	HRESULT co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	if (FAILED(co)) {
		vails_write_hresult("CoInitializeEx", co);
		return -1;
	}
	IFileOpenDialog *dlg = NULL;
	HRESULT hr = CoCreateInstance(&vails_clsid_file_open, NULL, CLSCTX_INPROC_SERVER,
	                              &vails_iid_file_open, (void **)&dlg);
	if (FAILED(hr) || !dlg) {
		vails_write_hresult("CoCreateInstance(FileOpenDialog)", hr);
		CoUninitialize();
		return -1;
	}
	vails_config_dialog((IFileDialog *)dlg, 0, multi, title, filters, default_path, NULL);
	hr = dlg->lpVtbl->Show(dlg, (HWND)hwnd);
	int rc;
	if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
		rc = 0; // dismissed: a normal result, not an error
	} else if (FAILED(hr)) {
		vails_write_hresult("IFileDialog::Show", hr);
		rc = -1;
	} else {
		// IShellItemArray has no GetDisplayName in the mingw C vtbl, so
		// the selection is walked item by item (also the only way to
		// report one path per entry for a multi-select).
		IShellItemArray *items = NULL;
		DWORD count = 0;
		hr = dlg->lpVtbl->GetResults(dlg, &items);
		if (FAILED(hr) || !items) {
			vails_write_hresult("IFileOpenDialog::GetResults", hr);
			rc = -1;
		} else if (FAILED(items->lpVtbl->GetCount(items, &count))) {
			items->lpVtbl->Release(items);
			vails_write_hresult("IShellItemArray::GetCount", E_FAIL);
			rc = -1;
		} else {
			int at = 0;
			rc = 0;
			for (DWORD k = 0; k < count; k++) {
				IShellItem *item = NULL;
				wchar_t *wpath = NULL;
				if (FAILED(items->lpVtbl->GetItemAt(items, k, &item)) || !item) {
					continue;
				}
				if (SUCCEEDED(item->lpVtbl->GetDisplayName(item, vails_sigdn_filesyspath,
				                                            &wpath)) &&
				    wpath) {
					if (!vails_write_one_path(wpath, out, out_len, &at)) {
						CoTaskMemFree(wpath);
						item->lpVtbl->Release(item);
						rc = -2;
						break;
					}
					rc++;
					CoTaskMemFree(wpath);
				}
				item->lpVtbl->Release(item);
			}
			items->lpVtbl->Release(items);
		}
	}
	dlg->lpVtbl->Release(dlg);
	CoUninitialize();
	return rc;
}

static int vails_dialog_save(void *hwnd, const char *title, const char *filters,
                             const char *default_path, const char *default_name,
                             char *out, int out_len) {
	vails_dialog_clear_error();
	HRESULT co = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	if (FAILED(co)) {
		vails_write_hresult("CoInitializeEx", co);
		return -1;
	}
	IFileSaveDialog *dlg = NULL;
	HRESULT hr = CoCreateInstance(&vails_clsid_file_save, NULL, CLSCTX_INPROC_SERVER,
	                              &vails_iid_file_save, (void **)&dlg);
	if (FAILED(hr) || !dlg) {
		vails_write_hresult("CoCreateInstance(FileSaveDialog)", hr);
		CoUninitialize();
		return -1;
	}
	vails_config_dialog((IFileDialog *)dlg, 1, 0, title, filters, default_path,
	                    default_name);
	hr = dlg->lpVtbl->Show(dlg, (HWND)hwnd);
	int rc;
	if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
		rc = 0;
	} else if (FAILED(hr)) {
		vails_write_hresult("IFileDialog::Show", hr);
		rc = -1;
	} else {
		IShellItem *item = NULL;
		hr = dlg->lpVtbl->GetResult(dlg, &item);
		if (FAILED(hr) || !item) {
			vails_write_hresult("IFileSaveDialog::GetResult", hr);
			rc = -1;
		} else {
			wchar_t *wpath = NULL;
			hr = item->lpVtbl->GetDisplayName(item, vails_sigdn_filesyspath, &wpath);
			item->lpVtbl->Release(item);
			if (FAILED(hr) || !wpath) {
				vails_write_hresult("IShellItem::GetDisplayName", hr);
				rc = -1;
			} else {
				int at = 0;
				rc = vails_write_one_path(wpath, out, out_len, &at) ? 1 : -2;
				CoTaskMemFree(wpath);
			}
		}
	}
	dlg->lpVtbl->Release(dlg);
	CoUninitialize();
	return rc;
}
