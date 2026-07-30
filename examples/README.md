# Examples

| File | Status | Notes |
|---|---|---|
| [basic_math.butter](basic_math.butter) | **Runs today** | Arithmetic, precedence, comparisons, booleans. |
| [functions.butter](functions.butter) | **Runs today** | Function declarations, parameters, and calls (`add`, `square`, `max`). |
| [fibonacci.butter](fibonacci.butter) | **Runs today** | Recursive `fib(n)` — proof the VM's call-frame model (ISA.bnf section 6) supports a function calling itself. |
| [arrays.butter](arrays.butter) | **Runs today** | Fixed-size array declaration, indexed assignment/reads, a `for` range loop, and `len(arr)` driving the loop bound instead of a hardcoded size (ISA.bnf sections 2, 5, and 7). |
| [array_functions.butter](array_functions.butter) | **Runs today** | Arrays passed to and returned from functions: fixed-size by value (`doubleAll`) and generic/unsized by reference (`sum(int[] arr)`, `identity`) — one `sum` working across arrays of different lengths (ISA.bnf section 6). |
| [imports.butter](imports.butter) | **Runs today** | Cross-file `import`/`export` — a diamond dependency (both `imports.butter` and [stats.butter](stats.butter) import [numeric.butter](numeric.butter)) that gets compiled exactly once (ISA.bnf section 8). |
| [stdlib_math.butter](stdlib_math.butter) | **Runs today** | `import "math.std.butter"` — the bundled standard library (src/stdlib.zig), resolved by name and embedded in the `butter` binary rather than read from a file on disk (ISA.bnf section 8). |
| [io.butter](io.butter) | **Runs today** | `read`/`write` against `stdin`, `stdout`, and `stderr` — `write` as `print` without the newline, a short-read copy loop over a byte buffer, and a generic `int[]` buffer serving every size (GRAMMAR.bnf design note 3k, ISA.bnf section 9). Needs input piped in. |
| [files.butter](files.butter) | **Runs today** | `open`/`read`/`write`/`close` against a real file — `write`/`append`/`read` modes, and a stream that's now a genuine runtime value rather than only ever one of `stdin`/`stdout`/`stderr` (GRAMMAR.bnf design note 3l, ISA.bnf section 10). Creates/overwrites `examples/greeting.txt`. |

Try any of them:

```bash
zig build run -- examples/basic_math.butter
zig build run -- examples/functions.butter
zig build run -- examples/fibonacci.butter
zig build run -- examples/arrays.butter
zig build run -- examples/array_functions.butter
zig build run -- examples/imports.butter
zig build run -- examples/stdlib_math.butter
zig build run -- examples/files.butter
# or, reading from standard input instead of a file:
zig build run -- --stdin < examples/basic_math.butter
```

`io.butter` reads standard input, so pipe it something:

```bash
echo "hello there" | zig build run -- examples/io.butter
```

Note that `--stdin` and a program that reads `stdin` can't both have it: the
source program is read from standard input first and consumes all of it, so
the program itself then sees end of input (`read` returns 0). Pass a file
path when the program does its own reading.

`files.butter` opens paths relative to the CURRENT DIRECTORY, not this
`examples/` folder (`open` resolves at run time, unlike `import`, which
resolves at compile time relative to the importing file) — run it from the
repo root as shown above, and it will create/overwrite
`examples/greeting.txt` each time.
