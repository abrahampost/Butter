#!/usr/bin/env node
// Copies the right `butter-lsp` binary from `zig-out/release/<triple>/`
// (produced by `zig build release` at the repo root) into this
// extension's `bin/` folder so it can be bundled into the .vsix.
//
// Usage: node scripts/stage-lsp-binary.js [vsce-target]
// vsce-target is one of win32-x64, linux-x64, linux-arm64, darwin-x64,
// darwin-arm64. Omit it to auto-detect the host platform/arch — useful
// for local `npm run package` testing.

const fs = require("fs");
const path = require("path");

// vsce target -> zig release triple (must match the `release_targets`
// list in build.zig at the repo root).
const TARGET_TO_TRIPLE = {
  "win32-x64": "x86_64-windows-gnu",
  "linux-x64": "x86_64-linux-gnu",
  "linux-arm64": "aarch64-linux-gnu",
  "darwin-x64": "x86_64-macos",
  "darwin-arm64": "aarch64-macos",
};

function detectHostTarget() {
  const plat = process.platform;
  const arch = process.arch;
  if (plat === "win32" && arch === "x64") return "win32-x64";
  if (plat === "linux" && arch === "x64") return "linux-x64";
  if (plat === "linux" && arch === "arm64") return "linux-arm64";
  if (plat === "darwin" && arch === "x64") return "darwin-x64";
  if (plat === "darwin" && arch === "arm64") return "darwin-arm64";
  throw new Error(
    `No known vsce target for host platform "${plat}"/"${arch}". Pass one explicitly: ${Object.keys(TARGET_TO_TRIPLE).join(", ")}`,
  );
}

const requestedTarget = process.argv[2] || detectHostTarget();
const triple = TARGET_TO_TRIPLE[requestedTarget];
if (!triple) {
  console.error(
    `Unknown target "${requestedTarget}". Expected one of: ${Object.keys(TARGET_TO_TRIPLE).join(", ")}`,
  );
  process.exit(1);
}

const repoRoot = path.resolve(__dirname, "..", "..", "..");
const isWindows = triple.includes("windows");
const binaryName = isWindows ? "butter-lsp.exe" : "butter-lsp";
const sourcePath = path.join(repoRoot, "zig-out", "release", triple, binaryName);

if (!fs.existsSync(sourcePath)) {
  console.error(
    `Missing ${sourcePath}\nBuild it first from the repo root with: zig build release`,
  );
  process.exit(1);
}

const binDir = path.join(__dirname, "..", "bin");
// Clear stale binaries from a previous target's staging run so a vsix
// never accidentally ships more than one platform's executable.
fs.rmSync(binDir, { recursive: true, force: true });
fs.mkdirSync(binDir, { recursive: true });
const destPath = path.join(binDir, binaryName);

fs.copyFileSync(sourcePath, destPath);
if (!isWindows) {
  fs.chmodSync(destPath, 0o755);
}

console.log(`Staged ${requestedTarget} (${triple}) -> editors/vscode-butter/bin/${binaryName}`);
