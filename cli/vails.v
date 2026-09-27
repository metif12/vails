// vails CLI --- version/doctor/init/run/build/dts (Phase 4 + Phase 5 T5).
// init scaffolds a runnable project (main.v + vails.json + frontend/);
// run serves the frontend in dev mode (loopback dev server with
// livereload) and opens the first window at its URL; build compiles the
// project dir to a binary (packaging stays Phase 7); dts generates the
// frontend's TypeScript declarations + service JS snippets from the
// capability grants; doctor validates the toolchain and the project.
// Panics/exits are fine here (never in library modules).
module main

import bridge
import config
import dev
import os
import services
import webview

const version = '0.3.0'

fn main() {
	args := os.args[1..]
	if args.len == 0 {
		print_usage()
		return
	}
	match args[0] {
		'version' {
			println('vails ' + version)
		}
		'doctor' {
			doctor()
		}
		'init' {
			name := if args.len > 1 && !args[1].starts_with('--') { args[1] } else { 'hello' }
			init_app(name) or {
				eprintln('init failed: ' + err.msg())
				exit(1)
			}
		}
		'run' {
			run_dev(args[1..]) or {
				eprintln('run failed: ' + err.msg())
				exit(1)
			}
		}
		'build' {
			build_app(args[1..]) or {
				eprintln('build failed: ' + err.msg())
				exit(1)
			}
		}
		'dts' {
			emit_dts(args[1..]) or {
				eprintln('dts failed: ' + err.msg())
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
	println('usage: vails <version|doctor|init [name]|run|build|dts> [flags]')
	println('  init [name]          scaffold main.v + vails.json + frontend/')
	println('  run [--config path] [--port N] [--serve-only]')
	println('                       dev server + open first window at its URL')
	println('                       (--serve-only: just serve, no window)')
	println('  build [--config path] [--output path]')
	println('                       compile the project dir to a binary')
	println('  dts [--config path] [--out path] [--js] [--check]')
	println('                       generate .d.ts (+ --js service snippets)')
	println('                       for the granted services')
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

fn has_flag(args []string, flag string) bool {
	for a in args {
		if a == flag {
			return true
		}
	}
	return false
}

fn load_project_config(args []string) !config.VailsConfig {
	path := flag_value(args, '--config', 'vails.json')
	return config.load(path)!
}

// project_dir_of returns the directory holding the config file so asset
// reads resolve the same way regardless of the caller's cwd.
fn project_dir_of(args []string) string {
	path := flag_value(args, '--config', 'vails.json')
	dir := os.dir(path)
	if dir == '' {
		return '.'
	}
	return dir
}

// run_dev implements `vails run`: loopback dev server (spawned) + first
// window opened at its URL. The window carries an EMPTY router, so JS->V
// calls fail with 'unknown method' until the real app binary runs --- this
// mode is for frontend iteration (live reload on every file save), not
// for bridge development.
fn run_dev(args []string) ! {
	cfg := load_project_config(args)!
	port := flag_value(args, '--port', dev.default_port.str()).int()
	if port <= 0 || port > 65535 {
		return error('invalid --port (1-65535)')
	}
	root := project_dir_of(args)
	reg := cfg.to_registry()
	w := cfg.windows[0]
	srv := dev.new_dev_server(root, cfg.asset_root, port, reg, w.label)
	if has_flag(args, '--serve-only') {
		println('serving "' + os.join_path(root, cfg.asset_root) + '" at ' + srv.dev_url())
		srv.run()!
		return
	}
	_ = spawn srv.run()
	println('dev server: ' + srv.dev_url() + ' (reloads on every frontend save)')
	mut router := bridge.new_router()
	webview.run(
		label:    w.label
		title:    w.title
		width:    w.width
		height:   w.height
		url:      srv.dev_url()
		router:   &router
		registry: reg
	)!
}

// build_app implements `vails build`: compile the project dir (which must
// hold main.v, e.g. from `vails init`) to a binary. Scaffolded projects
// import vails modules by bare name (`bridge`, `webview`, ---), so the
// compiler needs the vails source root on its module path: build sets
// VMODULES to it (explicit VAILS_HOME wins, else walk-up from the CLI
// binary and the cwd). GUI backends need the native toolchain too --- see
// `vails doctor`. Packaging stays Phase 7.
fn build_app(args []string) ! {
	cfg := load_project_config(args)!
	root := project_dir_of(args)
	main_path := os.join_path(root, 'main.v')
	if !os.exists(main_path) {
		return error('no main.v in "' + root + '" (`vails init` creates one)')
	}
	home := vails_home()
	if home == '' {
		return error('cannot find the vails source root (no v.mod + webview/ found from the CLI or cwd) --- set VAILS_HOME to your vails checkout')
	}
	out := flag_value(args, '--output', cfg.bundle.name)
	mut cc := ''
	$if windows {
		cc = ' -cc gcc'
	}
	cmd := 'v' + cc + ' -o "' + out + '" "' + root + '"'
	println('+ VMODULES=' + home + ' ' + cmd)
	old_modules := os.getenv('VMODULES')
	os.setenv('VMODULES', join_modules_path(home, old_modules), true)
	r := os.execute(cmd)
	os.setenv('VMODULES', old_modules, true)
	if r.exit_code != 0 {
		return error('compile failed:\n' + r.output)
	}
	println('built: ' + out + ' (DLLs stay side-by-side on Windows; packaging arrives in Phase 7)')
}

// granted_service_commands flattens the capability command lists of a
// config into the unique command names the frontend may call.
fn granted_service_commands(cfg config.VailsConfig) []string {
	mut out := []string{}
	for spec in cfg.capabilities {
		out << spec.commands.clone()
	}
	return services.granted_commands(out)
}

// emit_dts implements `vails dts` (T5): the frontend's TypeScript
// declarations for the services its capabilities actually grant, plus the
// per-service JS snippets. Generation is driven by vails.json, so a
// frontend can only type-check against what it was allowed to call.
//   --out  path    where to write the .d.ts (default <asset_root>/vails.d.ts)
//   --js          also write <asset_root>/vails-services.js
//   --check       print what would be written, write nothing (CI use)
fn emit_dts(args []string) ! {
	cfg := load_project_config(args)!
	root := project_dir_of(args)
	out := flag_value(args, '--out', os.join_path(cfg.asset_root, 'vails.d.ts'))
	granted := granted_service_commands(cfg)
	picked, unknown := services.select_for(granted)
	if picked.len == 0 {
		return error('no granted command matches a service; add e.g. "dialog.open" to a capability in vails.json')
	}
	for name in unknown {
		// App commands (ping, counter_*) are not services, so this is
		// informational, not a failure.
		eprintln('  note: "' + name + '" is not a service command (app command, no .d.ts entry)')
	}
	header := dts_header(cfg, picked)
	// Unknown names are app commands (ping, counter_*) or typos; either
	// way they get a .d.ts entry, so the note is informational, printed
	// once on every path.
	report_unknown(unknown)
	if has_flag(args, '--check') {
		println('--- ' + os.join_path(root, out) + ' ---')
		println(header + services.dts(picked))
		return
	}
	write_if_changed(root, out, header + services.dts(picked))!
	println('wrote ' + os.join_path(root, out) + ' (' + picked.len.str() +
		' service(s): ' + picked.map(it.name).join(', ') + ')')
	if has_flag(args, '--js') {
		js_out := os.join_path(cfg.asset_root, 'vails-services.js')
		write_if_changed(root, js_out, services.snippets(picked))!
		println('wrote ' + os.join_path(root, js_out) + ' (load it from index.html)')
	}
}

// report_unknown lists granted command names no service provides.
fn report_unknown(unknown []string) {
	for name in unknown {
		eprintln('  note: "' + name + '" is not a service command (app command, no .d.ts entry)')
	}
}

// dts_header is the fixed top of the generated file: it says where the
// content comes from so nobody hand-edits it.
fn dts_header(cfg config.VailsConfig, picked []services.Service) string {
	mut out := '// Generated by `vails dts` from the capability grants in vails.json - do not edit.\n'
	out += '// Services: ' + picked.map(it.name + ' ' + it.version).join(', ') + '\n'
	out += '// App: ' + cfg.name + ' ' + cfg.version + '\n'
	return out
}

// write_if_changed keeps timestamps stable so the dev server does not
// reload the page on every `vails dts` run.
fn write_if_changed(root string, rel string, content string) ! {
	path := os.join_path(root, rel)
	if os.exists(path) && os.read_file(path)! == content {
		return
	}
	os.write_file(path, content)!
}

// vails_home locates the vails source root for VMODULES: explicit
// VAILS_HOME first, then walk-up from the CLI binary (installed next to
// source) and from the cwd (monorepo / in-checkout projects).
fn vails_home() string {
	h := os.getenv('VAILS_HOME')
	if h != '' && is_vails_root(h) {
		return h
	}
	for base in [os.dir(os.executable()), os.getwd()] {
		mut dir := base
		for _ in 0 .. 8 {
			if is_vails_root(dir) {
				return dir
			}
			parent := os.dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return ''
}

// is_vails_root recognizes the vails checkout (v.mod plus the core
// module dirs a scaffolded main.v imports from).
fn is_vails_root(dir string) bool {
	return dir != '' && dir != '.' && os.exists(os.join_path(dir, 'v.mod'))
		&& os.is_dir(os.join_path(dir, 'webview')) && os.is_dir(os.join_path(dir, 'bridge'))
}

fn join_modules_path(home string, old string) string {
	mut sep := ':'
	$if windows {
		sep = ';'
	}
	if old == '' {
		return home
	}
	return home + sep + old
}

fn doctor() {
	println('vails doctor')
	println('  vails       : ' + version)
	home := vails_home()
	if home == '' {
		println('  vails home  : NOT FOUND (set VAILS_HOME --- needed by `vails build` outside a checkout)')
	} else {
		println('  vails home  : ' + home)
	}
	vv := os.execute('v version')
	if vv.exit_code == 0 {
		println('  v version   : ' + vv.output.trim_space())
	} else {
		println('  v version   : MISSING (`v` must be on PATH, need 0.5.x)')
	}
	println('  os          : ' + os.user_os())
	$if linux {
		r := os.execute('pkg-config --modversion webkit2gtk-4.1')
		if r.exit_code == 0 {
			println('  webkit2gtk  : ' + r.output.trim_space())
		} else {
			println('  webkit2gtk  : MISSING (sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev)')
		}
	} $else $if windows {
		gcc := os.execute('gcc --version')
		if gcc.exit_code == 0 {
			println('  gcc         : ' + gcc.output.split_into_lines()[0])
		} else {
			println('  gcc         : MISSING (install MSYS2 ucrt64 toolchain + put C:\\msys64\\ucrt64\\bin on PATH)')
		}
		header := 'C:/msys64/ucrt64/include/webview/webview.h'
		if os.exists(header) {
			println('  webview     : header found (' + header + ')')
		} else {
			println('  webview     : MISSING (pacman -S mingw-w64-ucrt-x86_64-webview mingw-w64-ucrt-x86_64-webview2-loader)')
		}
	} $else {
		println('  webview     : Windows/Linux only in this MVP (Phase 6 adds macOS)')
		println('  note        : pure-V modules (bridge/events/assets/---) still testable here')
	}
	report_backends()
	cfg_path := 'vails.json'
	if os.exists(cfg_path) {
		cfg := config.load(cfg_path) or {
			println('  vails.json  : INVALID (' + err.msg() + ')')
			return
		}
		println('  vails.json  : ok (' + cfg.windows.len.str() + ' window(s), ' +
			cfg.capabilities.len.str() + ' capabilit(ies))')
		report_services(cfg)
		if os.is_dir(cfg.asset_root) {
			println('  asset_root  : ok ("' + cfg.asset_root + '")')
		} else {
			println('  asset_root  : MISSING ("' + cfg.asset_root + '" not found - `vails run` has nothing to serve)')
		}
	} else {
		println('  vails.json  : not found (optional here; `vails init` creates one)')
	}
}

// report_backends lists, per service, whether THIS build has a native
// backend on THIS platform. A grant is not a promise: `vails.json` can grant
// `notification.*` on a machine where notification is a stub, and the
// frontend should hear that from doctor rather than from a promise
// rejection. The answers come from the services themselves (services.supports
// -> each service's own `*_support()`), so this function only prints.
fn report_backends() {
	list := services.supports()
	println('  backends    : ' + services.ok_count(list).str() + '/' +
		list.len.str() + ' service(s) native here')
	for line in services.report(list) {
		println('               ' + line)
	}
}

// report_services tells the user which of the granted commands are
// services (and therefore get a .d.ts + a JS snippet), so a missing
// `vails dts` run is visible here instead of only in a type error.
fn report_services(cfg config.VailsConfig) {
	mut granted := []string{}
	for spec in cfg.capabilities {
		granted << spec.commands.clone()
	}
	picked, unknown := services.select_for(services.granted_commands(granted))
	if picked.len == 0 {
		println('  services    : none granted (add e.g. "dialog.open" to a capability)')
		return
	}
	println('  services    : ' + picked.map(it.name + ' ' + it.version).join(', ') +
		' (run `vails dts` for the .d.ts)')
	// A granted service whose backend is a stub here is worth naming, even
	// though the grant is perfectly valid (the app may be shipped for the
	// other platform).
	for s in picked {
		if st := services.status_of(s.name) {
			if !st.ready {
				println('                 ! ' + s.name + ' is a stub here: ' + st.note)
			}
		}
	}
	_ = unknown
}

// init_app scaffolds a runnable project: minimal main.v (config +
// frontend file + ping, capability-gated), vails.json with the frontend
// grant (so the dev server serves strictly, no special cases), and a
// single-file frontend with a ping button.
fn init_app(name string) ! {
	os.mkdir_all(name) or { return error('cannot create dir: ' + err.msg()) }
	os.mkdir_all(os.join_path(name, 'frontend')) or {
		return error('cannot create frontend dir: ' + err.msg())
	}
	os.write_file(os.join_path(name, 'main.v'), scaffold_main)!
	os.write_file(os.join_path(name, 'frontend', 'index.html'), scaffold_index.replace('APP_NAME', name))!
	os.write_file(os.join_path(name, 'vails.json'), scaffold_config(name))!
	println('created ./' + name + '/ (main.v + vails.json + frontend/)')
	println('  dev   : cd ' + name + ' && vails run')
	println('  app   : cd ' + name + ' && v run .')
	println('  check : cd ' + name + ' && vails doctor')
}

// scaffold_config is default_config plus the frontend grant: without it
// the dev server (and the window) would deny everything by default.
fn scaffold_config(name string) string {
	mut cfg := config.default_config(name)
	cfg.capabilities << config.CapabilitySpec{
		id:          'main-app'
		windows:     ['main']
		commands:    ['ping']
		asset_roots: [cfg.asset_root]
	}
	return cfg.encode()
}

const scaffold_main = "module main

import bridge
import config
import os
import webview

fn ping_handler(_ string) !string {
	return 'pong'
}

// Minimal Vails app: window geometry and capability grants come from
// vails.json; the UI is frontend/index.html. Handlers run on the webview
// main thread: keep them fast, deliver heavy work as events.
fn main() {
	app_cfg := config.load('vails.json') or {
		eprintln('vails.json: ' + err.msg())
		exit(1)
	}
	html := os.read_file(os.join_path(app_cfg.asset_root, 'index.html')) or {
		eprintln(err.msg())
		exit(1)
	}
	w := app_cfg.window('main') or {
		eprintln(err.msg())
		exit(1)
	}
	mut router := bridge.new_router()
	router.register_validated('ping', bridge.validate_empty, ping_handler) or {
		eprintln(err.msg())
	}
	webview.run(
		label:    w.label
		title:    w.title
		width:    w.width
		height:   w.height
		router:   &router
		registry: app_cfg.to_registry()
		html:     html
	) or {
		eprintln(err.msg())
		exit(1)
	}
}
"

const scaffold_index = '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta http-equiv="Content-Security-Policy" content="default-src \'self\'; script-src \'self\' \'unsafe-inline\'; style-src \'self\' \'unsafe-inline\'; img-src \'self\' data:; font-src \'self\' data:; connect-src \'self\'; media-src \'self\' blob:; object-src \'none\'; base-uri \'self\'; frame-ancestors \'none\'" />
<title>APP_NAME</title>
<style>
:root { color-scheme: light dark; }
body { font-family: system-ui, sans-serif; margin: 2rem; line-height: 1.5; }
button { font-size: 1rem; padding: 0.5rem 1rem; }
button:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
#status { margin-top: 1rem; }
</style>
</head>
<body>
<h1>APP_NAME</h1>
<p><button id="ping">ping backend</button></p>
<p id="status" role="status">not pinged yet</p>
<script>
"use strict";
const status = document.getElementById("status");
document.getElementById("ping").addEventListener("click", async () => {
  // Outside a Vails window (plain browser / vails run) window.vails is
  // missing: fail visibly instead of throwing.
  if (!window.vails) { status.textContent = "no backend (open via the app binary)"; return; }
  try {
    status.textContent = "backend says: " + await window.vails.call("ping");
  } catch (e) {
    status.textContent = "error: " + e;
  }
});
</script>
</body>
</html>
'
