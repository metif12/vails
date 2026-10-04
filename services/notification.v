// services/notification.v - the notification service: a short native message
// the OS shows without stealing focus (Phase 5 S1 wave 2; a real WinRT toast
// from ADR-0018).
//
// Pure-V half: the options, their bounds, the timeout clamp, the toast XML
// and the manifest. The OS half is a WinRT toast on Windows
// (toast_shim.h) and an explicit stub on Linux.
//
// Why a toast and not the tray balloon this used to be: a balloon is
// `Shell_NotifyIconW` with `NIF_INFO`, which Windows 11 routes to the
// Action Center under the name of the .exe, needs a tray icon that outlives
// the balloon (so a V worker had to delete it again), and cannot be
// attributed to a real app. A toast is a first-class Windows 10/11
// notification: it carries the app's own name and icon and lands in the
// Action Center properly. The cost is the WinRT/COM stack, which is what
// toast_shim.h is for - and the AppUserModelID a desktop app must
// register before the shell will show one at all (see AppIdentity).
//
// `is_supported` exists so a frontend can ask before it tries: a service
// that silently does nothing on a platform it has no backend for is worse
// than one that says so (this is the same reason dialog's cancellation is a
// result and not an error).
module services

import bridge
import json2
import webview

// Bounds on the two strings. A notification is a sentence, not a document.
const max_notify_title = 128
const max_notify_body = 512

// ## Toast action buttons: built, tested, and deliberately not sent
//
// `toast_actions_available` is false, and that is a statement about this
// machine's *toolchain* rather than about Windows.
//
// A toast's buttons are pure XML - `<actions>` inside `<toast>` - so rendering
// them needs no new WinRT API and no new IID, and the builder below is
// complete. What is missing is *delivery*: a click has to come back to the app
// as `IToastActivatedEventArgs`, which means the IIDs of
// `IToastNotificationManagerStatics` and `IToastActivatedEventArgs`.
//
// Those IIDs are not obtainable here (ADR-0039): the MSYS2 header names both
// interfaces but carries zero `__declspec(uuid)` declarations, the installed SDK
// copy is C++/WinRT templates with no C-readable IIDs, and neither
// `Windows.winmd` nor `UniversalApisContract.winmd` is installed. Guessing a
// GUID would activate the wrong object - worse than having no buttons.
//
// So the buttons are built and tested, the capability is false, and `notify`
// sends a toast *without* them. A button that renders and does nothing is the
// same lie the balloon was removed for (ADR-0018): the user is shown an
// affordance that silently fails. When the IIDs arrive this is one constant.
pub const toast_actions_available = false

// Why the capability is false, in one sentence a `doctor` reader can act on.
pub const toast_actions_blocked = 'toast action buttons need the IIDs of ' +
	'IToastNotificationManagerStatics and IToastActivatedEventArgs to deliver a ' +
	'click, and neither is available in this build environment (no uuid ' +
	'declarations in the mingw headers, no C IIDs in the SDK, no winmd). The ' +
	'buttons are built and tested but not sent, rather than shown dead ' +
	'(ADR-0039)'

// Bounds on one action. Deliberately modest: a toast button is a label, and a
// long one is either clipped by the shell or wrapped onto two lines, neither of
// which is what the caller wrote.
const max_action_id = 64
const max_action_content = 64
const max_action_arguments = 256

// Where a button appears. `contextual` is the only placement Windows 10/11
// desktop honours for a normal app; `system` is accepted because the schema has
// it and a future shell may honour it, but it is not the default and pretending
// otherwise would put a button where Windows ignores it.
pub const action_placement_contextual = 'contextual'
pub const action_placement_system = 'system'

// NotificationAction is one button on the toast.
//
// `id` is Vails' own handle for the button, stable across a round trip, and is
// what a frontend matches against. `arguments` is what Windows hands back, and
// the two are separate because a caller may want the wire payload to be
// something another program could produce.
pub struct NotificationAction {
pub mut:
	id      string
	content string
	// `arguments` and `placement` are optional on the wire and zero when absent
	// - V zeroes struct fields, and an `= ''` on a string is a warning rather
	// than documentation. The two documented defaults are applied by
	// `effective_placement` and by the empty-arguments case below, so they hold
	// however the struct was built: from JSON, or from V code.
	arguments string
	placement string
}

