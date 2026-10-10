module buildplan

fn test_linux_app_builds_with_gc_none() {
	// ADR-0005: Boehm GC crashes when WebKit spawns subprocesses, so this
	// is not a preference. Asserted here rather than in a CI command
	// because a build flag a developer has to remember is a flag CI gets
	// wrong on the first run.
	assert needs_gc_none(.linux)
	assert !needs_gc_none(.windows)
	assert !needs_gc_none(.other)
	f := app_flags(.linux)
	assert f.contains('-gc')
	assert f.contains('none')
}

fn test_windows_app_needs_only_cc_gcc() {
	// The README asserts an app needs no flags beyond `-cc gcc`; if that
	// ever stops being true this test is where it should be noticed.
	//
	// This exact equality is also the guard that caught `app_flags` reading the
	// HOST os instead of its `target` argument (2026-10-05, on the first Linux CI
	// run): with the branch wrapped in `$if windows` the function returned `[]`
	// here on Linux, and an assertion like `f.contains('-cc')` would have passed
	// on Windows while checking nothing on Linux. Do not loosen this to `.contains`
	// or `.all` — the equality is what makes it a host-independence check, and it
	// now runs, and bites, on both platforms.
	f := app_flags(.windows)
	assert f == ['-cc', 'gcc']
}

fn test_cli_needs_ws2_32_on_windows_and_app_does_not() {
	// The asymmetry is the whole reason there are two recipes: the CLI
	// embeds the dev server (net.http) and an app does not.
	c := cli_flags(.windows)
	assert c.contains('-lws2_32')
	assert c.contains('-Wno-incompatible-pointer-types')
	assert app_flags(.windows).all(it != '-lws2_32')
	// Linux needs neither: net.http on Linux uses pthreads, not winsock.
	assert !cli_flags(.linux).any(it == '-lws2_32')
}

fn test_cross_platform_recipes_are_assertable_from_any_host() {
	// The reason Target is an argument rather than os.user_os(): a Linux
	// plan is asserted on the Windows CI run and vice versa. If any of
	// these read the host OS they would only ever be half-checked.
	assert !app_flags(.linux).contains('-cc')
	assert !app_flags(.other).contains('-cc')
	assert app_flags(.other).len == 0
}

fn test_recipe_output_carries_the_exe_suffix_on_windows_only() {
	assert recipe(.windows, 'services', true, '').output == 'services.exe'
	assert recipe(.linux, 'services', true, '').output == 'services'
	assert recipe(.other, 'services', true, '').output == 'services'
}

fn test_recipe_stages_dlls_on_windows_only() {
	w := recipe(.windows, 'app', true, '')
	assert w.stage_dlls
	assert w.dll_source == ucrt64_bin
	l := recipe(.linux, 'app', true, '')
	assert !l.stage_dlls
	assert l.dll_source == ''
}

fn test_recipe_honours_the_config_switch_that_nothing_used_to_read() {
	// bundle.windows_dll_side_by_side has existed since T6 and was never
	// acted on. Turning it off must be a real choice, not a no-op.
	off := recipe(.windows, 'app', false, '')
	assert !off.stage_dlls
	assert off.dll_source == ''
	assert off.warnings.len == 0
}

fn test_recipe_stamps_the_version_when_given() {
	// `-d ident=value` is the whole mechanism: no generated file, no
	// -ldflags, and the app reads it back with buildinfo.version().
	r := recipe(.linux, 'app', false, '1.2.3')
	assert r.flags.contains('-d')
	assert r.flags.contains('vails_version=1.2.3')
	unstamped := recipe(.linux, 'app', false, '')
	assert !unstamped.flags.contains('-d')
	assert !unstamped.flags.any(it.starts_with('vails_version='))
}

fn test_recipe_does_not_stamp_dev() {
	// Stamping the literal 'dev' would make `is_release` true and turn
	// off the doctor warning while changing nothing an updater can use.
	r := recipe(.linux, 'app', false, 'dev')
	assert !r.flags.any(it.starts_with('vails_version='))
}

fn test_recipe_replaces_rather_than_duplicates_gc_none() {
	r := recipe(.linux, 'app', false, '')
	assert r.has_flag('-gc')
	assert r.flags.count(it == '-gc') == 1
}

fn test_command_is_exactly_runnable() {
	r := recipe(.windows, 'app', true, '1.2.3')
	cmd := r.command('C:/src/app')
	assert cmd.starts_with('v ')
	assert cmd.contains('-cc gcc')
	assert cmd.contains('-d vails_version=1.2.3')
	// The output is quoted: a project path with a space in it is not an
	// exotic case on Windows and an unquoted path fails in a way that
	// looks like a compiler bug.
	assert cmd.contains('-o "app.exe"')
	assert cmd.ends_with('"C:/src/app"')
}

fn test_command_quotes_a_flag_containing_a_space() {
	// `-cflags '-Wno-x'` is two argv entries; without the inner quotes
	// the shell splits it and `v` receives `-Wno-` as a compiler flag.
	r := Recipe{
		target: .windows
		flags:  ['-cflags -Wno-incompatible-pointer-types']
		output: 'vails.exe'
	}
	assert r.command('.') == 'v "-cflags -Wno-incompatible-pointer-types" ' +
		'-o "vails.exe" "."'
	// The real recipes pass the pair as two entries, which need no inner
	// quoting because neither half has a space.
	r2 := Recipe{
		target: .windows
		flags:  ['-cflags', '-Wno-incompatible-pointer-types']
		output: 'vails.exe'
	}
	assert r2.command('.') == 'v -cflags -Wno-incompatible-pointer-types ' +
		'-o "vails.exe" "."'
}

fn test_five_dlls_and_the_abi_version_is_in_the_name() {
	assert side_by_side_dlls.len == 5
	assert side_by_side_dlls[0] == 'libwebview-0.12.dll'
	// The 0.12 is why webview is pinned: an unpinned pacman that moves
	// to 0.13 produces a DLL this list does not name, and the resulting
	// .exe fails with a loader error naming neither the file nor the
	// version.
	assert side_by_side_dlls[0].contains('0.12')
}

fn test_dll_targets_are_the_constant_list_not_a_directory_scan() {
	// A scan would silently pick up whatever else is in ucrt64/bin.
	r := recipe(.windows, 'app', true, '')
	assert r.dll_targets() == side_by_side_dlls
}

fn test_missing_dlls_names_the_ones_actually_absent() {
	// "It does not start" is not a diagnostic. A missing libwebview and
	// a missing libstdc++ look identical to a user and are completely
	// different problems.
	empty := missing_dlls('/definitely/not/a/real/ucrt64/bin')
	assert empty.len == 5
	assert empty == side_by_side_dlls
}
