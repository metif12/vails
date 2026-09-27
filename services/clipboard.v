// services/clipboard.v — the clipboard service seam.
//
// Phase 5 S1 wave 1 (ADR-0014) left the native half unimplemented on
// purpose: the command surface below is what a later wave (or the GTK
// backend) will implement, and it is already capability-gated, typed and
// documented. Every platform fails explicitly instead of pretending, so
// `v test .` never touches the real clipboard — unit tests must be
// side-effect free.
//
// Read/write need no OS capability check of their own: the wire names are
// the capability names, so a frontend without a grant gets
// 'forbidden: clipboard.read_text …' (ADR-0007).
module services

import bridge
import json2
import webview

// clipboard_manifest is the service manifest (T5).
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
				summary: 'replaces the clipboard text'
			},
		]
		ts_types: [
			'\texport function write_text(text: string): Promise<void>;',
		]
	}
}

// read_text returns the clipboard text. Both backends land with the
// service: Windows needs user32's OpenClipboard/SetClipboardData, Linux
// the GTK clipboard (or xclip). Until then every OS fails explicitly
// instead of returning a silent empty string.
pub fn read_text() !string {
	$if windows {
		return error('services.read_text: not implemented yet (Phase 5 S1 wave 2)')
	} $else {
		return error('services.read_text: not implemented on this OS (Phase 5 S1 wave 2)')
	}
}

// write_text replaces the clipboard text. See read_text for the backend
// status.
pub fn write_text(text string) ! {
	$if windows {
		return error('services.write_text: not implemented yet (Phase 5 S1 wave 2)')
	} $else {
		return error('services.write_text: not implemented on this OS (Phase 5 S1 wave 2)')
	}
}

// install_clipboard binds the clipboard command surface on router. The
// handlers are bound even though the native half is pending, so a grant in
// vails.json produces a clear backend error instead of
// 'unknown method: clipboard.read_text'.
//
// Params are raw JSON like every other command (ADR-0010), so a text
// payload arrives JSON-encoded: the frontend calls
// `vails.clipboard.write_text(JSON.stringify(text))`.
pub fn install_clipboard(mut router bridge.Router, _ctx webview.Ctx) ! {
	mut backend := Backend{}
	backend['clipboard.read_text'] = fn (_ string) !string {
		return read_text()!
	}
	backend['clipboard.write_text'] = fn (params string) !string {
		text := json2.decode[string](params) or {
			return error(bridge.err_bad_params('expected a JSON string: ' + err.msg()))
		}
		write_text(text)!
		return ''
	}
	install(mut router, clipboard_manifest(), backend)!
}
