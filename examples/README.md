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

Try any of them:

```bash
zig build run -- examples/basic_math.butter
zig build run -- examples/functions.butter
zig build run -- examples/fibonacci.butter
zig build run -- examples/arrays.butter
zig build run -- examples/array_functions.butter
zig build run -- examples/imports.butter
zig build run -- examples/stdlib_math.butter
# or, reading from standard input instead of a file:
zig build run -- --stdin < examples/basic_math.butter
```
