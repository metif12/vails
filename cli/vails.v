// vails CLI — minimal in Phase 0 (version/doctor/init), grows in Phase 4.
// Panics/exits are fine here (never in library modules).
module main

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
		else {
			eprintln('unknown command: ' + args[0])
			print_usage()
			exit(1)
		}
	}
}

fn print_usage() {
	println('usage: vails <version|doctor|init [name]>')
	println('  Phase 4 adds: run, build')
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
	println('created ./' + name + '/main.v — run it on Linux with: v run ./' + name)
}
