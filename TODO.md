# TODO — language & build-system audit

Findings from an audit of what's missing to build basic CLI tools in Butter,
plus build-system observations. Each task is written to be picked up
independently by an agent: it names the files involved, what's currently
true, and what "done" looks like. Nothing here has been implemented yet.

Priority key: **P0** blocking (a basic CLI tool can't be written without
it) → **P4** nice-to-have / infrastructure polish.

---

## P0 — blocking for basic CLI tools

### 1. String concatenation — DONE
`add()` in [src/vm.zig](src/vm.zig) now handles a STRING+STRING pair
(byte-concatenation into a fresh heap string) alongside the existing
numeric path; any other mismatched pairing is still `TypeMismatch`.
Documented in GRAMMAR.bnf's Strings design notes and ISA.bnf's ADD entry.
Covered by unit tests in `src/vm.zig` and the `strings` integration case
under `tests/cases/`.

### 2. String ordering comparisons (`<`, `<=`, `>`, `>=`) — DONE
`compare()` in [src/vm.zig](src/vm.zig) now does byte-lexicographic
comparison (`std.mem.order`) when both operands are STRING, alongside the
existing numeric path. Documented in GRAMMAR.bnf/ISA.bnf. Covered by unit
tests (equal-prefix, differing-length, empty-string cases) and the
`strings` integration case.

### 3. Program argument access (`argv`) — DONE
`args` is now a bare keyword (like `stdin`/`stdout`/`stderr`, GRAMMAR.bnf
design note 3p) evaluating to a fresh `list` of strings, built at run time
by a new `PUSH_ARGS` opcode (ISA.bnf) from `Vm.run`'s `Host.args` field —
threaded from [src/main.zig](src/main.zig), which now treats a literal
`--` on its own command line as the boundary between CLI flags and the
program's own args. Documented in GRAMMAR.bnf/ISA.bnf. Covered by lexer,
parser, and VM unit tests, the `args` integration case under
`tests/cases/`, and `examples/cli_args.butter`.

