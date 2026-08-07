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

**Build it** (from the repo root, requires [Zig](https://ziglang.org/download/) `0.16.0`):

```bash
zig build
```

This produces `zig-out/bin/butter-lsp` (`butter-lsp.exe` on Windows)
alongside the `butter` CLI itself.

**Point the extension at it** one of two ways:

- Put `butter-lsp` on your `PATH` — the extension looks it up there by
  default, and no other configuration is needed.
- Or set the `butter.lsp.path` setting to its full path.

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

## Package as a `.vsix` (optional)

```bash
npm install
npm run compile
npx @vscode/vsce package
```

Installs via `code --install-extension butter-language-<version>.vsix`.
Note this packages the TypeScript client only — `butter-lsp` itself isn't
bundled and must be installed separately (see above).
