// dialog.v - the native file/message dialog service (Phase 5 S1, first
// service with a real OS backend).
//
// Pure-V half: option decoding + validation, result encoding, the manifest
// and the handler set. The OS half lives in dialog_windows.c.v (IFileOpen
// Dialog / IFileSaveDialog / MessageBoxW behind dialog_shim.h) and
// dialog_linux.c.v.
//
// Threading: all three commands are modal — the native call blocks the
// webview main thread until the user answers. That is the one documented
// exception to the ADR-0010 rule (ADR-0014): a modal dialog is meant to
// freeze the UI, and the frontend cannot interact with the page behind it
// anyway. Everything expensive (directory listing, thumbnails) happens
// inside the OS dialog, not in V.
//
// Capability-gated like everything else (ADR-0007): the wire names
// 'dialog.open' / 'dialog.save' / 'dialog.message' are the names a
// vails.json capability has to grant.
module services

import bridge
import json2
import webview

// Dialog kinds. The wire value is the command's short name, so a grant
// and a kind are spelled the same.
pub const kind_open = 'open'
pub const kind_save = 'save'
pub const kind_message = 'message'

// Message-box button sets, as the frontend spells them.
pub const buttons_ok = 'ok'
pub const buttons_ok_cancel = 'okcancel'
pub const buttons_yes_no_cancel = 'yesnocancel'

// Hard limits. Options come from JS, so every string is bounded before it
// reaches a fixed-size native buffer; the numbers are deliberately
// generous (a title is a sentence, a message is a paragraph).
const max_title = 512
const max_message = 4096
const max_path = 1024
const max_filters = 16
const max_extensions = 32

// Filter is one entry of a file picker's type list: a display name plus
// the accepted extensions ('png' or 'png,jpg'; a leading dot and
// surrounding spaces are accepted, everything else is rejected).
pub struct Filter {
pub mut:
	name       string
	extensions string
}

// Options is the params payload of all three dialog commands. `kind`
// selects the behaviour and must match the command that was called, so a
// granted 'dialog.open' cannot be abused to run a save or a message box.
pub struct Options {
pub mut:
	kind         string
	title        string
	message      string
	buttons      string = buttons_ok
	default_path string
	default_name string
	filters      []Filter
	multi        bool
}

// Result is the JSON a dialog command resolves with. Canceled dialogs
// return `{canceled: true}` with no paths, which is a normal result, not
// an error: the promise resolves, the frontend decides what to do.
pub struct Result {
pub mut:
	canceled bool
	paths    []string
	button   string
}

// parse_options decodes and validates the params payload of one dialog
// command. `want` is the kind the command stands for. A bare JSON string
// is accepted as the dialog title, which is what a minimal frontend
// sends.
pub fn parse_options(want string, params string) !Options {
	if params == '' || params == 'null' {
		return error('dialog: no options for ' + want)
	}
	mut opts := json2.decode[Options](params) or {
		title := json2.decode[string](params) or {
			return error('dialog: invalid options: ' + err.msg())
		}
		return Options{
			title: title
		}
	}
	// The kind defaults to the command's own kind, so `{"title":"Pick"}`
	// and a bare "Pick" both work; a conflicting kind is rejected below.
	if opts.kind == '' {
		opts.kind = want
	}
	opts.validate(want)!
	return opts
}

// validate rejects anything the native layer cannot honor, before any
// native call happens.
pub fn (o Options) validate(want string) ! {
	if o.kind == '' {
		return error('dialog: kind is required (open, save or message)')
	}
	if o.kind != want {
		return error('dialog: ' + want + ' does not accept kind "' + o.kind + '"')
	}
	if o.title.len > max_title {
		return error('dialog: title is longer than ' + max_title.str() + ' characters')
	}
	if o.message.len > max_message {
		return error('dialog: message is longer than ' + max_message.str() + ' characters')
	}
	if o.default_path.len > max_path || o.default_name.len > max_path {
		return error('dialog: path hint is longer than ' + max_path.str() + ' characters')
	}
	if !is_button_set(o.buttons) {
		return error('dialog: buttons must be ok, okcancel or yesnocancel')
	}
	if o.kind == kind_message {
		if o.message == '' {
			return error('dialog: message is required for kind "message"')
		}
		return
	}
	if o.filters.len > max_filters {
		return error('dialog: at most ' + max_filters.str() + ' filters')
	}
	for f in o.filters {
		validate_filter(f)!
	}
	if o.default_name != '' && o.kind == kind_open {
		return error('dialog: default_name is only valid for kind "save"')
	}
	if o.multi && o.kind != kind_open {
		return error('dialog: multi is only valid for kind "open"')
	}
}

