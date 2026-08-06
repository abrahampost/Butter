# Contributing to Butter

This covers working on the Butter language implementation itself (lexer,
parser, compiler, VM, standard library) — as opposed to just writing
`.butter` programs, which the [README](README.md) covers.

## Requirements

- [Zig](https://ziglang.org/download/) `0.16.0` (see `minimum_zig_version`
  in [build.zig.zon](build.zig.zon))

## Building

```bash
zig build
```

The `butter` executable is written to `zig-out/bin/`.

## Testing

```bash
zig build test              # unit + integration tests + fuzz smoke test
zig build test-integration  # just the .butter program integration tests
zig build test-performance  # timed performance benchmarks
zig build perf-report       # JSON performance report (-- --output <path>)
zig build perf-compare      # flag regressions between two perf-report runs
zig build fmt-check         # check formatting (zig fmt --check)
```

See [tests/README.md](tests/README.md) for details on how each test suite
works, how to add cases, and how `perf-report`/`perf-compare` feed CI's
run-over-run performance regression check.

CI (`.github/workflows/ci.yml`) runs `zig build fmt-check`, `zig build
test`, and a `performance-tests` job (`zig build test-performance` plus
the `perf-report`/`perf-compare` regression check above) on every push/PR
to `master` — run the first two locally before opening a PR.

## Project layout

| Path | Contents |
|---|---|
| [src/](src/) | Lexer, parser, compiler, VM, and standard library |
| [examples/](examples/) | Sample `.butter` programs, one per language feature |
| [tests/](tests/) | Integration, performance, and fuzz tests |
| [editors/vscode-butter/](editors/vscode-butter/) | VS Code syntax highlighting extension |
| [docs/GRAMMAR.bnf](docs/GRAMMAR.bnf) | Language grammar |
| [docs/ISA.bnf](docs/ISA.bnf) | Compiled bytecode instruction set |

## Design references

- [docs/GRAMMAR.bnf](docs/GRAMMAR.bnf) — the lexical/syntactic grammar, with
  numbered design notes explaining non-obvious choices
- [docs/ISA.bnf](docs/ISA.bnf) — the bytecode instruction set the compiler
  targets
- [TODO.md](TODO.md) — audit of missing language/build-system features,
  written as independently pickup-able tasks
- [DESIGN-error-recovery.md](DESIGN-error-recovery.md) — an example design
  spike for a not-yet-implemented feature; new non-trivial features should
  generally get one of these before implementation

## Releases

Tagging a commit `vX.Y.Z` and pushing the tag triggers
`.github/workflows/release.yml`, which builds stripped `ReleaseFast`
binaries for the target triples in `build.zig`'s `release` step
(`zig build release`) and publishes them to a GitHub Release.
