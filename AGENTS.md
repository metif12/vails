# AGENTS.md — Vails agent contract

Read this before writing any code. The project language is V (0.5.x).
Wails v2/v3 is a **design reference only** — never translate Go line-by-line
(there is no Go→V translator; only `c2v` for C exists).

## 1. Commands (run from repo root `vails/`)

```sh
v fmt -w .        # format before every commit
v test .          # must be green (Linux GUI tests stay manual, see tests/e2e_linux/)
```

Windows (MSYS2 ucrt64): prefix every build command with
`env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH` and use `-cc gcc`:

```sh
v -cc gcc -o hello.exe ./examples/hello
```

**The test command on Windows needs no extra flags on the current compiler:**

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc test .
```

The **CLI** likewise builds clean:

```powershell
v -cc gcc -o vails.exe ./cli
```

### Both of those used to need a flag, and the reason is still worth knowing

On **V 0.5.2** the test command carried `-ldflags "-lws2_32"` and the CLI carried
`-cflags "-Wno-incompatible-pointer-types"` as well. Neither is needed on the
compiler this machine has now (§1b) — measured 2026-10-03, 33 test files green
with no flags at all. Keep the knowledge anyway, because the flags are not wrong,
they are **version-scoped**:

`dev/` imports `net.http`; V 0.5.2's `dependency_scan_fallback` link path emits
`-l` flags sourced from `#flag` **before** most object files, and GNU `ld` only
resolves an archive against the objects that precede it — so `ws2_32` is on the
link line and cannot resolve anyway. Symptoms are `undefined reference to
__imp_connect` / `__WSAFDIsSet` in `net_sockets.c`. Adding `#flag windows
-lws2_32` to the importing module **does not help** (tried in `dev/dev.v`,
reverted); `-ldflags` did, because it is emitted last. If a build ever fails with
`undefined reference to __imp_connect` again, add the flag back rather than
hunting: see ADR-0034 and `buildplan.cli_flags`.

`buildplan.cli_flags` still emits both flags, which is deliberate — they are
harmless on a fixed compiler and required on an unfixed one, and the test that
asserts them is what documents that they exist on purpose.

Linux (WSL Ubuntu, V built from source at /root/vsrc): GUI apps MUST use
`-gc none` (Boehm vs WebKit fork, ADR-0005); headless runs need
`unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11`,
`WEBKIT_DISABLE_COMPOSITING_MODE=1` — see tests/e2e_linux/run_headless.sh.

The Linux `v` is **not on PATH**: call it as `wsl -d Ubuntu -- /root/vsrc/v <args>`
(or `export PATH=/root/vsrc:$PATH` inside the shell first).

### 1b. Which V is on this machine, and what that changes

One section, because the previous two contradicted each other within an hour of
each other — which is the lesson. `v` on PATH is now `C:\Users\xman\v\.bin\v.bat`,
a one-line forwarder to `C:\Users\xman\v\v.exe`, which is **V 0.5.2 `0137eb5`,
i.e. master**, built from a git checkout (re-measured 2026-10-03).

Consequences, all measured on this machine:

- **The two link flags are gone.** `v -cc gcc test .` and
  `v -cc gcc -o vails.exe ./cli` both succeed with no `-ldflags` and no
  `-cflags`, across 33 test files. They are still *documented* in §1 because they
  are version-scoped, and `buildplan.cli_flags` still emits them.
- **`json2` exists in this vlib**, so the build works — but read the next line
  before you trust that on any other machine.
- **VSH works**: `v run script.vsh` compiles and runs a `.vsh` file. Three
  script-mode rules cost real time and are written up where they bit —
  `tests/e2e_windows/capture.vsh` carries them in its header. The short version:
  a `.vsh` has **no `module` line**, its **top-level statements are the program**
  (so `fn main()` is never called), and **all definitions must precede all code**
  or the file compiles to a binary that silently does nothing.
- Agent skills from V's bundled catalog are installed at
  `~/.agents/skills/v-{lang,testing,concurrency,memory,workflow}`. They were
  copied out of a clone rather than installed with `v skills add --global`,
  which does the same thing: see below.

#### `json2` exists only on `vlang/v` master, and in NO release

The `json2` bullet above is true of **this machine's install and of nothing
else**. Measured 2026-10-05 against the GitHub API, because the Windows CI
runner refused to build and the smoke step named the reason:

- `json2` was added to `vlang/v` on **2026-10-03**, commit `152ba0d2`.
- It is **not** in tag `0.5.2`, nor in `weekly.2026.08` / `.07` / `.06` / `.05`.
  Every published tag predates it.
