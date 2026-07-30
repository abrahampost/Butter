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

### 4. Process exit code control
Every successful run exits 0; every uncaught `RuntimeError` exits 1 with a
fixed message ([src/main.zig:145](src/main.zig#L145)). A program has no
way to signal a specific nonzero exit code (needed for `grep`/`diff`-style
tools).
- Add an `exit(code)` builtin/statement that halts the VM and propagates
  the requested code out to `main.zig`'s `std.process.exit`.
- Document in GRAMMAR.bnf (new statement or call form) and ISA.bnf (new
  opcode, likely a variant of `halt`).
- Add tests: normal halt still exits 0, `exit(n)` exits `n`, `exit` mid-
  function skips remaining code.

### 5. Number → string composition — DONE
Verified `stringify(n) + " ..."` works end-to-end now that task #1 has
landed; covered by the last line of the `strings` integration case
(`tests/cases/strings.butter`/`.expected`).

---

## P1 — significant gaps (workable around today, but painful)

### 6. String → number parsing
Only path is `json()`, which requires well-formed JSON and rejects
anything else (`"42px"` fails rather than partially parsing). No general
`parseInt`/`parseFloat`.
- Add `int`/`float` conversion builtins (naming should mirror the
  existing `type`-keyword style, e.g. reuse `int(s)`/`float(s)` as call
  syntax) that parse a string and raise a `RuntimeError` (new or reused
  variant) on malformed input.
- Document in GRAMMAR.bnf/ISA.bnf; add tests for valid/invalid input,
  leading/trailing whitespace, negative numbers.

### 7. float → int cast
No path exists anywhere in the VM (`@intFromFloat` is unused in the
codebase — confirmed via grep). `floor`/`ceil`/`round` in
[src/std/math.std.butter](src/std/math.std.butter) all return `float`;
there is no way to obtain an actual `int` from a computed float.
- Add an explicit cast builtin (e.g. `int(x)` for truncation, consistent
  with task #6's naming if both land) with defined truncation-toward-zero
  semantics.
- Document rounding/truncation behavior explicitly in GRAMMAR.bnf.
- Add tests: positive, negative, exact-integer floats, values near
  i64 bounds (overflow behavior should match the existing `Overflow`
  RuntimeError convention used by `add`/`sub`/etc.).

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