### 4. Process exit code control — DONE
`exit <expression>` is now a statement (GRAMMAR.bnf design note 3q,
alongside `close`) that halts the whole program immediately, from
anywhere, via a new `EXIT` opcode (ISA.bnf) — `expression` must be an INT
in 0..255 (`RuntimeError.TypeMismatch`/`InvalidExitCode` otherwise) and is
stashed on `Vm.exit_code` before `run` returns normally (not as an error —
`exit(0)` isn't a failure). [src/main.zig](src/main.zig) checks
`vm.exit_code` after a successful run and calls `std.process.exit` with
it; a program that never calls `exit` still exits 0 as before. Covered by
lexer/parser/compiler/VM unit tests (including a nested-call case proving
`exit` skips every remaining frame, not just its own) and the `exit_code`
integration case under `tests/cases/` (a grep-style tool combining `args`
and `exit`, exercising all three of its branches' real exit codes).

### 5. Number → string composition — DONE
Verified `stringify(n) + " ..."` works end-to-end now that task #1 has
landed; covered by the last line of the `strings` integration case
(`tests/cases/strings.butter`/`.expected`).

---

## P1 — significant gaps (workable around today, but painful)

### 6. String → number parsing — DONE
`int(s)`/`float(s)` are now special-form expressions (parsed like
`json`/`stringify`, reusing the existing `int`/`float` type keywords as
call syntax — GRAMMAR.bnf design note 3r) that parse a `string` into a
number via new `PARSE_INT`/`PARSE_FLOAT` opcodes (ISA.bnf section 13) in
[src/vm.zig](src/vm.zig), thin wrappers over `std.fmt.parseInt`/
`parseFloat`. A non-string operand is `RuntimeError.TypeMismatch`;
malformed content (empty, non-numeric, a decimal point for `int`
specifically, internal/surrounding whitespace) is the new
`RuntimeError.NumberParseFailed`. Documented in GRAMMAR.bnf/ISA.bnf.
Covered by parser/compiler/VM unit tests (valid/invalid input,
leading/trailing whitespace, negative numbers, non-string operands) and
the `parse_numbers` integration case under `tests/cases/`.

### 7. float → int cast — DONE
`int(x)` (task #6's special form) now has a second runtime branch: if `x`
evaluates to a `float` rather than a `string`, `PARSE_INT` (ISA.bnf
section 13) truncates it toward zero into an `i64` via the new
`Vm.checkedIntFromFloat` in [src/vm.zig](src/vm.zig) — checked against
i64's representable range up front rather than trusting
`@intFromFloat`'s safety-checked-UB precondition, so NaN/±Infinity/an
out-of-range magnitude are `RuntimeError.Overflow` (the same variant
`add`/`sub`/`mul` already use), not a crash. An `int` operand is
deliberately still `RuntimeError.TypeMismatch` — no implicit
"already an int" identity cast. Documented in GRAMMAR.bnf design note 3r
and ISA.bnf's PARSE_INT entry. Covered by VM unit tests (positive,
negative, exact-integer floats, values at/near i64's bounds, NaN/
Infinity) and compiler-level/integration tests (`parse_numbers.butter`).

### 8. Escape sequences in string literals — DONE
`\n`, `\t`, `\\`, and `\"` are now recognized inside a `STRING` (GRAMMAR.bnf
design note 3s). [src/lexer.zig](src/lexer.zig)'s `string()` scan now
treats `\"` as a non-terminating escaped quote (rather than ending the
literal) and rejects any other character after a `\` as
`Error.InvalidEscapeSequence`; the token's lexeme still carries the raw
`\x` bytes un-decoded. Actual decoding happens in
[src/parser.zig](src/parser.zig)'s new `unescapeString`, applied
uniformly wherever a `STRING` token's contents become text — an ordinary
string literal, an `import` path, and a map-literal key — via a fresh
arena allocation; a literal with no backslash is returned unchanged
(unallocated), same as before this feature existed. Documented in
GRAMMAR.bnf's lexical grammar and design note 3s. Covered by lexer unit
tests (escaped quote, escaped backslash before a real closing quote,
unterminated-after-backslash, invalid escape) and parser unit tests
(decoding in a literal/import path/map key, an escaped quote not ending
the string), plus the `escapes` integration case under `tests/cases/`
exercising embedded newlines and tabs end to end.

### 9. Error recovery (try/catch or Result-style handling) — DONE
`try <block> catch IDENTIFIER <block>` (GRAMMAR.bnf design note 3u) traps a
runtime error raised anywhere inside its body — at any depth, including
several call frames deep — and binds a fresh instance of the built-in
`Error` struct describing it, with four always-present fields: `error` (the
`RuntimeError` tag name, the stable thing to branch on), `message`,
`operation`, and `path`. Originally a `map` (design note 3t at the time);
switched to a struct once structs existed (design note 3z), so a typo'd
field name is `SemanticError.UnknownField` at compile time instead of a
runtime `KeyNotFound`. The alternatives weighed and rejected, and why, are
in `DESIGN-error-recovery.md`, the design spike this task asked for.

19 of the 23 `RuntimeError` variants are catchable; `StackOverflow`,
`StackUnderflow`, `CallStackOverflow` and `HandlerStackOverflow` are not
(VM-integrity failures — running a handler needs the stack room that just
ran out), nor is `error.OutOfMemory` (building the error struct allocates).
Two new opcodes, `PUSH_HANDLER`/`POP_HANDLER` (ISA.bnf section 14), over a
64-entry handler table beside the call frames; `RET` drops the departing
frame's handlers, which covers every way out of a frame by construction.
Covered by lexer/parser/compiler/VM unit tests, the `try_catch` integration
case (15 variants caught and identified by tag, running against a real
scratch filesystem via the harness's new `expectCaseOutputWithFs`), and
`examples/error_handling.butter`.

Landing this also fixed nine latent refcount leaks in the VM: an
instruction that popped a value and then failed used to strand the
reference, which was harmless while every error killed the process and is a
live leak once a handler resumes. The invariant is documented on `Vm.pop`.

---

## P2 — meaningful but not blocking

### 10. Environment variable access — DONE
`getenv(name)` and `hasenv(name)` are now special-form expressions (parsed
like `json`/`stringify`, GRAMMAR.bnf design note 3v) compiling to new
`GET_ENV`/`HAS_ENV` opcodes (ISA.bnf section 15). `getenv` evaluates to a
fresh `string` — `""` for an unset variable, never `null` and never an
error, so its static type is unconditionally `string`; `hasenv` evaluates to
`bool` and is the only way to tell an exported-but-empty variable from an
absent one (the `has(map, key)` split, taken for the same reason —
`KeyNotFound` was rejected because a missing variable is the common case,
and the default-then-override pattern would otherwise need a `try`/`catch`
per lookup). The name is an arbitrary expression, so a prefixed namespace of
settings can be swept in a loop; a non-string name is
`RuntimeError.TypeMismatch`.

The environment is injected as `Vm.Host.env` (a flat name/value slice, the
same shape `Host.args` has), snapshotted before the program starts;
[src/main.zig](src/main.zig) hands over this process's environment whole.
An embedder that supplies none gets an empty environment rather than a
refusal — deliberately not a capability gate like `Host.fs`, since a program
can't tell the two apart and reading an absent variable has no effect
outside the VM. Lookup is byte-exact on every platform, Windows included, so
one program reads the same everywhere. Read-only: there is no `setenv`, and
the environment can't be enumerated.

Covered by lexer/parser/compiler/VM unit tests (set/unset/set-but-empty,
computed names, case sensitivity, first-wins on a repeated name, non-string
names released rather than leaked, static types checked against a declared
type) and the `env` integration case under `tests/cases/`, plus
`examples/env_vars.butter`. The integration case injects its environment
through the `Host` rather than exporting a variable into the test process —
the same way the `args` cases inject argv — so it stays deterministic
regardless of what the machine running the suite has exported; the real
process-environment path through `main.zig` was verified by running the
built binary with a variable set.

### 11. Subprocess/exec support — DONE
`exec(command, args)` is now a special-form expression (GRAMMAR.bnf design
note 3x, parsed like `getenv`/`rename` — not also a `<type>` keyword, so a
bare `exec(...)` is a legal `<expr-stmt>` too), compiling to a new `EXEC`
opcode (ISA.bnf section 17) in [src/vm.zig](src/vm.zig). `command` is a
`string`, `args` a `list` of `string`s (its own argv[1..], checked at
runtime, not compile time — same stance `rename`'s two operands take); it
spawns the process via `std.process.run`, waits for it to exit, and
evaluates to a fresh `map` with three keys always present: `"stdout"`/
`"stderr"` (its captured output) and `"exit_code"` (an `int`).

This is the first builtin with side effects reaching outside the VM's own
sandboxed `fs`/stream model, so — as flagged — it gets its own capability
gate, `Host.process` (the exact same `{ io, dir }` shape `Host.fs` already
has, so an embedder/test can point `exec` and `open`/`exists`/... at the
same directory), defaulting to absent: `RuntimeError.ProcessesUnavailable`
with none. A spawn failure (no such program, no permission) is
`RuntimeError.ProcessSpawnFailed`; a child that didn't exit normally
(killed by a signal, stopped, ...) is
`RuntimeError.ProcessTerminatedAbnormally` — there's no sane 0..255 code to
report for either. All three are catchable, bringing the catchable-variant
count to 25. [src/main.zig](src/main.zig) grants the CLI's own process
permission unconditionally, mirroring how it already grants `fs`.

Deliberately minimal, matching this entry's own scope: the spawned child's
standard input is always empty (no way to pipe bytes in), and
`"stdout"`/`"stderr"` are the FULL captured output gathered only after it
exits (no incremental/streaming form) — a future pass could add an opt-in
interactive form without changing this one. The child's environment is the
real OS process environment, not `Host.env` (which only governs this
Butter program's own `getenv`/`hasenv`) — a program can't use `Host.env` to
sandbox what a spawned child itself sees.

Documented in GRAMMAR.bnf/ISA.bnf. Covered by lexer/parser/compiler/VM unit
tests (capability gate, non-string command, non-list args, a non-string
element within args, a nonexistent program's `ProcessSpawnFailed`, static
type `map`), a `ProcessesUnavailable` case in
[tests/cases/try_catch.butter](tests/cases/try_catch.butter), the
[exec](tests/cases/exec.butter) integration case (which spawns a REAL
per-host-OS process — PowerShell on Windows, `/bin/sh` on POSIX, chosen by
`tests/integration_test.zig` via `builtin.os.tag` and handed over as
`args` so the `.butter` source itself stays platform-agnostic, the same
reason `args`/`env` cases are injected rather than read from the real
process), and [examples/exec.butter](examples/exec.butter).

### 12. Directory and filesystem metadata operations — DONE
`exists(path)`, `listDir(path)`, `remove(path)`, and `rename(from, to)`
are now special-form expressions (GRAMMAR.bnf design note 3w, parsed like
`getenv`/`open` — none is also a `<type>` keyword, so each is a legal bare
`<expr-stmt>` too), compiling to four new opcodes in
[src/vm.zig](src/vm.zig) (`PATH_EXISTS`/`LIST_DIR`/`PATH_REMOVE`/
`PATH_RENAME`, ISA.bnf section 16) that reuse `open`'s existing `Host.fs`
capability gate rather than adding a second one — a program that can
already `open` a file can reach everything these need.

`exists` is deliberately lenient: it evaluates to `bool` and only ever
raises for the capability gate or a non-string argument — any other
reason the check can't be answered (missing, no permission, a bad path)
reads as `false`, matching the inherently racy, advisory nature of an
existence check on any real filesystem. `remove`/`rename` instead extend
`delete(map, key)`'s "absent is a no-op, not an error" split to the
filesystem: each evaluates to whether there was something to remove/move
(`false`, not an error, when the source was already gone), while a
genuine failure (no permission, a non-empty directory, a missing
destination parent, an I/O error) raises the new catchable
`RuntimeError.RemoveFailed`/`RenameFailed`. `rename` checks whether its
source exists via an independent `access` call first rather than trusting
the underlying rename's own `FileNotFound`, which on at least one
supported host can't be told apart from the destination's parent
directory being missing — a real failure, not a no-op. `listDir` has no
such lenient fallback (there's no meaningful "couldn't tell" empty list
for "list this directory's contents"): any failure to open or walk `path`
is `RuntimeError.ListDirFailed`. It evaluates to a fresh `list` of entry
names only (no kind, not recursive, never `.`/`..`), in whatever order the
OS iterator returns them — never sorted, matching every other host-order
dependency this VM already has (`keys(map)` aside, which IS
insertion-ordered).

19 of Butter's `RuntimeError` variants were catchable before this task;
`ListDirFailed`/`RemoveFailed`/`RenameFailed` bring that to 22 (design note
3u's count updated accordingly). Butter still has no way to CREATE a
directory (no `mkdir` builtin was in scope here), which is why
`RemoveFailed`'s one non-empty-directory failure mode can't be exercised by
a `.butter` program at all — [tests/cases/try_catch.butter](tests/cases/try_catch.butter)'s
header comment documents the gap, and
[src/compiler.zig](src/compiler.zig)'s dedicated `RemoveFailed` test seeds
a non-empty directory directly via Zig instead.

Covered by lexer/parser/compiler/VM unit tests (capability gate, type
mismatches on one or both operands, static types `bool`/`bool`/`bool`/
`list`), end-to-end `src/compiler.zig` tests against a real
`std.testing.tmpDir` (success and every failure path for all four,
including the two "genuinely fails, not just absent" cases for
`remove`/`rename`), two new cases in
[tests/cases/try_catch.butter](tests/cases/try_catch.butter)
(`ListDirFailed`/`RenameFailed`), the
[dir_ops](tests/cases/dir_ops.butter) integration case (order-independent
by construction — it checks `listDir`'s result by membership, not
position), and [examples/dir_ops.butter](examples/dir_ops.butter).

---

## P3 — larger language features

### 13. First-class / higher-order functions
No closures, and functions can't be passed as values (GRAMMAR.bnf's
"Functions" design note: "No nesting, no closures"). Every collection
operation in [src/std/collections.std.butter](src/std/collections.std.butter)
is hand-written per case because there's no way to pass a comparator or
callback.
- Design spike required: at minimum decide whether this means true
  closures (capturing enclosing scope — currently explicitly
  disallowed) or just function-values without capture (pass a top-level
  `func` by reference).
- Write a design note before implementation; this touches ast.zig,
  parser.zig, compiler.zig, and vm.zig's value representation.

### 14. Structs / records / enums
Objects today are maps with string keys by convention (see Set/Stack/
Queue in `collections.std.butter`) — workable, but no shape validation
and stringly-typed field access.
- Design spike required: decide whether this is a compile-time-only
  sugar over `map` (cheaper) or a genuinely new runtime value kind.
- Write a design note before implementation.

### 15. Time, clock, and random-number access — DONE
`now()`, `random()`, and `random(start, end)` are now special-form
expressions (GRAMMAR.bnf design note 3y, parsed like `getenv`/`exec` —
neither `now` nor `random` is also a `<type>` keyword, so a bare use of
either is a legal `<expr-stmt>` too), compiling to three new opcodes
(`NOW`/`RANDOM_FLOAT`/`RANDOM_RANGE`, ISA.bnf section 18) in
[src/vm.zig](src/vm.zig). `now()` evaluates to a fresh `float` of seconds
since the Unix epoch, sub-second precision included; `random()`/
`random(start, end)` are distinguished purely by argument count (the same
way `write`'s two forms are) and evaluate to a fresh `float` in `[0, 1)` or
a fresh `int` in `[start, end)` respectively — end EXCLUSIVE, the same
convention the for-loop's own `start..end` uses. `random(start, end)`'s
bounds are checked to be `int` at compile time where possible, mirroring
the for-loop's own bounds exactly, and always at runtime; `start >= end` is
the new catchable `RuntimeError.InvalidRange`, checked before any entropy is
drawn.

Both builtins are capability-gated exactly like `open`/`exec`
(`Host.clock: ?std.Io`, defaulting to absent — `RuntimeError.
ClockUnavailable` with none), since this Zig version's own wall-clock and
OS-entropy access both go through `std.Io` rather than a global ambient
function. `random()`/`random(start, end)` have a second way around that
gate — `Host.rng_seed: ?u64`, an override that makes their output exactly
reproducible run to run, bypassing `Host.clock` entirely and seeded lazily
on first use so a program gets a genuine sequence rather than one value
repeated. This is the deterministic test mode this task called for
designing in; `now()` has no such override (pinning wall-clock time would
defeat its own purpose), so its own coverage instead asserts plausibility
against a real clock (`std.testing.io`) rather than an exact value.
[src/main.zig](src/main.zig) grants `Host.clock` unconditionally (mirroring
`fs`/`process`) but never sets `rng_seed`, so a program run from the CLI
always draws real entropy.

This brings the catchable-`RuntimeError` count from 25 to 27 (design note
3u's count updated accordingly). Documented in GRAMMAR.bnf/ISA.bnf. Covered
by lexer/parser/compiler/VM unit tests (capability gate, seeded
determinism and cross-run reproducibility, range validation before entropy
is drawn, non-int/float operand rejection matching the for-loop's own
bounds, static types `float`/`float`/`int`), two new cases in
[tests/cases/try_catch.butter](tests/cases/try_catch.butter)
(`ClockUnavailable`/`InvalidRange`), the
[time_random](tests/cases/time_random.butter) integration case (run with a
fixed `Host.rng_seed` and no clock, so its `.expected` output is exactly
reproducible), and [examples/time_random.butter](examples/time_random.butter).

---

## P4 — build-system and infrastructure polish

### 16. Add CI
No `.github/workflows` exists. Nothing currently runs `zig build test` on
push/PR.
- Add a GitHub Actions workflow that installs the pinned Zig version
  (0.16.0, per [build.zig.zon](build.zig.zon)) and runs `zig build test`
  on push and PR against `master`.

### 17. Add a `zig fmt` check
No formatting check is wired into `build.zig` or CI.
- Add a build step (or CI step) that runs `zig fmt --check` over `src/`
  and `tests/` and fails the build on unformatted files.

### 18. Add a release/distribution step
`build.zig` already exposes `standardOptimizeOption`/
`standardTargetOptions`, so `-Doptimize=ReleaseFast -Dtarget=...` works
ad hoc, but there's no packaged `release` build step and no cross-
compiled artifact publishing.
- Add a `release` step to `build.zig` (or a CI workflow) that builds
  stripped `ReleaseFast` binaries for common target triples and attaches
  them to GitHub Releases.

### 19. Add a fuzz target
Zig 0.16 has native fuzzing support (`zig build test --fuzz`). The
hand-rolled recursive-descent lexer/parser in `src/lexer.zig` and
`src/parser.zig` is exactly the kind of code that benefits from it.
- Add a fuzz test target that feeds arbitrary byte input through the
  lexer → parser pipeline and asserts it never panics/crashes (parse
  errors are fine, panics are not).

### 20. (Informational, low priority) `.zig-cache` size
Local `.zig-cache` was observed at ~1.5GB against a 6MB `zig-out`. It's
gitignored so this isn't a repo-bloat issue, just a local-disk one.
- No action needed now; if it keeps growing, revisit CI cache scoping or
  periodic local pruning (`zig build` cache is safe to delete entirely
  and will rebuild).