// effective_placement is the placement actually sent.
//
// An unset one means contextual, and that is a decision rather than a
// convenience: `placement=""` is not "the schema's default" to the shell, it is
// an invalid attribute value, so writing the field straight through would
// produce a document the shell rejects. Normalising here means the default holds
// for a struct built in V as well as one decoded from JSON.
//
// Pure, because it is a rule that the XML and the validator must agree on -
// they did not, once, when the struct carried a field default that JSON decoding
// was free to overwrite.
pub fn effective_placement(a NotificationAction) string {
	if a.placement == '' {
		return action_placement_contextual
	}
	return a.placement
}

// The notification's lifetime, in milliseconds. The floor keeps a
// notification readable rather than a flicker; the ceiling keeps a stuck
// one from outliving the app that sent it.
//
// This is a *hint*, not a promise, and it is worth being precise about
// why: a WinRT toast's on-screen duration is chosen by the shell from the
// user's notification settings, and no API call overrides it. What the
// request still decides is the toast's own `duration` attribute (short vs
// long), so the value is honoured as far as the platform allows - see
// toast_xml.
const min_timeout = 1500
const max_timeout = 60000
const default_timeout = 8000

// The timeout at which a toast asks for the longer on-screen duration. The
// shell's "long" is roughly 25 s against a default of about 7 s, so the
// crossover sits nearer the default than the ceiling: anything asking for
// most of a minute wants the long one.
const long_duration_timeout = 10000

// AppIdentity is what the toast is attributed to. A desktop (unpackaged)
// app must have an AppUserModelID before the shell will show a toast for
// it, and that AUMID is what appears as the notification's name in the
// Action Center.
//
// The V side carries it as an opaque string and never interprets it; the
// charset rules live in `config.validate_identifier` (this is a framework
// app identity, not a service detail). The toast backend registers it with
// the shell on first use.
pub struct AppIdentity {
pub mut:
	// id is the AppUserModelID, e.g. 'com.example.myapp'.
	id string
	// display_name is the human-readable name the Action Center shows.
	// Empty falls back to the id inside the backend.
	display_name string
}

// The mechanism names notify resolves with. A single string that says which
// OS path actually ran, so a frontend (and an E2E screenshot) can tell a
// real toast from a stub without a second command.
//
// One value today ('toast'): the balloon fallback was deliberately removed
// rather than kept, because a notification that changes mechanism
// depending on the machine is harder to reason about than one that fails
// loudly (ADR-0018).
pub const backend_toast = 'toast'

// The reason codes vails_toast_diagnose returns across the shim boundary.
// Declared here rather than in the C half because the *sentences* below are
// the part worth testing, and a test cannot reach C.
//
// These strings are a wire contract of sorts: the C half spells them as macros
// (see toast_shim.h's vails_toast_reason_*), and nothing enforces that they
// match. If you change one, change both — and `notification_test.v` will tell
// you whether the V half still recognises every code it is asked about.
pub const toast_reason_ok = ''
pub const toast_reason_no_class_store = 'no-class-store'
pub const toast_reason_not_registered = 'not-registered'
pub const toast_reason_activate_failed = 'activate-failed'
pub const toast_reason_init_failed = 'init-failed'
// Not from C: the reason on a platform with no WinRT at all, so that
// `notification_support` can use one code path instead of two.
pub const toast_reason_other_platform = 'other-platform'

