//! `textDocument/completion` — context-aware: keywords, in-scope locals/
//! params, same-file top-level symbols, exported symbols from imports,
//! `expr.` member completion (struct fields/methods, or enum variants for
//! `EnumName.`), and `import "..."` path completion.
//!
//! Unlike hover.zig/definition.zig, this re-tokenizes the CURRENT (live)
//! buffer text itself rather than relying only on `mod_analysis`'s
//! possibly-stale token cache — completion is requested precisely while
//! the user is mid-edit (typing a partial identifier), which is exactly
//! when the last successful parse is most likely to be out of date. Live
//! tokens answer "what's textually around the cursor right now" (a
//! trigger '.', an `import` keyword, the partial word itself); the
//! stale-but-good `mod_analysis` still supplies the actual symbol data
//! (functions/structs/scope), same as hover/definition.
//!
//! Import-path completion only offers the three bundled stdlib names in
//! this pass — completing sibling `.butter` files on disk is a follow-up
//! (see the top-level design plan's Phase 2 list).

const std = @import("std");
const workspace = @import("workspace.zig");
const symbols = @import("symbols.zig");
const scope_mod = @import("scope.zig");
const protocol = @import("protocol.zig");
const tk = @import("tokens.zig");

const keywords = [_][]const u8{
    "print", "if",     "else",    "while",  "or",     "and",    "true",
    "false", "int",    "float",   "bool",   "string", "func",   "return",
    "for",   "in",     "import",  "export", "len",    "read",   "write",
    "stdin", "stdout", "stderr",  "open",   "close",  "append", "map",
    "list",  "push",   "keys",    "has",    "delete", "json",   "stringify",
    "null",  "args",   "getenv",  "hasenv", "exit",   "throw",  "try",
    "catch", "exists", "listDir", "remove", "rename", "mkdir",  "exec",
    "now",   "random", "struct",  "enum",   "ord",    "join",
};

const stdlib_imports = [_][]const u8{ "math.std.butter", "collections.std.butter", "string.std.butter" };

const Context = union(enum) {
    /// Index of the '.' token a member (field/method/variant) completion
    /// follows.
    member: usize,
    import_path,
    general,
};

pub fn complete(allocator: std.mem.Allocator, analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, live_text: []const u8, wire_pos: protocol.Position) ![]const protocol.CompletionItem {
    const pos = tk.Position.fromUtf16(live_text, wire_pos);
    const live_tokens = tk.tokenize(allocator, live_text) catch return &.{};
    const found = findContext(live_tokens, pos);

    var out: std.ArrayList(protocol.CompletionItem) = .empty;
    switch (found.ctx) {
        .import_path => {
            for (stdlib_imports) |name| {
                if (std.mem.startsWith(u8, name, found.prefix)) {
                    try out.append(allocator, .{ .label = name, .kind = protocol.CompletionItemKind.module });
                }
            }
        },
        .member => |dot_idx| {
            try completeMember(allocator, analysis, mod_analysis, live_tokens, dot_idx, found.prefix, &out);
        },
        .general => {
            try completeGeneral(allocator, analysis, mod_analysis, pos, found.prefix, &out);
        },
    }
    return out.toOwnedSlice(allocator);
}

fn findContext(tokens: []const tk.Token, pos: tk.Position) struct { ctx: Context, prefix: []const u8 } {
    var idx = tk.nearestIndexAtOrBefore(tokens, pos) orelse return .{ .ctx = .general, .prefix = "" };
    // A NEWLINE/EOF token marks a position, not content — when the cursor
    // sits exactly at one's own start (typing at the end of a line, or at
    // the end of the buffer with no trailing newline), it ties with
    // (and, being later, wins over) the real token right before it. Step
    // back to whatever's actually there instead.
    while (idx > 0 and (tokens[idx].type == .newline or tokens[idx].type == .eof)) idx -= 1;
    const tok = tokens[idx];
    const same_line = tok.line - 1 == pos.line;
    const start_char = tok.column - 1;
    const touches = same_line and pos.character >= start_char and pos.character <= start_char + tok.lexeme.len;

    if (tok.type == .identifier and touches) {
        if (idx >= 1 and tokens[idx - 1].type == .dot) return .{ .ctx = .{ .member = idx - 1 }, .prefix = tok.lexeme };
        if (idx >= 1 and tokens[idx - 1].type == .kw_import) return .{ .ctx = .import_path, .prefix = tok.lexeme };
        return .{ .ctx = .general, .prefix = tok.lexeme };
    }
    if (tok.type == .dot) return .{ .ctx = .{ .member = idx }, .prefix = "" };
    if (tok.type == .kw_import) return .{ .ctx = .import_path, .prefix = "" };
    if (tok.type == .string and idx >= 1 and tokens[idx - 1].type == .kw_import) return .{ .ctx = .import_path, .prefix = "" };
    return .{ .ctx = .general, .prefix = "" };
}

