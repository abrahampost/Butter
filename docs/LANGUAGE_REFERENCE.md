# Butter Language Reference

Comprehensive reference for every documented feature and behavior of
Butter, illustrated with worked syntax examples rather than formal
grammar. Synthesized from [`GRAMMAR.bnf`](GRAMMAR.bnf) (syntax),
[`ISA.bnf`](ISA.bnf) (bytecode/runtime semantics), and the compiler/VM
source (`src/lexer.zig`, `parser.zig`, `ast.zig`, `compiler.zig`,
`vm.zig`, `value.zig`, `module.zig`, `json.zig`) — those files (and the
formal grammar in particular) are the ultimate source of truth if you
need the precise production rules; this doc is a terse example-driven
index over them, verified against the actual implementation rather than
just the prose design notes.

There is no `break`/`continue`, no `switch`/`match`, no closures, no
generics (beyond the one built-in array/reference mechanism), no
inheritance/interfaces, and no operator overloading beyond what's listed
below. If a feature isn't in this document, it doesn't exist in Butter.

---

## 1. Lexical grammar

- **Whitespace**: space, tab, `\r` discarded. `\n` is significant (a
  `NEWLINE` token; ends most statements).
- **Comments**: `#` to end of line (not included). Not nested, not
  recognized inside a string.
- **Identifiers**: `[A-Za-z_][A-Za-z0-9_]*`.
- **INT**: digits only (`42`). **FLOAT**: digits `.` digits — a leading or
  trailing bare `.` (`.5`, `5.`) is not a valid FLOAT token.
- **STRING**: `"..."`, supporting:
  - 5 escapes, exactly: `\n` `\t` `\\` `\"` `\$`. Any other character after
    `\` is a lexer error — no "pass the backslash through" fallback.
  - `${expr}` interpolation (§10.2).
- A lone `=` is a lexer error (`==` is required — no C-style assignment
  operator exists at all; `:=` is the only assignment token).
- `.` and `..` are distinct tokens (`..` — range/slice — is checked first,
  so a single `.` never misparses as half of `..`).

### 1.1 Keywords (56, all reserved — cannot be used as identifiers)

| Category | Keywords |
|---|---|
| Literals / types | `true` `false` `null` `int` `float` `bool` `string` `map` `list` |
| Declarations | `func` `struct` `enum` `import` `export` `return` |
| Control flow | `if` `else` `while` `for` `in` `or` `and` |
| Streams / files | `stdin` `stdout` `stderr` `open` `close` `read` `write` `append` |
| Collections | `push` `keys` `has` `delete` `len` `join` |
| JSON / parsing | `json` `stringify` `ord` `chr` |
| Error handling | `try` `catch` `throw` `exit` |
| Environment | `getenv` `hasenv` `args` |
| Filesystem | `exists` `listDir` `remove` `rename` `mkdir` |
| Process | `exec` |
| Time / random | `now` `random` |
| Statement | `print` |

### 1.2 Operators & punctuation

```
+  -  *  **  /  %                arithmetic
( )  { }  [ ]                    grouping / blocks / arrays / indexing
!  !=  ==  <  <=  >  >=          logical-not, comparisons
:  :=  ->  ,  .  ..              field/entry sep, assign, return-arrow, sep, field/range
```

---

## 2. Types

| Type | Kind | Notes |
|---|---|---|
| `int` | scalar, `i64` | overflow-checked arithmetic |
| `float` | scalar, `f64` | |
| `bool` | scalar | |
| `string` | heap, refcounted | immutable, byte-indexed, content equality |
| `map` | heap, refcounted | string-keyed, insertion-ordered, reference semantics |
| `list` | heap, refcounted | reference semantics |
| `struct` (user) | heap, refcounted | fixed named fields, reference semantics |
| `enum` (user) | scalar (not heap) | fixed named tag, distinct from `int` |
| `func(T,...)->T` | scalar (not heap) | structural function-value type (§7.2) |
| stream | scalar | no dedicated type keyword — declare as `int` (§2.1) |
| `null` | scalar, singleton | satisfies **no** declared type — `int x := null` is `TypeMismatch` |

Arrays are **not** a value type: a fixed-size array is `N` consecutive
stack slots of one scalar type, not a runtime value (§8). `map`/`list`
fields/params/locals are always exactly one value, never a run of slots.

### 2.1 The "stream as int" convention

No dedicated type keyword exists for a stream. To keep `int f := open(...)`
(as used throughout the codebase's own examples) legal, a stream value is
accepted anywhere `int` is statically expected, and nowhere else.

### 2.2 Zero / default values

| Type | Default (no initializer, or a function/field falling through) |
|---|---|
| `int` | `0` |
| `float` | `0.0` |
| `bool` | `false` |
| `string` | `""` |
| `map` | fresh empty map (real heap allocation) |
| `list` | fresh empty list (real heap allocation) |
| struct | fresh instance, every field recursively defaulted (real heap allocation) |
| enum | its first-declared variant |
| `func(...)->...`-typed | **none** — must always be explicitly initialized |

### 2.3 Static type checking (best-effort, not exhaustive)

Checked at compile time (`SemanticError.TypeMismatch`): a var-decl
initializer, an assignment's value, a call argument, a `return` value, a
struct literal's field values, an `if`/`while` condition (must be `bool`),
a for-loop's `start`/`end` (must be `int`), an `exit` code (must be
`int`), and every binary/unary/logical operator's operand(s).

- `int` widens to `float` wherever `float` is expected — acceptance only,
  not an inserted conversion (`x`'s slot still stores a raw int).
  `float` never implicitly narrows to `int` (use `int(x)`, §17).
- `bool`/`string`/`map`/`list`/struct/enum accept only their own exact
  type — no coercions. A struct/enum's "exact type" means the *same
  declared type*, not merely another type of identical shape.
- `==`/`!=` are **never** statically checked — valid (and simply `false`
  when mismatched) across any two types at runtime.
- Whenever an expression's type genuinely depends on a runtime value the
  compiler can't track (a map/list element, `json(...)`'s parsed root, an
  unresolved call), checking is skipped here; the runtime
  `RuntimeError.TypeMismatch` is the only guard.

---

## 3. Program structure

```butter
import "geometry.butter"      # imports — must come first, or anywhere before use

struct Counter { int n }       # struct/enum declarations
enum Status { Ok, Failed }

func increment(Counter c) -> int {   # function declarations
    c.n := c.n + 1
    return c.n
}

Counter c := Counter{n: 0}     # top-level code — runs as the program's entry point
print increment(c)
```

Only `import`, `[export] func`, `[export] func (Type recv) name(...)`,
`[export] struct`, `[export] enum`, and plain var-declarations/statements
are legal at the top level — never reachable from inside a block/
if/while/function body. A top-level var-declaration (like `Counter c`
above) can't be `export`ed (sidesteps module-init-order questions).

### 3.1 `import` / `export`

```butter
# geometry.butter
export struct Point { float x, float y }
export func dist(Point p) -> float {
    return sqrt(p.x * p.x + p.y * p.y)
}
func helper() -> int { return 0 }   # not exported — invisible to importers

