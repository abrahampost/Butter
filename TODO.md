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

### 8. Escape sequences in string literals
Per GRAMMAR.bnf section 1, `STRING` has no escape syntax at all —
`"a\nb"` is four literal characters. There's no way to embed a newline,
tab, or literal quote in a string, which makes multi-line usage/help text
awkward (must be built from multiple `print` calls).
- Add `\n`, `\t`, `\\`, `\"` (minimum viable set) to the lexer's string
  scanning in [src/lexer.zig](src/lexer.zig).
- Update GRAMMAR.bnf's lexical grammar and the STRING production note.
- Add lexer unit tests and at least one integration case using embedded
  newlines/tabs.

### 9. Error recovery (try/catch or Result-style handling)
Every `RuntimeError` (`IndexOutOfBounds`, `KeyNotFound`, `TypeMismatch`,
`JsonParseFailed`, divide-by-zero, etc.) aborts the whole process
immediately — see the `RuntimeError` enum and its call sites throughout
[src/vm.zig](src/vm.zig). There's no way for a program to attempt a
fallible operation and continue on failure, beyond manually guarding with
`has()` before a map read.
- This is a genuine language-design task, not a small addition — treat it
  as its own design spike before implementation. Options to weigh:
  a `try <expr> else <block>` statement form, a checked-variant of each
  fallible builtin (`tryOpen`, etc.) returning a sentinel, or a minimal
  `Result`-shaped map convention built entirely in stdlib.
- Write a short design note (comparable to the existing GRAMMAR.bnf
  section 3 notes) proposing the chosen approach before touching the
  parser/compiler/VM.
- Once a design is chosen: update GRAMMAR.bnf, ISA.bnf, compiler.zig,
  vm.zig, and add both unit and integration tests covering at least one
  case per existing `RuntimeError` variant.

---

## P2 — meaningful but not blocking

### 10. Environment variable access
No `getenv`-equivalent exists anywhere in the stdlib or VM.
- Add a `getenv(name)` builtin (returning `string`, with a defined
  behavior for an unset variable — e.g. empty string, or paired with a
  `hasenv`-style check).
- Document in GRAMMAR.bnf/ISA.bnf; add an integration test that sets an
  env var before invoking the test binary.

### 11. Subprocess/exec support
No way to shell out to another program. This blocks a large class of CLI
tools that wrap or orchestrate other binaries.
- Scope a minimal `exec`/`spawn` builtin: command + args in, captured
  stdout/stderr + exit code out (shape it like the existing
  stream/buffer conventions used by `read`/`write`).
- Consider the security/design implications (this is the first builtin
  with side effects outside the sandboxed `fs`/stream model — should
  probably be gated the same way `.fs` already is, i.e. absent unless the
  embedder opts in).
- Document in GRAMMAR.bnf/ISA.bnf; add an integration test.

### 12. Directory and filesystem metadata operations
`open`/`read`/`write`/`close` (GRAMMAR.bnf section 3, "Files") only
operate on a path you already know exists (for `read` mode) or are
willing to create/truncate (`write`/`append`). There's no listing,
existence check, stat, delete, or rename.
- Add builtins for at minimum: `exists(path)`, `listDir(path)` (→ list of
  names), `remove(path)`, `rename(from, to)`.
- Document in GRAMMAR.bnf/ISA.bnf; add integration tests using a temp
  directory (mirroring how `files.butter`/`json.butter` already
  create/overwrite fixtures under `examples/`).

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

### 15. Time, clock, and random-number access
No timestamp, duration, or random-value builtins — blocks anything
needing unique IDs, timing/benchmarking, or randomized behavior.
- Add minimal builtins: `now()` (unix timestamp, `int` or `float`) and
  `random()` (float in `[0, 1)`, or an `int` range form matching the
  `for`-loop's existing `start..end` convention).
- Document in GRAMMAR.bnf/ISA.bnf; add tests (random needs a
  seeded/deterministic test mode to be testable at all — design that in).

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