// toast_failure_note turns a reason code into a sentence a reader can act on.
//
// ## Why this exists rather than printing the HRESULT
//
// The activation failure is `REGDB_E_CLASSNOTREG (0x80040154)`, and that one
// HRESULT has two causes that send a reader to completely different places:
//
//   - the app's AppUserModelID is wrong or unregistered — a Vails bug;
//   - the machine has no system WinRT class store at all — a broken or
//     deliberately stripped Windows image, which no amount of correct code
//     fixes.
//
// Measured on Windows 11 build 28000 (ADR-0039): the second case, and
// `HKLM\SOFTWARE\Classes\ActivatableClasses\ClassId` was *absent* while COM
// and WinSxS were intact. Reporting only the HRESULT sends the reader to
// `bundle.identifier`, which is already correct on such a machine.
//
// So the note names the branch that is missing, and gives the two commands
// that repair it. `doctor` printing an action beats `doctor` printing a
// number.
//
// Pure V on purpose: the C half's registry probe cannot be unit-tested, but
// every branch below can, so the mapping is exhaustively covered even though
// the probe is not.
pub fn toast_failure_note(code string) string {
	match code {
		toast_reason_ok {
			return ''
		}
		toast_reason_no_class_store {
			return 'this Windows has no WinRT class store: ' +
				'HKLM\\SOFTWARE\\Classes\\ActivatableClasses\\ClassId is missing, ' +
				'so NO WinRT class can be activated - not just the toast ones. ' +
				'This is a stripped/debloated Windows image, not a Vails bug, and ' +
				'no AppUserModelID will fix it. Repair the component store from an ' +
				'elevated prompt (DISM /Online /Cleanup-Image /RestoreHealth, then ' +
				'sfc /scannow), or reinstall Windows in place; ' +
				'tests/e2e_windows/README.md has the details'
		}
		toast_reason_not_registered {
			return 'the WinRT class store is present but ToastNotificationManager ' +
				'is not in it (REGDB_E_CLASSNOTREG, hr=0x80040154). That is a ' +
				'partial Windows install rather than a stripped image: run ' +
				'DISM /Online /Cleanup-Image /RestoreHealth and sfc /scannow. ' +
				'A wrong AppUserModelID does not produce this HRESULT - it ' +
				'produces a toast that silently does not appear'
		}
		toast_reason_activate_failed {
			return 'the WinRT toast classes exist but activation failed for another ' +
				'reason. The WinRT component DLLs (wpncore.dll, wpnprv.dll) are the ' +
				'ones to check; they live in C:\\Windows\\System32'
		}
		toast_reason_init_failed {
			return 'this thread could not get a COM/WinRT apartment ' +
				'(RoInitialize failed). On Windows that usually means the thread ' +
				'was initialised in an incompatible apartment - a COM object on a ' +
				'thread that then calls into the toast stack'
		}
		toast_reason_other_platform {
			return 'no WinRT on this platform; notification is a Windows toast only ' +
				'(ADR-0039)'
		}
		else {
			// An unknown code means the C half learned a reason this half does
			// not know. Say the code rather than inventing a diagnosis for it.
			return 'the toast is unavailable for a reason this build does not ' +
				'recognise (code "' + code + '")'
		}
	}
}

// toast_failure_reason asks the platform *why* the toast stack is unusable,
// and returns one of the toast_reason_* codes. `toast_failure_note` turns it
// into a sentence; `notification_support` is its only caller today.
//
// A separate function rather than folding the probe into notification_support
// so that the mapping stays testable and the probe stays in the platform file
// (AGENTS.md §3: cross-platform code behind the facade).
pub fn toast_failure_reason() string {
	$if windows {
		return toast_diagnose_native()
	} $else {
		return toast_reason_other_platform
	}
}

// NotificationOptions is the params payload of notification.notify. `title`
// may be empty (a body-only toast is legal), `timeout_ms` is clamped rather
// than rejected: a frontend asking for 10 ms wants a short notification, not
// an error.
//
// The two bounds are byte counts, and they are deliberately far wider than
// anything the platform imposes: a WinRT toast's text has no fixed field
// (the XML document is the limit), so unlike the balloon this replaced,
// there is nothing to truncate against. They exist to keep a frontend from
// pushing a document into a notification box.
pub struct NotificationOptions {
pub mut:
	title      string
	body       string
	timeout_ms int = default_timeout
	// actions are the toast's buttons. Decoded and validated like any other
	// option, and then NOT sent: see toast_actions_available.
	actions []NotificationAction
}

