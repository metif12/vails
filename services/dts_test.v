module services

// demo is a local two-command service: every V test file compiles as its
// own module, so test helpers cannot be shared between _test.v files.
fn demo() Service {
	return Service{
		name:     'demo'
		version:  '0.1.0'
		summary:  'test service'
		commands: [
			Command{
				name:   'demo.run'
				params: '{ value: number }'
				result: 'string'
			},
			Command{ name: 'demo.stop', result: 'void' },
		]
	}
}

fn test_specs_use_short_names() {
	specs := demo().specs()
	assert specs.len == 2
	assert specs[0].name == 'run'
	assert specs[0].params == '{ value: number }'
	assert specs[0].result == 'string'
}

fn test_specs_mark_no_arg_commands_undefined() {
	specs := demo().specs()
	assert specs[1].name == 'stop'
	assert specs[1].params == 'undefined'
}

fn test_dts_emits_namespace_per_service() {
	out := dts([demo()])
	assert out.contains('export namespace demo {')
	assert out.contains('export function run(params: { value: number }): Promise<string>;')
	assert out.contains('export function stop(params: undefined): Promise<void>;')
}

fn test_dts_declares_the_runtime_shape() {
	out := dts([demo()])
	assert out.contains('export const service: string;')
	assert out.contains('export const version: string;')
	// one namespace per service, not one per service+runtime
	assert out.split('export namespace').len == 2
}

fn test_dts_includes_manifest_types_first() {
	typed := Service{
		name:     'typed'
		version:  '0.1.0'
		commands: [Command{ name: 'typed.get', result: 'Typed' }]
		ts_types: ['\texport interface Typed { value: string; }']
	}
	out := dts([typed])
	assert out.contains('export interface Typed { value: string; }')
	// the interface must come before the function that returns it
	assert (out.index('interface Typed') or { -1 }) < (out.index('Promise<Typed>') or { -1 })
}

fn test_dts_of_nothing_is_empty() {
	assert dts([]) == ''
}

fn test_snippets_are_prefixed_per_service() {
	out := snippets([demo()])
	assert out.starts_with('// service: demo 0.1.0 - test service')
	assert out.contains('v.demo = v.demo || {}')
}

fn test_snippets_of_nothing_is_empty() {
	assert snippets([]) == ''
}

// --- Command.blocking must reach the service description (ADR-0014) ---
//
// ADR-0014 justifies the `blocking` flag with one sentence: the manifest marks
// these commands "so the constraint is visible in the service description, not
// only in prose". Before this was wired, `dts` emitted a bare signature and the
// flag was in neither — the generated `.d.ts` a frontend type-checks against was
// byte-identical whether a command froze the UI or not.
//
// These three tests are the enforcement, and they are deliberately two-sided.
// A test that only asserted "blocking commands are marked" would pass if `dts`
// marked *everything*, which is the same failure mode as a guard that cannot
// fail: it would look like coverage while checking nothing.

fn blocking_demo() Service {
	return Service{
		name:     'demo'
		version:  '0.1.0'
		summary:  'test service'
		commands: [
			Command{
				name:     'demo.slow'
				params:   '{ }'
				result:   'string'
				blocking: true
			},
			Command{ name: 'demo.fast', result: 'void' },
		]
	}
}

fn test_a_blocking_command_is_marked_in_the_generated_description() {
	out := dts([blocking_demo()])
	assert out.contains('/** slow blocks the UI until it is answered')
	// The marker must be the line IMMEDIATELY above the declaration it
	// describes. TypeScript attaches a JSDoc comment to the declaration that
	// follows it, and to the wrong one otherwise — so "somewhere earlier in the
	// file" is not good enough, and a character-count heuristic is not either
	// (the note is prose and its length is not the property).
	lines := out.split('\n')
	mut note := -1
	for i, l in lines {
		if l.contains('/** slow blocks') {
			note = i
		}
	}
	assert note >= 0
	mut next := note + 1
	for next < lines.len && lines[next].trim(' \t') == '' {
		next++
	}
	assert lines[next].contains('export function slow(')
	// And the marker names the rule, so a reader knows it is deliberate rather
	// than a performance hint.
	assert out.contains('ADR-0014')
	assert out.contains('documented exception')
}

fn test_a_non_blocking_command_is_not_marked() {
	// The other half, and the reason this file is worth having: a generator that
	// marked everything would satisfy the test above on its own.
	out := dts([blocking_demo()])
	assert !out.contains('fast blocks')
	assert out.contains('export function fast(params: undefined): Promise<void>;')
	// Exactly one marker, for exactly one blocking command.
	assert out.split('/**').len - 1 == 1
}

// The flag is a POLICY boundary, so the set of commands on the wrong side of it
// is pinned rather than derived. Deriving it ("every blocking command has a
// marker") is what the two tests above do; this one catches the case they cannot:
// somebody marks a new command blocking, or unmarks an existing one, and the
// marker still matches perfectly.
//
// Four commands, and the reason each is here is not interchangeable:
//   - dialog.open/save/message: ADR-0014's own exception, a native modal that
//     freezes until answered.
//   - menu.popup: blocks on Windows (a native TrackPopupMenu loop) but NOT on
//     Linux, where the GTK menu is emitted and returns immediately. It is marked
//     blocking because the flag describes the worst platform, not the current
//     one — worth pinning, because unmarking it would look correct from a Linux
//     machine and silently break the Windows threading contract.
fn test_the_set_of_blocking_commands_is_pinned() {
	// `manifests()` rather than an enumerated list of services, so a service
	// added later is covered by this assertion the moment it exists — a pinned
	// list of the *other* services would have needed editing here first, which
	// is the same drift this is meant to catch.
	mut got := []string{}
	for s in manifests() {
		for c in s.commands {
			if c.blocking {
				got << c.name
			}
		}
	}
	got.sort()
	// Four, and the reason each is here is not interchangeable:
	//   - dialog.open/save/message: ADR-0014's own exception, a native modal that
	//     freezes until the user answers.
	//   - menu.popup: blocks on Windows (a native TrackPopupMenu loop) but NOT on
	//     Linux, where the GTK menu is emitted and returns immediately. It is
	//     marked blocking because the flag describes the worst platform, not the
	//     current one — worth pinning, because unmarking it would look correct
	//     from a Linux machine and silently break the Windows threading
	//     contract that ADR-0014 records.
	//
	// So this assertion fails two ways on purpose: a fifth blocking command
	// anywhere, and a missing one here.
	assert got == ['dialog.message', 'dialog.open', 'dialog.save', 'menu.popup']
	// The flag is visible in the description for every one of them, which is the
	// promise being enforced: no blocking command may reach a frontend as a bare
	// signature.
	out := dts(manifests())
	for c in got {
		short := c.all_after('.')
		assert out.contains('/** ' + short + ' blocks the UI'), c
	}
}
