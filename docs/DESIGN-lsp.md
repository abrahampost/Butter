# DESIGN: `butter-lsp`, a language server for Butter

## Problem

Editor support was TextMate-grammar syntax highlighting only
(`editors/vscode-butter/`) — no diagnostics-as-you-type, hover, go-to-
definition, or completion.

## Constraint that shaped everything else

`ast.Stmt` carries a `line` (statement granularity); `ast.Expr` carries no
source position at all. A real LSP needs to answer "what's at line N,
column M" — the obvious approach is threading `line`/`column` through
every `Expr` variant (mirroring `Stmt`'s own `kind`+`line` shape). That
was rejected for this pass: it's a large, invasive diff across
`parser.zig`/`ast.zig`/`compiler.zig`/`optimizer.zig` — all
performance-gated (see CI's `performance-tests` job) and covered by a
fuzz suite — before any LSP feature work could even start.

## Approach: additive only, positions recovered by re-tokenizing

`src/lsp/` is new files only. Zero changes to `ast.zig`/`parser.zig`/
`compiler.zig`/`optimizer.zig`/`module.zig`. Every position-aware feature
re-tokenizes the relevant file (the real `lexer.zig`, which already
stamps a 1-based `line`+`column` on every token) and recovers whatever
position it needs by searching that token stream, anchored on the one
position the AST does carry (`Stmt.line`) — see `src/lsp/tokens.zig`'s
`segmentNames`/`singleDeclarationName`/`matchingClose` for the general
technique (walking a bracket-delimited or single-statement token range,
tracking depth, picking out identifier positions).

This turned out to simplify the design further: `ast.Stmt`'s
`function_decl`/`method_decl`/`struct_decl`/`enum_decl`/`import_stmt`
variants already carry full signatures directly in the AST — so
symbol/hover/completion/definition never need the compiler at all, only
`module.Loader` + raw AST walking (`src/lsp/symbols.zig`). The real
`compiler.Compiler.compileModules` (`src/lsp/workspace.zig`) is used
solely to produce semantic-error diagnostics; its resulting bytecode
chunk is discarded.

## Resolution order

Mirrors the language's own rules (GRAMMAR.bnf): a local/parameter/
receiver in the enclosing function wins first ("a function body resolves
only its own parameters and locals"), then a same-file top-level
function/struct/enum, then an EXPORTED symbol from a directly-imported
module (never transitive — same restriction `compiler.zig`'s
`functionVisible`/`typeVisible` have). See `src/lsp/resolve.zig`.

`scope.zig`'s local resolution is deliberately FLAT per function (nearest
declaration at-or-before the use line), not truly block-scoped the way
the compiler's `popLocalsAbove` is — a name declared inside an `if`/
`while`/`for`/`try` body and referenced after that block closes still
resolves in the LSP, where the real compiler would reject it. Diagnostics
are unaffected (they run the actual compiler); only hover/definition/
completion can be slightly too permissive in this shadowing edge case.

`.field`/`.method(...)` resolution (also in `resolve.zig`) only goes ONE
hop deep: the base must be a bare local/parameter (or a bare type name,
for `EnumName.Variant`) immediately before the `.`. `a.b.c` resolves
hovering over `b`, not `c` — that would need `a.b`'s own inferred type,
i.e. real expression type inference, which needs the compiler's
`inferType` (no standalone, non-codegen entry point today).

## Stale-tree fallback

Butter's parser has no error recovery — the first syntax error aborts the
whole parse (`parser.SyntaxError.UnexpectedToken`). `documents.zig` keeps
the LAST successful analysis (`Document.good`) around and only replaces
it when a NEW analysis attempt succeeds; diagnostics always reflect the
CURRENT (possibly broken) buffer regardless. This is what keeps hover/
definition/completion working while the user is mid-edit.

## Multi-file handling

Every open document is analyzed as its OWN entry point (`workspace.zig`),
exactly like `butter path/to/file.butter` itself works — there's no
project-manifest concept naming a single "real" entry point, and any file
is a legal one. A syntax/semantic error surfaces on whichever file is
actually at fault (`Diagnostic.path`), not just the file that triggered
re-analysis, so editing an imported helper file with a real error still
shows up correctly even if only the importer is open.

Imports are re-read from disk on every analysis pass (not from other open
buffers' in-memory text) — `textDocument/didSave` re-analyzes every open
document for this reason, since saving one file can change what a
DIFFERENT open file's own diagnostics/symbols should be.

## Explicitly out of scope for this pass

Find-references, rename, signature help, semantic tokens, expression-
level type-on-hover, import-path completion beyond the three bundled
stdlib names (no workspace `.butter` file scanning), and incremental/
perf-optimized re-analysis (every analysis pass re-runs the whole
loader+compiler for the affected file(s) — fine for the small CLI-script-
sized programs this language targets, per its own README).

## Testing

`src/lsp/*.zig` — in-file `test "..."` blocks (`zig build test-lsp`),
mirroring the project's existing convention (`parser.zig`/`ast.zig`
etc.) — pure-function tests against `workspace.analyze`'s in-process
result, no subprocess involved. `tests/lsp_smoke_test.zig`
(`zig build test-lsp-smoke`) is the one layer those can't reach: it
spawns the actual built `butter-lsp` binary and drives it over real
Content-Length-framed stdio JSON-RPC, with its own independent framing
implementation (deliberately not `@import`ing `src/lsp/rpc.zig`) so the
server isn't validated against itself.