// notification_manifest is the service manifest (T5).
pub fn notification_manifest() Service {
	return Service{
		name:     'notification'
		version:  '0.1.0'
		summary:  'short native notification'
		commands: [
			Command{
				name:    'notification.notify'
				params:  'NotificationOptions'
				result:  'string'
				summary: 'shows a notification without taking focus; resolves with the mechanism that ran'
			},
			Command{
				name:    'notification.is_supported'
				result:  'boolean'
				summary: 'reports whether this platform has a notification backend'
			},
		]
		ts_types: [
			// snake_case, because a V struct field name IS the wire name:
			// json2 does not map camelCase keys onto snake_case fields, so a
			// `timeoutMs` here would decode into nothing (ADR-0015, Notes).
			'\texport interface NotificationOptions { title?: string; body: string; timeout_ms?: number; actions?: NotificationAction[]; }',
			// `actions` is advertised even though the service does not send them
			// (toast_actions_available is false). Declaring it keeps the generated
			// types a description of the *schema*, which is stable, while the
			// capability - which is a property of this build - is what `doctor`
			// reports. A frontend can therefore generate and typecheck against the
			// full shape today and gate the UI on the capability at runtime.
			'\texport interface NotificationAction { id: string; content: string; arguments?: string; placement?: "contextual" | "system"; }',
		]
	}
}

// parse_notify_options decodes notification.notify's params. A bare JSON
// string is accepted as the body, which is what a minimal frontend sends;
// the bounds are checked by notify, which wraps them in 'bad params: …' like
// opener.
pub fn parse_notify_options(params string) !NotificationOptions {
	if params == '' || params == 'null' {
		return error('notification: no body to show')
	}
	mut opts := json2.decode[NotificationOptions](params) or {
		body := json2.decode[string](params) or {
			return error('notification: invalid options: ' + err.msg())
		}
		return with_body(body)
	}
	if opts.body.trim_space() == '' {
		return error('notification: body is required')
	}
	return opts
}

// with_body is the tail of parse_notify_options for the bare-string case, so
// the "a body must say something" rule cannot be forgotten on one path.
fn with_body(body string) !NotificationOptions {
	if body.trim_space() == '' {
		return error('notification: body is required')
	}
	return NotificationOptions{
		body: body
	}
}

// validate_notification enforces the string bounds. A negative timeout is not
// an error: the timeout is a hint (see clamp_timeout), so nothing here looks
// at it.
//
// Named for the service on purpose: a bare `validate` in this flat module
// namespace collides with the `validate` parameter of
// bridge.Router.register_validated in V's C codegen, and gcc 16 rejects the
// generated function pointer (ADR-0015, Notes).
//
// The validated byte bound is deliberately wider than anything the toast
// needs: a WinRT toast has no fixed-width text field to clip against, so a
// long body is shown whole up to the bound and refused above it, which is
// the honest thing for a box this size.
pub fn validate_notification(o NotificationOptions) ! {
	if o.title.len > max_notify_title {
		return error('notification: title is longer than ' + max_notify_title.str() +
			' characters')
	}
	if o.body.len > max_notify_body {
		return error('notification: body is longer than ' + max_notify_body.str() +
			' characters')
	}
	// A NUL would truncate both strings inside the C string the backend
	// builds - a truncation the frontend did not ask for, and the same trap
	// `tray` guards against (ADR-0015).
	if o.title.contains('\x00') {
		return error('notification: title must not contain a NUL')
	}
	if o.body.contains('\x00') {
		return error('notification: body must not contain a NUL')
	}
	validate_notification_actions(o.actions)!
}

// max_notification_actions bounds the button count. Three is what the shell has
// room for on a toast; more than that and Windows drops the extras, which is a
// silent truncation - so it is refused instead.
const max_notification_actions = 3

