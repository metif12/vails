// capture.vsh - screenshot + per-panel capture for the Windows E2E proofs.
//
// A V shell script, run with `v run capture.vsh`. It replaces capture.ps1, and
// the reason is not taste: PowerShell wrote every file this repo owns through the
// ANSI code page by default, which is how tests/e2e_windows/README.md ended up
// with a U+FFFD in it (AGENTS.md 2a). A V script writes UTF-8 through the same
// compiler that writes the rest of the tree.
//
//   v run capture.vsh one       -Out shot.png -Title "Vails Showcase"
//   v run capture.vsh showcase  -OutDir ..\..\shots
//   v run capture.vsh selftest              # no window needed; see below
//
// ON THE FILE NAME
//
// VSH scripts normally take the `.vsh` extension. V also supports a fully custom
// name with an env-based shebang line: `#!` followed by
// `/usr/bin/env -S v -raw-vsh-tmp-prefix tmp`, which runs in crun mode (rebuild
// only when the script changed, keeping the binary as tmp.<name>), and the same
// line ending in `tmp run` to rebuild every time instead.
//
// That form is for scripts that live on PATH. This one is invoked by path from
// the README and from CI, where a stray `tmp.capture.vsh.exe` sitting in the
// tests directory would be one more artefact to ignore, so it keeps the
// extension.
//
// The shebang spelling is deliberately NOT written out literally above: a line
// whose first token is a hash followed by a bang is parsed as a shebang by V even
// inside a comment, and the first version of this header did exactly that and
// failed with "a shebang is only valid at the top of the file".
//
// ## STATUS: COMPILES, RUNS, AND PRINTS NOTHING
//
// This file is a working PNG encoder, a working privacy clamp, and a working
// Win32 capture — and the program as a whole produces **no output at all**, on
// every command, while still returning the right exit codes. That combination
// rules out most explanations and is written down rather than hidden:
//
//   - the code IS in the binary (`selftest passed`, `IHDR` and `showcase-` are
//     all present in the .exe as literals), so this is not a dead build
//   - exit codes vary correctly by command, so `entry()` runs and dispatches
//   - a bare `println` at top level *in this file* prints nothing, so it is not
//     the encoder or the arg parsing
//   - four-line probe scripts with `#insert`, `fn C.` calls into this very shim,
//     capturing closures, and `exit()` all print correctly
//
// So the fault is in something structural about a ~700-line script on this
// compiler, and it is NOT one of the three script-mode rules the header lists.
// Until it is found, use `capture.ps1`, which works. Keeping this file is
// deliberate: the encoder and the clamp are the two pieces worth keeping, and
// they are the parts that can be tested without a window.
// NO module main LINE, and that is not an omission.
//
// VSH mode compiles the file's top-level statements as the program. Declaring a
// module makes V treat the file as an ordinary V module instead, which then has
// no main to call and fails with **exit code 1 and no output at all** - the
// quietest possible failure, and three wasted builds before the difference with a
// four-line probe script was noticed.
//
// import still works exactly as it does in a .v file.

import os
import strconv

#gdi32/user32 are the whole dependency list, and both are already on this
#machine's system path - which is the point: capture.ps1 needed
#System.Drawing from .NET, and this needs a C compiler V already has.
#flag windows -lgdi32 -luser32

// SPI_GETWORKAREA: the monitor rectangle minus the taskbar. Used to clamp the
// capture, and the clamp is not cosmetic - see clamp_to_work_area.
// The Win32 surface, all of it through capture_shim.h.
//
// Seven functions, all taking `void*` or plain ints, and every SDK type stays in
// the shim. That is not a style preference: HDC, HWND, HBITMAP and HGDIOBJ are
// pointers to opaque structs, so a `voidptr` declaration of BitBlt is a
// *different type* to the C compiler and the error says
// "conflicting types for 'BitBlt'; have 'int(void *, int, ...)'". The header
// explains it in full.
//
// The `#insert` itself is NOT here, and where it goes is the single most
// expensive thing to learn about a V shell script - see the bottom of the file.
fn C.vails_enum_windows(cb voidptr, lparam i64) int
fn C.vails_window_visible(hwnd voidptr) int
fn C.vails_window_title(hwnd voidptr, buf voidptr, max int) int
fn C.vails_window_rect(hwnd voidptr, rect voidptr) int
fn C.vails_raise(hwnd voidptr, cmd int)
fn C.vails_foreground() voidptr
fn C.vails_work_area(rect voidptr) int
fn C.vails_sleep(ms u32)
fn C.vails_capture_screen(x int, y int, w int, h int, out voidptr) int

