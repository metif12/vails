// services/balloon.v - the balloon service: a tray balloon, shown on request,
// under its own name.
//
// ## Why this exists when `notification` does not (ADR-0039)
//
// `notification` is a WinRT toast and nothing else - no fallback, no
// substitution - because a notification that changes mechanism depending on
// the machine is harder to reason about than one that fails loudly
// (ADR-0018). That decision stands and this file does not touch it: no code
// path here is reachable from `notification`, and the two services never
// appear in one command's result.
//
// So what is this for? A machine where WinRT cannot be activated at all.
// Measured on Windows 11 build 28000: `HKLM\SOFTWARE\Classes\ActivatableClasses\ClassId`
// absent, so *no* WinRT class activates and the toast fails with
// REGDB_E_CLASSNOTREG no matter how correct the app is. A framework whose only
// way to tell the user something depends on a system component the user cannot
// repair from inside the app is a framework with one user-facing capability.
//
// The balloon is pure Win32 + shell32, so it works there. It is also honestly
// lesser - Windows 11 routes it to the Action Center under the name of the
// bare `.exe`, it cannot carry an app name or icon, and it is not a real toast.
// It is a *secondary* service and its manifest says so.
//
// ## The dead-icon hazard
//
// ADR-0018 named three objections to the balloon as a notification; two were
// about attribution, and the third was mechanical: `NIF_INFO` attaches to a
// tray icon, that icon must outlive the balloon, and so something has to delete
// it afterwards - "which is why the balloon needed a V worker to delete the
// icon again, and why a single stray worker would have left a row of dead
// icons".
//
// The fix here is not a cleverer worker, it is a per-call icon id:
// `balloon_icon_id` hands out a different `uId` for each call, so a late worker
// can only ever delete its own icon, and deleting an icon that is already gone
// is a shell no-op. A stale worker is harmless instead of fatal, and the wrap
// around is a pure function so it can be tested without a shell.
//
// ## What is in this file
//
// The options, their bounds, the timeout policy and the icon-id policy - all
// pure, all unit-tested in balloon_test.v - plus the manifest and the routing.
// The OS half is `Shell_NotifyIconW` with `NIF_INFO` (balloon_windows.c.v) and
// an explicit stub on Linux.
module services

import bridge
import json2
import webview

// Bounds on the two strings. The shell truncates rather than refuses
// (`set_wide_field`), so these are a guard rail on the frontend rather than a
// guarantee about what is displayed - a caller that exceeds them is told, and
// one that does not may still see a clipped tail.
//
// The bounds are the shell's own field widths from NotifyIconData (szInfoTitle
// is 64 units, szInfo 256), minus the NUL. Matching them means the bound is
// never a Vails invention: there is no value a caller could send that the
// platform would have displayed in full anyway.
const max_balloon_title = 63
const max_balloon_body = 255

// The balloon's lifetime, and the clamp around it.
//
// The floor is the shortest a balloon can be readable; the ceiling is the
// longest the shell honours (NIIF uses a documented range, and anything beyond
// it is capped by the shell anyway). Unlike a toast's `duration` - which the
// shell decides from the user's own settings - this value is honoured, because
// it is both the shell's `uTimeout` and how long the temporary icon lives.
const min_balloon_timeout = 1500
const max_balloon_timeout = 30000
const default_balloon_timeout = 8000

// How long the temporary icon outlives the balloon itself.
//
// The grace period is the point of this constant. `uTimeout` controls when the
// balloon text goes away; nothing removes the *icon*, so the icon is removed
// after the timeout plus this margin. Without the margin the icon can vanish
// while its own balloon is still on screen, which shows the user a message with
// no icon beside it - the one visual artefact that makes a balloon look broken.
const balloon_icon_grace_ms = 1500

// The icon id space. `Shell_NotifyIconW` identifies an icon by (hWnd, uId), so
// every live balloon needs its own id or they overwrite each other and the
// loser's cleanup deletes the winner's icon.
//
// This span is what makes a stale worker harmless rather than dangerous: with
// 1024 ids, a worker that wakes up very late deletes an id that has most likely
// been reused by a *different*, still-showing balloon - which is the old bug
// again. The span is therefore sized against the real worst case rather than
// chosen for convenience: a caller would have to issue 1024 balloons, each
// outliving its own icon grace period, inside one grace period to hit it. At
// the clamp that is over four minutes of back-to-back balloons, and the
// consequence is one missing icon - not a crash, not a leak, and not a wrong
// message.
const balloon_uid_span = 1024
const balloon_icon_base = u32(0x42414C4E) // "BALN"

// BalloonOptions is the params payload of balloon.show.
//
// A bare JSON string is accepted as the body, matching `notification.notify` -
// a minimal frontend should be able to say something in one call.
pub struct BalloonOptions {
pub mut:
	title      string
	body       string
	timeout_ms int = default_balloon_timeout
}