// validate_notification_actions checks one button list: the count, each field's
// bounds, a legal placement, and ids that are unique within the toast.
//
// Uniqueness matters more than it looks: the id is what a frontend matches a
// delivered click against, and two buttons sharing one would make the returned
// event ambiguous in a way nothing downstream could resolve.
//
// Pure V, so all of it is unit-tested even though the delivery it enables is
// not yet built.
pub fn validate_notification_actions(actions []NotificationAction) ! {
	if actions.len > max_notification_actions {
		return error('notification: at most ' + max_notification_actions.str() +
			' actions per notification')
	}
	mut seen := map[string]bool{}
	for a in actions {
		if a.id.trim_space() == '' {
			return error('notification: an action needs an id')
		}
		if a.id.len > max_action_id {
			return error('notification: action id is longer than ' +
				max_action_id.str() + ' characters')
		}
		if a.content.trim_space() == '' {
			return error('notification: action "' + a.id +
				'" needs content, which is the button label')
		}
		if a.content.len > max_action_content {
			return error('notification: action "' + a.id + '" content is longer than ' +
				max_action_content.str() + ' characters')
		}
		if a.arguments.len > max_action_arguments {
			return error('notification: action "' + a.id + '" arguments are longer than ' +
				max_action_arguments.str() + ' characters')
		}
		// A NUL truncates inside the XML document's attribute, which would produce
		// a button whose label is not the one that was validated.
		if a.id.contains('\x00') || a.content.contains('\x00')
			|| a.arguments.contains('\x00') {
			return error('notification: action "' + a.id + '" must not contain a NUL')
		}
		if effective_placement(a) != action_placement_contextual
			&& effective_placement(a) != action_placement_system {
			return error('notification: action "' + a.id + '" placement must be ' +
				action_placement_contextual + ' or ' + action_placement_system)
		}
		if a.id in seen {
			return error('notification: two actions share the id "' + a.id +
				'", so a click could not be told apart')
		}
		seen[a.id] = true
	}
}

// escape_xml escapes one text node's content for the toast document.
//
// Five entities, no more: '&' and '<' must be escaped or the document is
// malformed, '>' closes a CDATA-ish sequence by convention, and the quotes
// are escaped so the same function is safe in an attribute value if the
// toast ever grows one. Everything else - including the emoji and accented
// letters a notification is likely to carry - passes through untouched,
// because the document is UTF-8 from end to end.
//
// This is the single most bug-prone line in the whole toast path: an
// unescaped '<' from a frontend turns a notification into a document the
// shell refuses to parse, and the symptom (nothing appears) points nowhere
// near the cause. Hence a pure function with its own tests.
pub fn escape_xml(s string) string {
	mut out := []u8{}
	for c in s {
		entity := match c {
			`&` { '&amp;' }
			`<` { '&lt;' }
			`>` { '&gt;' }
			`"` { '&quot;' }
			`'` { '&apos;' }
			else { '' }
		}
		if entity != '' {
			// A []u8 accumulator because one escaped char is five bytes:
			// `out << entity` is a []u8 append of a string, which V rejects.
			out << entity.bytes()
		} else {
			out << u8(c)
		}
	}
	return out.bytestr()
}

// toast_duration maps a clamped timeout to the toast's `duration`
// attribute. The shell offers two on-screen durations (short and long) and
// no API to set a number of milliseconds, so this is the only part of
// timeout_ms the platform can actually honour.
pub fn toast_duration(timeout_ms int) string {
	if timeout_ms >= long_duration_timeout {
		return 'long'
	}
	return 'short'
}

// toast_xml builds the WinRT toast document for one notification.
//
// `ToastGeneric` is the only template that renders an app's own name and
// icon on Windows 10/11, and it takes the title as the first <text> and the
// body as the second. An empty title is dropped entirely rather than emitted
// as an empty node, because a blank first line is what the template uses for
// "no heading" - emitting one anyway is how a body-only notification ends
// up with a mysterious gap above it.
//
// The duration attribute comes from the clamped timeout, so the timeout is
// carried through to the one thing the shell lets us control about it.
//
// Both strings are escaped by escape_xml, which is the reason this function
// is pure V: the document is the part of the toast path most likely to be
// wrong, and it is the part `v test` can actually check.
//
// ## Where the actions go, and why they are not there today
//
// `<actions>` is a sibling of `<visual>`, a child of `<toast>`, and AFTER the
// visual element - not inside the binding, and not before it. Getting that
// nesting wrong produces a document the shell refuses to parse, whose symptom
// is that *nothing* appears, so the structure is spelled out in
// `toast_actions_element` rather than assembled here by string concatenation.
//
// The actions are appended only when `toast_actions_available` is true, which
// today it is not. Everything below is built and tested; the constant is the
// only thing standing between it and the wire.
pub fn toast_xml(opts NotificationOptions) string {
	mut out := '<toast duration="' + toast_duration(clamp_timeout(opts.timeout_ms)) +
		'"><visual><binding template="ToastGeneric">'
	if opts.title != '' {
		out += '<text>' + escape_xml(opts.title) + '</text>'
	}
	out += '<text>' + escape_xml(opts.body) + '</text>'
	out += '</binding></visual>'
	if toast_actions_available && opts.actions.len > 0 {
		out += toast_actions_element(opts.actions)
	}
	out += '</toast>'
	return out
}