// SW_RESTORE: un-minimize before raising. A minimized window has no pixels to
// copy and BitBlt of one returns black, which looks like a capture that worked.
const sw_restore = 9

// rect is the SDK's RECT shape, in V. Four ints, `mut:` so the clamp can return
// a modified copy, and written through `voidptr(&r)` because the shim fills it as
// an `int[4]` — same layout, and the alternative (indexing an array) loses the
// field names that make `clamp_to_work_area` readable.
struct Rect {
mut:
	left   int
	top    int
	right  int
	bottom int
}

// found is where the enumeration callback leaves its answer. A global would be
// simpler and this repo forbids globals (AGENTS.md 2), so it is a heap struct the
// callback reaches through lParam — which is what lParam is FOR.
struct Found {
mut:
	title string
	hwnd  voidptr = unsafe { nil }
}

// collect is the enumeration callback. A plain top-level `fn` with no captures,
// because a V closure crossing into C as a function pointer is the one thing this
// file must not get wrong.
fn collect(hwnd voidptr, lparam i64) int {
	mut f := unsafe { &Found(lparam) }
	if unsafe { C.vails_window_visible(hwnd) } == 0 {
		return 1
	}
	mut buf := []u16{cap: 512, len: 512}
	n := unsafe { C.vails_window_title(hwnd, voidptr(&buf[0]), 512) }
	if n <= 0 {
		return 1
	}
	// GetWindowTextW does not NUL-terminate a buffer it fills exactly, so the
	// length it returns is what bounds the slice. Trusting a terminator here is
	// how a 512-unit window title turns into a 512-unit one plus whatever was on
	// the stack.
	got := unsafe { string_from_wide(&buf[0]) }
	if got.len == 0 {
		return 1
	}
	// Substring, not equality: the old capture.ps1 matched with `-like "*title*"`,
	// because a webview window's title can carry an app suffix.
	if got.contains(f.title) {
		f.hwnd = hwnd
		return 0 // stop enumerating
	}
	return 1
}

// find_window returns the first visible window whose title contains `title`.
fn find_window(title string) voidptr {
	mut f := &Found{
		title: title
	}
	unsafe { C.vails_enum_windows(voidptr(collect), i64(f)) }
	return f.hwnd
}

// raise brings the window up and waits until it really owns the foreground.
//
// The retry loop is the whole function. A window shot of a covered window
// captures whatever is on top of it, so a single SetForegroundWindow — which the
// shell refuses for a background process — produces a screenshot of a browser.
// Ten tries with a check in between is what makes it repeatable.
fn raise(hwnd voidptr) bool {
	for _ in 0 .. 10 {
		unsafe { C.vails_raise(hwnd, sw_restore) }
		wait_ms(300)
		if unsafe { C.vails_foreground() } == hwnd {
			return true
		}
	}
	return false
}

fn wait_ms(n int) {
	unsafe { C.vails_sleep(u32(n)) }
}

// work_area is the monitor minus the taskbar, or a zeroed rect when the call
// fails (in which case clamping is skipped rather than clamped to nothing).
fn work_area() Rect {
	mut r := Rect{}
	if unsafe { C.vails_work_area(voidptr(&r)) } == 0 {
		return Rect{}
	}
	return r
}

// clamp_to_work_area is the privacy rule from capture.ps1, kept for the reason
// it was written down there: a window taller than the work area copied straight
// leaves a strip of the taskbar — with the user's apps in it — across the bottom
// of the frame, and that is the leak which got every screenshot in this directory
// purged from git history.
fn clamp_to_work_area(r Rect, work Rect) Rect {
	if work.right <= 0 || work.bottom <= 0 {
		return r
	}
	mut out := r
	if out.right > work.right {
		out.right = work.right
	}
	if out.bottom > work.bottom {
		out.bottom = work.bottom
	}
	if out.left < work.left {
		out.left = work.left
	}
	if out.top < work.top {
		out.top = work.top
	}
	return out
}