- It lives at **`vlib/json2`**, not `vlib/v/json2`. Upstream ships
  `vlib/v/astjson` and no `json2` under `vlib/v`, so a `vlib/v` listing makes it
  look absent — it is at the vlib root.

So **no released V can build this repository.** `bridge/` and `state/` import
`json2`, and a released compiler fails with
`builder error: cannot import module "json2" (not found)`.

Two consequences, and the first one inverted a decision:

1. **The Windows CI job cannot be pinned to a release.** Pinning was the right
   instinct — every other flag there is justified against a specific V — but the
   only pin that works is a `vlang/v` *commit*, which means building V from source
   on the runner. MSYS2 then has to be installed **before** V, because V's own
   Windows build needs a C compiler. Not done.
2. **"Install a newer V" is not a complete instruction.** Newer *released* V does
   not help. What helps is a V built from master.

The trap this sits in: a machine with a master checkout builds fine, so the
dependency looks satisfied locally, and the failure only appears on a fresh
machine — which is what CI is for.

#### Two history worth keeping, because both cost an afternoon

**There were two V installs, and one could not build this repo.** Until
2026-10-03, `C:\Users\xman\AppData\Local\Programs\v` (V 0.5.2 `7647ce1`) was
first on PATH, and its vlib had **no `json2`** — so `bridge/` and `state/`, which
import it, failed with `builder error: cannot import module "json2" (not found)`.
That reads like a Vails dependency problem and is not one. That install is now
gone; the trap worth remembering is the shape of it, not the path. **That commit
is also the one CI installs**, so on 2026-10-05 the same failure appeared on a
clean GitHub runner from the other direction — see the section above.

**`v up` is not a way to fix a Vails build.** It replaces the install's `vlib`
with V master's and then cannot compile master's own `vup` tool with the 0.5.2
`v.exe` already sitting there (`use -enable-globals ... to enable globals`),
which leaves the install unusable — *every* build fails, `jsesc` included. The
recovery was `git -C "...\Programs\v" checkout 7647ce1c6f`, which puts `v.exe`
and `vlib` back in the same commit. **If `v` ever fails on every single build,
suspect a half-applied `v up` before suspecting the repo.**

#### `v skills` and `v mcp serve` exist upstream, with a caveat

V master carries both: `v skills` (the bundled agent skills) and `v mcp serve`
(a compiler MCP server). Building master needs `makev.bat` **in a console with
inheritable handles** — from an agent shell it fails with
`failed SetHandleInformation: The handle is invalid`. The bundled skills can be
read straight out of a clone instead: `git clone --depth 1
https://github.com/vlang/v`, then copy `vlib/v/skills/<name>/` to
`~/.agents/skills/<name>/`, which is exactly what `v skills add <name> --global`
does. `v mcp serve` needs the built compiler, so it is not available here yet.


## 2. V style rules

- `v fmt` is law. One official style, no debates.
- No globals. `pub` only what other modules need; `pub mut` only for
  structs that `json.decode` must fill.
- Errors as values: `!T` + `or { }`. Never panic in library code;
  `panic` is allowed only in `cli/` and `examples/`.
- C interop: `#include` + `fn C.*` declarations live **only** in
  `*_linux.c.v` (or later `_windows.c.v` / `_darwin.c.v`) files.
  Redeclare the minimum signature surface you actually call.
- Prefer small pure-V modules with `_test.v` over clever code.
- New native capability = new file under `services/` + test + ADR entry.

### 2b. Six V 0.5.2 constructs that do not compile

The first four were found the hard way while landing ADR-0034; the last two were
found on 2026-10-04 while fixing F0's cross-thread emit, and both were measured
in a standalone file with no Vails code before being worked around. Each one's
error message points somewhere other than the offending line, so they are listed
here rather than left to be rediscovered.

- **`if x := f(); cond {` is a parse error** — and so is `if x := f() {`,
  which additionally demands an `?T` from `f`. The message is
  `unexpected eof, expecting `}`` at **end of file**. The `for` equivalent
  parses, so the bug is specific to `if`. Write the long form:

  ```v
  x := f()
  if x != '' { ... }
  ```

- **`$d('ident')` crashes the parser** (`array.get: index out of range
  (i,a.len):-1` in `call_args`), and `$d(ident, def)` is rejected with
  *"$d() values can only be pure literals"*. Only the **two-argument,
  all-literal** form works:

  ```v
  return $d('vails_version', 'dev')
  ```

  See `buildinfo.version()`; its comment says the same thing.

- **`f() or { return err.msg() }` panics the parser** when `f()` is inside
  a **void `test_` function**. Use a module-level helper that returns the
  message — `buildinfo.v_mod_version` / `sqlreg.bind_report` /
  `deps.parse_report` all exist for this and each is one line.