# main.butter
import "geometry.butter"
Point p := Point{x: 3, y: 4}
print dist(p)          # ok — dist is exported
# print helper()       # SemanticError.FunctionNotVisible — not exported
```

- `import "path"` — `path` resolves relative to the **importing file's own
  directory** (unlike `open`, which resolves relative to the process's
  current directory, §15.3).
- Functions, methods, structs, and enums may each be individually
  `export`ed. A method's `export` is independent of its struct's own.
- Visibility is **direct-import-only, not transitive** — importing B does
  not expose what B itself imports.
- Function names are unique across the **whole compiled program**, not
  per-file (`SemanticError.DuplicateFunction` on collision, even between
  files that never import each other). Struct/enum names share one
  separate program-wide namespace with each other (never with function
  names).
- The module loader runs entirely **before** compilation: it recursively
  lexes/parses every transitively imported file depth-first, memoized by
  normalized path (a diamond dependency compiles exactly once). A cycle
  (A imports B imports A) is `LoadError.CircularImport`.
- An imported file's top level may contain only: more imports, function
  decls, method decls, struct/enum decls — a top-level var-declaration is
  legal only in the entry program.
- **Bundled standard library**: an import path is checked against a fixed
  table of `.std.butter` names *before* touching the filesystem — a hit
  resolves to source embedded in the `butter` binary at build time
  (currently `math.std.butter`, `string.std.butter`,
  `collections.std.butter`, `io.std.butter` — §26).

---

## 4. Declarations & assignment

```butter
int x := 5              # declaration + initializer
float pi                # declaration only — zero value (0.0) until assigned
string name := "Ada"
int[5] fixed             # fixed-size array — size is a compile-time literal
func sum(int[] xs) -> int { ... }   # `[]` — generic/by-reference, params & returns only

x := 10                  # plain identifier assignment
xs[0] := 1                # index assignment (array/list/map)
p.field := 5               # field assignment (struct)
y := (x := 5)                # assignment is itself an expression, evaluating to 5
```

- Array suffix: `[N]` (fixed size, literal int only) or bare `[]`
  (generic/by-reference, param/return position only — §8).
- `map`/`list`/struct/enum/function-typed declarations never take an
  array suffix.
- Assignment recognizes three lvalue shapes, reinterpreted from an
  already-parsed expression: `IDENTIFIER := v`, `base[index] := v`,
  `base.field := v`. A slice (`s[a..b] := v`) is never an lvalue (parse
  error). Assignment is itself an **expression** evaluating to the
  assigned value (`STORE_LOCAL` peeks, doesn't consume) — `y := (x := 5)`
  is legal.
- **Scoping**: lexical, block-scoped, resolved entirely at **compile
  time** to stack slots — there is no runtime name lookup. Shadowing an
  outer variable in an inner block is allowed; referencing an undeclared
  name is `CompileError.UndefinedVariable`.
- **No closures, no nested function declarations.** A function body
  resolves only its own parameters and locals — never a top-level or
  enclosing variable.

---

## 5. Operators

### 5.1 Precedence (loosest to tightest)

| # | Operators | Assoc. | Notes |
|---|---|---|---|
| 1 (loosest) | `:=` | right | assignment is the whole expression grammar's root |
| 2 | `or` | left | short-circuit |
| 3 | `and` | left | short-circuit |
| 4 | `==` `!=` | left | never type-checked |
| 5 | `<` `<=` `>` `>=` | left | numeric or string only |
| 6 | `+` `-` | left | |
| 7 | `*` `/` `%` | left | |
| 8 | `**` | left | binds tighter than `* / %`, same convention as most languages |
| 9 | `!` `-` (unary) | — | prefix, chains arbitrarily (`!!true`); binds tighter than `**` (`-2 ** 2` is `(-2) ** 2` = `4`, not `-(2 ** 2)`) |
| 10 (tightest) | `[...]` `[a..b]` `.name` `.name(...)` | left | postfix, chains (`doc["a"]["b"]`, `p.field.sub`) |

`**` is left-associative: `2 ** 3 ** 2` → `64` (i.e. `(2 ** 3) ** 2`, not
`2 ** (3 ** 2)`). Verified against the running compiler:
`print 3 + 2 ** 2` → `7` (i.e. `3 + (2 ** 2)`), `print 2 * 3 ** 2` → `18`
(i.e. `2 * (3 ** 2)`).

### 5.2 Semantics

- **`+`**: both numeric → arithmetic (int stays int, overflow-checked;
  any float operand promotes both). Both `string` → fresh string of `a`'s
  bytes then `b`'s. Any other pairing (including string + number) is
  `RuntimeError.TypeMismatch` — **no implicit numeric-to-string
  conversion** (use `stringify`/interpolation).
- **`-` `*` `/` `%`**: numeric only; `TypeMismatch` otherwise. `/`/`%` by
  zero and int overflow are `RuntimeError`s (`DivisionByZero`,
  `Overflow`), never traps or silent wraps.
- **`**`**: numeric only, same int/float promotion as above.
- unary **`-`**: numeric only. **`!`**: `bool` only.
- **`==` `!=`**: defined for *every* pair of value types, never a compile
  or runtime error. Numeric compares by value across int/float.
  String-shaped compares by content. list/map/struct compare by
  **pointer identity only, never deep**. Enum compares type *and*
  variant. Any other mismatched pair is simply unequal.
- **`<` `<=` `>` `>=`**: both numeric → by value. Both `string` → byte
  lexicographic (equal common prefix orders the shorter string first).
  Any other pairing is `TypeMismatch` — no cross-type ordering.
- **`or`**: if left is `true`, short-circuits — result is left's own
  value, right never evaluated. Else discards left, result is right's
  value.
- **`and`**: if left is `false`, short-circuits — result is left's own
  value. Else discards left, result is right's value.
  (Both operands of `and`/`or` must be `bool` at runtime —
  `RuntimeError.TypeMismatch` otherwise.)

---

## 6. Control flow

```butter
if x < 2 {
    return x
} else {
    return x * 2
}

while i < 10 {
    i := i + 1
}

for i in 0..10 {          # ascending, step 1, 10 excluded (0..9)
    print i
}

if flag print "on"        # braces optional — body is any single statement/block
```

- `if`/`while`/`for` each take a bare statement/block as their body — a
  single statement/block/nested-if, no braces required (though a `{...}`
  block is idiomatic). Condition must statically be `bool`.
- `for v in start..end body`: **always ascending, step 1, end exclusive**.
  `start`/`end` are each evaluated **once**, at loop entry. `v` is a
  fresh loop-scoped `int` — reassigning it inside the body is legal but
  doesn't affect iteration count/bounds beyond the current pass.
  No C-style three-clause form, no descending range, no custom step.
- **No `break`, no `continue`.** The only ways out of a loop body early
  are `return` (from a function), `exit` (halts the whole program), or a
  caught/uncaught error.
- **No `switch`/`match`.**

---

## 7. Functions

```butter
func fib(int n) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