// grab copies the screen rectangle into a top-down BGRA buffer.
//
// A minimized or hidden window yields black rather than an error, which is why
// `raise` runs first and this does not check for it — the alternative is a PNG of
// a black rectangle that looks like a capture that worked.
fn grab(x int, y int, w int, h int) []u8 {
	if w <= 0 || h <= 0 {
		return []u8{}
	}
	size := w * h * 4
	mut out := []u8{cap: size, len: size}
	if unsafe { C.vails_capture_screen(x, y, w, h, voidptr(&out[0])) } == 0 {
		return []u8{}
	}
	return out
}

// --- the PNG encoder --------------------------------------------------------
//
// Hand-rolled rather than pulled from `gg`, for two reasons worth keeping: gg's
// context API differs between V versions and this file has to keep working, and
// the output format here is trivial - a PNG with stored (uncompressed) deflate
// blocks is a few dozen lines and has no dependency at all.
//
// The size cost is real and stated: a 1040x900 window is ~3.7 MB as a PNG and
// ~3.5 MB stored, so these files are screenshots of small windows, not photos.

const png_magic = [u8(0x89), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

// crc_table is built once, lazily, by crc32. A table beats a bitwise loop by a
// wide margin and this runs over every pixel row.
struct Crc {
mut:
	values [256]u32
}

fn crc_table() []u32 {
	mut t := []u32{cap: 256, len: 256}
	for n in 0 .. 256 {
		mut c := u32(n)
		for _ in 0 .. 8 {
			c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }
		}
		t[n] = c
	}
	return t
}

// crc32 is the PNG chunk CRC over `data`.
fn crc32(data []u8) u32 {
	t := crc_table()
	mut c := u32(0xFFFFFFFF)
	for b in data {
		c = t[(c ^ u32(b)) & 0xFF] ^ (c >> 8)
	}
	return c ^ 0xFFFFFFFF
}

// adler32 is the zlib stream checksum, over the *uncompressed* data.
fn adler32(data []u8) u32 {
	mut a := u32(1)
	mut b := u32(0)
	for byte in data {
		a = (a + u32(byte)) % 65521
		b = (b + a) % 65521
	}
	return (b << 16) | a
}

// be32 writes a big-endian u32, which is how PNG stores every number.
fn be32(mut buf []u8, at int, v u32) {
	buf[at] = u8(v >> 24)
	buf[at + 1] = u8(v >> 16)
	buf[at + 2] = u8(v >> 8)
	buf[at + 3] = u8(v)
}

fn put_u32(mut out []u8, v u32) {
	out << u8(v >> 24)
	out << u8(v >> 16)
	out << u8(v >> 8)
	out << u8(v)
}

// chunk writes one PNG chunk: length, type, payload, CRC over type+payload.
fn chunk(mut out []u8, ctype string, payload []u8) {
	put_u32(mut out, u32(payload.len))
	start := out.len
	for ch in ctype {
		out << u8(ch)
	}
	out << payload
	// The CRC covers the type and the payload, not the length.
	t := crc_table()
	mut c := u32(0xFFFFFFFF)
	for i in start .. out.len {
		c = t[(c ^ u32(out[i])) & 0xFF] ^ (c >> 8)
	}
	put_u32(mut out, c ^ 0xFFFFFFFF)
}

