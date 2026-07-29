# Examples

| File | Status | Notes |
|---|---|---|
| [basic_math.butter](basic_math.butter) | **Runs today** | Arithmetic, precedence, comparisons, booleans. |
| [functions.butter](functions.butter) | **Runs today** | Function declarations, parameters, and calls (`add`, `square`, `max`). |
| [fibonacci.butter](fibonacci.butter) | **Runs today** | Recursive `fib(n)` — proof the VM's call-frame model (ISA.bnf section 6) supports a function calling itself. |
| [arrays.butter](arrays.butter) | **Runs today** | Fixed-size array declaration, indexed assignment/reads, and a `for` range loop (ISA.bnf sections 5 and 7). |

Try any of them:

```bash
zig build run -- examples/basic_math.butter
zig build run -- examples/functions.butter
zig build run -- examples/fibonacci.butter
zig build run -- examples/arrays.butter
# or, reading from standard input instead of a file:
zig build run -- --stdin < examples/basic_math.butter
```
