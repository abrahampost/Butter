# Butter Language (VS Code)

TextMate-grammar-based syntax highlighting for `.butter` files. No language
server, no build step — just a language declaration and a grammar, derived
from [`GRAMMAR.bnf`](../../docs/GRAMMAR.bnf)'s lexical rules.

## Try it locally

From this folder, either:

- Press `F5` in VS Code (with this folder open) to launch an Extension
  Development Host with the grammar loaded, or
- Symlink/copy this folder into your VS Code extensions directory
  (`%USERPROFILE%\.vscode\extensions\butter-language` on Windows) and
  restart VS Code.

## Package as a `.vsix` (optional)

```bash
npx @vscode/vsce package
```

Installs via `code --install-extension butter-language-0.0.1.vsix`.