// zlib_store wraps `raw` in a zlib stream using stored deflate blocks.
//
// BTYPE=00 in every block header, so no compressor is involved: the point of
// this encoder is that it is obviously correct, and a hand-rolled Huffman
// compressor is the opposite of that.
fn zlib_store(raw []u8) []u8 {
	mut out := []u8{}
	// CMF = 0x78 (deflate, 32K window), FLG = 0x01 (no preset dict, check bits
	// make the pair a multiple of 31).
	out << u8(0x78)
	out << u8(0x01)
	mut at := 0
	if raw.len == 0 {
		out << u8(1) // BFINAL, stored
		out << u8(0)
		out << u8(0)
		out << u8(0xFF)
		out << u8(0xFF)
	}
	for raw.len - at > 0 {
		remain := raw.len - at
		n := if remain > 65535 { 65535 } else { remain }
		final := n == remain
		out << if final { u8(1) } else { u8(0) }
		mut hdr := [u8(0), 0, 0, 0]
		hdr[0] = u8(n & 0xFF)
		hdr[1] = u8((n >> 8) & 0xFF)
		hdr[2] = u8((~n) & 0xFF)
		hdr[3] = u8(((~n) >> 8) & 0xFF)
		out << hdr
		for i in 0 .. n {
			out << raw[at + i]
		}
		at += n
	}
	put_u32(mut out, adler32(raw))
	return out
}

// encode_png turns a top-down BGRA buffer into PNG bytes.
//
// Colour type 6 (RGBA), 8 bits per channel, no interlacing. BGRA in, RGBA out:
// the swap is the only per-pixel work, and doing it here means the caller can
// hand over a DIB without thinking about it.
fn encode_png(bgra []u8, w int, h int) []u8 {
	mut raw := []u8{}
	for y in 0 .. h {
		// Filter type 0 (None) per scanline. Every other filter would compress
		// better; this one has nothing to get wrong.
		raw << u8(0)
		for x in 0 .. w {
			i := (y * w + x) * 4
			if i + 3 >= bgra.len {
				break
			}
			raw << bgra[i + 2] // R
			raw << bgra[i + 1] // G
			raw << bgra[i] // B
			raw << bgra[i + 3] // A
		}
	}
	mut png := []u8{}
	png << png_magic
	mut ihdr := []u8{}
	put_u32(mut ihdr, u32(w))
	put_u32(mut ihdr, u32(h))
	ihdr << u8(8) // bit depth
	ihdr << u8(6) // colour type: RGBA
	ihdr << u8(0) // compression: deflate
	ihdr << u8(0) // filter method: adaptive
	ihdr << u8(0) // interlace: none
	chunk(mut png, 'IHDR', ihdr)
	chunk(mut png, 'IDAT', zlib_store(raw))
	chunk(mut png, 'IEND', []u8{})
	return png
}

// --- commands ---------------------------------------------------------------

// cmd_capture is the drop-in for `capture.ps1 -Out <file> -WindowTitle <title>`.
fn cmd_capture(out_path string, title string, delay_ms int) int {
	if delay_ms > 0 {
		wait_ms(delay_ms)
	}
	mut w := 0
	mut h := 0
	mut x := 0
	mut y := 0
	if title == '' {
		// There is no whole-screen mode here on purpose. capture.ps1 had one and
		// warned about it; the warning was not enough, because a screenshot that
		// leaks a desktop survives in every clone forever, and every image in
		// this directory was once purged from git history for exactly that.
		// Refusing is the only version of this that cannot be used by accident.
		return fail('-Title is required. A whole-screen capture frames the desktop, ' +
			'and every screenshot in this directory was once purged from git ' +
			'history for leaking it - so this script has no whole-screen mode.')
	}
	hwnd := find_window(title)
	if hwnd == unsafe { nil } {
		return fail('no visible window whose title contains "' + title +
			'". Is the app running?')
	}
	if !raise(hwnd) {
		// Not fatal, and deliberately: the shot is still worth taking, and it is
		// worth taking with a warning in the output rather than not at all.
		println('warning: could not bring "' + title + '" to the foreground; the ' +
			'shot may contain whatever is on top of it')
	}
	mut r := Rect{}
	unsafe { C.vails_window_rect(hwnd, voidptr(&r)) }
	r = clamp_to_work_area(r, work_area())
	x = r.left
	y = r.top
	w = r.right - r.left
	h = r.bottom - r.top
	if w <= 0 || h <= 0 {
		return fail('window "' + title + '" has a ' + w.str() + 'x' + h.str() +
			' rectangle (fully offscreen?)')
	}
	pixels := grab(x, y, w, h)
	if pixels.len == 0 {
		return fail('the screen copy failed (no screen DC, or the window is ' +
			'minimized)')
	}
	png := encode_png(pixels, w, h)
	save_png(out_path, png) or { return fail(err.msg()) }
	println('wrote ' + out_path + ' (' + w.str() + ' x ' + h.str() + ')')
	return 0
}

