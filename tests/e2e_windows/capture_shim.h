// capture_shim.h — the seven Win32 calls capture.vsh needs, with signatures V
// can actually write.
//
// WHY THIS EXISTS
//
// V's `fn C.` declarations have to match the SDK prototypes exactly, and the GDI
// and USER types are not `void*`: HDC, HWND, HBITMAP, HGDIOBJ and HDC-compatible
// handles are all pointers to opaque structs (`struct HDC__ *` and friends), and
// a `voidptr` parameter is a *different type* to the compiler. So the obvious
//
//     fn C.BitBlt(dest voidptr, ...) int
//
// does not compile. The errors are of the least helpful kind available:
//
//     src.c:3039:5: error: conflicting types for 'BitBlt'; have
//       'int(void *, int, int, int, int, void *, int, int, u32)'
//
// which reads like a V problem and is a C one.
//
// This is the same reason services/list_shim.h and services/drop_shim.h exist
// (AGENTS.md §2: keep raw C out of the V files, and redeclare only the surface
// you actually call). The wrappers take `void*` and plain ints, so the V side
// declares seven functions with types it can name, and every SDK type stays on
// this side of the line where it belongs.
//
// The alternative — pulling all of this into V with an `int` for every handle —
// would compile only because nothing type-checks the handles, and a wrong handle
// is a silent memory corruption rather than a compile error.

#ifndef VAILS_CAPTURE_SHIM_H
#define VAILS_CAPTURE_SHIM_H

#include <windows.h>

// The window enumeration callback. Declared as a plain function pointer rather
// than WNDENUMPROC so the V side can pass its own function without V having to
// spell the SDK's typedef. The signature is the SDK's: return 0 to stop.
typedef int (*vails_enum_proc)(void *hwnd, long long lparam);

// vails_enum_windows walks the top-level windows. `cb` is a V function pointer.
// Returns the number of windows visited, or 0 if the walk failed.
static inline int vails_enum_windows(vails_enum_proc cb, long long lparam) {
	return (int)EnumWindows((WNDENUMPROC)cb, (LPARAM)lparam);
}

// vails_window_visible reports whether the window is on screen. A hidden or
// minimised window has no pixels to copy, and BitBlt of one returns black
// rather than failing — so this is checked before the copy, not after.
static inline int vails_window_visible(void *hwnd) {
	return IsWindowVisible((HWND)hwnd) ? 1 : 0;
}

// vails_window_title writes at most `max` UTF-16 units (including the
// terminator) and returns the character count written, or 0.
//
// The count matters: GetWindowTextW does NOT NUL-terminate a buffer it fills
// exactly, so the V side must bound its slice by the return value rather than
// trusting a terminator to be there. That detail is in the caller's comment too.
static inline int vails_window_title(void *hwnd, unsigned short *buf, int max) {
	return GetWindowTextW((HWND)hwnd, (LPWSTR)buf, max);
}

// vails_window_rect fills `rect` as left, top, right, bottom.
static inline int vails_window_rect(void *hwnd, int *rect) {
	RECT r;
	if (!GetWindowRect((HWND)hwnd, &r)) {
		return 0;
	}
	rect[0] = r.left;
	rect[1] = r.top;
	rect[2] = r.right;
	rect[3] = r.bottom;
	return 1;
}

// vails_raise brings the window up (SW_RESTORE) and asks for the foreground.
// It does NOT wait: the wait is a loop with a check in the V side, because
// "did it actually come up" is a question only the caller can answer.
static inline void vails_raise(void *hwnd, int cmd) {
	ShowWindow((HWND)hwnd, cmd);
	SetForegroundWindow((HWND)hwnd);
}

// vails_foreground returns the window that owns the foreground, so the caller
// can tell whether its raise actually took. A single SetForegroundWindow from a
// background process is routinely refused by the shell, and a screenshot of a
// covered window is a screenshot of a browser.
static inline void *vails_foreground(void) {
	return (void *)GetForegroundWindow();
}

// vails_work_area fills `rect` with the monitor minus the taskbar, or returns 0.
// The clamp matters: a window taller than the work area would otherwise be
// copied off the bottom of the screen, and CopyFromScreen/BitBlt of a region
// that runs off the desktop leaves a strip of the taskbar — with the user's
// installed apps in it — in the picture. Every screenshot in this directory was
// once purged from git history for exactly that.
static inline int vails_work_area(int *rect) {
	RECT r;
	if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &r, 0)) {
		return 0;
	}
	rect[0] = r.left;
	rect[1] = r.top;
	rect[2] = r.right;
	rect[3] = r.bottom;
	return 1;
}

// vails_sleep is here rather than in V because the V side has no portable sleep
// and `time.sleep` would be an import for one call.
static inline void vails_sleep(unsigned int ms) {
	Sleep(ms);
}

// vails_capture_screen copies the screen rectangle (x, y, w, h) into `out` as
// top-down BGRA, and returns 1 on success.
//
// The whole DC/DIB/BitBlt/GetDIBits sequence is on this side of the line for
// three reasons, all of them practical:
//
//   - HDC/HBITMAP/HGDIOBJ are SDK-only types (see the header comment).
//   - The DIB must be created with a NEGATIVE height to be top-down, which means
//     row 0 is the top row and no flip is needed afterwards. Doing that in V
//     would mean a second pass over every pixel.
//   - `out` must be `w * h * 4` bytes and this function trusts the caller's
//     arithmetic; the V side owns that buffer and therefore owns the size.
//
// GetDC(NULL) is the screen DC rather than the window's own: a window can hang
// partly offscreen, and the pixels that matter are the ones on screen.
static inline int vails_capture_screen(int x, int y, int w, int h,
                                       unsigned char *out) {
	if (w <= 0 || h <= 0 || out == 0) {
		return 0;
	}
	HDC screen = GetDC(NULL);
	if (screen == 0) {
		return 0;
	}
	int ok = 0;
	HDC mem = CreateCompatibleDC(screen);
	if (mem == 0) {
		ReleaseDC(NULL, screen);
		return 0;
	}
	BITMAPINFO info;
	ZeroMemory(&info, sizeof(info));
	info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
	info.bmiHeader.biWidth = w;
	// Negative height: top-down rows.
	info.bmiHeader.biHeight = -h;
	info.bmiHeader.biPlanes = 1;
	info.bmiHeader.biBitCount = 32;
	info.bmiHeader.biCompression = BI_RGB;
	void *bits = 0;
	HBITMAP dib = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, 0, 0);
	if (dib != 0) {
		HGDIOBJ old = SelectObject(mem, dib);
		if (BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY) != 0) {
			// The DIB section is updated asynchronously; reading it without this
			// flush is the classic way to get the top half of one frame and the
			// bottom half of another.
			GdiFlush();
			memcpy(out, bits, (size_t)w * (size_t)h * 4);
			ok = 1;
		}
		SelectObject(mem, old);
		DeleteObject(dib);
	}
	DeleteDC(mem);
	ReleaseDC(NULL, screen);
	return ok;
}

#endif