- **A local named `home_target` is reported as `host_target`** in
  `cli/vails.v` (which imports `webview`); it works elsewhere. Renamed to
  `target_for_host`; do not "tidy" the name back.

- **A closure cannot capture a local without declaring it.** A captured
  name must be listed as inherited. When that gets in the way, take the
  value as a function argument instead (see `sqlreg.bind_report`).

- **A closure literal with a capture list and NO explicit signature does not
  parse as a `return` expression.** `return fn [js] { … }` is a parse error;
  `return fn [js] () { … }` compiles. Measured in a standalone file with no
  Vails code, so it is the compiler and not this repository. The message is
  `invalid expression: unexpected token }` pointing at the **enclosing
  function's** closing brace — three braces away from the actual mistake — so
  budget for reading the wrong line. `webview/eval_job` is the worked example;
  it takes `fn [w, js] ()`. **Always write the signature.**

- **A closure literal passed as an ARGUMENT to a call that is followed by `or`
  is parsed as that anonymous function's return type.** The error names it
  outright — `expected return type, not `or` for anonymous function` — which is
  more helpful than the one above, but the fix is the same shape: hoist the
  closure into a named binding first, or into a function that returns it.

  ```v
  post_to_main(ctx, fn [w, js] { … }) or { … }   // parse error
  job := eval_job(w, js)                          // eval_job returns the closure
  post_to_main(ctx, job) or { … }                 // parses
  ```

### 2c. Two V 0.5.2 bugs that COMPILE and then lie

Unlike §2b these produce **no error at all**. Both were found while landing F0
(`webview/window.v`), both were measured in a standalone reproduction before
being worked around, and both are worse for it: a test that asserts on the
wrong answer still passes, and a lookup that finds nothing reports that it
found something.

- **`or` does not run its block for a `none` Option of a REFERENCE type.**

  ```v
  fn find() ?&Window { return unsafe { nil } }
  find() or { /* NEVER RUNS — the `or` treats a none ?&T as `some` */ }
  ```

  Every other combination is fine, verified one cell at a time: `?int` none and
  `?int` some both behave, and a **some** `?&Window` behaves. Only the
  none-reference cell is broken.

  **Why it is nasty:** `has()` written as `f() or { return false }` returns
  **true for something that does not exist**, and a duplicate-key check written
  that way rejects the *first* insert. In this repo it presented as
  `assert !r.has('main')` failing on a **provably empty registry**, which sends
  you looking at the registry rather than at the compiler.

  **Workaround — do not return `Option<&T>`.** Return the plain reference and
  compare against nil, which is correct in every case:

  ```v
  pub fn (r &WindowRegistry) find(label string) &Window {
      for w in r.windows {
          if w.label == label { return w }
      }
      return unsafe { nil }          // not `?&Window`
  }
  pub fn (r &WindowRegistry) has(label string) bool {
      return r.find(label) != unsafe { nil }   // not `find(label) or { false }`
  }
  ```

  `.is_none()` is **not** an alternative: V 0.5.2 rejects it
  (*"Option type cannot be called directly, you should unwrap it first"*), and
  it cannot be called on a call's return value either.

  Nothing in this repo returned `Option<&T>` before `window.v`, so no shipped
  code was affected — but the pattern is worth avoiding until the compiler is
  fixed.

- **A closure captures a `mut s &T` PARAMETER by value, not by reference.**

  ```v
  fn sink_ctx(mut s &Sink) Ctx {
      return Ctx{ eval_fn: fn [mut s] (js string) ! { s.got << js } }
  }
  // the caller's `s.got` stays EMPTY — the append went to a copy inside the
  // closure's environment
  ```

  Verified by calling the resulting `eval_fn` **directly** and finding
  `got.len == 0`, so this is not about the method chain. The same capture
  written as `fn [qp, mut probe]` over a `mut probe := &Probe{}` **local**
  works correctly (`webview/jobs_test.v` relies on it) — the trigger is
  passing the reference in as a parameter.

  **Workaround — capture a plain reference and mutate under `unsafe`:**

  ```v
  eval_fn: fn [s] (js string) ! {
      unsafe { s.got << js }
  }
  ```

  This is the same move as `detach`'s `unsafe { free(host) }`, and the closure
  now writes through to the caller's object. `webview/window_test.v`'s
  `ready_window` says the same thing in a comment, because the symptom
  (assertions passing against an always-empty sink) reads like a *test* bug
  rather than a capture bug.

