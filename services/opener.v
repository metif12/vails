// services/opener.v - the opener service: hand a path or a URL to whatever
// the user has chosen as the default handler (Phase 5 S1 wave 2).
//
// Pure-V half: the two commands' params, the validation that matters for
// security, and the manifest. The OS half is one function per platform
// (ShellExecuteW on Windows, GIO's g_app_info_launch_default_for_uri on
// Linux) because both are a single call to the shell.
//
// Why the validation is not decoration: `opener` is the one service whose
// whole job is to make the OS do something with a string the frontend
// supplied. `open_url` therefore accepts only http/https/mailto/tel, and
// `open_path` only a local path - so a granted capability cannot be turned
// into `file://` exfiltration, a UNC share, or an ms-msdt:/smb: launch. This
// is the same allowlist Tauri applies (ADR-0015).
module services

import bridge
import json2
import webview

// Bounds on the two payloads. A URL is a sentence; a path is a path.
const max_url_len = 2048
const max_path_len = 1024

// The schemes open_url accepts, in the order the error message lists them.
const url_schemes = ['http', 'https', 'mailto', 'tel']

// OpenerUrlOptions is the params payload of opener.open_url. The field is
// named `url` because that is what the generated .d.ts promises the
// frontend - the wire shape and the TS shape are the same thing.
pub struct OpenerUrlOptions {
pub mut:
	url string
}

// OpenerPathOptions is the params payload of opener.open_path. `with` names
// an application to use instead of the default handler; it is Windows only
// for now, because on Linux the desktop resolves the application itself and
// an application *name* has no equivalent (the backend says so instead of
// pretending).
pub struct OpenerPathOptions {
pub mut:
	path string
	with string
}

// open_url_manifest is the service manifest (T5).
pub fn opener_manifest() Service {
	return Service{
		name:     'opener'
		version:  '0.1.0'
		summary:  'open a path or URL in the default application'
		commands: [
			Command{
				name:    'opener.open_url'
				params:  'OpenerUrlOptions'
				result:  'string'
				summary: 'opens a URL with the default handler (http, https, mailto, tel)'
			},
			Command{
				name:    'opener.open_path'
				params:  'OpenerPathOptions'
				result:  'string'
				summary: 'opens a local file or directory with the default handler'
			},
		]
		ts_types: opener_ts_types()
	}
}

// opener_ts_types are the TypeScript shapes the generated .d.ts refers to.
// They live in the manifest so codegen needs no second source.
fn opener_ts_types() []string {
	return [
		'\texport interface OpenerUrlOptions { url: string; }',
		'\texport interface OpenerPathOptions { path: string; with?: string; }',
	]
}

// parse_url_options decodes opener.open_url's params: the object the .d.ts
// promises, or a bare JSON string (what a minimal frontend sends).
pub fn parse_url_options(params string) !OpenerUrlOptions {
	if params == '' || params == 'null' {
		return error('opener: no url for this command')
	}
	mut opts := json2.decode[OpenerUrlOptions](params) or {
		raw := json2.decode[string](params) or {
			return error('opener: invalid options: ' + err.msg())
		}
		return OpenerUrlOptions{
			url: raw
		}
	}
	if opts.url == '' {
		return error('opener: url is required')
	}
	return opts
}

// parse_path_options decodes opener.open_path's params, with the same
// bare-string fallback.
pub fn parse_path_options(params string) !OpenerPathOptions {
	if params == '' || params == 'null' {
		return error('opener: no path for this command')
	}
	mut opts := json2.decode[OpenerPathOptions](params) or {
		raw := json2.decode[string](params) or {
			return error('opener: invalid options: ' + err.msg())
		}
		return OpenerPathOptions{
			path: raw
		}
	}
	if opts.path == '' {
		// A payload carrying only `with` is a mistake worth naming.
		return error('opener: path is required')
	}
	return opts
}