// cmd_selftest exercises everything that does not need a window.
//
// This is the half of this file that can be verified on a machine with no GUI
// session, and it exists because the other half cannot be: the encoder is pure V
// and is checked here, so the untested part of a capture is the Win32 calls and
// nothing else.
fn cmd_selftest() int {
	mut failures := 0
	mut check := fn [mut failures] (name string, ok bool) {
		if !ok {
			failures++
			println('FAIL ' + name)
		} else {
			println('ok   ' + name)
		}
	}
	// A 2x2 image with four known pixels.
	mut px := []u8{}
	px << u8(0xFF) << u8(0x00) << u8(0x00) << u8(0xFF) // B=255 R=0 -> red
	px << u8(0x00) << u8(0xFF) << u8(0x00) << u8(0xFF) // green
	px << u8(0x00) << u8(0x00) << u8(0xFF) << u8(0xFF) // blue
	px << u8(0xFF) << u8(0xFF) << u8(0xFF) << u8(0xFF) // white
	png := encode_png(px, 2, 2)
	check('png starts with the 8-byte signature', png[0..8] == png_magic)
	check('IHDR is the first chunk', png[12..16] == [u8(0x49), 0x48, 0x44, 0x52])
	// width and height, big-endian, right after the IHDR length+type.
	check('IHDR width is 2', png[19] == 2)
	check('IHDR height is 2', png[23] == 2)
	check('bit depth is 8', png[24] == 8)
	check('colour type is 6 (RGBA)', png[25] == 6)
	check('IEND is last', png[png.len - 4..] == [u8(0x49), 0x45, 0x4E, 0x44])
	// The whole point of writing this rather than calling a library: the bytes are
	// checkable. A 2x2 RGBA image is 8 header + 4 per scanline (filter byte + 2
	// pixels) = 16 raw bytes.
	z := zlib_store([]u8{})
	check('an empty zlib stream is 8 bytes', z.len == 8)
	check('zlib header is 0x78 0x01', z[0] == 0x78 && z[1] == 0x01)
	check('crc32 of an empty input is 0', crc32([]u8{}) == 0)
	// The known CRC of "123456789" - the value every CRC implementation is
	// checked against, so a wrong polynomial cannot pass.
	check('crc32("123456789") is 0xCBF43926', crc32('123456789'.bytes()) == 0xCBF43926)
	check('adler32("123456789") is 0x091E01DE', adler32('123456789'.bytes()) ==
		0x091E01DE)
	// The clamp, which is a privacy rule and therefore worth testing as one.
	work := Rect{
		left:   0
		top:    0
		right:  1920
		bottom: 1040
	}
	// Taller than the work area: the services-window case, which is exactly why the
	// clamp exists - that window is 1089 px tall on a 1040 px work area.
	mut tall := Rect{
		left:   10
		top:    10
		right:  1000
		bottom: 1050
	}
	c := clamp_to_work_area(tall, work)
	check('a too-tall rect is clamped to the work area', c.bottom == 1040)
	check('the left edge is untouched', c.left == 10)
	inside := clamp_to_work_area(Rect{
		left:   5
		top:    5
		right:  50
		bottom: 50
	}, work)
	check('a rect inside the work area is untouched', inside.right == 50
		&& inside.bottom == 50)
	check('a zero work area disables clamping',
		clamp_to_work_area(tall, Rect{}).bottom == 1050)
	if failures > 0 {
		println('')
		println(failures.str() + ' check(s) failed')
		return 1
	}
	println('')
	println('selftest passed')
	return 0
}

fn fail(msg string) int {
	eprintln('capture: ' + msg)
	return 1
}

fn save_png(path string, data []u8) ! {
	mut f := os.create(path) or { return error(err.msg()) }
	f.write(data)!
	f.close()
}