// balloon_manifest is the service manifest (T5).
pub fn balloon_manifest() Service {
	return Service{
		name:     'balloon'
		version:  '0.1.0'
		summary:  'tray balloon: a short shell message, secondary to notification'
		commands: [
			Command{
				name:    'balloon.show'
				params:  'BalloonOptions'
				result:  'string'
				summary: 'shows a tray balloon and resolves with the mechanism that ran'
			},
			Command{
				name:    'balloon.is_supported'
				result:  'boolean'
				summary: 'reports whether this platform has a balloon backend'
			},
		]
		ts_types: [
			// snake_case, because a V struct field name IS the wire name (ADR-0015,
			// Notes): json2 does not map camelCase onto snake_case fields.
			'\texport interface BalloonOptions { title?: string; body: string; timeout_ms?: number; }',
		]
	}
}

// parse_balloon_options decodes balloon.show's params, accepting a bare string
// as the body. Empty is an error rather than an empty balloon: a balloon with
// no text is a tray icon with nothing attached to it.
pub fn parse_balloon_options(params string) !BalloonOptions {
	if params == '' || params == 'null' {
		return error('balloon: no body to show')
	}
	mut opts := json2.decode[BalloonOptions](params) or {
		body := json2.decode[string](params) or {
			return error('balloon: invalid options: ' + err.msg())
		}
		return balloon_with_body(body)
	}
	if opts.body.trim_space() == '' {
		return error('balloon: body is required')
	}
	return opts
}

// balloon_with_body is the tail of parse_balloon_options for the bare-string
// case, so the "a body must say something" rule cannot be forgotten on one path.
fn balloon_with_body(body string) !BalloonOptions {
	if body.trim_space() == '' {
		return error('balloon: body is required')
	}
	return BalloonOptions{
		body: body
	}
}

// validate_balloon enforces the bounds. `timeout_ms` is clamped rather than
// rejected, exactly like notification's: a caller asking for 10 ms wants a short
// balloon, not an error.
pub fn validate_balloon(o BalloonOptions) ! {
	if o.title.len > max_balloon_title {
		return error('balloon: title is longer than ' + max_balloon_title.str() +
			' characters')
	}
	if o.body.len > max_balloon_body {
		return error('balloon: body is longer than ' + max_balloon_body.str() +
			' characters')
	}
	// A NUL would truncate both strings inside the wide field the shell writes,
	// a truncation the caller did not ask for - the same trap notification and
	// tray both guard (ADR-0015).
	if o.title.contains('\x00') {
		return error('balloon: title must not contain a NUL')
	}
	if o.body.contains('\x00') {
		return error('balloon: body must not contain a NUL')
	}
}

// clamp_balloon_timeout maps a requested lifetime into the supported range.
pub fn clamp_balloon_timeout(ms int) int {
	if ms < min_balloon_timeout {
		return min_balloon_timeout
	}
	if ms > max_balloon_timeout {
		return max_balloon_timeout
	}
	return ms
}

// balloon_with_clamped_timeout returns a copy of opts with the timeout inside
// the supported range. A copy, not a mutation on purpose: pure, and it keeps
// the `mut`-struct-parameter shape out of the service (V's C backend mishandles
// it - gcc 16 rejects the generated function pointer).
pub fn balloon_with_clamped_timeout(opts BalloonOptions) BalloonOptions {
	return BalloonOptions{
		title:      opts.title
		body:       opts.body
		timeout_ms: clamp_balloon_timeout(opts.timeout_ms)
	}
}

// balloon_cleanup_ms is how long the temporary icon survives: the balloon's own
// lifetime plus the grace period.
//
// This is the dead-icon policy as one pure function, because the alternative -
// the number appearing in a `spawn`'s sleep - cannot be asserted on at all, and
// a policy that cannot be tested is a policy that gets shortened by someone in a
// hurry.
pub fn balloon_cleanup_ms(timeout_ms int) int {
	return clamp_balloon_timeout(timeout_ms) + balloon_icon_grace_ms
}

// balloon_icon_id returns the shell icon id for call number `seq`.
//
// The wrap is the edge case worth having a test for rather than a comment: after
// `balloon_uid_span` calls the ids repeat, and the design says that is benign
// because a late worker then deletes only the icon at its own (hWnd, uId), which
// the shell treats as already gone.
//
// V's `%` is a *truncated* remainder, so `-1 % 1024` is `-1` rather than `1023`.
// Nothing here passes a negative seq - the counter starts at zero and only goes
// up - but the floored branch is kept because the alternative is a function
// whose stated invariant ("always base + [0, span)") is false for one input,
// and a reader is entitled to rely on that.
pub fn balloon_icon_id(seq int) u32 {
	mut offset := seq % balloon_uid_span
	if offset < 0 {
		offset += balloon_uid_span
	}
	return balloon_icon_base + u32(offset)
}