func doubleAll(int[5] xs) -> int[5] { ... }   # fixed-size array param/return, by value
func sum(int[] xs) -> int { ... }              # generic array param, by reference
```

- Every function declares a return type and **always** returns one — no
  `void`. Falling off the end without `return` yields the declared
  type's zero value (§2.2); there is no "did every path return?" check.
- A call's argument **count** must match the callee's declared parameter
  count exactly; each argument's type is checked where staticaly
  determinable (§2.3); a `return` value is checked the same way.
- **No nesting, no closures**: a body resolves only its own parameters
  and locals.
- Recursion works unmodified (each call gets its own frame/base
  pointer) — bounded by `CallStackOverflow`/`StackOverflow`, not
  catchable.

### 7.1 Struct methods

```butter
struct Point { float x, float y }

func (Point p) dist() -> float {
    return sqrt(p.x * p.x + p.y * p.y)
}

func (Point p) scale(float factor) {
    p.x := p.x * factor      # mutates the caller's own instance — receiver is by reference
    p.y := p.y * factor
}

Point origin := Point{x: 3, y: 4}
print origin.dist()            # method call: base.method(args)
origin.scale(2)
```

- Receiver clause order is `(Type name)` — struct type, then receiver
  variable name (not Go's `(name Type)` order). `Type` must be an
  already-declared **struct** — an enum receiver is
  `SemanticError.ReceiverNotAStruct`.
- Desugars to an ordinary function whose first parameter is the receiver
  — identical semantics to any other function body otherwise.
- **Static dispatch only, resolved at compile time** by the receiver
  expression's declared struct type — no vtables, no interfaces, no way
  for two structs to satisfy a shared "method contract". Calling an
  unknown method is `SemanticError.UnknownMethod`.
- **Receiver is always passed by reference** (a struct value already is
  a heap reference) — mutating a field on the receiver inside a method
  is visible to the caller immediately, no extra syntax needed.
- A method name must not collide with its struct's own field names or
  another method already on that struct (`DuplicateFieldOrMethod`). Two
  *different* structs may freely share a method name — the namespace is
  per-receiver-type, not the single flat table plain functions share.
  Independently `export`able per method.
- A method reference is **never** usable as a function value (§7.2), and
  there's no syntax to reference one bare (no call) — `p.dist` with no
  `(...)` is treated as an ordinary (likely-mistaken) field access.
- **Not supported**: a method's array return type can't feed the three
  contexts an ordinary function call's array return can (array-typed
  var-decl initializer, array-typed call argument, array return) — only
  scalar/map/list/struct/enum method returns work everywhere a plain
  call's result does.

### 7.2 Function values

```butter
func add(int a, int b) -> int { return a + b }
func mul(int a, int b) -> int { return a * b }

