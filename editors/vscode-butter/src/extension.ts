// Thin VS Code client: all of the actual language intelligence
// (diagnostics, hover, go-to-definition, completion, document symbols)
// lives in the `butter-lsp` binary (src/lsp/ in the main repo) — this
// file's only job is starting it as a language server child process and
// wiring it to VS Code's document/language APIs via vscode-languageclient.

import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

// No path override configured: fall back to PATH lookup, matching how
// every other Butter CLI tool (butter itself) is expected to be
// installed — see this extension's README for setup instructions.
function resolveServerCommand(): string {
  const configured = vscode.workspace
    .getConfiguration("butter")
    .get<string>("lsp.path");
  if (configured && configured.trim().length > 0) {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (workspaceFolder) {
      return configured.replace(/\$\{workspaceFolder\}/g, workspaceFolder);
    }
    return configured;
  }
  return process.platform === "win32" ? "butter-lsp.exe" : "butter-lsp";
}

export function activate(_context: vscode.ExtensionContext): void {
  const serverOptions: ServerOptions = {
    command: resolveServerCommand(),
    args: [],
    transport: TransportKind.stdio,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "butter" }],
  };

  client = new LanguageClient(
    "butterLanguageServer",
    "Butter Language Server",
    serverOptions,
    clientOptions,
  );

  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
