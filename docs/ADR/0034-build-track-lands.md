# ADR-0034 — The build track lands: version stamping, a build that starts, a first CI, the `sql` policy and dependencies

Date: 2026-09-29. Status: accepted (ROADMAP items B0, B1, B2, B3, B5, D0 shipped).

ADR-0022 planned the build & release track and ADR-0032 planned the data
services. This records what actually happened when the cheap front-loaded
items of both were implemented in one sitting, and — more usefully — the
six places where reality did not match the plan.

## What landed

| item | module | what it is |
|---|---|---|
| **B0** | `buildinfo/` | the app's build identity: `-d vails_version=`, the framework version, SemVer validation, `v.mod` drift |
| **B1** | `buildplan/` + `cli/vails.v` | `vails build` that produces a binary that **starts**; `--version`; DLL staging; `doctor --config` |
| **B2** | `Dockerfile` | the Linux build environment, on V's own published base image |
| **B3** | `.github/workflows/ci.yml` | the first CI: linux container + windows MSYS2 + release on a tag |
| **B5** | `deps/` + `vails deps` | a dependency *declaration* and a lock file — and nothing that fetches |
| **D0** | `sqlreg/` | the `sql` security policy as code: a page names a query, V owns the statement |

`v test .` is 36/36 on Windows (it was 31/32 when this started, for a
reason that turned out not to be a bug in this repository — see below).

## The six corrections

These matter more than the table above, because each one is a case where
a plan that sounded right was wrong, and the code now carries the reason.

### 1. `$d('ident')` is a V 0.5.2 parser crash, not a fallback

ADR-0022 recorded the read side of version stamping as
`const build_version = $d('vails_version') or { 'dev' }`. **That does not
compile.** Three separate forms fail:

```
$d('x')                -> V panic: array.get: index out of range (i,a.len):-1 in call_args
$d('x') or { 'd' }     -> the same panic (the `or` form panics the PARSER, before any `or` logic)
$d(ident, dev_version) -> error: $d() values can only be pure literals
```

The only working form is the two-argument one, and **both** arguments
must be literals:

```v
return $d('vails_version', 'dev')
```