func(int, int) int op := add    # `func(paramTypes) returnType` — a structural type
print op(2, 3)                    # -> 5
op := mul                          # reassign to any function with the same signature
print op(2, 3)                    # -> 6
```

- Names any top-level function with that **exact structural signature**
  — never an anonymous/inline function, never a closure (no syntax
  defines a new function anywhere but the top level). A bare reference
  to a declared function's own name (not followed by `(`) is a value of
  this type.
- Every type inside a `func(...)->...` signature (each param, the
  return) is restricted to a plain scalar: `int`/`float`/`bool`/
  `string`/`map`/`list` — never a struct/enum name, never a nested
  function type — so two signatures compare purely structurally.
- Eligible only if the underlying function *also* has no array-typed
  parameter and no array return type. Referencing an ineligible function
  bare is a compile error (`InvalidFunctionValue`).
- A function-typed local/parameter has **no zero value** — it must
  always be initialized (`MissingFunctionInitializer` otherwise).
- **Not supported this pass**: a struct field or a function's own return
  type may not be function-typed — only a parameter or local variable
  can be.
- Calling through a func-typed value (`CALL_VALUE`) checks each argument
  against the **declared signature**, not whichever concrete function is
  currently held — the value could hold any function matching that
  signature, decided only at run time.

---

## 8. Arrays

```butter
int[5] fixed := [1, 2, 3, 4, 5]   # fixed size — N is a compile-time literal

func sum(int[] xs) -> int {         # generic ([]) — parameter/return only, by reference
    int total := 0
    for i in 0..len(xs) {
        total := total + xs[i]
    }
    return total
}

print sum(fixed)          # passing a fixed array where `int[]` is expected: by reference
print len(fixed)            # 5 — compile-time constant for a bare fixed-array name
```

- **Fixed-size**: `N` is always a compile-time `int` literal; element
  type is always a plain scalar; no nesting (no array of arrays, no
  array of map/list/struct/enum).
- **Generic** (`[]`): legal only as a parameter or return type. Crosses
  a call boundary **by reference** (`ArrayRef{base, len}`, one runtime
  value) instead of by value.
- A plain fixed-size local crosses a call boundary **by value** (a fresh
  copy) unless the callee's parameter is generic, in which case the
  compiler synthesizes a reference to the caller's own slots instead.
- **Indexing is bounds-checked at runtime**
  (`RuntimeError.IndexOutOfBounds`).
- `len(arr)` on a bare fixed-array identifier is a **compile-time
  constant**; on a generic one it's a runtime read of the reference's
  own length field.
- A generic reference may only be **returned** if it was received as-is
  (a parameter, or forwarded from a nested call) — never one
  synthesized from this function's own locals, since that would point
  into a frame about to be discarded
  (`CompileError.EscapingArrayReference`).
- An array-literal (`[1, 2, 3]`) is a fixed-array initializer wherever
  one's expected; otherwise it builds a `list` (§9).

---

## 9. Maps and lists

```butter
map config := { "width": 80, "height": 24 }   # map literal — keys are STRING tokens
list nums := [1, 2, 3]                          # array literal in a non-array context -> list

config["width"] := 100        # bracket set (insert-or-update)
print config["width"]          # bracket get -> 100
config["depth"] := 3           # dynamic key, only possible after the map exists
print doc["a"]["b"]              # chains

push(nums, 4)                  # -> 4 (new length); no way to remove an element
has(config, "height")            # -> true, no error even if missing
delete(config, "height")          # -> true (existed) / false (didn't) — never errors
keys(config)                        # -> fresh list of keys, insertion order
len(nums)                            # -> 4

map b := config          # aliases the SAME map — b["x"] := 1 is visible through config too
```

- Heap values with **reference semantics**: `b := a` (where `a` is a
  list/map) makes `b` an alias of the same object — mutation through
  one is visible through the other. Nesting is free (list of maps, map
  of lists).
- Map keys are `STRING` tokens (static text only) in a literal; a
  *dynamic* key needs `m[expr] := v` after the map already exists.
- An array literal (`[expr, ...]`) is a fixed-array initializer wherever
  a fixed array is expected, otherwise it builds a `list`.
- **Bracket indexing** (`m[k]`, `xs[i]`) reuses the same postfix `[...]`
  syntax for both get and set, and chains (`doc["a"]["b"]`). List index
  must be an in-bounds `int`; map index any string-shaped value
  (insert-or-update on write, `RuntimeError.KeyNotFound` on a missing
  read).
- `push(list, v)` → new length. **There is no way to remove a list
  element** in this language version.
- `keys(m)` → a **fresh** list of a map's own keys, in insertion order —
  the only way to iterate a map (no dedicated foreach form; combine with
  `for i in 0..len(ks) { ks[i] ... }`).
- `has(m, k)` / `delete(m, k)` — presence-check / remove, with **no
  error** for a missing key (unlike a bracket read).
- `len(v)` on a non-bare-array-identifier expression: list → element
  count, map → entry count, string → byte length.
- Map is **order-preserving** (insertion order), so `keys`/`print`/JSON
  output are deterministic. A repeated key in a map literal is
  last-wins.
- `==`/`!=` compare by **pointer identity only, never deep** — same as
  struct.

---

## 10. Strings

```butter
string s := "hello"
print s[0]           # -> "h" (a fresh length-1 string, not an int)
print s[1..3]          # -> "el" (slice, end exclusive)
print s + "!"             # -> "hello!"
print s < "world"           # -> true (byte-lexicographic)
# s[0] := "H"                 # RuntimeError.TypeMismatch — strings are read-only
```

- **Byte-indexed, not codepoint-indexed** — a multi-byte UTF-8 character
  occupies more than one index, consistent with `read`/`write`'s `int`
  buffers.
- `s[i]` → a **fresh length-1 string** (there is no separate "char"
  type) — chosen so it compares directly against a string literal
  (`s[i] == "{"`). `RuntimeError.IndexOutOfBounds` unless
  `0 <= i < len(s)`.
- `s[a..b]` → a **slice**: fresh string of bytes `[a, b)`, end exclusive.
  `IndexOutOfBounds` unless `0 <= a <= b <= len(s)`; `a == b` is legal,
  yields `""`.
- **Read-only** — there is no `s[i] := v` (`RuntimeError.TypeMismatch` if
  attempted): a mutable index would let writing through one alias
  silently change every other variable that happens to hold "the same"
  string, since assignment aliases the same heap object rather than
  copying.
- `+` and `< <= > >=` are overloaded onto strings — see §5.2.

### 10.1 Escape sequences

Exactly five, decoded once the surrounding quotes are stripped: `\n`
`\t` `\\` `\"` `\$`. Any other character after `\` is a lexer error.

### 10.2 String interpolation `"...${expr}..."`

```butter
string name := "Ada"
list xs := [1, 2]
print "hello, ${name}! ${1 + 2} apples, xs = ${xs}"
# -> hello, Ada! 3 apples, xs = [1, 2]
print "literal dollar-brace: \${not interpolated}"
```

- An unescaped `${` opens an interpolation; everything up to the
  matching `}` is parsed as an ordinary expression — anything legal
  anywhere else in the language (a call, indexing, arithmetic, a nested
  string, ...) — and its **rendered** value is spliced into the
  surrounding text.
- `\$` is the escape for a literal `${` (or a lone `$`, though `$` alone
  needs no escaping — only the two-character `${` is special).
- Renders non-string values **the way `print`/`write` do** (unquoted
  `42`, `true`, `[1, 2]` for a list, bare variant name for an enum) —
  **not** the way `stringify` does. `stringify`-style JSON is never used
  for interpolation.
- Recurses to any depth (`"${ "inner: ${x}" }"` works).
- A syntax error inside `${...}` is reported at the position of the
  **whole string literal**, not an offset inside the braces.

---

## 11. Structs

```butter
struct Point {
    float x,
    float y
}

Point p := Point{x: 3, y: 4}   # every field required, by name, any order
p.x := 10                        # field write
print p.x                          # field read -> 10
# print p.z                            # SemanticError.UnknownField — caught at compile time

Point origin                        # no initializer -> {x: 0.0, y: 0.0}, a real heap alloc
```

- Top-level only, optionally `export`ed. Struct and enum names share
  **one** program-wide namespace — a struct and an enum can never share
  a name, any more than two functions can.
- A field's type may be any scalar, `map`, `list`, or another
  struct/enum (nesting and mutual references between structs are free)
  — **never** a fixed/generic array.
- **Reference type**, heap-allocated and refcounted like `map`/`list`:
  `b := a` aliases; mutation through one is visible through the other.
- `p.field` (read) / `p.field := v` (write) are the only two operations,
  both resolved **entirely at compile time** — a typo'd field name is
  `SemanticError.UnknownField` at compile time, never a runtime
  `KeyNotFound` the way a bad map key would be. Neither op can raise a
  `RuntimeError`.
- `TypeName{field1: expr1, ...}` constructs an instance: **every**
  declared field is required, keyed by name, in any order.
  `MissingField` / `UnknownField` / `DuplicateFieldInLiteral` on
  mistakes. There is no partial/default-filled literal — a struct-typed
  local with no initializer gets the recursive zero-value instead
  (§2.2).
- `==`/`!=` compare by **pointer identity only, never deep**.

### 11.1 Built-in `Error` struct

One struct type, `Error`, is built in (registered before any user type,
occupying the name unconditionally — a program cannot redeclare it).
Four `string` fields, always all present: `error`, `message`,
`operation`, `path`. It's what `try`/`catch`'s binding is typed as
(§13); otherwise an ordinary struct — `Error{...}` constructs one,
`.field` reads it, like any other:

```butter
Error e := Error{error: "Custom", message: "bad input", operation: "", path: ""}
print e.message
```

---

## 12. Enums

```butter
enum Color { Red, Green, Blue }

Color c := Color.Red
if c == Color.Red {
    print "stop"           # variant reference + comparison
}
print c                       # prints "Red" — the bare variant name
# int n := Color.Red             # SemanticError.TypeMismatch — no implicit int conversion
```

- Top-level only, optionally `export`ed, sharing struct's namespace.
- Plain named tag, **no payload** (not a data-carrying union). Variant
  names unique within their own enum (`DuplicateVariant`).
- `EnumName.Variant` is a compile-time constant of a **genuinely
  distinct runtime type from `int`** — assigning/passing/returning a
  bare `int` where an enum is expected is `SemanticError.TypeMismatch`.
  Never heap-allocated; as cheap to copy as an int.
- `.` disambiguation (compiler decides, not the parser): if the base of
  `<expr>.name` is a bare identifier that names **no local currently in
  scope** but *does* name a declared enum type, it's a variant
  reference; a local always wins if one by that name exists. Any other
  shape must be a struct field read.
- Prints as its bare variant name (`Red`, not `0`/`"Red"`). **No JSON
  representation** (`stringify` → `Unstringifiable`/`TypeMismatch`). No
  built-in ordinal cast.
- `==`/`!=`: `true` only for the **same declared enum type and the same
  variant** — cross-type (or vs. a bare `int`) is simply `false`, never
  an error (no special carve-out from the "==/!= untyped" rule, §2.3).
- Default value (no initializer, or falling off a function's end): the
  **first-declared variant**.

---

## 13. Error handling: `try` / `catch` / `throw`

```butter
try {
    int n := int("not a number")
    print n
} catch e {
    print e.error       # -> "NumberParseFailed" — stable, safe to branch on
    print e.message
}

try {
    if input == "" {
        throw Error{error: "EmptyInput", message: "input required", operation: "", path: ""}
    }
} catch _ {              # `_` for a handler that ignores the binding
    print "invalid"
}
```

- Runs the `try` block; if a **catchable** runtime error is raised while
  it does — at any depth, including inside functions it calls — execution
  abandons the rest of the block and jumps to the `catch` block's first
  statement, with the catch identifier (`e` above) bound to a fresh
  `Error` struct (§11.1) instance describing the failure.
- **Both blocks require braces** (unlike `if`/`while`/`for`'s bare
  statement/block body); the binding identifier is **mandatory** — use
  `catch _ { ... }` for a handler that ignores it.
- **Separate scopes**: a local declared in the `try` body is not visible
  in the `catch` body (it may never have been initialized). The binding
  is an ordinary local of the catch block's own scope, statically typed
  `Error`.
- **Innermost enclosing `try` wins.** An error raised *inside* a catch
  block is not caught by its own `try` (already spent) — it propagates
  to the next enclosing `try`, or terminates the program.
- `throw <expr>` raises a catchable error of the program's own choosing.
  The thrown expression must statically be the built-in `Error` type
  (`SemanticError.TypeMismatch` otherwise) — build one with an
  `Error{error: "...", message: "...", operation: "...", path: "..."}`
  literal, or re-throw one already caught. Legal anywhere a statement
  is, unrestricted like `exit` (not scoped to a function body the way
  `return` is).
- `return` inside a `try` block returns from the enclosing function
  normally, abandoning the handler. `exit` inside a `try` block still
  halts the **entire program** immediately — not an error, nothing to
  intercept.
- A file opened inside a `try` block that's abandoned mid-way **stays
  open** (the open-file table isn't rewound on unwind) — flushed/closed
  automatically only when the program halts. A handler wanting a
  deterministic close does it itself.
- The handler stack is a fixed 64 entries — a 65th live `try` is
  `HandlerStackOverflow` (itself **not** catchable).

### 13.1 The `Error` struct's four fields

Always all present, so a handler can read any without a guard:

| Field | Meaning |
|---|---|
| `error` | The `RuntimeError` tag name (e.g. `"KeyNotFound"`) — stable, safe to branch on |
| `message` | Human-readable text (identical to what an uncaught error prints) — **not** a compatibility promise |
| `operation` | e.g. `"open"`, `""` if none |
| `path` | The file/path involved, `""` if none |

### 13.2 Catchable errors (29)

`TypeMismatch`, `DivisionByZero`, `Overflow`, `IndexOutOfBounds`,
`ByteOutOfRange`, `StreamReadFailed`, `StreamWriteFailed`,
`FileOpenFailed`, `TooManyOpenFiles`, `FileCloseFailed`,
`StreamNotReadable`, `StreamNotWritable`, `StreamClosed`,
`CannotCloseStandardStream`, `FilesUnavailable`, `KeyNotFound`,
`JsonParseFailed`, `NumberParseFailed`, `InvalidExitCode`,
`ListDirFailed`, `RemoveFailed`, `RenameFailed`, `MkdirFailed`,
`ProcessesUnavailable`, `ProcessSpawnFailed`,
`ProcessTerminatedAbnormally`, `ClockUnavailable`, `InvalidRange`,
`InvalidCharLength`.

### 13.3 Not catchable

`StackOverflow`, `StackUnderflow`, `CallStackOverflow`,
`HandlerStackOverflow` — VM-integrity failures, not program conditions;
running a handler needs the very stack room that just ran out. Also not
catchable: an allocator `OutOfMemory` (not a `RuntimeError` at all —
building the error struct itself allocates) and `UncaughtThrow` (a
`throw` that found no handler at the moment it ran — by construction, no
later `try` could ever catch it).

---

## 14. Byte-stream I/O

```butter
int[64] buf
int n := read(stdin, buf)      # short read: >=1 byte, <=len(buf); 0 only at EOF
while n > 0 {
    write(stdout, buf, n)        # write the first n bytes of buf -> bytes written
    n := read(stdin, buf)
}

write(stdout, "hello")           # renders like `print` but with no trailing newline
```

- `stdin`/`stdout`/`stderr` are bare keywords evaluating to a stream. An
  opened file (§15) works anywhere one of them does.
- `read(stream, buf) -> int`: `buf` must be a **bare identifier** naming
  an `int` array (fixed or generic) — fills it with raw bytes (0..255,
  one byte per element). **Short read** (POSIX-style): at least 1 byte
  and at most `len(buf)`; **0 only at end of input**; never loops to
  fill the buffer.
- `write(stream, value) -> int`: renders `value` exactly like `print`
  but with **no trailing newline**; returns the byte count written.
- `write(stream, buf, n) -> int`: writes the first `n` bytes of `buf`
  (an `int` array); returns bytes actually written.
  `RuntimeError.ByteOutOfRange` if any of the first `n` elements isn't
  an int in `0..255`; `IndexOutOfBounds` unless `0 <= n <= len(buf)`.
- Direction (`stdin` readable, `stdout`/`stderr` writable) is checked at
  **compile time** for a literal keyword use
  (`CompileError.WrongStreamDirection`), at **runtime** otherwise
  (`RuntimeError.StreamNotReadable`/`StreamNotWritable`).
- Embedder-dependent behavior: no `in` supplied → every `read` reports
  `0`; no `err` supplied → bytes written to `stderr` are counted but
  dropped; no `fs` supplied → every `open` fails `FilesUnavailable`.

---

## 15. Files

```butter
int f := open("data.txt", read)     # must already exist
int g := open("out.txt", write)      # truncates or creates
int h := open("log.txt", append)      # creates, or seeks to current end

int[64] buf
int n := read(f, buf)
write(g, buf, n)
close f
close g
close h
```

- `open(path, mode) -> stream`. `mode` is a bare keyword, fixed at
  compile time (even though success/failure isn't):
  - `read` — file must already exist.
  - `write` — truncates existing content, or creates.
  - `append` — creates, or seeks to the current end.
  - Failure: `TooManyOpenFiles` (fixed table of 8 open files),
    `FileOpenFailed` (no such file, no permission, ...),
    `FilesUnavailable` (no filesystem capability granted at all).
- `close <expr>` — a **statement**, not an expression. Closing a
  standard stream is rejected
  (`CannotCloseStandardStream` — compile-time if the stream is a literal
  keyword, runtime otherwise). Every file still open when the program
  halts is flushed and closed automatically.
- `read`/`write`/`write(...,...,...)` work on a file stream unchanged
  (§14). A closed or invalid stream is `RuntimeError.StreamClosed`.
- **Relative paths resolve against the process's current directory**,
  not any source file's own directory (unlike `import`, §3.1).

---

## 16. JSON

```butter
int[256] buf
int n := read(open("data.json", read), buf)
map doc := json(buf, n)          # result type depends on the document's root
print doc["name"]

string text := stringify(doc)      # -> properly escaped JSON text, round-trips through json(...)
```

- `json(buf, count)` parses `count` bytes of an `int` buffer as JSON
  text, evaluating to whatever the document's root is (number → int or
  float, bool, null, string, list, or map) — a special form (its result
  type isn't fixed at compile time), not an ordinary `func`. Malformed
  input → `RuntimeError.JsonParseFailed`.
- `stringify(value)` renders any value as properly-escaped JSON text
  (round-trips through `json(...)`, unlike `print`/interpolation's
  human-readable rendering). A stream, array reference, enum, or
  function value has no JSON shape → `RuntimeError.TypeMismatch`.

---

## 17. Numeric parsing & the float→int cast

```butter
int a := int("42")          # -> 42 (string -> parsed int)
int b := int(3.9)             # -> 3 (float -> truncated toward zero, not rounded)
int c := int(-3.9)              # -> -3, not -4
float d := float("3.14")          # -> 3.14
float e := float("inf")             # -> +Infinity (special-value text accepted)
# int("3.5")                          # RuntimeError.NumberParseFailed — no decimal point
```

`int`/`float` double as type keywords (`int x`, `func f() -> float`)
*and* this call-like special form — never ambiguous, since the
type-keyword reading is only ever consulted at the start of a
var-decl/param/return-type position, never while parsing an expression.

- **`int(x)`** branches on `x`'s runtime shape:
  - `string` → parses base-10 signed integer text (`std.fmt.parseInt`).
    Leading `+`/`-` accepted. **No** whitespace trimming, **no** decimal
    point allowed (`int("3.5")` fails, `int(" 42")` fails). Malformed →
    `RuntimeError.NumberParseFailed`.
  - `float` → **truncates toward zero** (`int(3.9)` is `3`,
    `int(-3.9)` is `-3`, not `-4`). `RuntimeError.Overflow` if the
    integer part doesn't fit `i64` (including NaN/±Infinity).
  - anything else (**`int` included** — no implicit "already an int"
    identity) → `RuntimeError.TypeMismatch`.
- **`float(s)`** parses a `string` only (`std.fmt.parseFloat`) — also
  accepts `"nan"`/`"inf"`/`"-inf"` (case-insensitive). No whitespace
  trimming. Malformed → `NumberParseFailed`. Passing an `int` is
  `TypeMismatch` — **there is no `int`→`float` widening cast**; only
  float→int truncation is provided.

---

## 18. Character conversion

```butter
print ord("A")       # -> 65
print ord("a")         # -> 97
# ord("AB")               # RuntimeError.InvalidCharLength — must be exactly one byte

print chr(65)          # -> "A"
print chr(97)             # -> "a"
# chr(256)                    # RuntimeError.ByteOutOfRange — must be 0..255
print ord(chr(65))       # -> 65
print chr(ord("Z"))        # -> "Z"
```

- `ord(s) -> int`: `s` must be `string`-shaped and **exactly one byte**
  long (`RuntimeError.InvalidCharLength` otherwise, checked rather than
  silently reading the first byte) — returns that byte's value, `0..255`.
- `chr(n) -> string`: `ord`'s inverse. `n` must be `int`-shaped
  (`RuntimeError.TypeMismatch` otherwise) and in `0..255`
  (`RuntimeError.ByteOutOfRange` otherwise, checked rather than
  truncated/wrapped) — returns the length-1 `string` whose single byte is
  `n`.
- **Byte-valued, not codepoint-valued**, both directions — a lone UTF-8
  continuation byte is still exactly one valid `ord`/`chr` byte, not a
  decoded codepoint.

---

## 19. String join

```butter
list parts := ["a", "b", "c"]
print join(parts, ", ")     # -> "a, b, c"
print join([], ", ")           # -> "" — sep never read for an empty list
```

- `join(list, sep) -> string`: every element of `list` must be
  `string`-shaped (`TypeMismatch` otherwise); `sep` inserted between
  each consecutive pair, none before the first or after the last.
  `list` itself must be a `list` (`TypeMismatch` if not). An empty list
  → `""` without ever reading `sep`.
- Single measure-then-copy pass — the O(n) alternative to repeated `+`
  concatenation in a loop (which is O(n²) since strings are immutable
  and `+` always allocates fresh copies of both operands).
- `list`'s elements are **read, not consumed** — `join` never mutates,
  empties, or frees the caller's list.

---

## 20. Environment variables

```butter
string editor := getenv("EDITOR")     # "" if unset — never an error
if hasenv("EDITOR") {                    # the only way to tell "unset" from "set to \"\""
    print "using ${editor}"
} else {
    print "using default"
}
```

- `getenv(name) -> string`: value of environment variable `name`, or
  `""` if unset — **never** an error and never `null`, so this alone
  can't distinguish "unset" from "set to empty string".
- `hasenv(name) -> bool`: whether `name` is set — the only way to make
  that distinction.
- `name` must be `string`-shaped at runtime (`TypeMismatch` otherwise);
  not checked at compile time. May be any expression (a computed name
  works: `getenv("BUTTER_" + setting)`).
- **Lookup is byte-exact on every platform, including Windows** (whose
  own environment is normally case-insensitive) — `getenv("path")` finds
  nothing where the variable is spelled `Path`, deliberately, for
  cross-platform consistency.
- The environment is a **snapshot** taken before the program starts, not
  read live — it cannot shift mid-run. There is no way for a program to
  **set** a variable, list every name, or affect its parent process.

---

## 21. Directory & filesystem metadata

```butter
if exists("data.txt") {
    print "found it"
}
list entries := listDir(".")     # one level, unsorted, never "." or ".."
remove("scratch.txt")               # -> bool: true if something was deleted
rename("old.txt", "new.txt")          # -> bool: true if `from` existed
mkdir("out")                             # -> bool: true if newly created
```

All five share `open`'s capability gate (`RuntimeError.FilesUnavailable`
with no filesystem access) and resolve a relative path against the
**process's current directory** (like `open`, unlike `import`). Every
path argument is an arbitrary expression, checked `string`-shaped only
at **runtime**.

| Call | Returns | Success semantics | Failure |
|---|---|---|---|
| `exists(path)` | `bool` | whether anything's there right now | **lenient** — any other failure (permission, malformed path, missing parent) reads as `false`, never an error |
| `listDir(path)` | `list` of names | one level only (not recursive), never `.`/`..`, **unsorted** (whatever order the OS hands back) | `ListDirFailed` |
| `remove(path)` | `bool` | deletes file or **empty** dir; `true` if something was removed | absent → `false` (no-op, not error); other failure → `RemoveFailed` |
| `rename(from, to)` | `bool` | moves/renames, **replacing** `to` if it exists; `true` if `from` existed | `from` absent → `false`; other failure → `RenameFailed` |
| `mkdir(path)` | `bool` | creates dir, **non-recursive** (missing parent fails); `true` if newly created | already-a-directory → `false` (no-op); other failure (incl. exists-as-a-file) → `MkdirFailed` |

None of the five recurses into directory contents on your behalf.

---

## 22. Subprocess execution

```butter
map result := exec("echo", ["hello", "world"])
print result["stdout"]        # captured output, gathered only after the child exits
print result["exit_code"]       # int
```

- `exec(command, args) -> map`: spawns `command` (string) with `args`
  (a `list` of strings) as its own `argv[1..]`, **waits for exit**, and
  returns a fresh map with exactly three keys, always all present:
  `"stdout"`, `"stderr"` (captured output, as strings), `"exit_code"`
  (an `int`).
- Own capability gate (`Host.process`, separate from `Host.fs`) — a
  spawned process is unbounded by whatever directory-scoping the
  embedder gave `Host.fs`. No gate → `RuntimeError.ProcessesUnavailable`.
- `command`/`args` checked at **runtime**: non-string `command`,
  non-`list` `args`, or a non-string element within `args` →
  `TypeMismatch`. Couldn't start at all → `ProcessSpawnFailed`. Exited
  abnormally (signal, stopped, ...) → `ProcessTerminatedAbnormally`
  (no sane `exit_code` to report).
- Child's **working directory** matches wherever a relative
  `open`/`exists` path resolves. Child's **environment** is the real OS
  process environment (**not** `Host.env`/sandboxed by `getenv`) — a
  program cannot use `getenv`'s sandbox to control what a spawned child
  itself sees.
- **No way to pipe bytes into a spawned child** (its stdin is always
  empty) and **no incremental/streaming output** — `stdout`/`stderr` are
  the full captured output, gathered only after the child exits.

---

## 23. Time & randomness

```butter
float start := now()             # seconds since the Unix epoch, sub-second precision
float coinFlip := random()         # uniform in [0, 1)
int roll := random(1, 7)             # uniform int in [1, 7) -> 1..6, end exclusive
float elapsed := now() - start
```

- `now() -> float`: current wall-clock time as seconds since the Unix
  epoch, sub-second precision. No int-seconds form (`int(now())`
  truncates already). Own capability gate (`Host.clock`) →
  `RuntimeError.ClockUnavailable` if absent. **No override exists** for
  `now()` — its own tests assert plausibility, not an exact value.
- `random() -> float`: uniform in `[0, 1)`.
- `random(start, end) -> int`: uniform in `[start, end)` — end
  **exclusive**, matching the for-loop's own convention. `start >= end`
  → `RuntimeError.InvalidRange`, checked **before** any entropy is
  drawn (works even with no clock access). `start`/`end` must be `int`
  (checked at compile time where possible, always at runtime).
- Both `random` forms share `Host.clock`'s gate — **unless**
  `Host.rng_seed` is set by the embedder, which bypasses the clock
  entirely for a deterministic, reproducible sequence (seeded lazily, on
  first use; a program that calls `random` more than once gets a real
  sequence, not one value repeated).

---

## 24. Program arguments

```butter
# butter myprog.butter -- Ada Grace
list names := args     # -> ["Ada", "Grace"]
print len(names)          # -> 2
```

- `args` is a bare keyword (like `stdin`), but evaluates directly to a **fresh
  `list` of strings** — everything after a literal `--` on the CLI's own
  command line. No `--` → an empty list.
- Every occurrence of `args` builds its **own independent list** —
  mutating one (via `push`, index-assign) never affects another `args`
  read elsewhere in the same program (unlike aliasing a `list` local via
  `b := a`).

---

## 25. Statements

```butter
print "hello"                                          # print
close f                                                   # close
exit 0                                                       # exit
throw Error{error: "E", message: "m", operation: "", path: ""}   # throw
return x                                                        # return
2 + 2                                                             # bare expression statement
```

Each statement ends at a newline or EOF (or, immediately before a
block's closing `}`, needs no terminator at all — `{ print "x" }` on one
line is legal).

| Statement | Behavior |
|---|---|
| `print expr` | Renders `expr` (list-of-elements bracketed/comma-separated, enum as bare variant name, etc.) followed by a newline, always to the `out` stream |
| `close expr` | Closes a stream; illegal on a standard stream (§15) |
| `exit expr` | `expr` must be `int` `0..255` (`TypeMismatch`/`InvalidExitCode` otherwise). Halts the **entire program immediately**, from anywhere (top level, mid-loop, several calls deep) — every open file flushed/closed first. A program that never calls `exit` still exits `0` on falling off the end |
| `throw expr` | See §13 |
| `return expr` | Only meaningful inside a function body — a semantic error at the top level, though grammatically legal anywhere a statement is |
| bare `expr` | Any expression used as a statement (its value discarded) |

---

## 26. Bundled standard library

Resolved by reserved name, not filesystem path (`import "X.std.butter"`,
§3.1) — source is embedded in the `butter` binary. All pure Butter, built
only on the core language + the builtins above.

### 26.1 `math.std.butter`

All `float -> float` unless noted:

`abs` `min(a,b)` `max(a,b)` `clamp(x,lo,hi)` `sign` `floor` `ceil`
`trunc` `round` `sqrt` `pow(base,exp)` — plus `gcd(int,int) -> int` and
`factorial(int) -> int`.

### 26.2 `string.std.butter`

Byte-oriented throughout (matches the core language's byte-indexed
strings, not Unicode-aware).

| Group | Functions |
|---|---|
| Character class (1-byte `string` in) | `isSpace` `isDigit` `isUpper` `isLower` `isAlpha` `isAlphaNumeric` → `bool` |
| Search | `indexOf(s,sub) -> int` (-1 if absent; `sub==""` matches at 0) · `contains` · `startsWith` · `endsWith` → `bool` · `count(s,sub) -> int` (non-overlapping; `sub==""` is 0) |
| Trim | `trimStart` `trimEnd` `trim` |
| Split/join/replace | `split(s,sep) -> list` (keeps empty pieces; `sep==""` splits into 1-byte pieces) · `replace(s,target,replacement) -> string` (`target==""` returns `s` unchanged) · `repeat(s,n) -> string` |
| Pad | `padStart(s,targetLen,pad)` · `padEnd(s,targetLen,pad)` — `s` already ≥ `targetLen`, or empty `pad`, returns `s` unchanged |
| Reverse | `reverse(s) -> string` — **byte**-reversed; scrambles multi-byte UTF-8 |
| Case | `toUpper` `toLower` — **ASCII-only** (`a`-`z`/`A`-`Z`); every other byte passes through unchanged |

### 26.3 `collections.std.butter`

Each type has a plain `xNew()` constructor (no receiver to hang it off
yet); everything else is a method. All elements are `string` (the only
type a map key can be, since each wraps a `map`). **Popping/peeking/
dequeuing an empty collection raises `RuntimeError.KeyNotFound`** — guard
with `isEmpty()` first.

| Type | Constructor | Methods |
|---|---|---|
| `Set` | `setNew()` | `contains(x)` `add(x)->bool` `discard(x)->bool` `size()->int` `isEmpty()->bool` `toList()->list` `union(Set)->Set` `intersection(Set)->Set` `difference(Set)->Set` `isSubset(Set)->bool` `equals(Set)->bool` |
| `Stack` (LIFO) | `stackNew()` | `add(x)->int` `pop()->string` `peek()->string` `size()->int` `isEmpty()->bool` |
| `Queue` (FIFO) | `queueNew()` | `enqueue(x)->int` `dequeue()->string` `peek()->string` `size()->int` `isEmpty()->bool` |

### 26.4 `io.std.butter`

Built on the core language's `open`/`read`/`close`/`chr`/`join` (§14-15,
§18-19) — not a new capability, just a convenience over them.

| Function | Notes |
|---|---|
| `readFile(path) -> string` | The entire contents of the file at `path`, decoded byte-for-byte (§18's "byte, not codepoint" convention) into a `string`. `path` is resolved the same way `open` resolves one — against the **current directory**, not the importing file's own directory. Propagates `open`/`read`'s own errors uncaught (`RuntimeError.FileOpenFailed` if `path` doesn't exist or isn't readable, `RuntimeError.FilesUnavailable` with no filesystem capability granted, §15) — same as calling `open`/`read` directly would. |

---

## 27. CLI

```bash
butter path/to/program.butter                # run a file
butter --stdin < path/to/program.butter       # read the program from stdin
butter --disassemble path/to/program.butter   # print compiled bytecode instead of running it
butter path/to/program.butter -- foo bar      # program sees `args` == ["foo", "bar"]
```

Build: `zig build` (Zig `0.16.0`) → `zig-out/bin/butter[.exe]` (plus
`butter-lsp`, a language server for the VS Code extension in
`editors/vscode-butter/`).

Note: `--stdin` and a program that itself `read`s `stdin` can't both
have it — the source program consumes all of standard input first, so
the program's own `read` sees immediate EOF (`0`). Pass a file path when
the program does its own reading.

---

## Appendix A — Compile-time errors (`SemanticError`)

| Error | Meaning |
|---|---|
| `UndefinedVariable` | Reference to (or assignment to) an undeclared name |
| `UndefinedFunction` | Call to an undeclared function name |
| `DuplicateFunction` | Function name collision anywhere in the compiled program |
| `ArityMismatch` | Call's argument count doesn't match the callee's parameter count |
| `ReturnOutsideFunction` | `return` used outside a function body |
| `NotAnArray` | `read`/`write`'s buffer argument doesn't name an array |
| `ArrayUsedAsScalar` | A fixed-size array's bare name used where a scalar is expected |
| `ArrayLengthMismatch` | Array-literal element count doesn't match the declared fixed size |
| `InvalidArrayInitializer` | Malformed array-literal initializer |
| `NotIndexable` | Bracket-indexing (or `len`) on a bare local that's statically neither array, list, map, nor string |
| `FunctionNotVisible` | Calling a function not exported by / not in the current module's direct imports |
| `InvalidArrayArgument` | Array-typed call argument doesn't match the parameter's array shape |
| `InvalidArrayReturn` | Returned value doesn't match a declared array return type |
| `EscapingArrayReference` | Returning a generic array reference synthesized from this function's own locals |
| `WrongStreamDirection` | Compile-time-detectable read from `stdout`/`stderr` or write to `stdin` |
| `CannotCloseStandardStream` | `close stdin`/`stdout`/`stderr` detected at compile time |
| `TypeMismatch` | Statically-known expression type doesn't fit where used (§2.3) |
| `UndefinedType` | A type position (var-decl, param, return type, struct field) names an identifier that isn't a declared struct/enum |
| `DuplicateTypeName` | A struct/enum name collision (structs and enums share one namespace) |
| `DuplicateField` | A struct declares the same field name twice |
| `DuplicateVariant` | An enum declares the same variant name twice |
| `UnknownField` | `.field` read/write, or a struct-literal key, names a field the struct doesn't have |
| `MissingField` | A struct literal omits one of the type's required fields |
| `DuplicateFieldInLiteral` | A struct literal supplies the same field twice |
| `NotAStruct` | A `.field` access's base isn't statically a struct |
| `UnknownEnumVariant` | `EnumType.name` where `name` isn't a declared variant |
| `TypeNotVisible` | A struct/enum type exists but isn't exported by an imported module |
| `InvalidFunctionValue` | Bare reference to a function ineligible as a function value (array param/return) |
| `MissingFunctionInitializer` | A function-typed local/parameter declared with no initializer |
| `ReceiverNotAStruct` | A method's receiver clause names an enum, not a struct |
| `DuplicateFieldOrMethod` | A struct's field and method (or two methods) share a name |
| `UnknownMethod` | `.method(...)` call names a method the receiver's struct type doesn't have |

## Appendix B — Runtime errors (`RuntimeError`)

**C** = catchable via `try`/`catch` (§13.2).

| Error | C | Meaning |
|---|---|---|
| `StackOverflow` | ✗ | Value stack exhausted |
| `StackUnderflow` | ✗ | VM-integrity failure (should never surface from valid compiled code) |
| `CallStackOverflow` | ✗ | Frame stack exhausted (deep/unbounded recursion) |
| `HandlerStackOverflow` | ✗ | More than 64 live `try` handlers at once |
| `TypeMismatch` | ✓ | An operand/argument's runtime type doesn't fit the operation |
| `DivisionByZero` | ✓ | `/` or `%` by zero |
| `Overflow` | ✓ | Int arithmetic overflow, or `int(float)` out of `i64` range |
| `IndexOutOfBounds` | ✓ | Array/string index or slice bound out of range |
| `ByteOutOfRange` | ✓ | A `write(...)` buffer element, or `chr(...)`'s argument, isn't an int in `0..255` |
| `StreamReadFailed` / `StreamWriteFailed` | ✓ | Underlying I/O error on `read`/`write` |
| `FileOpenFailed` | ✓ | `open` couldn't open the path (missing, no permission, ...) |
| `TooManyOpenFiles` | ✓ | More than 8 files open at once |
| `FileCloseFailed` | ✓ | Flushing a file's buffered writes failed |
| `StreamNotReadable` / `StreamNotWritable` | ✓ | `read`/`write` against a stream opened the wrong direction |
| `StreamClosed` | ✓ | Using an already-`close`d (or never-valid) file stream |
| `CannotCloseStandardStream` | ✓ | `close`ing `stdin`/`stdout`/`stderr` at runtime |
| `FilesUnavailable` | ✓ | No filesystem capability granted (`open` and all of §21) |
| `KeyNotFound` | ✓ | Bracket-reading a missing map key |
| `JsonParseFailed` | ✓ | `json(...)`'s input wasn't well-formed JSON |
| `NumberParseFailed` | ✓ | `int(s)`/`float(s)` given malformed text |
| `InvalidExitCode` | ✓ | `exit`'s value wasn't an int in `0..255` |
| `ListDirFailed` | ✓ | `listDir` couldn't list the path |
| `RemoveFailed` | ✓ | `remove` found something but couldn't delete it |
| `RenameFailed` | ✓ | `rename` found `from` but couldn't rename it |
| `MkdirFailed` | ✓ | `mkdir` couldn't create the directory |
| `ProcessesUnavailable` | ✓ | No process-spawn capability granted (`exec`) |
| `ProcessSpawnFailed` | ✓ | `exec`'s command couldn't be started |
| `ProcessTerminatedAbnormally` | ✓ | `exec`'s child didn't exit normally |
| `ClockUnavailable` | ✓ | No clock capability granted (`now`, `random` without a seed) |
| `InvalidRange` | ✓ | `random(start, end)` with `start >= end` |
| `InvalidCharLength` | ✓ | `ord(s)` where `s` isn't exactly one byte |
| `UncaughtThrow` | ✗ | A `throw` that found no active handler (structurally can never be caught later) |