// BalloonState is the service's per-window state: the counter behind
// `balloon_icon_id`.
//
// A struct rather than a module-level counter because AGENTS.md §2 forbids
// globals, and a struct is also what makes the counter testable - a test can
// make two calls against one state and assert the ids differ. `tray` owns its
// state for the same reason (its host hook has to outlive the call that
// installed it); here the state is smaller but the rule is identical.
pub struct BalloonState {
mut:
	seq int
}

// next_icon_id advances this state's counter and returns the icon id for the
// call.
//
// Not thread-safe, and deliberately so: the handlers for one window run on its
// main thread (ADR-0010/0014), which is the assumption that makes this a plain
// increment. It is the assumption to re-check first if balloon.show ever
// becomes callable from more than one thread.
pub fn (mut st BalloonState) next_icon_id() u32 {
	id := balloon_icon_id(st.seq)
	st.seq++
	return id
}

// The mechanism names show resolves with. One value, and it is the honest one:
// unlike `notification` there is nothing to confuse it with, because the toast
// is a different service.
pub const balloon_backend_balloon = 'balloon'

// show_balloon raises one balloon and returns the mechanism that ran.
//
// Not a blocking command: the shell owns the message's lifetime, so the handler
// returns as soon as the balloon is up. The temporary icon outlives this call on
// purpose - the shell attaches the text to the icon, so removing it here would
// remove the message with it.
pub fn show_balloon(mut st &BalloonState, ctx webview.Ctx, opts BalloonOptions) !string {
	validate_balloon(opts) or {
		return error(bridge.err_bad_params(err.msg()))
	}
	clamped := balloon_with_clamped_timeout(opts)
	$if windows {
		return show_balloon_native(ctx, st.next_icon_id(), clamped)
	} $else {
		_ = clamped
		_ = ctx
		_ = st
		return error('balloon.show: not implemented on this platform yet ' +
			'(Phase 5b - the GTK notification API, which is not a balloon)')
	}
}

// is_supported reports whether this platform has a balloon backend. A
// compile-time answer, and honest: no backend means false.
pub fn balloon_is_supported() bool {
	$if windows {
		return balloon_is_supported_native()
	} $else {
		return false
	}
}

// balloon_backend builds the handler set for one window.
//
// The `mut state := st` dance is tray's, and it is load-bearing rather than
// stylistic: on this compiler a closure that captures a `mut &T` *parameter*
// captures a copy, so the handler's writes land in the closure's own
// environment and the counter never advances - which would hand every balloon
// the same icon id and put ADR-0018's row of dead icons straight back
// (AGENTS.md §2c).
pub fn balloon_backend(mut st &BalloonState, ctx webview.Ctx) Backend {
	mut state := st
	mut backend := Backend{}
	backend['balloon.show'] = fn [ctx, mut state] (params string) !string {
		opts := parse_balloon_options(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		return show_balloon(mut state, ctx, opts)!
	}
	backend['balloon.is_supported'] = fn (_ string) !string {
		return json2.encode(balloon_is_supported(), escape_unicode: true)
	}
	return backend
}

// install_balloon binds the balloon service on router for one window and
// returns its state, for the same reason install_tray does: the state has to
// outlive the call that created it.
//
// No AppIdentity parameter, unlike install_notification: Windows 11 attributes a
// balloon to the bare executable name and it cannot carry an app name or icon
// (ADR-0018), so an identity here would be a parameter that cannot change
// anything.
pub fn install_balloon(mut router bridge.Router, ctx webview.Ctx) !&BalloonState {
	mut st := &BalloonState{}
	install(mut router, balloon_manifest(), balloon_backend(mut st, ctx))!
	return st
}

// balloon_support answers "can this platform show a balloon?" (see support.v).
//
// Same `$if` as the dispatch, so the two cannot disagree about which platforms
// have a backend. Not runtime-probed like notification_support, and the
// difference is the point: a balloon needs nothing from the machine that the
// build does not already link, so there is no second question to ask.
pub fn balloon_support() ServiceStatus {
	$if windows {
		return ServiceStatus{
			name:  'balloon'
			ready: true
			note:  'Shell_NotifyIconW with NIF_INFO; a secondary shell message, NOT a Windows toast - notification is that (ADR-0039). Attributed to the bare .exe name'
		}
	} $else {
		return ServiceStatus{
			name:  'balloon'
			ready: false
			note:  'no balloon backend on this platform: a GTK notification is not a shell balloon, and pretending otherwise would give the frontend a mechanism name it cannot honour (ADR-0039)'
		}
	}
}
