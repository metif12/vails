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
import buildinfo
import buildplan
import config
import deps
import dev
import os
import services
import webview

// version is the framework version, owned by buildinfo so there is one
// number in the repository rather than two editable-by-hand ones (B0).
const version = buildinfo.framework_version

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
			doctor(args[1..])
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
		'deps' {
			report_deps(args[1..]) or {
				eprintln('deps failed: ' + err.msg())
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
	println('  build [--config path] [--output path] [' + buildinfo.help + ']')
	println('                       compile the project dir to a runnable binary')
	println('  doctor [--config path]')
	println('                       validate the toolchain and the project')
	println('  dts [--config path] [--out path] [--js] [--check]')
	println('                       generate .d.ts (+ --js service snippets)')
	println('                       for the granted services')
	println('  deps [--config path]')
	println('                       list the declared dependencies and compare')
	println('                       them against ' + deps.lock_path)
}

// report_deps implements `vails deps` (B5).
//
// It reports, and it does not install. That split is deliberate and it
// is the whole of what this command is in v1: the declarations are
// parsed, validated and diffed against `vails.lock`, so a project can be
// checked in CI without a network, and the fetching is left to
// `v install` / VPM — which is the tool that already knows how to resolve
// a constraint and how to put a module on VMODULES.
//
// Writing that a framework's own `deps install` would "just call VPM"
// sounds harmless and is where the two-writers problem comes from: the
// moment Vails maintains its own copy of the resolved tree, a hand-run
// `v install` and a Vails-run one can disagree, and the build depends on
// which one ran last. One writer for the tree, VPM; one writer for the
// declarations, this module.
fn report_deps(args []string) ! {
	path := flag_value(args, '--config', 'vails.json')
	text := os.read_file(path) or {
		return error('cannot read ' + path + ': ' + err.msg())
	}
	set := deps.parse(text)!
	println('dependencies (' + path + '): ' + set.summary())
	if set.is_empty() {
		println('  nothing to resolve. Add a "dependencies" block to ' + path +
			', e.g. [{"name": "vlang.leveldb", "version": ">=1.0.0"}]')
		return
	}
	lock_file := os.join_path(os.dir(path), deps.lock_path)
	locked := os.read_file(lock_file) or {
		println('  ' + deps.lock_path + ' : not written yet (run `v install` to resolve)')
		return
	}
	locked_set := deps.decode_lock(locked)!
	mut missing := []string{}
	mut extra := []string{}
	for d in set.items {
		have := locked_set.get(d.name) or {
			missing << d.name
			continue
		}
		// Only an EXACT requirement is compared. A constraint like
		// `>=1.0.0` was satisfied once, at resolve time, and the lock
		// records the concrete version that satisfied it — so comparing
		// the two here would report every ranged dependency as stale
		// forever, which is what the first version of this function did.
		//
		// Re-evaluating the constraint at report time would also mean a
		// second implementation of "does 1.4.2 satisfy >=1.0.0", and two
		// implementations of a resolver is the thing this command
		// deliberately avoids: VPM resolves, this reports.
		if deps.is_exact_requirement(d.version) && have.version != d.version {
			missing << d.name + ' (lock has ' + have.version + ', config pins ' +
				d.version + ')'
			continue
		}
		println('  ' + d.name + ' ' + have.version)
	}
	for d in locked_set.items {
		if set.get(d.name) == none {
			extra << d.name + ' ' + d.version
		}
	}
	for s in missing {
		eprintln('  ! ' + s + ' - not resolved by ' + deps.lock_path)
	}
	for s in extra {
		eprintln('  ! ' + s + ' - in ' + deps.lock_path + ' but not in ' +
			cfg_name(args))
	}
	if missing.len > 0 || extra.len > 0 {
		return error(deps.lock_path + ' does not match ' + cfg_name(args) +
			' (run `v install` to re-resolve)')
	}
}

// cfg_name is the config path the command was pointed at, for messages.
fn cfg_name(args []string) string {
	return flag_value(args, '--config', 'vails.json')
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
// hold main.v, e.g. from `vails init`) to a binary that actually runs.
// Scaffolded projects import vails modules by bare name (`bridge`,
// `webview`, ---), so the compiler needs the vails source root on its
// module path: build sets VMODULES to it (explicit VAILS_HOME wins, else
// walk-up from the CLI binary and the cwd).
//
// Everything decided here comes from buildplan, so the flag set, the DLL
// list and the output name are unit-tested on every platform without a
// compiler (ADR-0022 B1). What is left here is the I/O: run the command,
// copy the DLLs, and say what went wrong if either fails.
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
	// Validate the version BEFORE compiling: a binary that exists with the
	// wrong string in it is worse than one that was never built.
	version_arg := flag_value(args, '--version', '')
	mut stamped := ''
	if version_arg != '' {
		stamped = buildinfo.validate_version(version_arg)!
	}
	mut r := buildplan.recipe(target_for_host(), cfg.bundle.name,
		cfg.bundle.windows_dll_side_by_side, stamped)
	// The `if x := f(); cond {` form is a V 0.5.2 parser bug
	// ("unexpected eof, expecting `}`"), and the `if x := f() {` form
	// additionally demands an Option from f. Both are recorded because
	// the short forms are what everyone writes by reflex and the error
	// message points at the end of the file rather than at this line.
	out := flag_value(args, '--output', '')
	if out != '' {
		r.output = out
	}
	for w in r.warnings {
		eprintln('  ! ' + w)
	}
	cmd := r.command(root)
	println('+ VMODULES=' + home + ' ' + cmd)
	old_modules := os.getenv('VMODULES')
	os.setenv('VMODULES', join_modules_path(home, old_modules), true)
	res := os.execute(cmd)
	os.setenv('VMODULES', old_modules, true)
	if res.exit_code != 0 {
		return error('compile failed:\n' + res.output)
	}
	println('built: ' + r.output + stamp_note(stamped))
	if r.stage_dlls {
		stage_dlls(r)!
	} else if r.target == .windows {
		println('  (side-by-side DLLs not staged: bundle.windows_dll_side_by_side is false)')
	}
}

// stamp_note says what a build carries, because a release built without
// a version looks exactly like a development build from the outside and
// the difference decides whether every update check is disabled.
fn stamp_note(stamped string) string {
	if stamped == '' {
		return ' (unstamped: pass --version <semver> to enable update checks)'
	}
	return ' (stamped ' + stamped + ')'
}

// stage_dlls copies the five side-by-side DLLs next to the built binary
// (ADR-0005). This is the step whose absence made `vails build` produce
// an .exe that could not start: the list existed only as `#` comments in
// the READMEs, so a green CI would have shipped a dead artifact.
//
// It reports the individual missing files rather than a single failure,
// because a missing `libwebview-0.12.dll` (the toolchain is not the one
// the build assumed) and a missing `libstdc++-6.dll` (it is, but
// something else is wrong) are the same symptom to a user and completely
// different problems to fix.
fn stage_dlls(r buildplan.Recipe) ! {
	missing := buildplan.missing_dlls(r.dll_source)
	if missing.len > 0 {
		return error('cannot stage the side-by-side DLLs from ' + r.dll_source +
			': missing ' + missing.join(', ') + '\n  the binary built, but it ' +
			'will not START until those files are next to it')
	}
	mut copied := 0
	mut skipped := 0
	for name in r.dll_targets() {
		src := os.join_path(r.dll_source, name)
		// V 0.5.2 has no os.copy_file, so the copy is read + write.
		// These are the loaders a shipped app already depends on, a few
		// hundred KB each, and doing it in V keeps the staging step out
		// of a shell script (which is the thing ADR-0022 says was
		// missing in the first place).
		bytes := os.read_file(src) or {
			return error('read ' + src + ': ' + err.msg())
		}
		dst := os.join_path(os.dir(os.abs_path(r.output)), name)
		// Skip an identical destination rather than rewriting it. A
		// rebuild while the app is running leaves the loader DLLs locked
		// by the OS, and an unconditional write then fails the build
		// AFTER the binary was produced — which is the worst possible
		// moment to report an error, and the reason `vails build` on an
		// already-built project has to be a no-op rather than a ritual.
		if os.exists(dst) {
			mut already := false
			if existing := os.read_file(dst) {
				already = existing == bytes
			}
			if already {
				skipped++
				continue
			}
		}
		os.write_file(dst, bytes) or {
			return error('write ' + dst + ': ' + err.msg() + '\n  the binary ' +
				'built and is at ' + r.output + '; this file is probably still ' +
				'loaded by a running instance')
		}
		copied++
	}
	println('staged ' + copied.str() + ' side-by-side DLL(s) from ' +
		r.dll_source + ' next to ' + r.output + (if skipped > 0 {
		' (' + skipped.str() + ' already up to date)'
	} else {
		''
	}))
}

// target_for_host maps the host OS onto buildplan's Target enum. buildplan
// takes the target as an argument precisely so a Linux plan can be
// asserted from a Windows CI run; this is the only place the two meet.
//
// It is not called `home_target`, which is the obvious name: V 0.5.2
// reports `unknown function: host_target` for a `home_target` declared in
// this file, and the name works fine in a module that does not import
// `webview` — so something in the webview module graph rewrites the
// identifier. Renaming fixed it; the reason is recorded so nobody
// "tidies" the name back.
fn target_for_host() buildplan.Target {
	mut t := buildplan.Target.other
	$if windows {
		t = .windows
	}
	$if linux {
		t = .linux
	}
	return t
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

// doctor validates the toolchain and the project. It takes args rather
// than hard-coding `vails.json`: a workspace with more than one project
// in it is exactly what a build matrix looks like, and a `doctor` that
// can only look at the cwd is useless there (ADR-0022 B1).
fn doctor(args []string) {
	println('vails doctor')
	println('  vails       : ' + version)
	// The framework's own version drift is reported here rather than
	// fixed silently: `v.mod` and the CLI were two hand-edited numbers
	// and they were already disagreeing (B0).
	home := vails_home()
	if home == '' {
		println('  vails home  : NOT FOUND (set VAILS_HOME --- needed by `vails build` outside a checkout)')
	} else {
		println('  vails home  : ' + home)
		if text := os.read_file(os.join_path(home, 'v.mod')) {
			drift := buildinfo.version_drift(text)
			if drift != '' {
				println('  ! version   : ' + drift)
			}
		}
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
		// The tray service links a second library, and a build that fails on
		// one missing header is a much worse first impression than a line
		// here: the services module's C is compiled into every GUI app.
		ind := os.execute('pkg-config --modversion ayatana-appindicator3-0.1')
		if ind.exit_code == 0 {
			println('  appindicator: ' + ind.output.trim_space() + ' (tray)')
		} else {
			println('  appindicator: MISSING (sudo apt install libayatana-appindicator3-dev - the tray service needs it)')
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
		// The five DLLs a built app cannot start without. Reported as a
		// count of what is actually present, because `vails build` copies
		// them and a build that silently could not is the failure this
		// whole line exists to make visible earlier (B1).
		present := buildplan.side_by_side_dlls.len - buildplan.missing_dlls(buildplan.ucrt64_bin).len
		println('  side-by-side: ' + present.str() + '/' +
			buildplan.side_by_side_dlls.len.str() + ' DLL(s) in ' +
			buildplan.ucrt64_bin)
	} $else {
		println('  webview     : Windows/Linux only in this MVP (Phase 6 adds macOS)')
		println('  note        : pure-V modules (bridge/events/assets/---) still testable here')
	}
	report_backends()
	cfg_path := flag_value(args, '--config', 'vails.json')
	if os.exists(cfg_path) {
		cfg := config.load(cfg_path) or {
			println('  ' + cfg_path + '  : INVALID (' + err.msg() + ')')
			return
		}
		println('  ' + cfg_path + '  : ok (' + cfg.windows.len.str() + ' window(s), ' +
			cfg.capabilities.len.str() + ' capabilit(ies))')
		report_services(cfg)
		// The dependency list is reported before the asset_root check
		// because a missing dependency is the more expensive failure: the
		// asset_root is one line away, a module that never got fetched is
		// a build error three files deep.
		if text := os.read_file(cfg_path) {
			set := deps.parse(text) or {
				// A malformed block is a report line, not a crash: the
				// rest of doctor is still useful, and the message names
				// the offending dependency.
				println('  dependencies: INVALID (' + err.msg() + ')')
				return
			}
			println('  dependencies: ' + set.summary())
			if !set.is_empty() {
				report_lock(cfg_path)
			}
		}
		if os.is_dir(cfg.asset_root) {
			println('  asset_root  : ok ("' + cfg.asset_root + '")')
		} else {
			println('  asset_root  : MISSING ("' + cfg.asset_root + '" not found - `vails run` has nothing to serve)')
		}
	} else {
		println('  ' + cfg_path + '  : not found (optional here; `vails init` creates one)')
	}
	// The build identity of THIS binary, last, because it is the one line
	// that survives into whatever a user reports: an unstamped binary
	// reports 'dev' forever, and 'dev' silently disables every update
	// check (B0, and ADR-0020's U6 before it moved here).
	println('  build       : ' + buildinfo.describe())
}

// report_lock says whether the resolved set on disk matches what the
// config declares. A missing lock is a one-line note, not a failure —
// `doctor` is a report, and a project that has simply not run
// `v install` yet is not broken.
fn report_lock(cfg_path string) {
	lock_file := os.join_path(os.dir(cfg_path), deps.lock_path)
	locked := os.read_file(lock_file) or {
		println('               ! ' + deps.lock_path +
			' not written yet - run `v install` before building')
		return
	}
	locked_set := deps.decode_lock(locked) or {
		println('               ! ' + deps.lock_path + ' is unreadable (' + err.msg() + ')')
		return
	}
	println('               resolved: ' + locked_set.summary())
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
	// notification has a second, config-shaped precondition: a desktop app
	// cannot raise a WinRT toast without an AppUserModelID. Reporting it
	// here is the whole point of doctor's backends section - the failure
	// otherwise surfaces as a notification that never appears, with
	// nothing in the message pointing at vails.json.
	if picked.any(it.name == 'notification') && cfg.bundle.identifier == '' {
		println('                 ! notification.notify needs bundle.identifier in ' +
			'vails.json: it is the Windows AppUserModelID the toast is ' +
			'attributed to (ADR-0018)')
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