fn completeGeneral(allocator: std.mem.Allocator, analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, pos: protocol.Position, prefix: []const u8, out: *std.ArrayList(protocol.CompletionItem)) !void {
    for (keywords) |kw| {
        if (std.mem.startsWith(u8, kw, prefix)) {
            try out.append(allocator, .{ .label = kw, .kind = protocol.CompletionItemKind.keyword });
        }
    }

    const file_symbols = mod_analysis.symbols;
    for (file_symbols.functions) |f| {
        if (f.line <= pos.line and pos.line <= f.end_line) {
            if (scope_mod.build(allocator, mod_analysis.tokens, f)) |fscope| {
                for (fscope.locals) |l| {
                    if (l.decl_line <= pos.line and std.mem.startsWith(u8, l.name, prefix)) {
                        try out.append(allocator, .{
                            .label = l.name,
                            .kind = protocol.CompletionItemKind.variable,
                            .detail = if (l.is_param) "param" else "local",
                        });
                    }
                }
            } else |_| {}
            break;
        }
    }

    for (file_symbols.functions) |f| {
        if (!f.isMethod() and std.mem.startsWith(u8, f.name, prefix)) {
            try out.append(allocator, .{ .label = f.name, .kind = protocol.CompletionItemKind.function });
        }
    }
    for (file_symbols.structs) |s| {
        if (std.mem.startsWith(u8, s.name, prefix)) {
            try out.append(allocator, .{ .label = s.name, .kind = protocol.CompletionItemKind.class });
        }
    }
    for (file_symbols.enums) |e| {
        if (std.mem.startsWith(u8, e.name, prefix)) {
            try out.append(allocator, .{ .label = e.name, .kind = protocol.CompletionItemKind.@"enum" });
        }
    }

    for (file_symbols.imports) |imp| {
        const m = imp.resolved orelse continue;
        const imported = analysis.findModule(m.path) orelse continue;
        for (imported.symbols.functions) |f| {
            if (f.exported and !f.isMethod() and std.mem.startsWith(u8, f.name, prefix)) {
                try out.append(allocator, .{ .label = f.name, .kind = protocol.CompletionItemKind.function });
            }
        }
        for (imported.symbols.structs) |s| {
            if (s.exported and std.mem.startsWith(u8, s.name, prefix)) {
                try out.append(allocator, .{ .label = s.name, .kind = protocol.CompletionItemKind.class });
            }
        }
        for (imported.symbols.enums) |e| {
            if (e.exported and std.mem.startsWith(u8, e.name, prefix)) {
                try out.append(allocator, .{ .label = e.name, .kind = protocol.CompletionItemKind.@"enum" });
            }
        }
    }
}

fn completeMember(allocator: std.mem.Allocator, analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, live_tokens: []const tk.Token, dot_idx: usize, prefix: []const u8, out: *std.ArrayList(protocol.CompletionItem)) !void {
    if (dot_idx == 0 or live_tokens[dot_idx - 1].type != .identifier) return;
    const base_name = live_tokens[dot_idx - 1].lexeme;
    const line: u32 = @intCast(live_tokens[dot_idx].line - 1);
    const file_symbols = mod_analysis.symbols;

    if (findEnumAnywhere(analysis, mod_analysis, base_name)) |er| {
        for (er.e.variants) |v| {
            if (std.mem.startsWith(u8, v.name, prefix)) {
                try out.append(allocator, .{ .label = v.name, .kind = protocol.CompletionItemKind.enum_member });
            }
        }
        return;
    }

    var struct_name: ?[]const u8 = null;
    for (file_symbols.functions) |f| {
        if (f.line <= line and line <= f.end_line) {
            if (scope_mod.build(allocator, mod_analysis.tokens, f)) |fscope| {
                if (fscope.resolve(base_name, line)) |local| struct_name = local.named_type;
            } else |_| {}
            break;
        }
    }
    const name = struct_name orelse return;
    const sr = findStructAnywhere(analysis, mod_analysis, name) orelse return;

    for (sr.s.fields) |fld| {
        if (std.mem.startsWith(u8, fld.field.name, prefix)) {
            try out.append(allocator, .{ .label = fld.field.name, .kind = protocol.CompletionItemKind.field });
        }
    }
    for (sr.module.symbols.functions) |f| {
        if (f.isMethod() and std.mem.eql(u8, f.receiver_type.?, name) and std.mem.startsWith(u8, f.name, prefix)) {
            try out.append(allocator, .{ .label = f.name, .kind = protocol.CompletionItemKind.method });
        }
    }
}

