# Design note — error recovery (`try`/`catch`), TODO #9

Status: **proposed**, nothing implemented. This is the design spike TODO #9
asks for; the prose in sections 2 and 6 is written to be folded into
GRAMMAR.bnf (design note 3u) and ISA.bnf (section 14) once the
implementation lands, at which point this file goes away.

Chosen approach: a **scoped `try`/`catch` statement** that traps a runtime
error raised anywhere inside its body — including several call frames deep —
and binds a structured `map` describing the failure. Rejected alternatives
and why are in section 8.

---

## 1. Syntax

```ebnf
<statement>   ::= ... | <try-stmt>

<try-stmt>    ::= 'try' <block> 'catch' IDENTIFIER <block>
```

Two new keywords, `try` and `catch`, added to the KEYWORD list.

Both parts are a `<block>` specifically — not the `<declaration>` that
`if`/`while` accept. Braces are mandatory on both sides because both halves
are load-bearing scopes (the catch block's scope is what the error binding
lives in), and because a braceless `try` reads ambiguously next to a
following `catch`.

The IDENTIFIER binding is mandatory. A `catch { ... }` with no binding is a
plausible convenience, but it saves one identifier at the cost of a second
grammar production and a second codegen path; a program that doesn't care
writes `catch _ { ... }` (`_` is a legal IDENTIFIER — `<alpha>` includes
`_`).

```
try {
    int f := open(path, read)
    int n := read(f, buf)
    print json(buf, n)
    close f
} catch e {
    write(stderr, "cannot read " + path + ": " + e["message"] + "\n")
    exit 1
}
```

## 2. Semantics (GRAMMAR.bnf design note 3u)

- `try <block> catch <ident> <block>` runs its first block; if any
  **catchable** runtime error (section 3) is raised while it runs — at any
  depth, including inside a function it calls, and inside a function that
  one calls — execution abandons the rest of that block and continues at the
  first statement of the catch block, with IDENTIFIER bound to a fresh `map`
  describing the failure (section 4). If the try block completes without
  error, the catch block is skipped entirely.
- The two blocks are **separate scopes**. A local declared in the try block
  is not in scope in the catch block — it may never have been initialized,
  since that's precisely the case the catch block exists to handle. The
  error binding is a local of the catch block's own scope and is discarded
  at its end, like any other local.
- The binding's static type is `map` (design note 3t). Reading a key out of
  it (`e["message"]`) is an unchecked map read, exactly like any other.
- `try`/`catch` nests, and the innermost enclosing `try` wins. An error
  raised **inside a catch block is not caught by its own `try`** — that
  handler is already spent by the time the catch block runs — so it
  propagates to the next enclosing `try`, or terminates the program.
- `return` inside a try block returns from the enclosing function normally,
  abandoning the handler (section 6). `exit` inside a try block still exits
  the whole program immediately (design note 3q) — it is not an error, so
  there is nothing for a handler to catch, and no `try` can intercept it.
- **A file opened inside a try block stays open** if the block is abandoned
  mid-way. The open-file table is not rewound, for the same reason the value
  stack is: a stream can legitimately outlive the block that opened it (a
  local declared outside the `try` and assigned inside it), and there is no
  way to tell that apart from one that can't. Every still-open file is
  flushed and closed when the program halts, as always; a program that wants
  a deterministic close does it in the catch block.

## 3. Which errors are catchable

Catchable — all 19 of these become observable to a Butter program for the
first time:

`TypeMismatch`, `DivisionByZero`, `Overflow`, `IndexOutOfBounds`,
`ByteOutOfRange`, `StreamReadFailed`, `StreamWriteFailed`, `FileOpenFailed`,
`TooManyOpenFiles`, `FileCloseFailed`, `StreamNotReadable`,
`StreamNotWritable`, `StreamClosed`, `CannotCloseStandardStream`,
`FilesUnavailable`, `KeyNotFound`, `JsonParseFailed`, `NumberParseFailed`,
`InvalidExitCode`.

Not catchable — these pass through every handler and terminate the program
exactly as they do today:

- `StackOverflow`, `StackUnderflow`, `CallStackOverflow`, and the new
  `HandlerStackOverflow` (section 5). These are VM-integrity failures, not
  program conditions: the program has no meaningful recovery for them, and
  running a catch block requires the very stack room that's just been
  exhausted.
