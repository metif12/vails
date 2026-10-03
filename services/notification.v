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
			'\texport interface NotificationOptions { title?: string; body: string; timeout_ms?: number; }',
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
pub fn toast_xml(opts NotificationOptions) string {
	mut out := '<toast duration="' + toast_duration(clamp_timeout(opts.timeout_ms)) +
		'"><visual><binding template="ToastGeneric">'
	if opts.title != '' {
		out += '<text>' + escape_xml(opts.title) + '</text>'
	}
	out += '<text>' + escape_xml(opts.body) + '</text>'
	out += '</binding></visual></toast>'
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
// support.v). Same `$if` as the dispatch, so the two cannot disagree.
pub fn notification_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'notification'
			ready: true
			note:  'WinRT toast (Windows.UI.Notifications); needs bundle.identifier as the AppUserModelID'
		}
	} $else {
		return ServiceStatus{
			name:  'notification'
			ready: false
			note:  'no backend on this platform yet (Phase 5b: libnotify or GNotification)'
		}
	}
}