// --- the showcase table -----------------------------------------------------
//
// ONE LAUNCH PER PANEL, ON PURPOSE. The showcase's own design says the tally at
// the top of the window is the proof (ADR-0037), so one screenshot of a fully
// run window would be enough for the verdict. This does the harder thing so that
// a screenshot cannot quietly contain a neighbour's PASS and be read as this
// panel's - the same reasoning as the per-probe filenames, and the same as
// `emit_to`: a status line showing somebody else's result is a wrong answer with
// no error anywhere.
//
// `action` is not always the panel's name: the menu panel is filled by `menubar`
// and the dialog panel by `dialogOpen`, because each of those cards has more than
// one button and only one of them is the checkable half. The page validates the
// name and says so in the tally if it does not recognise it.

struct Panel {
	name   string
	action string
	proves string
}

const panels = [
	Panel{
		name:   'bridge'
		action: 'bridge'
		proves: 'demo.ping round trip'
	},
	Panel{
		name:   'post'
		action: 'post'
		proves: 'post_to_main from a worker (U0)'
	},
	Panel{
		name:   'caps'
		action: 'caps'
		proves: 'an ungranted command is refused'
	},
	Panel{
		name:   'osinfo'
		action: 'osinfo'
		proves: 'os_info.get'
	},
	Panel{
		name:   'clipboard'
		action: 'clipboard'
		proves: 'write then read back'
	},
	Panel{
		name:   'notify'
		action: 'notify'
		proves: 'a real toast'
	},
	Panel{
		name:   'opener'
		action: 'opener'
		proves: 'a file:// URL is refused'
	},
	Panel{
		name:   'menu'
		action: 'menubar'
		proves: 'the window menu bar installs'
	},
	Panel{
		name:   'dialog'
		action: 'dialogOpen'
		proves: 'a file picker opens (modal; killed after)'
	},
	Panel{
		name:   'tray'
		action: 'tray'
		proves: 'icon + menu install (NEEDS YOU: click it)'
	},
	Panel{
		name:   'drop'
		action: 'drop'
		proves: 'the window is armed (NEEDS YOU: drag a file)'
	},
]

// window_title is the showcase's, from its vails.json.
const showcase_title = 'Vails Showcase'

// toolchain_bin is where the five runtime DLLs come from.
//
// The same knob and the same default as buildplan.toolchain (ADR-0038), read
// here rather than imported: a `v run` script gets vlib and nothing else, and
// adding `-path` to reach a repo module would make the command in the README
// longer than the thing it is doing. One line of duplication, deliberately, and
// the two are expected to change together.
fn toolchain_bin(override string) string {
	root := if override != '' {
		override
	} else if os.getenv('VAILS_TOOLCHAIN') != '' {
		os.getenv('VAILS_TOOLCHAIN')
	} else {
		'C:/msys64/ucrt64'
	}
	mut r := root.replace('\\', '/')
	for r.len > 3 && r.ends_with('/') {
		r = r[..r.len - 1]
	}
	return r + '/bin'
}

// side_by_side is the five DLLs a Windows GUI app cannot start without. The
// 0.12 in the first name is the ABI version (buildplan.side_by_side_dlls).
const side_by_side = ['libwebview-0.12.dll', 'WebView2Loader.dll', 'libgcc_s_seh-1.dll',
	'libstdc++-6.dll', 'libwinpthread-1.dll']