// toast_actions_element builds the `<actions>` block for a toast's buttons.
//
// Present and unit-tested, unreachable in a build where
// `toast_actions_available` is false. That is deliberate and is the whole
// decision ADR-0039 records: the buttons are ready, and they are held back
// until a click can actually come back.
//
// The `arguments` attribute is always emitted, even when empty. Windows treats
// a missing attribute and an empty one the same, and emitting it unconditionally
// means the document this function builds is a literal reflection of the action
// rather than something whose shape depends on a field's value.
//
// Both attributes go through escape_xml, which matters here in a way it does not
// for `<text>`: these are attribute *values*, so an unescaped quote ends the
// attribute and turns the rest of the document into markup.
pub fn toast_actions_element(actions []NotificationAction) string {
	mut out := '<actions>'
	for a in actions {
		out += '<action content="' + escape_xml(a.content) + '" arguments="' +
			escape_xml(a.arguments) + '" placement="' + escape_xml(effective_placement(a)) +
			'"/>'
	}
	out += '</actions>'
	return out
}

// clamp_timeout maps the requested lifetime into the supported range. Pure V
// so the rule is unit-tested instead of living in a `max(min(x))` inside a
// platform file.
pub fn clamp_timeout(ms int) int {
	if ms < min_timeout {
		return min_timeout
	}
	if ms > max_timeout {
		return max_timeout
	}
	return ms
}

// notify shows one notification and returns the mechanism that ran.
//
// Nothing waits on a human, so it is not a blocking command: the document
// is handed to the shell and the handler returns. The bounds and the
// timeout clamp are applied here, not in the handler, so calling notify
// directly gets the same 'bad params: …' contract the router would produce.
//
// The identity is a parameter rather than a global (AGENTS.md §2) and not
// read from the environment: the AppUserModelID is an app property, and the
// app's config is where it lives.
pub fn notify(ctx webview.Ctx, id AppIdentity, opts NotificationOptions) !string {
	validate_notification(opts) or {
		return error(bridge.err_bad_params(err.msg()))
	}
	clamped := with_clamped_timeout(opts)
	$if windows {
		return notify_native(ctx, id, clamped)
	} $else {
		_ = clamped
		_ = id
		return error('notification.notify: not implemented on this platform yet ' +
			'(Phase 5b - libnotify or GNotification)')
	}
}

// with_clamped_timeout returns a copy of opts with the timeout inside the
// supported range. A copy rather than a mutation on purpose: a pure function
// is testable, and it keeps the `mut`-struct-parameter shape (which the V C
// backend mishandles, gcc 16 rejects the generated function pointer) out of
// the service.
pub fn with_clamped_timeout(opts NotificationOptions) NotificationOptions {
	return NotificationOptions{
		title:      opts.title
		body:       opts.body
		timeout_ms: clamp_timeout(opts.timeout_ms)
		// Carried through rather than dropped, so a clamped copy still describes
		// the notification the caller asked for. Today the actions are not sent
		// anyway (toast_actions_available); the day they are, dropping them here
		// would be a bug that no test would catch, because the gate would have
		// become true and the copy would still be empty.
		actions:    opts.actions
	}
}

// is_supported reports whether this platform has a notification backend. It
// is a compile-time answer, and it is honest: no backend means false, not a
// hopeful true.
pub fn is_supported() bool {
	$if windows {
		return is_supported_native()
	} $else {
		return false
	}
}