- `error.OutOfMemory`. It isn't a `RuntimeError` at all (it comes from the
  Zig allocator, `CompileError`-style), and building the error map itself
  allocates — so a handler for it could not run.

`exit` is not in either list because it is not an error: it returns from
`Vm.run` normally (src/vm.zig's `.exit` case), which already bypasses the
handler stack with no special-casing.

## 4. The error map

Four keys, **always all present**, so a program can read any of them without
guarding with `has()` first — predictability matters more here than
compactness, since the language has no shape validation (TODO #14):

| key | value | when |
| --- | --- | --- |
| `"error"` | the `RuntimeError` tag name, e.g. `"KeyNotFound"` | always |
| `"message"` | human-readable text — the same string the CLI prints today | always |
| `"operation"` | the operation that failed, e.g. `"open"` | `""` unless the error carries a `Diagnostic` |
| `"path"` | the file involved | `""` unless the error carries a `Diagnostic` |

`"error"` is the stable one to branch on (`if e["error"] == "KeyNotFound"`);
`"message"` is for humans and its exact wording is not a compatibility
promise. The last two come from `Vm.diagnostic` (src/vm.zig:132), which only
the file errors, `JsonParseFailed`, and `NumberParseFailed` set.

Rendering reuses main.zig's existing formatting so a caught-and-reported
error reads identically to an uncaught one. `Vm.diagnostic` is cleared as
part of unwinding, so a later, detail-free uncaught error can't report stale
detail from an earlier caught one.

## 5. Runtime (ISA.bnf section 14)

Two new opcodes:

- **`PUSH_HANDLER <target>`** — pushes a handler onto the VM's handler
  stack, recording everything needed to resume: the current chunk, `target`
  (the catch block's entry offset in that chunk), `sp`, `bp`, `frame_count`,
  and `return_width`. No effect on the value stack.
- **`POP_HANDLER`** — discards the top handler. Emitted where the try body
  falls off its end normally.

The handler stack is a fixed array on `Vm` (`max_handlers = 64`), sized like
`files` and for the same reason — no allocator at run time. Nesting deeper
than that is the new non-catchable `HandlerStackOverflow`. It must be a
runtime limit rather than a compile-time one: lexical nesting within a chunk
is bounded, but recursion through a function that itself contains a `try` is
not.

**Unwinding.** When the dispatch loop sees a catchable error and the handler
stack is non-empty, it takes the top handler H and:

1. pops H;
2. decrefs `stack[H.sp .. sp]` and sets `sp = H.sp` — the same loop
   `decrefStack` (src/vm.zig:736) already runs over the whole stack, just
   bounded below; correct across frames for the same reason it is there,
   since the physical stack is one flat array;
3. restores `chunk`, `bp`, `frame_count`, `return_width` from H, and sets
   `ip = H.ip`;
4. clears `self.diagnostic`;
5. builds the error map (section 4) and pushes it — so it lands at exactly
   the slot the compiler allocated for the binding (section 6);
6. continues the loop.

**RET drops stale handlers.** A `return` from inside a try block leaves that
frame's handler installed with an `ip` into a chunk that's no longer running.
RET therefore pops every handler whose recorded `frame_count` exceeds the
post-return frame count. Doing this at runtime rather than making the
compiler emit `POP_HANDLER` before each in-try `return` keeps it correct for
every path out of a frame by construction. Butter has no `break` or
`continue`, so `return`, `exit`, and falling off the end are the only ways
to leave a try block other than the error path itself.

## 6. Codegen (ISA.bnf section 4 pattern)

```
       PUSH_HANDLER  catch_target
       <try body>                     (* its own scope; locals POPped at end *)
       POP_HANDLER
       JUMP  end_target
     catch_target:
       <catch body>                   (* error map is already on the stack,
                                         pushed by the VM, and IS the binding's
                                         local slot *)
       POP                            (* discard the binding, via the normal
                                         end-of-scope popLocalsAbove *)
     end_target:
```

Both jumps are backpatched clox-style, exactly like `compileIf`
(src/compiler.zig:800).

The binding needs no `store_local` and no dedicated opcode: at the `try`
statement the compiler's `next_slot` is some N, the try body's own locals
occupy N upward and are popped by `popLocalsAbove` at its end, and the catch
block declares the binding as an ordinary local at slot N. At run time,
unwinding restores `sp` to the recorded `H.sp` (which is `bp + N`) and then
pushes the map — landing it at exactly slot N. The compiler's existing
end-of-scope POP then discards it with no special case.

## 7. Implementation plan

The one prerequisite refactor: **`Vm.run`'s dispatch switch has to become
catchable.** Today every instruction propagates out of `run` via `try`
(src/vm.zig:765–1253), so there's no point at which the loop can regain
control. Extract the switch body into a `step()` taking an execution-state
struct (`chunk`/`ip`/`bp`/`return_width`/`frames`/`frame_count` are all
`run` locals now) so the loop can `catch |err|`. Mechanical, but it touches
most of a 500-line switch.

**Hazard to audit while doing it: a partially-executed instruction must not
leak a reference.** Several instructions pop a value and then raise an error
before decreffing it. That's harmless today — the process is dying — but
under a catch it's a live refcount leak, and the popped slot sits *above*
`sp`, so unwinding's decref loop won't reach it. What bounds the audit is
that `Value.decref` is a no-op on a non-object, so only pops that can yield
a string/map/list matter: the index/slice, map, JSON, parse, `write`, and
`print` groups. The rule to establish and document: *an instruction that
returns an error must leave every object it popped either already decreffed
or still below `sp`.* The existing test suite runs the VM under
`std.testing.allocator`, so a missed case fails a test rather than going
unnoticed.

Suggested landing order, each step green before the next:

1. ~~The `step()` refactor alone — no behavior change, all existing tests
   pass.~~ **DONE.** `Vm.run`'s loop body is now `Vm.step`, threading an
   `Exec` struct (chunk/ip/bp/return_width/frames/frame_count) that used to
   be `run`'s locals; `run` is a three-line loop over it. Behavior is
   unchanged — `run` still propagates every error — but a handler now has a
   place to catch one. One wrinkle worth knowing before step 3: `step` must
   stay `inline`, since a real call per instruction measured 30-50% slower
   on the dispatch-bound benchmarks (its doc comment has the numbers).
   Inlining doesn't weaken the seam: `try` inside an inline function still
   yields its error to the call site, which is `run`'s loop.
2. The reference-leak audit above, with a test per fixed site.
3. `Vm` handler table, both opcodes, unwinding, `HandlerStackOverflow`, the
   error map. VM unit tests over hand-built chunks, like the existing `.exit`
   tests (src/vm.zig:1281+).
4. Lexer (`try`/`catch`), ast.zig (`Try { body, error_var, handler }`),
   parser — with their unit tests.
5. compiler.zig codegen, scope and slot handling, `map` typing for the
   binding.
6. Docs: GRAMMAR.bnf KEYWORD list + `<try-stmt>` + design note 3u; ISA.bnf
   section 3 entries, the section 4 pattern above, and new section 14.
7. `tests/cases/try_catch.butter` covering **all 22 `RuntimeError`
   variants** — 19 caught and inspected, 3 asserted to still escape — plus an
   `examples/` program showing the CLI-tool shape (open, parse, report,
   `exit 1`).

## 8. Alternatives considered

- **`<expr> else <expr>` fallback** (`int(s) else 0`). Cheaper and very
  ergonomic for defaulting, but discards the error entirely, so a CLI tool
  still can't say *why* it failed — the motivating case. Worth adding later
  on top of this same handler machinery; the two share everything in
  section 5.
- **`attempt(<expr>)` returning a Result map.** Same runtime, packaged as a
  special form like `json`/`stringify` instead of new statement syntax.
  Rejected as the primary form because multi-statement recovery reads badly
  through it, though it stays available as a later addition.
- **Checked builtins returning `null`** (`get(m, k)`, `tryOpen(...)`).
  Rejected: it only helps at the exact call site of a blessed builtin, so an
  error raised inside a stdlib function still kills the program, and it can't
  express `Overflow`/`DivisionByZero`/`TypeMismatch` at all — TODO #9's
  "one case per `RuntimeError` variant" is unreachable this way.
- **A `Result`-shaped map convention built purely in stdlib.** Not actually
  a standalone option: Butter code cannot observe a `RuntimeError` today, so
  such a convention could only ever sit on top of the checked builtins above,
  and inherits their gap.