- **`spawn` with a `mut ... &T` parameter crashes or hangs.** Found while
  landing F0's thread-per-window backend, and it is the same root cause as the
  bullet above: V 0.5.2 loses mutability through a reference.

  ```v
  fn worker(mut j &WindowJob) { j.failed = true }
  spawn worker(mut j)      // unhandled access violation, or a hang
  ```

  Measured one variable at a time in a standalone file with no Vails code:
  bare `spawn f()` is fine; `spawn f(x)` with a plain `&T` is fine; a `chan`
  field reached through a plain `&T` is fine (8 threads, joined through the
  channel, green). The only broken cell is the `mut` reference. The failure
  mode is not consistent — the same construct crashed in one program and hung
  in another — so a hang and a crash here are the same bug.

  **Workaround — plain reference plus `unsafe` writes**, which is what
  `webview_windows.c.v`'s `WindowJob` does (`#[heap]`, `unsafe { j.error = … }`):

  ```v
  #[heap]
  struct Job { mut: error string; failed bool }
  fn worker(j &Job) { unsafe { j.failed = true } }
  spawn worker(j)
  ```

  **Do not use `sync.WaitGroup` to join threads in this V.** It compiles, and
  `add`/`done`/`wait` all work on a single thread — and `done()` called from a
  spawned thread is an unhandled access violation. A `chan` with enough
  capacity for the thread count, held in a `#[heap]` struct, is the join
  primitive that works. Note V rejects `spawn f(mut ch)` (a `chan` is not a
  reference type), which is why the channel is reached through a struct field
  rather than passed as an argument.

### 2a. Every file is UTF-8, without a BOM

Non-ASCII characters are used on purpose in this repo — em-dashes in prose and
in V comments, `✅` in the README tables, `Δ` in the example subtitle — so this
is a rule about *how* they are stored, not about avoiding them.

- **UTF-8, no BOM.** Not UTF-16, not cp1252/ANSI, not "whatever the shell
  defaulted to". A `.c.v` with a cp1252 byte in a comment is still a valid V
  file to the compiler, which is the problem: nothing complains until the
  character renders as U+FFFD, the replacement character, or the diff shows
  mojibake.
- **Windows PowerShell 5.1 is the hazard here.** `Set-Content` /
  `Out-File` / `>` **default to the ANSI code page**, so writing a file
  containing `—` through them mangles it. Always pass the encoding:

  ```powershell
  Set-Content -Path x.md -Value $s -Encoding utf8
  ```

  `Get-Content` is the same trap when *reading*: add `-Encoding utf8` or the
  console will show a correct file as mojibake, which sends you looking for
  damage that is not there.
- **Prefer the file tools over shell redirection** for editing existing files
  (§ "Definition of done"). They preserve encoding; `Add-Content` on a UTF-8
  file is how `services/dialog_test.v` grew its test cases, and it works,
  but `Set-Content` without `-Encoding utf8` is what corrupted
  `tests/e2e_linux/README.md`, `tests/e2e_windows/README.md` and
  `services/tray_windows.c.v` in the first place.
- **A new file ends with a newline, in UTF-8.**

If a file already shows the replacement character, do not guess what it was
— read it with a UTF-8-aware tool first, then replace it.

## 3. Phase discipline

Current phase is tracked in `ROADMAP.md` (checkbox). Rules:

1. Work only inside the current phase's scope.
2. Each phase ends with: code + tests + docs line in `ROADMAP.md`.
3. Cross-platform code goes behind the `webview/` facade;
   `application/`, `bridge/`, `events/` must stay OS-agnostic.
4. When stuck on a native API, write the pure-V seam first and stub the
   native side with `error('not implemented on ...')`.

## 4. Wails reference map (where to look, not what to copy)

| Vails module | Wails guide |
|---|---|
| `application/` | `v3/pkg/application` (AppOptions, lifecycle) |
| `bridge/` | `v2/internal/binding` (method dispatch, JSON) |
| `generator/` | `v2/internal/typescriptify`, `v3/internal/generator` |
| `assets/` | `v2/pkg/assetserver`, `v3/internal/assetserver` |
| `cli/` | `v3/internal/commands`, `v2/pkg/commands` |
| `webview/` | `v2/internal/frontend`, `v3/internal/runtime` |
| `services/` | `v3/pkg/services`, `v3/internal/dbus`, `v3/internal/keychain` |

## 5. Definition of done (per task)

- `v fmt -w .` clean, `v test .` green on Windows.
- No file written or edited this task has a U+FFFD in it, and every
  touched file is still valid UTF-8 (§2a). A shell redirection that wrote
  one is the defect, not the character.
- New public API has a `_test.v` case and one line in `CONTEXT.md` if it
  changes the domain model.
- `CHANGELOG.md` gets a line under `## [Unreleased]` (its conventions are in
  that file's header).
- Linux-only behavior documented in `tests/e2e_linux/README.md`.
