// services/clipboard.v - the system clipboard service (Phase 5 S1 wave 2).
//
// Pure-V half: payload decoding, the size bound, the parent-window rule and
// the manifest. The OS half lives in clipboard_windows.c.v (user32
// CF_UNICODETEXT) and clipboard_linux.c.v (the GTK clipboard) and is reached
// through read_text_native / write_text_native, exactly like dialog reaches
// open_native / save_native (ADR-0014). `v test` never calls a native half:
// it opens the user's clipboard, and a test must stay side-effect free. The
// round trip is proven by examples/services instead.
//
// Read/write need no capability check of their own: the wire names are the
// capability names, so a frontend without a grant gets
// 'forbidden: clipboard.read_text …' (ADR-0007).
module services

import bridge
import json2
import webview

// max_text_bytes bounds the text a frontend may put on the clipboard.
// The clipboard is shared machine state, so a bound keeps a generated or
// pasted megabyte from being pushed silently; 1 MiB of UTF-8 is far past
// anything a human copies and far below anything that hurts.
const max_text_bytes = 1 << 20

// clipboard_manifest is the service manifest (T5).
//
// read_text takes no params; write_text takes the text as a JSON string
// (ADR-0010 keeps params raw JSON), so a frontend calls
// `vails.clipboard.write_text(JSON.stringify(text))`. It resolves with the
// empty string: a command always answers with a result.
pub fn clipboard_manifest() Service {
	return Service{
		name:     'clipboard'
		version:  '0.1.0'
		summary:  'system clipboard text'
		commands: [
			Command{
				name:    'clipboard.read_text'
				result:  'string'
				summary: 'reads the clipboard as text'
			},
			Command{
				name:    'clipboard.write_text'
				params:  'string'
				result:  'string'
				summary: 'replaces the clipboard text'
			},
		]
	}
}

// read_text returns the clipboard text. A clipboard holding no text is a
// normal state, not a failure: the result is the empty string (the same
// contract the native backends implement - see the comment in
// clipboard_windows.c.v).
//
// The Ctx is needed by the backends, not by this function: Windows opens the
// clipboard for reading with a NULL window (no owner needed), and so does
// GTK. Taking the same argument as write_text keeps the two commands
// symmetric and leaves room for a backend that does need it.
pub fn read_text(ctx webview.Ctx) !string {
	$if windows {
		return read_text_native(ctx)
	} $else $if linux {
		return read_text_native(ctx)
	} $else {
		_ = ctx
		return error('services.read_text: not implemented on this platform yet (Phase 6, macOS backend)')
	}
}

// write_text replaces the clipboard text. Needs a parent window handle on
// Windows: EmptyClipboard turns the window that opened the clipboard into its
// owner, and with a NULL window the owner is NULL — MSDN warns that this
// makes SetClipboardData fail, and even where it does not, an unowned
// clipboard is the OS's to discard. So require_parent rejects a Ctx without
// a handle instead of leaving the write to chance.
pub fn write_text(ctx webview.Ctx, text string) ! {
	$if windows {
		write_text_native(ctx, text)!
	} $else $if linux {
		write_text_native(ctx, text)!
	} $else {
		_ = ctx
		_ = text
		return error('services.write_text: not implemented on this platform yet (Phase 6, macOS backend)')
	}
}

// decode_text is the pure-V half of write_text's params: the payload is a
// JSON string, because ADR-0010 keeps params raw JSON. A frontend that sends
// something else (an object, a number, broken JSON) gets the standard
// 'bad params: …' value, not a native error.
pub fn decode_text(params string) !string {
	if params == '' || params == 'null' {
		return error('expected a JSON string, the text to copy')
	}
	text := json2.decode[string](params) or {
		return error('expected a JSON string: ' + err.msg())
	}
	validate_text(text)!
	return text
}

// validate_text enforces the size bound. Empty text is legal: it is how a
// frontend clears the clipboard.
pub fn validate_text(text string) ! {
	if text.len > max_text_bytes {
		return error('clipboard text is longer than ' + max_text_bytes.str() +
			' bytes (got ' + text.len.str() + ')')
	}
}

// require_parent is the parent-window rule, kept in pure V so it is unit
// testable: a hand-built Ctx in a test (or a window on a platform that
// hands out no handle) must not reach the native call.
pub fn require_parent(ctx webview.Ctx, command string) ! {
	if !ctx.has_parent() {
		return error('services.' + command + ': needs the window handle (' +
			'pass the Ctx from Config.on_ready)')
	}
}

// install_clipboard binds the clipboard command surface on router.
pub fn install_clipboard(mut router bridge.Router, ctx webview.Ctx) ! {
	mut backend := Backend{}
	backend['clipboard.read_text'] = fn [ctx] (_ string) !string {
		return read_text(ctx)!
	}
	backend['clipboard.write_text'] = fn [ctx] (params string) !string {
		text := decode_text(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		write_text(ctx, text)!
		return ''
	}
	install(mut router, clipboard_manifest(), backend)!
}
