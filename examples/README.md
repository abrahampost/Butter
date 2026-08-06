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
| [stdlib_collections.butter](stdlib_collections.butter) | **Runs today** | `import "collections.std.butter"` — `Set`, `Stack`, and `Queue`, each a struct wrapping a `map` with the operations exposed as struct methods (src/std/collections.std.butter, GRAMMAR.bnf design note 3af): set union/intersection/difference/equality, LIFO add/pop/peek, and FIFO enqueue/dequeue/peek. |
| [stdlib_string.butter](stdlib_string.butter) | **Runs today** | `import "string.std.butter"` — trim/case conversion/reverse, search (`contains`/`startsWith`/`endsWith`/`indexOf`), `split`/`join`/`replace`, `padStart`/`padEnd`/`repeat`, and character classification (`isDigit`/`isAlpha`/`isSpace`), all pure Butter (src/std/string.std.butter) built on the core language's byte-indexed strings plus the `ord`/`join` builtins. |
| [io.butter](io.butter) | **Runs today** | `read`/`write` against `stdin`, `stdout`, and `stderr` — `write` as `print` without the newline, a short-read copy loop over a byte buffer, and a generic `int[]` buffer serving every size (GRAMMAR.bnf design note 3k, ISA.bnf section 9). Needs input piped in. |
| [files.butter](files.butter) | **Runs today** | `open`/`read`/`write`/`close` against a real file — `write`/`append`/`read` modes, and a stream that's now a genuine runtime value rather than only ever one of `stdin`/`stdout`/`stderr` (GRAMMAR.bnf design note 3l, ISA.bnf section 10). Creates/overwrites `examples/greeting.txt`. |
| [json.butter](json.butter) | **Runs today** | `map`/`list` as first-class heap values, bracket-indexing that chains through nested values, `has`/`keys`, `json(...)` parsing a byte buffer read from a real file into a map/list tree, and `stringify(...)` rendering a value back into (properly escaped) JSON text and writing it out again (GRAMMAR.bnf design notes 3m/3n/3o, ISA.bnf sections 11/12/13). Reads [data.json](data.json); creates/overwrites `dump.json`. |
| [env_vars.butter](env_vars.butter) | **Runs today** | `getenv`/`hasenv` (GRAMMAR.bnf design note 3v, ISA.bnf section 15) — reading configuration from the environment, with a built-in default that a variable overrides, `hasenv` telling an exported-but-empty setting from an absent one, and a numeric setting parsed under `try`/`catch`. Set `EDITOR`/`BUTTER_WIDTH`/`BUTTER_HEIGHT` to see it react. |
| [cli_args.butter](cli_args.butter) | **Runs today** | The bare `args` keyword (GRAMMAR.bnf design note 3p, ISA.bnf's PUSH_ARGS) — everything after a literal `--` on the CLI's own command line, as a `list` of strings. Needs `-- <name> ...` passed on the command line. |
| [dir_ops.butter](dir_ops.butter) | **Runs today** | `exists`/`listDir`/`remove`/`rename`/`mkdir` (GRAMMAR.bnf design note 3w, ISA.bnf section 16) — checking a path without opening it, listing a real directory's entries, moving/deleting a scratch file, and creating/removing a scratch directory, each showing the "absent"/"already there" is-a-no-op bool split and a genuine failure caught via `try`/`catch`. Creates and cleans up `examples/dir_ops_scratch.txt` and `examples/dir_ops_scratch_dir`. |
| [exec.butter](exec.butter) | **Runs today** | `exec(command, args)` (GRAMMAR.bnf design note 3x, ISA.bnf section 17) — spawning a real child process and capturing its `stdout`/`stderr`/`exit_code` as a `map`, plus a missing-program `ProcessSpawnFailed` caught via `try`/`catch`. Picks a small per-OS shell command via `hasenv("windir")`. |
| [time_random.butter](time_random.butter) | **Runs today** | `now()`/`random()`/`random(a, b)` (GRAMMAR.bnf design note 3y, ISA.bnf section 18) — a timestamp, a crude time+randomness unique ID, a die roll and a coin flip via `random(a, b)`'s end-exclusive range, an empty-range `InvalidRange` caught via `try`/`catch`, and a trivial `now()`-based timing measurement. |
| [string_interpolation.butter](string_interpolation.butter) | **Runs today** | `"...${expr}..."` interpolation (GRAMMAR.bnf design note 3ae, ISA.bnf section 23) — a variable, arithmetic, a struct field, a function call, list/map values and indexing, an enum variant, escaping a literal `${`/`$` with `\$`, and a nested interpolated string inside `${...}`. |

Try any of them:

```bash
zig build run -- examples/basic_math.butter
zig build run -- examples/functions.butter
zig build run -- examples/fibonacci.butter
zig build run -- examples/arrays.butter
zig build run -- examples/array_functions.butter
zig build run -- examples/imports.butter
zig build run -- examples/stdlib_math.butter
zig build run -- examples/stdlib_collections.butter
zig build run -- examples/stdlib_string.butter
zig build run -- examples/files.butter
zig build run -- examples/json.butter
# or, reading from standard input instead of a file:
zig build run -- --stdin < examples/basic_math.butter
# cli_args.butter needs its own '--' for the program's args (the first
# '--' is zig build's own separator, consumed before butter ever sees it):
zig build run -- examples/cli_args.butter -- Ada Grace
zig build run -- examples/dir_ops.butter
zig build run -- examples/exec.butter
zig build run -- examples/time_random.butter
zig build run -- examples/string_interpolation.butter
```

`env_vars.butter` reads its settings from the environment, so set some to
see it react (it runs fine with none set — that's the whole point of the
defaults it falls back to):

```bash
EDITOR=vim BUTTER_WIDTH=120 zig build run -- examples/env_vars.butter
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

`json.butter` is the same story — it opens `examples/data.json` relative to
the current directory, so it also needs to be run from the repo root as
shown above. It reads `data.json`, then near the end `stringify`s the
parsed document back into JSON text and writes it to
`examples/dump.json` — so, like `files.butter`, running it does
create/overwrite one file on disk.

`dir_ops.butter` is likewise relative-to-current-directory, and also lists
`examples/` itself — run it from the repo root as shown above. Unlike
`files.butter`/`json.butter`, it doesn't leave anything behind: the scratch
file it creates gets renamed and then removed again, and the scratch
directory it creates gets removed again, before the program ends.

`time_random.butter` draws real wall-clock time and real entropy (the CLI
never sets `Host.rng_seed` — see ISA.bnf section 18), so its output is
different every run; only the tests (which inject a fixed seed) get exactly
reproducible values.
