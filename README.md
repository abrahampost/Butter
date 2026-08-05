# Butter

[![CI](https://github.com/abrahampost/Butter/actions/workflows/ci.yml/badge.svg)](https://github.com/abrahampost/Butter/actions/workflows/ci.yml)

Butter is a small, statically-typed scripting language with a lexer,
parser, bytecode compiler, and VM, all written in [Zig](https://ziglang.org/).
It's built for writing basic CLI tools: variables, functions, arrays,
structs/enums, `map`/`list` values, string/JSON handling, and a standard
library for filesystem, process, environment, and time/random access.

```butter
func fib(int n) -> int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

int i := 0
while i < 10 {
    print fib(i)
    i := i + 1
}
```

See [examples/](examples/) for more, and [GRAMMAR.bnf](docs/GRAMMAR.bnf) /
[ISA.bnf](docs/ISA.bnf) for the full language grammar and bytecode ISA the
compiler targets.

## Getting the `butter` executable

Download a prebuilt binary for your platform from the
[latest release](https://github.com/abrahampost/Butter/releases/latest),
or build from source with [Zig](https://ziglang.org/download/) `0.16.0`:

```bash
zig build
```

The `butter` executable is written to `zig-out/bin/`.

## Running a program

```bash
zig build run -- path/to/program.butter
```

Or, after building, run the executable directly:

```bash
./zig-out/bin/butter path/to/program.butter
```

Other CLI options:

```bash
butter path/to/program.butter                # run a file
butter --stdin < path/to/program.butter       # read the program from stdin
butter --disassemble path/to/program.butter   # print compiled bytecode instead of running it
butter path/to/program.butter -- foo bar      # program sees `args` == ["foo", "bar"]
```

## Editor support

A basic VS Code extension providing syntax highlighting for `.butter` files
lives in [editors/vscode-butter/](editors/vscode-butter/).

## Contributing

Working on the language implementation itself (lexer, parser, compiler,
VM, standard library)? See [CONTRIBUTION.md](CONTRIBUTION.md) for build,
test, and project-layout details.
