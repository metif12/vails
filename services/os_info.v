// os_info.v - the os-info service: host facts for the frontend.
//
// The cheapest possible service (pure V, no C, no native handle) and
// therefore the reference for how a service is written: manifest, handler
// set, one JSON result. It also gives the frontend something to render
// without a dialog, which is how the dialog example proves two services at
// once.
//
// What it deliberately does NOT expose: user names, environment variables,
// installed software, network state. Host facts an app UI needs (OS, arch,
// hostname, app data dir, process id) and nothing that turns into
// surveillance. The command is capability-gated like every other command
// (ADR-0007), so even this needs a grant.
module services

import bridge
import json2
import os
import runtime

// Info is the JSON the command resolves with.
pub struct Info {
pub mut:
	os       string = os.user_os()
	arch     string = host_arch()
	hostname string
	cwd      string
	home_dir string
	temp_dir string
	exe_path string
	cpus     int = runtime.nr_cpus()
}

// host_arch names the target arch. V exposes the arch as a compile-time
// `$if` branch, not as a runtime value, so this is the honest way to
// report it.
fn host_arch() string {
	$if amd64 {
		return 'x86_64'
	} $else $if arm64 {
		return 'aarch64'
	} $else $if i386 {
		return 'x86'
	} $else {
		return 'unknown'
	}
}

// os_info_manifest is the service manifest (T5).
pub fn os_info_manifest() Service {
	return Service{
		name:     'os_info'
		version:  '0.1.0'
		summary:  'host os, arch and paths'
		commands: [
			Command{
				name:    'os_info.get'
				result:  'OsInfo'
				summary: 'returns host facts as JSON'
			},
		]
		ts_types: [
			'\texport interface OsInfo {',
			'\t\tos: string;',
			'\t\tarch: string;',
			'\t\thostname: string;',
			'\t\tcwd: string;',
			'\t\thome_dir: string;',
			'\t\ttemp_dir: string;',
			'\t\texe_path: string;',
			'\t\tcpus: number;',
			'\t}',
		]
	}
}

// collect gathers the host facts. Split from the handler so the shape is
// testable without a router.
pub fn collect() Info {
	return Info{
		hostname: os.hostname() or { 'unknown' }
		cwd:      os.getwd()
		home_dir: os.home_dir()
		temp_dir: os.temp_dir()
		exe_path: os.executable()
	}
}

// os_info_backend is the handler set.
pub fn os_info_backend() Backend {
	mut backend := Backend{}
	backend['os_info.get'] = fn (_ string) !string {
		return json2.encode(collect(), escape_unicode: true)
	}
	return backend
}

// install_os_info binds the os-info service on router.
pub fn install_os_info(mut router bridge.Router) ! {
	install(mut router, os_info_manifest(), os_info_backend())!
}
