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

**The test command on Windows carries one extra flag, and it is not
optional:**

```powershell
$env:PATH = "C:\msys64\ucrt64\bin;" + $env:PATH
v -cc gcc -ldflags "-lws2_32" test .    # 36/36
```

The reason is a V 0.5.2 bug, not a Vails one, and it is worth knowing
because the error message points nowhere near the cause. `dev/` imports
`net.http`; V's `dependency_scan_fallback` link path emits `-l` flags
sourced from `#flag` **before** most object files, and GNU `ld` only
resolves an archive against the objects that precede it — so
`ws2_32` is on the link line and cannot resolve anyway. Symptoms are
`undefined reference to __imp_connect` / `__WSAFDIsSet` in
`net_sockets.c`. Adding `#flag windows -lws2_32` to the importing module
**does not help** (tried in `dev/dev.v`, reverted); `-ldflags` does,
because it is emitted last. See ADR-0034 and `buildplan.cli_flags`.

The **CLI** has a second flag for a different reason (it embeds the dev
server, so it needs `-cflags` too):

```powershell
v -cc gcc -cflags "-Wno-incompatible-pointer-types" -ldflags "-lws2_32" -o vails.exe ./cli
```

An **app** needs neither beyond `-cc gcc` — `buildplan.app_flags` asserts
that, and the test is what stops the CLI's flags leaking into every build.

Linux (WSL Ubuntu, V built from source at /root/vsrc): GUI apps MUST use
`-gc none` (Boehm vs WebKit fork, ADR-0005); headless runs need
`unset WAYLAND_DISPLAY`, `GDK_BACKEND=x11`,
`WEBKIT_DISABLE_COMPOSITING_MODE=1` — see tests/e2e_linux/run_headless.sh.

The Linux `v` is **not on PATH**: call it as `wsl -d Ubuntu -- /root/vsrc/v <args>`
(or `export PATH=/root/vsrc:$PATH` inside the shell first).

### 1b. There are TWO V installs on this machine, and only one of them builds this repo

Measured 2026-09-30, and it cost a confusing afternoon, so it is written down:

| | |
|---|---|
| `C:\Users\xman\AppData\Local\Programs\v\v.exe` (first on PATH) | V 0.5.2 `7647ce1`. Its vlib has **no `json2`** |
| `C:\Users\xman\v\v.exe` (a git checkout, built from source) | V 0.5.2 `a9424eb`. Its vlib **has `json2`** |

`bridge/` and `state/` import `json2`, so plain `v test .` against the PATH
install fails with

```
builder error: cannot import module "json2" (not found)
```

which reads like a Vails dependency problem and is not one. **Use
`C:\Users\xman\v\v.exe` for anything that builds this repo**, or put
`C:\Users\xman\v` ahead of `Programs\v` on PATH.

`v up` is **not** how you fix this: it replaces the install's `vlib` with V
master's and then cannot compile master's own `vup` tool with the 0.5.2 `v.exe`
that is already there (`use -enable-globals ... to enable globals`), which
leaves the install unusable — *every* build fails, including `jsesc`. The
recovery is `git -C "C:\Users\xman\AppData\Local\Programs\v" checkout
7647ce1c6f`, which puts `v.exe` and `vlib` back in the same commit.

V master does carry two things this repo will want — `v skills`
(`vlang/v`'s bundled agent skills) and `v mcp serve` (a compiler MCP server) —
but building it needs `makev.bat` in a console with inheritable handles. From an
agent shell it fails with `failed SetHandleInformation: The handle is invalid`.
The bundled skills can be read straight out of a clone instead:
`git clone --depth 1 https://github.com/vlang/v`, then copy
`vlib/v/skills/<name>/` to `~/.agents/skills/<name>/`, which is exactly what
`v skills add <name> --global` does. Installed 2026-09-30: `v-lang`,
`v-testing`, `v-concurrency`, `v-memory`, `v-workflow`.

`webview_linux.c.v` compiles on Linux only (V `_linux` suffix rule).
All other modules must compile and pass tests on **Windows too** —
this repo's CI machine is Windows without gcc/pkg-config.

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

### 2b. Four V 0.5.2 constructs that do not compile

All four were found the hard way while landing ADR-0034. Each one's error
message points somewhere other than the offending line, so they are listed
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