const EnumRef = struct { e: symbols.EnumSymbol, module: workspace.ModuleAnalysis };

fn findEnumAnywhere(analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, name: []const u8) ?EnumRef {
    if (mod_analysis.symbols.findEnum(name)) |e| return .{ .e = e, .module = mod_analysis };
    for (mod_analysis.symbols.imports) |imp| {
        const m = imp.resolved orelse continue;
        const imported = analysis.findModule(m.path) orelse continue;
        if (imported.symbols.findEnum(name)) |e| {
            if (e.exported) return .{ .e = e, .module = imported };
        }
    }
    return null;
}

const StructRef = struct { s: symbols.StructSymbol, module: workspace.ModuleAnalysis };

fn findStructAnywhere(analysis: *const workspace.Analysis, mod_analysis: workspace.ModuleAnalysis, name: []const u8) ?StructRef {
    if (mod_analysis.symbols.findStruct(name)) |s| return .{ .s = s, .module = mod_analysis };
    for (mod_analysis.symbols.imports) |imp| {
        const m = imp.resolved orelse continue;
        const imported = analysis.findModule(m.path) orelse continue;
        if (imported.symbols.findStruct(name)) |s| {
            if (s.exported) return .{ .s = s, .module = imported };
        }
    }
    return null;
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

fn analyzeOk(gpa: std.mem.Allocator, source: []const u8) !workspace.Analysis {
    const result = try workspace.analyze(gpa, testing.io, source, "<test>", ".");
    return switch (result) {
        .ok => |a| a,
        .fail => error.TestUnexpectedResult,
    };
}

fn hasLabel(items: []const protocol.CompletionItem, label: []const u8) bool {
    for (items) |it| {
        if (std.mem.eql(u8, it.label, label)) return true;
    }
    return false;
}

test "complete offers keywords and top-level symbols filtered by prefix" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "func helper() -> int {\n    return 0\n}\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const items = try complete(arena_state.allocator(), &a, mod, "he", .{ .line = 0, .character = 2 });
    try testing.expect(hasLabel(items, "helper"));
    try testing.expect(!hasLabel(items, "if")); // "he" doesn't prefix "if"
}

test "complete offers a local/param inside its own function" {
    const gpa = testing.allocator;
    const source = "func f(int n) -> int {\n    return n\n}\n";
    var a = try analyzeOk(gpa, source);
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // Right after "return " on line 1 (live text, no partial word typed).
    const items = try complete(arena_state.allocator(), &a, mod, source, .{ .line = 1, .character = 11 });
    try testing.expect(hasLabel(items, "n"));
}

test "complete offers struct fields and methods after 'expr.'" {
    const gpa = testing.allocator;
    // The analysis itself must come from VALID source (workspace.analyze
    // is fail-fast) — the live buffer below is the one allowed to be
    // mid-edit ("return q." with nothing typed after the dot yet).
    var a = try analyzeOk(gpa,
        \\struct Point { int x, int y }
        \\func (Point p) sum() -> int {
        \\    return p.x + p.y
        \\}
        \\func use(Point q) -> int {
        \\    return q.x
        \\}
        \\
    );
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    const live = "struct Point { int x, int y }\nfunc (Point p) sum() -> int {\n    return p.x + p.y\n}\nfunc use(Point q) -> int {\n    return q.\n}\n";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // Right after "q." on line 5 (0-based).
    const items = try complete(arena_state.allocator(), &a, mod, live, .{ .line = 5, .character = 14 });
    try testing.expect(hasLabel(items, "x"));
    try testing.expect(hasLabel(items, "y"));
}

test "complete offers enum variants after 'EnumName.'" {
    const gpa = testing.allocator;
    // The analysis must come from valid source; the live buffer is the
    // one allowed to be mid-edit ("print Color." with nothing typed
    // after the dot yet).
    var a = try analyzeOk(gpa, "enum Color { Red, Green, Blue }\nprint Color.Red\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    const live = "enum Color { Red, Green, Blue }\nprint Color.\n";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // Right after "Color." on line 1.
    const items = try complete(arena_state.allocator(), &a, mod, live, .{ .line = 1, .character = 12 });
    try testing.expect(hasLabel(items, "Red"));
    try testing.expect(hasLabel(items, "Green"));
    try testing.expect(hasLabel(items, "Blue"));
}

test "complete offers stdlib names for an import path" {
    const gpa = testing.allocator;
    var a = try analyzeOk(gpa, "print 1\n");
    defer a.deinit();
    const mod = a.findModule("<test>").?;

    const live = "import \"ma\"\n";
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    // Inside the quotes, between "ma" and the closing '"'.
    const items = try complete(arena_state.allocator(), &a, mod, live, .{ .line = 0, .character = 10 });
    try testing.expect(hasLabel(items, "math.std.butter"));
}
