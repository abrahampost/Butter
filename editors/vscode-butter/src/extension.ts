// Thin VS Code client: all of the actual language intelligence
// (diagnostics, hover, go-to-definition, completion, document symbols)
// lives in the `butter-lsp` binary (src/lsp/ in the main repo) — this
// file's only job is starting it as a language server child process and
// wiring it to VS Code's document/language APIs via vscode-languageclient.

import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

// Priority: explicit `butter.lsp.path` override, then the platform
// binary bundled into this extension's own `bin/` folder (see
// scripts/stage-lsp-binary.js), then a PATH lookup for source/dev
// builds that didn't go through the packaging step.
function resolveServerCommand(context: vscode.ExtensionContext): string {
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

  const binaryName = process.platform === "win32" ? "butter-lsp.exe" : "butter-lsp";
  const bundled = context.asAbsolutePath(path.join("bin", binaryName));
  if (fs.existsSync(bundled)) {
    return bundled;
  }
  return binaryName;
}

export function activate(context: vscode.ExtensionContext): void {
  const serverOptions: ServerOptions = {
    command: resolveServerCommand(context),
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
