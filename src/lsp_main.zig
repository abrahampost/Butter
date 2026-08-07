//! Entry point for `butter-lsp`: a Language Server Protocol implementation
//! for Butter, built on top of the same lexer/parser/module-loader/
//! compiler `src/main.zig` uses. Speaks LSP over stdio (Content-Length-
//! framed JSON-RPC 2.0, per `src/lsp/rpc.zig`) — see `src/lsp/server.zig`
//! for request dispatch and `editors/vscode-butter/` for how an editor is
//! expected to launch this.

const std = @import("std");
const server = @import("lsp/server.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    try server.run(gpa, init.io);
}

test {
    std.testing.refAllDecls(@This());
}
