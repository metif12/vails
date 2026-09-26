// services/clipboard.v — first native service stub (Phase 5 implements it).
// Pattern for all services: pure-V API + error('not implemented on …')
// until the OS backend lands. Keeps App wiring testable everywhere.
module services

// read_text returns the clipboard text. Linux backend (xclip/xsel or
// GTK clipboard) lands in Phase 5; until then every OS fails explicitly.
pub fn read_text() !string {
	$if linux {
		return error('services.read_text: not implemented yet (Phase 5)')
	} $else {
		return error('services.read_text: not implemented on this OS (Phase 6)')
	}
}
