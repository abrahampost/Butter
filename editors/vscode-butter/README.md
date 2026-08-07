# Butter Language (VS Code)

Editor support for `.butter` files: TextMate-grammar syntax highlighting
(derived from [`GRAMMAR.bnf`](../../docs/GRAMMAR.bnf)'s lexical rules) plus
a language client that starts `butter-lsp` — the Butter language server —
for diagnostics, hover, go-to-definition, document outline, and
completion.

## Language Server

The extension's `src/extension.ts` starts `butter-lsp` as a child process
and talks LSP to it over stdio; all of the actual language intelligence
lives there, built on the same lexer/parser/module-loader/compiler
`butter` itself uses (`src/lsp/` in the repo root).

**Marketplace installs**: a prebuilt `butter-lsp` for your platform ships
inside the extension (see [Package as a `.vsix`](#package-as-a-vsix)
below) — nothing to build or install separately, and no other
configuration is needed.

**Building from source / overriding the version**, one of two ways
(from the repo root, requires [Zig](https://ziglang.org/download/)
`0.16.0`):

```bash
zig build
```

This produces `zig-out/bin/butter-lsp` (`butter-lsp.exe` on Windows)
alongside the `butter` CLI itself. Then either:

- Put it on your `PATH` — used as a fallback if no bundled binary is
  found (e.g. running the extension unpackaged via `F5`).
- Or set the `butter.lsp.path` setting to its full path, which always
  takes priority over both the bundled binary and `PATH`.

Features (this pass): diagnostics (parse and semantic errors, live as you
type, across `import`ed files too), hover (declared function/struct/enum/
variable signatures — not fully inferred expression types), go-to-
definition (same-file, across `import`s, and into the bundled stdlib),
document outline, and context-aware completion (keywords, in-scope
locals, same-file and imported symbols, struct fields/methods after
`expr.`, enum variants after `EnumName.`).

## Try it locally

From this folder, either:

- Press `F5` in VS Code (with this folder open) to launch an Extension
  Development Host with the grammar and language client loaded, or
- Symlink/copy this folder into your VS Code extensions directory
  (`%USERPROFILE%\.vscode\extensions\butter-language` on Windows) and
  restart VS Code.

Either way, first install the client's own dependencies and build it:

```bash
npm install
npm run compile
```

## Package as a `.vsix`

Each platform gets its own `.vsix` with that platform's `butter-lsp`
binary bundled in under `bin/`. From the repo root, build the release
binaries once (cross-compiles all targets from any host):

```bash
zig build release
```

Then, from this folder:

```bash
npm install
npm run package:win32-x64    # or :linux-x64, :linux-arm64, :darwin-x64, :darwin-arm64
npm run package:all          # all five at once
```

Each stages the matching `zig-out/release/<triple>/butter-lsp(.exe)`
into `bin/` (via `scripts/stage-lsp-binary.js`) before invoking
`vsce package --target <platform>`. Install one to test:
`code --install-extension butter-language-<version>-<target>.vsix`.

For quick local testing without picking a target, `npm run package`
stages the host platform's binary and produces a single untargeted
`.vsix`.

Publishing (`vsce login zbutter` with a Marketplace personal access
token, then `npm run publish:all` or `npm run publish:<target>`) is a
manual step — it's the Marketplace publisher's own credential and isn't
part of this build.
