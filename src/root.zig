//! Public API for the `butter` module: a lexer and recursive-descent parser
//! for the Butter language, as specified by GRAMMAR.bnf.

const std = @import("std");

pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const value = @import("value.zig");
pub const chunk = @import("chunk.zig");
pub const vm = @import("vm.zig");
pub const compiler = @import("compiler.zig");
pub const module = @import("module.zig");
pub const stdlib = @import("stdlib.zig");

test {
    std.testing.refAllDecls(@This());
}