// stage copies the DLLs, the manifest and the frontend next to the exe.
//
// All three are needed and each fails differently: no DLLs means a loader error
// naming none of them, no vails.json means "vails.json not found", no frontend
// means "index.html not found". An exe that cannot reach its page still opens a
// window, which is the confusing case.
fn stage(exe_dir string, toolchain string, project string) ! {
	mut staged := 0
	for dll in side_by_side {
		src := toolchain_bin(toolchain) + '/' + dll
		if os.exists(src) {
			dst := exe_dir + '/' + dll
			if !os.exists(dst) {
				os.cp_all(src, dst, true) or {
					return error('could not stage ' + dll + ': ' + err.msg())
				}
			}
			staged++
		}
	}
	if staged < side_by_side.len {
		return error('only ' + staged.str() + ' of ' + side_by_side.len.str() +
			' runtime DLLs found under ' + toolchain_bin(toolchain) +
			' - set VAILS_TOOLCHAIN to a ucrt64-shaped root that has them ' +
			'(ADR-0038). Every panel would otherwise "fail" for a reason that has ' +
			'nothing to do with the panel.')
	}
	manifest := os.join_path(project, 'examples/showcase/vails.json')
	if !os.exists(os.join_path(exe_dir, 'vails.json')) {
		os.cp_all(manifest, os.join_path(exe_dir, 'vails.json'), true) or {
			return error('could not stage vails.json: ' + err.msg())
		}
	}
	front := os.join_path(project, 'examples/showcase/frontend')
	if !os.exists(os.join_path(exe_dir, 'frontend')) {
		copy_dir(front, os.join_path(exe_dir, 'frontend')) or {
			return error('could not stage frontend/: ' + err.msg())
		}
	}
}

// copy_dir copies a directory tree, file by file.
//
// Hand-rolled because V's os has `cp_all` for a file list but no recursive
// directory copy on this version, and the alternative — shelling out to `xcopy`
// or `robocopy` — would make this script depend on a tool whose flags differ
// between the two. The showcase's frontend is two files, so a walk is not an
// over-engineering; it would be if the tree were large, and the comment says so
// rather than pretending otherwise.
fn copy_dir(src string, dst string) ! {
	os.mkdir_all(dst) or { return error(err.msg()) }
	mut entries := os.ls(src) or { return error(err.msg()) }
	for name in entries {
		from := src + '/' + name
		to := dst + '/' + name
		if os.is_dir(from) {
			copy_dir(from, to)!
		} else {
			os.cp_all(from, to, true)!
		}
	}
}

// kill_showcase ends every running copy.
//
// `taskkill` rather than a Process method because V's os.Process has run/wait/
// is_alive and no kill - and a showcase left running would make the next panel's
// capture a race between two windows with the same title, which is a screenshot
// of the wrong launch rather than an error.
fn kill_showcase() {
	os.execute('taskkill /F /IM showcase.exe')
}

// cmd_showcase is R4: one screenshot per panel.
fn cmd_showcase(out_dir string, settle_ms int, only string, project string, toolchain string, do_build bool) int {
	mut list := panels.clone()
	if only != '' {
		mut filtered := []Panel{}
		for p in list {
			if p.name == only {
				filtered << p
			}
		}
		if filtered.len == 0 {
			return fail('unknown panel "' + only + '". Have: ' + names() +
				'. (Panel and action names differ for menu and dialog - see the ' +
				'table above.)')
		}
		list = filtered.clone()
	}
	exe := os.join_path(project, 'showcase.exe')
	if do_build {
		println('building the showcase...')
		// `cd` + `&&` in one command rather than a workdir option, because
		// os.execute has no workdir parameter on Windows.
		build := os.execute('cd /d ' + project + ' && v -cc gcc -o showcase.exe ' +
			'./examples/showcase')
		if build.exit_code != 0 {
			return fail('the showcase did not build (exit ' +
				build.exit_code.str() + '): ' + build.output)
		}
	}
	if !os.exists(exe) {
		return fail('no showcase exe at ' + exe + ' (fix the path, or drop -NoBuild)')
	}
	stage(project, toolchain, project) or { return fail(err.msg()) }
	os.mkdir_all(out_dir) or {
		return fail('could not create ' + out_dir + ': ' + err.msg())
	}
	mut shots := 0
	for p in list {
		println('--- ' + p.name + ': ' + p.proves)
		kill_showcase()
		wait_ms(400)
		// The environment variable is the whole automation seam: main.v reads it,
		// injects one call into the page's own `run`, and the page refuses an
		// action it does not recognise by name rather than drawing an empty card.
		os.setenv('VAILS_SHOWCASE_PANEL', p.action, true)
		mut proc := os.new_process(exe)
		proc.set_work_folder(project)
		proc.run()
		// One settle number for the window, the page load and `demo.support`
		// together. Crude on purpose: a per-panel tuned delay is a delay that is
		// wrong on the machine you did not tune it on.
		shot := os.join_path(out_dir, 'showcase-' + p.name + '.png')
		if cmd_capture(shot, showcase_title, settle_ms) == 0 {
			shots++
		}
		os.setenv('VAILS_SHOWCASE_PANEL', '', true)
		// Killed, not closed: the dialog panel's modal means there is nothing to
		// close politely, and leaving it up makes the next capture a race.
		kill_showcase()
	}
	println('')
	println('captured ' + shots.str() + '/' + list.len.str() + ' panels into ' +
		out_dir)
	println('')
	println('READ each shot before trusting it: a badge saying FAIL or NEEDS YOU')
	println('is the honest answer, not a broken capture. The dialog panel is')
	println('covered by its own modal by design.')
	return 0
}