// validate_filter checks one file filter: a display name and at least one
// bare extension. Rejecting everything else keeps the native pattern
// string predictable (no paths, no wildcards, no quotes).
pub fn validate_filter(f Filter) ! {
	if f.name.trim_space() == '' {
		return error('dialog: filter name must not be empty')
	}
	if f.name.contains('|') || f.name.contains('(') || f.name.contains(')') {
		return error('dialog: filter name must not contain | ( ) ')
	}
	parts := f.extensions.split(',')
	if parts.len > max_extensions {
		return error('dialog: at most ' + max_extensions.str() + ' extensions per filter')
	}
	for p in parts {
		ext := p.trim_space().trim_left('.').to_lower()
		if ext == '' {
			return error('dialog: filter "' + f.name + '" has an empty extension')
		}
		for ch in ext {
			// u8(...) because a V string literal is not a byte: the
			// extension must be plain ASCII alphanumerics.
			c := u8(ch)
			if !(c >= `a` && c <= `z`) && !(c >= `0` && c <= `9`) {
				return error('dialog: filter "' + f.name +
					'" has an invalid extension "' + ext + '"')
			}
		}
	}
}

// is_button_set accepts the empty string as the default (ok).
pub fn is_button_set(s string) bool {
	return s == '' || s == buttons_ok || s == buttons_ok_cancel || s == buttons_yes_no_cancel
}

// native_filter_string renders the filters in the Windows convention the
// shim parses: "Images (*.png;*.jpg)|Text (*.txt)". Pure data, so the
// tests check the exact string the C side receives.
pub fn native_filter_string(filters []Filter) string {
	mut out := []string{}
	for f in filters {
		mut pats := []string{}
		for p in f.extensions.split(',') {
			ext := p.trim_space().trim_left('.').to_lower()
			if ext != '' {
				pats << '*.' + ext
			}
		}
		if pats.len == 0 {
			continue
		}
		out << f.name + ' (' + pats.join(';') + ')'
	}
	return out.join('|')
}

// encode_result renders a dialog result as the JSON the promise resolves
// with. An empty path list never leaks as `null`.
pub fn encode_result(r Result) string {
	mut paths := r.paths.clone()
	if paths.len == 0 {
		paths = []string{}
	}
	return json2.encode(r, escape_unicode: true)
}

// parse_paths splits the shim's NUL-separated buffer back into paths.
pub fn parse_paths(buf string) []string {
	mut out := []string{}
	for part in buf.split('\x00') {
		if part != '' {
			out << part
		}
	}
	return out
}

// GTK response ids, as literals (AGENTS.md §2). GTK answers a dialog with one
// of these rather than with a boolean, and the set is a GTK enum rather than
// anything this codebase controls — the file chooser uses ACCEPT, the message
// box uses OK/YES/NO/CANCEL.
//
// They live in this shared file, not in dialog_linux.c.v, for the same reason
// `menu.wm_command` and `host_message` do (ADR-0018/0023): the *classification*
// is the part worth testing, and the classifier has to run on every platform
// for that to be true. A Linux-only file would make the mapping testable only
// on the platform where it can never be run in CI.
const gtk_response_reject = -2
const gtk_response_accept = -3
const gtk_response_delete_event = -4
const gtk_response_ok = -5
const gtk_response_cancel = -6
const gtk_response_close = -7
const gtk_response_yes = -8
const gtk_response_no = -9

// The button names a message box reports. A closed set of four plus 'none',
// and the same set the Windows half produces from IDOK/IDCANCEL/IDYES/IDNO —
// one wire vocabulary for two native button sets is the whole point.
pub const button_none = 'none'
pub const button_ok = 'ok'
pub const button_cancel = 'cancel'
pub const button_yes = 'yes'
pub const button_no = 'no'

// gtk_button_name maps a GTK response id to the frontend's button name, or
// `none` for an id it does not know.
//
// The four "closed" ids are treated deliberately: DELETE_EVENT is the window
// manager's way of saying "closed", CLOSE is the dialog's own close button,
// REJECT is the file chooser's "this choice is not acceptable" and CANCEL is
// the button. From a frontend's point of view all four are the same user
// intent — declined — and reporting them as different buttons would push that
// distinction into every app.
pub fn gtk_button_name(rc int) ?string {
	match rc {
		gtk_response_ok, gtk_response_accept {
			return button_ok
		}
		gtk_response_yes {
			return button_yes
		}
		gtk_response_no {
			return button_no
		}
		gtk_response_cancel, gtk_response_reject, gtk_response_delete_event,
		gtk_response_close {
			return button_cancel
		}
		else {
			return none
		}
	}
}

// gtk_message_result turns a GTK message-box response into the same Result the
// Windows MessageBoxW half produces, so the two platforms answer identically.
//
// The accepted/declined split is the same rule as Windows (IDOK/IDYES are an
// answer, IDCANCEL/IDNO are not), which is what keeps `dialog.message`
// platform-independent for a frontend.
pub fn gtk_message_result(rc int) Result {
	name := gtk_button_name(rc) or {
		return Result{
			canceled: true
			button:   button_none
		}
	}
	accepted := name == button_ok || name == button_yes
	return Result{
		canceled: !accepted
		button:   name
	}
}