// validate_url enforces the scheme allowlist and the length bound. A URL
// without a scheme is rejected rather than guessed: prepending https:// would
// turn a typo into a request to a host the user never named.
pub fn validate_url(url string) ! {
	if url.len > max_url_len {
		return error('opener: url is longer than ' + max_url_len.str() + ' characters')
	}
	scheme := url_scheme(url)
	if scheme == '' {
		return error('opener: url needs a scheme (' + url_schemes.join(', ') +
			'), got "' + url + '"')
	}
	if scheme !in url_schemes {
		return error('opener: scheme "' + scheme + '" is not allowed (' +
			url_schemes.join(', ') + ')')
	}
	// What follows the colon has to say something: 'https://' or 'mailto:'
	// with nothing behind them is a frontend bug, not a URL.
	if url[scheme.len + 1..].trim_left('/').trim_space() == '' {
		return error('opener: url has nothing after "' + scheme + ':"')
	}
}

// validate_path enforces the local-path rules: a non-empty absolute-looking
// path, no URL scheme, and no NUL. Relative paths are allowed (the app may
// have a working directory it means), but a scheme is not - that is the
// open_url command's job, and letting it slip through here would make
// open_path a second way to launch a URL with a different validation.
pub fn validate_path(path string) ! {
	if path.len > max_path_len {
		return error('opener: path is longer than ' + max_path_len.str() + ' characters')
	}
	if path.trim_space() == '' {
		return error('opener: path is empty')
	}
	if path.contains('://') || url_scheme(path) != '' {
		return error('opener: open_path takes a local path, not a URL (use open_url)')
	}
	if path.contains('\x00') {
		return error('opener: path contains a NUL byte')
	}
}

// url_scheme returns the lowercase scheme of a URI, or the empty string when
// there is none. Only the part before the first colon counts, and only when
// the prefix is a real scheme: letters, digits, '+', '-', '.' - which is what
// keeps 'C:\\notes.txt' from reading as the scheme "c".
pub fn url_scheme(url string) string {
	idx := url.index(':') or { return '' }
	if idx < 2 {
		return ''
	}
	candidate := url[..idx]
	for ch in candidate {
		c := u8(ch)
		is_alpha := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
		is_digit := c >= `0` && c <= `9`
		if !is_alpha && !is_digit && c != `+` && c != `-` && c != `.` {
			return ''
		}
	}
	return candidate.to_lower()
}

// open_url hands a URL to the default handler. The result is the backend's
// own report: '' when the OS took it. Nothing here waits on a human (the
// browser or mail client is a separate process), so it is not a blocking
// command.
//
// A rejected URL is reported as 'bad params: …' even when open_url is called
// directly rather than through the router: it is the frontend's payload that
// is wrong, which is exactly what the ADR-0010 prefix is for. Keeping the
// wrapping here means the wire contract cannot differ between the two ways
// into this function.
pub fn open_url(url string) ! {
	validate_url(url) or {
		return error(bridge.err_bad_params(err.msg()))
	}
	$if windows {
		open_url_native(url)!
	} $else $if linux {
		open_url_native(url)!
	} $else {
		_ = url
		return error('services.open_url: not implemented on this platform yet (Phase 6, macOS backend)')
	}
}

// open_path hands a local path to the default handler. `with` names an
// application to use instead of the default; an empty string means the
// default. Rejections are 'bad params: …' for the same reason as open_url.
pub fn open_path(path string, with string) ! {
	validate_path(path) or {
		return error(bridge.err_bad_params(err.msg()))
	}
	if with.len > max_path_len {
		return error(bridge.err_bad_params('with is longer than ' +
			max_path_len.str() + ' characters'))
	}
	$if windows {
		open_path_native(path, with)!
	} $else $if linux {
		open_path_native(path, with)!
	} $else {
		_ = path
		_ = with
		return error('services.open_path: not implemented on this platform yet (Phase 6, macOS backend)')
	}
}

// opener_backend builds the handler set for one window. Option problems are
// wrapped in the standard 'bad params: …' value (ADR-0010) so a frontend can
// branch on the prefix instead of matching message text.
pub fn opener_backend(_ctx webview.Ctx) Backend {
	mut backend := Backend{}
	backend['opener.open_url'] = fn (params string) !string {
		opts := parse_url_options(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		open_url(opts.url)!
		return ''
	}
	backend['opener.open_path'] = fn (params string) !string {
		opts := parse_path_options(params) or {
			return error(bridge.err_bad_params(err.msg()))
		}
		open_path(opts.path, opts.with)!
		return ''
	}
	return backend
}

// install_opener binds the opener service on router for one window.
pub fn install_opener(mut router bridge.Router, ctx webview.Ctx) ! {
	install(mut router, opener_manifest(), opener_backend(ctx))!
}