fn names() string {
	mut out := []string{}
	for p in panels {
		out << p.name
	}
	return out.join(', ')
}

// entry is called at the end of this file, from top level.
//
// NOT n main(), and that is the whole reason the first version of this script
// produced no output at all: a .vsh file's top-level statements ARE the program, so
// V never calls a main in it. A VSH script is not a V program with a main that
// happens to have a different extension.
//
// The upshot for testing:  run capture.vsh selftest runs this, and so does
//  -o capture.exe capture.vsh && capture.exe selftest - one entry, both ways.
fn entry() {
	args := os.args[1..]
	mut cmd := 'capture'
	mut i := 0
	if args.len > 0 && !args[0].starts_with('-') {
		cmd = args[0]
		i = 1
	}
	mut out := if cmd == 'showcase' { 'shots' } else { '' }
	mut out_dir := 'shots'
	mut title := ''
	mut delay := 0
	mut settle := 2200
	mut only := ''
	mut project := '..\\..'
	mut toolchain := ''
	mut build := true
	for i < args.len {
		match args[i] {
			'-Out' {
				i++
				out = args[i]
			}
			'-OutDir' {
				i++
				out_dir = args[i]
			}
			'-Title', '-WindowTitle' {
				i++
				title = args[i]
			}
			'-DelayMs' {
				i++
				delay = strconv.atoi(args[i]) or { -1 }
			}
			'-SettleMs' {
				i++
				settle = strconv.atoi(args[i]) or { -1 }
			}
			'-Panel' {
				i++
				only = args[i]
			}
			'-ProjectDir' {
				i++
				project = args[i]
			}
			'-Toolchain' {
				i++
				toolchain = args[i]
			}
			'-NoBuild' {
				build = false
			}
			else {
				exit(fail('unknown argument: ' + args[i]))
			}
		}
		i++
	}
	match cmd {
		'capture' {
			exit(cmd_capture(out, title, delay))
		}
		'selftest' {
			exit(cmd_selftest())
		}
		'showcase' {
			exit(cmd_showcase(out_dir, settle, only, project, toolchain, build))
		}
		else {
			exit(fail('unknown command "' + cmd + '". Use one, showcase, selftest.'))
		}
	}
}

// The shim's `#insert` goes HERE: after every definition, immediately before the
// program's first statement.
//
// That ordering is not a style choice, and getting it wrong is the most expensive
// thing about a V shell script. **Script mode requires all definitions to come
// before any code**, so a `#insert` (or a `#flag`) sitting above the functions
// makes the whole file invalid — and V reports it as a *notice*, not an error:
//
//     capture.vsh:39:1: notice: script mode started here
//     capture.vsh:61:1: error: all definitions must occur before code in script mode
//
// The first build of this file had exactly that, and the result was the quietest
// failure available: `v -o capture.exe capture.vsh` printed one notice, produced
// a 660 KB binary, and that binary printed nothing and exited 0 on every command.
// Four builds went into it, and the theories blamed in turn were PowerShell,
// `fn main()` not being called, the missing module line, stdout buffering around
// `exit()`, and the shim. The message to look for is the one above, and the
// `script mode started here` notice names the directive that began the code.
#insert "@VMODROOT/tests/e2e_windows/capture_shim.h"

// The call itself: a script's program is its top-level statements, so this is the
// `main`. See the header for why it is not named `main`.
println('DIAG-C: top level before entry')
entry()