The compiler rejects *any* constant in that call, which is why
`buildinfo` repeats `ident` and `dev_version` as literals and has
`test_ident_is_namespaced` and `test_version_matches_dev_marker` to hold
the duplicated spellings together. The docs only imply the two-argument
form ("`$d()` will return the default value provided as the *second*
argument"), and the one-argument form is what everyone writes by reflex.

**Consequence for the plan:** ADR-0022's "no generated file and no
`-ldflags`" holds, but its example line does not, and nobody reading the
ADR would have found out without trying.

### 2. `v test .` was red for a compiler reason, and the fix is a flag

`dev/dev_test.v` failed to link with seven undefined references
(`__imp_connect`, `__imp_accept`, `__WSAFDIsSet`, …). The obvious reading
is that `dev` imports `net.http` and the toolchain does not link
`ws2_32` — a missing library.

**It is not a missing library.** `ws2_32` *is* on the link line, twice
(once from V's own `net/http/backend_vschannel_windows.c.v`, once from a
`#flag` added to `dev.v` during this work). The real cause is
**ordering**: V 0.5.2's `dependency_scan_fallback` path emits
`#flag`-sourced `-l` flags *before* most object files, and GNU `ld` only
resolves an archive against objects that precede it. The `-lws2_32` is
there, and it is useless where it is.

Consequences, all now written down where they will be read:

- A `#flag` in the importing module **cannot** fix this. Reproduced
  deliberately in `dev/dev.v` and then reverted.
- `-ldflags` **does** fix it, because it is emitted last.
- Therefore the Windows test command is
  `v -cc gcc -ldflags "-lws2_32" test .`, not `v test .`. AGENTS.md §1
  says so now, and so does `buildplan.cli_flags`, whose doc comment
  explains why the flag cannot live in the module.

This was worth a day of bisection and it is the kind of thing that gets
"fixed" by a well-meaning contributor adding a redundant `-lws2_32` to
four files.

### 3. `if x := f(); cond {` is also a V 0.5.2 parser bug

While bisecting the above, this surfaced:

```v
if out := flag_value(args, '--output', ''); out != '' {   // PARSE ERROR
if o := g(); o > 0 {                                     // PARSE ERROR (same)
if o := g() {                                             // also errors, and additionally
                                                           // demands an Option from g
```

`if x := 5 {` is the canonical V form and it does not parse. The
`for x := y; cond {}` form *does* parse, so the bug is specific to `if`.
The error message points at **end of file**, not at the line, which is
why the bisect took as long as it did.

`cli/vails.v` now writes the long form and says why, and the same trap
forced a module-level `err_msg` / `parse_report` / `bind_report` helper
in three test files.

### 4. A function named `home_target` cannot be called from `cli/vails.v`

`unknown function: host_target` — for a function declared as
`home_target` in the same file. It works in a module that does not import
`webview`, so something in the webview module graph rewrites the
identifier. Renamed to `target_for_host`; the reason is in the comment so
nobody tidies the name back.

### 5. `vails build`'s DLL staging is not idempotent, and that matters

The first E2E run of B1 built `smoketest.exe` and staged all five DLLs,
then **failed** on the second run with
`write ...libwebview-0.12.dll: failed to open file` — because the first
run's process still had the loader DLLs mapped.

The naive staging code reports that *after* a successful compile, which
is the worst possible moment to report a failure: the user has a binary
and an error. Staging now compares the destination bytes and skips a
match, so a rebuild over a running app is a no-op:

```
built: smoketest.exe (stamped 2.5.0)
staged 0 side-by-side DLL(s) from C:/msys64/ucrt64/bin next to smoketest.exe (5 already up to date)
```

A `write` failure that *is* a lock now names the cause in the message
rather than leaving a bare errno.

### 6. A lock file records what was *resolved*; a config records what was *asked for*

B5's first `vails deps` compared the two textually and reported
`vlang.leveldb (lock has 1.4.2, config asks >=1.0.0)` — i.e. **every
ranged dependency is stale forever**. Caught by running it, not by a
test, because the test asserted the shape rather than the semantics.

The fix is *not* to implement constraint satisfaction. That would be a
second resolver beside VPM's, which is exactly the disagreement this
command exists to prevent. The fix is `deps.is_exact_requirement`: only
a requirement that names one version is compared, everything else is
reported as resolved. One writer resolves (VPM), one writer declares
(`deps`), and neither re-implements the other.

## Decisions

- **The version has one home, and it is a constant, not a file.**
  `buildinfo.framework_version` is the framework's version;
  `buildinfo_test.v` asserts `v.mod` matches it, so the drift that was
  live in this repository (0.2.0 vs 0.4.0) cannot recur. `vails doctor`
  *also* reports drift, because a test that only runs in CI is not enough
  for a number a person edits by hand.
- **Version stamping validates before it compiles.** `buildinfo.validate_version`
  refuses `1.0`, `1.2.3.4`, `01.2.3` and an empty string, accepting `v1.2.3`,
  `1.2.3-rc.1` and `1.2.3+build.5`. It refuses `1.0` because the updater
  *compares* this string: `1.0` and `1.0.0` are different versions, and
  finding that out after release is the expensive way to find it out.
- **Stamping `'dev'` is refused even though it is a valid string.** It
  would make `buildinfo.is_release` true for a binary with nothing to
  compare against, and the doctor warning that exists for exactly this
  would go quiet.
- **The build recipe is a value, not a command line.** `buildplan.recipe`
  is a struct with `Target` as an *argument*, so a Linux recipe is
  asserted on the Windows CI run and a Windows recipe on the Linux one.
  `Recipe.output` is the only `pub mut` field: the CLI's `--output`
  overrides it, and a struct whose every field is writeable invites a
  caller to edit a decision the tests hold.
- **`-gc none` lives in `buildplan.app_flags(.linux)`, not in a CI
  command.** ADR-0005's rule, applied where a developer will find it.
- **The five DLLs are a constant, not a directory scan.** A scan would
  pick up whatever else is in `ucrt64\bin`. The `0.12` in
  `libwebview-0.12.dll` is why the list is also the argument for pinning
  `webview`.
- **CI is Linux-in-Docker + Windows-on-a-runner, and the Windows job
  asserts the artifact can start.** That assertion is the entire point of
  doing B1 before B3: the first CI here would otherwise have been a green
  tick next to an `.exe` that cannot launch.
- **B5 declares; VPM resolves.** `deps` parses, validates, encodes and
  diffs. It does not fetch, does not write `VMODULES`, and does not keep
  a tree. The reasoning is in `report_deps`'s doc comment: the moment
  Vails maintains its own resolved tree, a hand-run `v install` and a
  Vails-run one can disagree and the build depends on which ran last.
- **D0 is code, not prose.** `sqlreg` refuses SQL text, refuses multiple
  statements *at registration*, bounds parameter values, and refuses a
  named placeholder the statement does not contain. The registry has no
  mutating entry point at all — that absence is the threat model, and
  `test_the_registry_is_a_value_and_cannot_be_grown_at_runtime` says so.

## Rejected alternatives

- **Fixing `dev_test.v` by adding `-lws2_32` to `dev.v` as a `#flag`.**
  Tried, does not work (the ordering bug), and would have looked like a
  fix. This is the one that would have been committed by someone who did
  not read the linker output.
- **Writing `v.mod`'s version by hand and calling B0 done.** Rejected:
  the drift recurred the moment someone bumped one and not the other. The
  test is the feature.
- **A generated `version.v` instead of `$d`.** ADR-0022's "no generated
  file" is right, and the two-argument `$d` is the reason it stayed
  right.
- **Implementing SemVer constraint satisfaction in `deps`** to decide
  staleness. Rejected above: it is a second resolver, and it would be
  wrong the first time VPM's constraint syntax grew a form this
  implementation had not seen.
- **`vails deps install`.** See the VPM decision. It is the obvious next
  command and it is the one that creates the two-writers problem.
- **A `sql` service manifest in D0.** D0 is the policy only. A manifest
  would make `vails dts` promise `sql.exec` before there is a database
  behind it, which ADR-0025 explicitly calls worse than no service.

## Consequences

- `vails build` now produces an artifact that starts, on Windows, and
  prints what it did. Proved end to end:
  `vails build --version 2.5.0` → `smoketest.exe` + 5 DLLs, the process
  launches, and `2.5.0` is in the binary.
- `vails doctor` honours `--config`, reports the side-by-side DLL count,
  the dependency list, the lock state, `v.mod` drift, and this binary's
  own stamp.
- Four new pure-V modules, 36/36 tests, all gcc-free on Windows in the
  sense that matters (no C, no network, no toolchain).
- The Windows test command changed. That is a real cost of this ADR and
  it is paid in AGENTS.md §1 rather than discovered.

## Open decisions

- **`vails deps install` (B5's second half).** Deliberately not built.
  The decision is recorded above; the command is not.
- **B4 — Linux packaging and the real release.** The workflow's release
  job exists and stamps a version, but it does not yet produce an
  AppImage, a `deb`, or a `vails updater manifest`. That is B4, and B4
  still owes a decision on how much of Phase 7 packaging it absorbs.
- **The Linux CI job is unproven.** WSL was inaccessible in this session
  (`/root/vsrc/v: Permission denied` for the non-root user), so the
  Dockerfile has been written against V's own `docker_ci.yml` and
  `pkg-config` names already used by the backends, but no container has
  been built here. The Windows job's steps are also unproven for the
  honest reason that they need a GitHub runner.