// gtk_chooser_accepted reports whether a file chooser's response means the user
// picked something. Only ACCEPT does; CANCEL, DELETE_EVENT and a closed window
// are all a refusal, and a refusal is a normal result rather than an error.
pub fn gtk_chooser_accepted(rc int) bool {
	return rc == gtk_response_accept
}

// dialog_rc maps a backend return code to a Result: 0 is a cancellation (a
// normal result), a negative code is a failure carrying the backend's own
// message, anything else is a success with the paths in buf.
//
// The mapping is pure V on purpose — it is the part worth testing, and
// keeping it here means dialog_test.v compiles (and passes) on Linux too,
// not just where the shim exists. The C side supplies `reason`, so no
// `fn C.*` leaks into this file (ADR-0015).
pub fn dialog_rc(rc int, buf string, reason string) !Result {
	if rc == 0 {
		return Result{
			canceled: true
		}
	}
	if rc < 0 {
		return error('dialog: ' + reason)
	}
	return Result{
		canceled: false
		paths:    parse_paths(buf)
	}
}

// dialog_manifest is the service manifest (T5).
pub fn dialog_manifest() Service {
	return Service{
		name:     'dialog'
		version:  '0.1.0'
		summary:  'native file and message dialogs'
		commands: [
			Command{
				name:     'dialog.open'
				params:   'DialogOpenOptions'
				result:   'DialogFileResult'
				blocking: true
				summary:  'opens a native file picker'
			},
			Command{
				name:     'dialog.save'
				params:   'DialogSaveOptions'
				result:   'DialogFileResult'
				blocking: true
				summary:  'opens a native save dialog'
			},
			Command{
				name:     'dialog.message'
				params:   'DialogMessageOptions'
				result:   'DialogMessageResult'
				blocking: true
				summary:  'opens a native message box'
			},
		]
		ts_types: dialog_ts_types()
	}
}

// dialog_ts_types are the TypeScript shapes the generated .d.ts refers
// to. They live in the manifest so codegen needs no second source.
//
// Field names are snake_case, and that is not a style choice: a V struct
// field name IS the wire name (json2 does not map camelCase keys onto
// snake_case fields, and a `@json:` attribute does not survive V's C codegen
// - ADR-0015, Notes). Promising `defaultPath` here while the struct field is
// `default_path` produced a .d.ts that type-checked and then silently
// dropped the value.
fn dialog_ts_types() []string {
	return [
		'\texport interface DialogFilter { name: string; extensions: string; }',
		'\texport interface DialogOpenOptions { title?: string; default_path?: string; filters?: DialogFilter[]; multi?: boolean; }',
		'\texport interface DialogSaveOptions { title?: string; default_path?: string; default_name?: string; filters?: DialogFilter[]; }',
		"\texport interface DialogMessageOptions { title?: string; message: string; buttons?: 'ok' | 'okcancel' | 'yesnocancel'; }",
		'\texport interface DialogFileResult { canceled: boolean; paths: string[]; button: string; }',
		'\texport interface DialogMessageResult { canceled: boolean; paths: string[]; button: string; }',
	]
}

// dialog_backend builds the handler set for one window. The Ctx supplies
// the parent handle (dialogs are parented to the webview window) and the
// label used in error messages.
//
// Option problems are wrapped in the standard 'bad params: …' value
// (ADR-0010), so a frontend can branch on the prefix instead of matching
// message text.
pub fn dialog_backend(ctx webview.Ctx) Backend {
	mut backend := Backend{}
	backend['dialog.open'] = fn [ctx] (params string) !string {
		opts := parse_options(kind_open, params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		res := open_native(ctx, opts)!
		return encode_result(res)
	}
	backend['dialog.save'] = fn [ctx] (params string) !string {
		opts := parse_options(kind_save, params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		res := save_native(ctx, opts)!
		return encode_result(res)
	}
	backend['dialog.message'] = fn [ctx] (params string) !string {
		opts := parse_options(kind_message, params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		res := message_native(ctx, opts)!
		return encode_result(res)
	}
	return backend
}

// install_dialog binds the dialog service on router for one window.
pub fn install_dialog(mut router bridge.Router, ctx webview.Ctx) ! {
	install(mut router, dialog_manifest(), dialog_backend(ctx))!
}

// dialog_support answers "can this platform show a file picker?" (see
// support.v). The Linux half is still a stub even though the toolchain now
// exists: the GTK chooser is the last S1 item waiting on a human answering a
// modal window, and it is scheduled in Phase 5b.
pub fn dialog_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'dialog'
			ready: true
			note:  'Common Item Dialog + MessageBoxW'
		}
	} $else $if linux {
		return ServiceStatus{
			name:  'dialog'
			ready: false
			note:  'stub: the GTK chooser lands in Phase 5b'
		}
	} $else {
		return ServiceStatus{
			name:  'dialog'
			ready: false
			note:  'no backend on this platform yet (Phase 6, macOS)'
		}
	}
}
