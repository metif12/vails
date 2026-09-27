// vails CLI — version/doctor/init plus config-validating run/build
// dry-runs (T6). Full dev-server run arrives in Phase 3, packaging in
// Phase 7. Panics/exits are fine here (never in library modules).
module main

import config
import os

const version = '0.1.0'

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		print_usage()
		return
	}
	match args[0] {
		'version' {
			println('vails ' + version + ' (MVP, linux-first)')
		}
		'doctor' {
			doctor()
		}
		'init' {
			name := if args.len > 1 { args[1] } else { 'hello' }
			init_app(name) or {
				eprintln('init failed: ' + err.msg())
				exit(1)
			}
		}
		'run' {
			cfg := load_project_config(args[1..]) or {
				eprintln('run failed: ' + err.msg())
				exit(1)
			}
			print_config_summary(cfg)
			println('dev server: planned in Phase 3 — serving "' + cfg.asset_root +
				'" statically for now')
		}
		'build' {
			cfg := load_project_config(args[1..]) or {
				eprintln('build failed: ' + err.msg())
				exit(1)
			}
			print_config_summary(cfg)
			println('bundle: "' + cfg.bundle.name + '" (packaging arrives in Phase 7; DLLs stay side-by-side on Windows)')
		}
		else {
			eprintln('unknown command: ' + args[0])
			print_usage()
			exit(1)
		}
	}
}

fn print_usage() {
	println('usage: vails <version|doctor|init [name]|run|build> [--config path]')
	println('  run/build read vails.json (default ./vails.json); full behavior in Phase 3/7')
}

// flag_value returns the value of `--flag value` or `--flag=value`,
// or fallback when the flag is absent.
fn flag_value(args []string, flag string, fallback string) string {
	for i, a in args {
		if a == flag && i + 1 < args.len {
			return args[i + 1]
		}
		if a.starts_with(flag + '=') {
			return a[flag.len + 1..]
		}
	}
	return fallback
}

fn load_project_config(args []string) !config.VailsConfig {
	path := flag_value(args, '--config', 'vails.json')
	return config.load(path)!
}

fn print_config_summary(cfg config.VailsConfig) {
	println('app: ' + cfg.name + ' ' + cfg.version)
	for w in cfg.windows {
		println('  window "' + w.label + '": "' + w.title + '" ${w.width}x${w.height}')
	}
	println('  asset_root: ' + cfg.asset_root)
	println('  capabilities: ' + cfg.capabilities.len.str())
}

fn doctor() {
	println('vails doctor')
	println('  v version : check with `v version` (need 0.5.x)')
	println('  os        : ' + os.user_os())
	$if linux {
		r := os.execute('pkg-config --modversion webkit2gtk-4.1')
		if r.exit_code == 0 {
			println('  webkit2gtk: ' + r.output.trim_space())
		} else {
			println('  webkit2gtk: MISSING (sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev)')
		}
	} $else $if windows {
		gcc := os.execute('gcc --version')
		if gcc.exit_code == 0 {
			println('  gcc       : ' + gcc.output.split_into_lines()[0])
		} else {
			println('  gcc       : MISSING (install MSYS2 ucrt64 toolchain + put C:\\msys64\\ucrt64\\bin on PATH)')
		}
		header := 'C:/msys64/ucrt64/include/webview/webview.h'
		if os.exists(header) {
			println('  webview   : header found (' + header + ')')
		} else {
			println('  webview   : MISSING (pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader)')
		}
	} $else {
		println('  webview   : Windows/Linux only in this MVP (Phase 6 adds macOS)')
		println('  note      : pure-V modules (bridge/events/assets/…) still testable here')
	}
	if os.exists('vails.json') {
		config.load('vails.json') or {
			println('  vails.json: INVALID (' + err.msg() + ')')
			return
		}
		println('  vails.json: ok')
	} else {
		println('  vails.json: not found (optional here; `vails init` creates one)')
	}
}

const hello_main = "module main

import webview

fn main() {
	webview.run(title: 'Hello Vails', html: '<h1>Hello from Vails</h1>') or {
		eprintln(err.msg())
		exit(1)
	}
}
"

fn init_app(name string) ! {
	os.mkdir_all(name) or { return error('cannot create dir: ' + err.msg()) }
	os.write_file(os.join_path(name, 'main.v'), hello_main)!
	os.write_file(os.join_path(name, 'vails.json'), config.default_config(name).encode())!
	println('created ./' + name + '/main.v — run it on Linux with: v run ./' + name)
	println('created ./' + name + '/vails.json — validate with: vails doctor')
}