// notification_backend builds the handler set for one window. A rejected
// payload is 'bad params: …' from inside the service, like opener does, so
// the contract does not depend on the route the command took.
//
// `notify` resolves with the mechanism that ran (backend_toast), so a
// frontend can tell a real notification from a no-op without a second
// command - and so an E2E run can prove the toast path by what the page
// says, which is the only machine-checkable evidence a toast produces
// (ADR-0018).
pub fn notification_backend(ctx webview.Ctx, id AppIdentity) Backend {
	mut backend := Backend{}
	backend['notification.notify'] = fn [ctx, id] (params string) !string {
		opts := parse_notify_options(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		return notify(ctx, id, opts)!
	}
	backend['notification.is_supported'] = fn (_ string) !string {
		return json2.encode(is_supported(), escape_unicode: true)
	}
	return backend
}

// install_notification binds the notification service on router for one
// window, attributing its toasts to `id`.
//
// The identity is taken here rather than derived inside the service: it is
// the app's own config value (vails.json bundle.identifier), and a service
// that guessed one would make two apps with the same executable name share
// a single Action Center entry.
pub fn install_notification(mut router bridge.Router, ctx webview.Ctx, id AppIdentity) ! {
	install(mut router, notification_manifest(), notification_backend(ctx, id))!
}

// notification_support answers "can this platform show a notification?" (see
// support.v). Same `$if` as the dispatch, so the two cannot disagree about
// *which* platforms have a backend.
//
// ## Why this probes, when `is_supported()` deliberately does not
//
// There are two questions and they have different answers:
//
//   - `is_supported()` — **is the backend compiled into this build?** A compile
//     time fact, true on every Windows machine, and `notification_test.v` asserts
//     exactly that. Correct as it is.
//   - `notification_support()` — **can a notification actually be shown *here,
//     now*?** That is `toast_failure_reason()`, which activates the WinRT
//     classes and reports which way it failed (ADR-0039).
//
// `support.v`'s contract says `ready` means "the command works here", which is the
// second question. The first version of this function answered the *first* one by
// hardcoding `ready: true`, and the showcase's verify run on 2026-10-03 caught
// exactly the consequence: `doctor` printed `ok notification`, the showcase's
// support table said ready, so the panel called `notification.notify` — and it
// failed with `RoGetActivationFactory` → `hr=0x80040154` (REGDB_E_CLASSNOTREG,
// the ToastNotificationManager class is not registered in that session).
//
// So the honest answer costs one probe, and the probe already existed: it was
// `toast_available()`, defined and **called by nothing**. That dead function was
// the whole bug.
//
// It then got *better* rather than just being wired up (ADR-0039): a bool
// cannot distinguish a Vails bug from a broken Windows image, so the probe
// became `toast_failure_reason()` and the note below is generated from the
// cause. The dead function was the bug; the HRESULT was the next one, because
// the fix made `doctor` confident and specific about the wrong thing.
pub fn notification_support() ServiceStatus {
	$if windows {
		reason := toast_failure_reason()
		if reason == toast_reason_ok {
			mut note := 'WinRT toast (Windows.UI.Notifications); needs bundle.identifier as the AppUserModelID'
			if !toast_actions_available {
				note += '. Toast action BUTTONS are not sent: ' + toast_actions_blocked
			}
			return ServiceStatus{
				name:  'notification'
				ready: true
				note:  note
			}
		}
		// Not ready. The note names the cause rather than reporting the
		// HRESULT, because one HRESULT covers "your AppUserModelID is wrong"
		// and "this Windows has no WinRT at all" and those need opposite fixes
		// (ADR-0039). The leading clause still says the backend is built in,
		// so a reader can tell a missing implementation from a broken machine.
		return ServiceStatus{
			name:  'notification'
			ready: false
			note:  'the toast backend IS built in (notification.is_supported is ' +
				'true), but a toast cannot be shown here: ' +
				toast_failure_note(reason)
		}
	} $else {
		return ServiceStatus{
			name:  'notification'
			ready: false
			note:  toast_failure_note(toast_reason_other_platform)
		}
	}
}
