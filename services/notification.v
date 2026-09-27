// services/notification.v - the notification service: a short native message
// the OS shows without stealing focus (Phase 5 S1 wave 2).
//
// Pure-V half: the options, their bounds, the timeout clamp and the
// manifest. The OS half is a tray balloon on Windows
// (notification_windows.c.v) and an explicit stub on Linux
// (notification_linux.c.v).
//
// Why a balloon and not a WinRT toast: a toast needs the WinRT/COM stack
// reached by hand (RoActivateInstance, IToastNotificationManagerStatics, an
// XML payload as HSTRING), which is exactly the kind of code ADR-0014 keeps
// behind a shim and that no amount of `v test` can check. Shell_NotifyIconW
// is two flat C calls, the shell renders it as a real notification on
// Windows 10/11, and the one thing it costs is that the icon lives in the
// tray while the balloon is up - which is why the lifetime is explicit here
// (see notify_native). The WinRT toast is recorded as the follow-up in
// ADR-0015, together with the real `tray` service it shares code with.
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

// The balloon's lifetime, in milliseconds. The floor keeps a notification
// readable rather than a flicker; the ceiling keeps a stuck one from
// outliving the app that sent it.
const min_timeout = 1500
const max_timeout = 60000
const default_timeout = 8000

// NotificationOptions is the params payload of notification.notify. `title`
// may be empty (a body-only balloon is legal), `timeout_ms` is clamped rather
// than rejected: a frontend asking for 10 ms wants a short notification, not
// an error.
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
				summary: 'shows a notification without taking focus'
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
pub fn validate_notification(o NotificationOptions) ! {
	if o.title.len > max_notify_title {
		return error('notification: title is longer than ' + max_notify_title.str() +
			' characters')
	}
	if o.body.len > max_notify_body {
		return error('notification: body is longer than ' + max_notify_body.str() +
			' characters')
	}
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

// notify shows one notification. Nothing waits on a human, so it is not a
// blocking command: the balloon is handed to the shell and the handler
// returns. The bounds and the timeout clamp are applied here, not in the
// handler, so calling notify directly gets the same 'bad params: …'
// contract the router would produce.
pub fn notify(ctx webview.Ctx, opts NotificationOptions) ! {
	validate_notification(opts) or {
		return error(bridge.err_bad_params(err.msg()))
	}
	clamped := with_clamped_timeout(opts)
	$if windows {
		notify_native(ctx, clamped)!
	} $else {
		_ = clamped
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
pub fn notification_backend(ctx webview.Ctx) Backend {
	mut backend := Backend{}
	backend['notification.notify'] = fn [ctx] (params string) !string {
		opts := parse_notify_options(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		notify(ctx, opts) or {
			return error(err.msg())
		}
		return ''
	}
	backend['notification.is_supported'] = fn (_ string) !string {
		return json2.encode(is_supported(), escape_unicode: true)
	}
	return backend
}

// install_notification binds the notification service on router for one
// window.
pub fn install_notification(mut router bridge.Router, ctx webview.Ctx) ! {
	install(mut router, notification_manifest(), notification_backend(ctx))!
}

// notification_support answers "can this platform show a notification?" (see
// support.v). Same `$if` as the dispatch, so the two cannot disagree.
pub fn notification_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'notification'
			ready: true
			note:  'tray balloon (Shell_NotifyIconW); a WinRT toast would be richer'
		}
	} $else {
		return ServiceStatus{
			name:  'notification'
			ready: false
			note:  'no backend on this platform yet (Phase 5b: libnotify or GNotification)'
		}
	}
}
