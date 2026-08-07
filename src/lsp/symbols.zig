//! Builds a flat symbol table for one file's top-level declarations
//! (functions, methods, structs, enums, imports) directly from its
//! `ast.Program` — the AST's `FunctionDecl`/`MethodDecl`/`StructDecl`/
//! `EnumDecl`/`Import` variants already carry full signatures (design
//! plan: symbol/hover/completion/definition never need the compiler, only
//! `module.Loader` + raw AST walking). Each declared name's exact column
//! (the AST itself only has `Stmt.line`) is recovered by re-tokenizing the
//! file and searching around that line with tokens.zig's helpers.

const std = @import("std");
const butter = @import("butter");
const ast = butter.ast;
const module = butter.module;
const tk = @import("tokens.zig");
const Token = tk.Token;
const Position = tk.Position;

pub const ParamSymbol = struct {
    param: ast.Param,
    pos: Position,
};

pub const FunctionSymbol = struct {
    name: []const u8,
    name_pos: Position,
    /// Zero-based line the declaration starts on (its `func` keyword).
    line: u32,
    /// Zero-based line its closing '}' is on, when found — used for a
    /// DocumentSymbol's `range` (the whole body), vs. `name_pos`'s own
    /// point position (its `selectionRange`).
    end_line: u32,
    params: []const ParamSymbol,
    return_type: ast.ValueType,
    return_named_type: ?[]const u8,
    return_array_size: ?ast.ArraySpec,
    exported: bool,
    body: []const ast.Stmt,
    /// Set only for a method (`ast.Stmt.method_decl`) — the struct type
    /// name and parameter name of its receiver clause.
    receiver_type: ?[]const u8 = null,
    receiver_name: ?[]const u8 = null,
    receiver_name_pos: ?Position = null,

    pub fn isMethod(self: FunctionSymbol) bool {
        return self.receiver_type != null;
    }
};

pub const FieldSymbol = struct {
    field: ast.FieldDecl,
    pos: Position,
};

pub const StructSymbol = struct {
    name: []const u8,
    name_pos: Position,
    line: u32,
    end_line: u32,
    fields: []const FieldSymbol,
    exported: bool,
};

pub const VariantSymbol = struct {
    name: []const u8,
    pos: Position,
};

pub const EnumSymbol = struct {
    name: []const u8,
    name_pos: Position,
    line: u32,
    end_line: u32,
    variants: []const VariantSymbol,
    exported: bool,
};

pub const ImportSymbol = struct {
    /// Raw import path text, exactly as written in source (a `.std.butter`
    /// bare name or a relative file path) — matches `module.Module.path`
    /// for a bundled stdlib module, but NOT for a file import (that one is
    /// resolved against the importing file's own directory; see
    /// workspace.zig, which fills in `resolved` once it knows that).
    path: []const u8,
    path_pos: Position,
    line: u32,
    /// Filled in by workspace.zig after `module.Loader` resolves this
    /// import against the real module graph — `null` only if resolution
    /// itself failed (a load error already surfaced as a diagnostic).
    resolved: ?*module.Module = null,
};

pub const FileSymbols = struct {
    functions: []const FunctionSymbol,
    structs: []const StructSymbol,
    enums: []const EnumSymbol,
    /// Mutable (unlike the other three tables) so workspace.zig can fill
    /// in each entry's `.resolved` field after `module.Loader` resolves
    /// the real import graph — `build` itself only ever sees one file in
    /// isolation, with no module graph to resolve against.
    imports: []ImportSymbol,

    /// A bare-call-shaped lookup — never returns a method (methods are
    /// only reachable via `findMethod`, matching the language's own
    /// resolution rules: a method call always has an explicit receiver).
    pub fn findFunction(self: FileSymbols, name: []const u8) ?FunctionSymbol {
        for (self.functions) |f| {
            if (!f.isMethod() and std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    pub fn findMethod(self: FileSymbols, receiver_type: []const u8, name: []const u8) ?FunctionSymbol {
        for (self.functions) |f| {
            if (f.isMethod() and std.mem.eql(u8, f.receiver_type.?, receiver_type) and std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    pub fn findStruct(self: FileSymbols, name: []const u8) ?StructSymbol {
        for (self.structs) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    pub fn findEnum(self: FileSymbols, name: []const u8) ?EnumSymbol {
        for (self.enums) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    pub fn findImport(self: FileSymbols, path: []const u8) ?ImportSymbol {
        for (self.imports) |i| if (std.mem.eql(u8, i.path, path)) return i;
        return null;
    }
};

fn posOf(tok: ?Token, fallback_line_1based: usize) Position {
    if (tok) |t| return Position.fromToken(t);
    return .{ .line = @intCast(fallback_line_1based - 1), .character = 0 };
}

fn endLineOf(tokens: []const Token, open_idx: ?usize, fallback_line_1based: usize) u32 {
    if (open_idx) |oi| {
        if (tk.matchingClose(tokens, oi)) |ci| return @intCast(tokens[ci].line - 1);
    }
    return @intCast(fallback_line_1based - 1);
}

fn paramSymbols(allocator: std.mem.Allocator, tokens: []const Token, open_idx: ?usize, params: []const ast.Param, decl_line: usize) ![]const ParamSymbol {
    const out = try allocator.alloc(ParamSymbol, params.len);
    var name_toks: []?Token = &.{};
    defer if (name_toks.len > 0) allocator.free(name_toks);
    if (open_idx) |oi| name_toks = try tk.segmentNames(allocator, tokens, oi);

    for (params, 0..) |p, i| {
        const tok = if (i < name_toks.len) name_toks[i] else null;
        out[i] = .{ .param = p, .pos = posOf(tok, decl_line) };
    }
    return out;
}

/// Builds `FileSymbols` for one parsed file. `tokens` must be the result
/// of tokenizing that SAME file's source text (tokens.zig's `tokenize`) —
/// mismatched tokens/AST silently recovers wrong (or no) positions rather
/// than crashing, since every lookup here is a best-effort textual search,
/// not a structural one.
pub fn build(allocator: std.mem.Allocator, program: ast.Program, tokens: []const Token) !FileSymbols {
    var functions: std.ArrayList(FunctionSymbol) = .empty;
    var structs: std.ArrayList(StructSymbol) = .empty;
    var enums: std.ArrayList(EnumSymbol) = .empty;
    var imports: std.ArrayList(ImportSymbol) = .empty;

    for (program) |*stmt| {
        switch (stmt.kind) {
            .function_decl => |f| {
                const kw_idx = tk.findKeywordOnLine(tokens, stmt.line, .kw_func);
                const name_tok = if (kw_idx) |ki| nextIdentifier(tokens, ki) else null;
                const open_idx = if (kw_idx) |ki| tk.findFrom(tokens, ki, .lparen) else null;
                const body_open = if (open_idx) |oi| tk.findFrom(tokens, oi, .lbrace) else null;
                try functions.append(allocator, .{
                    .name = f.name,
                    .name_pos = posOf(name_tok, stmt.line),
                    .line = @intCast(stmt.line - 1),
                    .end_line = endLineOf(tokens, body_open, stmt.line),
                    .params = try paramSymbols(allocator, tokens, open_idx, f.params, stmt.line),
                    .return_type = f.return_type,
                    .return_named_type = f.return_named_type,
                    .return_array_size = f.return_array_size,
                    .exported = f.exported,
                    .body = f.body,
                });
            },
            .method_decl => |md| {
                const kw_idx = tk.findKeywordOnLine(tokens, stmt.line, .kw_func);
                const recv_open = if (kw_idx) |ki| tk.findFrom(tokens, ki, .lparen) else null;
                const recv_names = if (recv_open) |ro| try tk.segmentNames(allocator, tokens, ro) else &[_]?Token{};
                defer if (recv_open != null) allocator.free(recv_names);
                const recv_close = if (recv_open) |ro| tk.findFrom(tokens, ro, .rparen) else null;
                const name_tok = if (recv_close) |rc| nextIdentifier(tokens, rc) else null;
                const open_idx = if (recv_close) |rc| tk.findFrom(tokens, rc, .lparen) else null;
                const body_open = if (open_idx) |oi| tk.findFrom(tokens, oi, .lbrace) else null;
                try functions.append(allocator, .{
                    .name = md.name,
                    .name_pos = posOf(name_tok, stmt.line),
                    .line = @intCast(stmt.line - 1),
                    .end_line = endLineOf(tokens, body_open, stmt.line),
                    .params = try paramSymbols(allocator, tokens, open_idx, md.params, stmt.line),
                    .return_type = md.return_type,
                    .return_named_type = md.return_named_type,
                    .return_array_size = md.return_array_size,
                    .exported = md.exported,
                    .body = md.body,
                    .receiver_type = md.receiver_type,
                    .receiver_name = md.receiver_name,
                    .receiver_name_pos = if (recv_names.len > 0) posOf(recv_names[0], stmt.line) else null,
                });
            },
            .struct_decl => |sd| {
                const kw_idx = tk.findKeywordOnLine(tokens, stmt.line, .kw_struct);
                const name_tok = if (kw_idx) |ki| nextIdentifier(tokens, ki) else null;
                const open_idx = if (kw_idx) |ki| tk.findFrom(tokens, ki, .lbrace) else null;
                const field_toks = if (open_idx) |oi| try tk.segmentNames(allocator, tokens, oi) else &[_]?Token{};
                defer if (open_idx != null) allocator.free(field_toks);

                const fields = try allocator.alloc(FieldSymbol, sd.fields.len);
                for (sd.fields, 0..) |fd, i| {
                    const t = if (i < field_toks.len) field_toks[i] else null;
                    fields[i] = .{ .field = fd, .pos = posOf(t, stmt.line) };
                }
                try structs.append(allocator, .{
                    .name = sd.name,
                    .name_pos = posOf(name_tok, stmt.line),
                    .line = @intCast(stmt.line - 1),
                    .end_line = endLineOf(tokens, open_idx, stmt.line),
                    .fields = fields,
                    .exported = sd.exported,
                });
            },
            .enum_decl => |ed| {
                const kw_idx = tk.findKeywordOnLine(tokens, stmt.line, .kw_enum);
                const name_tok = if (kw_idx) |ki| nextIdentifier(tokens, ki) else null;
                const open_idx = if (kw_idx) |ki| tk.findFrom(tokens, ki, .lbrace) else null;
                const variant_toks = if (open_idx) |oi| try tk.segmentNames(allocator, tokens, oi) else &[_]?Token{};
                defer if (open_idx != null) allocator.free(variant_toks);

                const variants = try allocator.alloc(VariantSymbol, ed.variants.len);
                for (ed.variants, 0..) |v, i| {
                    const t = if (i < variant_toks.len) variant_toks[i] else null;
                    variants[i] = .{ .name = v, .pos = posOf(t, stmt.line) };
                }
                try enums.append(allocator, .{
                    .name = ed.name,
                    .name_pos = posOf(name_tok, stmt.line),
                    .line = @intCast(stmt.line - 1),
                    .end_line = endLineOf(tokens, open_idx, stmt.line),
                    .variants = variants,
                    .exported = ed.exported,
                });
            },
            .import_stmt => |imp| {
                const kw_idx = tk.findKeywordOnLine(tokens, stmt.line, .kw_import);
                const path_tok = if (kw_idx) |ki| nextOfType(tokens, ki, .string) else null;
                try imports.append(allocator, .{
                    .path = imp.path,
                    .path_pos = posOf(path_tok, stmt.line),
                    .line = @intCast(stmt.line - 1),
                });
            },
            else => {},
        }
    }

    return .{
        .functions = try functions.toOwnedSlice(allocator),
        .structs = try structs.toOwnedSlice(allocator),
        .enums = try enums.toOwnedSlice(allocator),
        .imports = try imports.toOwnedSlice(allocator),
    };
}

fn nextIdentifier(tokens: []const Token, idx: usize) ?Token {
    return nextOfType(tokens, idx, .identifier);
}

fn nextOfType(tokens: []const Token, idx: usize, tt: tk.TokenType) ?Token {
    if (idx + 1 >= tokens.len) return null;
    const t = tokens[idx + 1];
    return if (t.type == tt) t else null;
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

// `build` allocates every symbol table (and the nested params/fields/
// variants slices within it) through whatever allocator it's given — in
// production that's always workspace.zig's per-document arena, freed in
// one shot alongside the rest of that document's analysis. Tests mirror
// that here with their own arena rather than hand-freeing each nested
// slice individually.
fn parseAndBuild(arena: std.mem.Allocator, source: []const u8) !struct {
    symbols: FileSymbols,
} {
    const tokens = try tk.tokenize(arena, source);
    var parser = butter.parser.Parser.init(arena, tokens);
    const program = try parser.parseProgram();
    const symbols = try build(arena, program, tokens);
    return .{ .symbols = symbols };
}

test "build recovers a function's name position and parameter positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try parseAndBuild(arena_state.allocator(), "func add(int a, int b) -> int {\n    return a + b\n}\n");

    try testing.expectEqual(@as(usize, 1), result.symbols.functions.len);
    const f = result.symbols.functions[0];
    try testing.expectEqualStrings("add", f.name);
    try testing.expectEqual(@as(u32, 0), f.name_pos.line);
    try testing.expectEqual(@as(u32, 5), f.name_pos.character);
    try testing.expectEqual(@as(usize, 2), f.params.len);
    try testing.expectEqualStrings("a", f.params[0].param.name);
    try testing.expectEqual(@as(u32, 2), f.end_line);
}

test "build recovers a method's receiver and name position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try parseAndBuild(arena_state.allocator(),
        \\struct Point { int x, int y }
        \\func (Point p) sum() -> int {
        \\    return p.x + p.y
        \\}
        \\
    );

    try testing.expectEqual(@as(usize, 1), result.symbols.functions.len);
    const m = result.symbols.functions[0];
    try testing.expect(m.isMethod());
    try testing.expectEqualStrings("sum", m.name);
    try testing.expectEqualStrings("Point", m.receiver_type.?);
    try testing.expectEqualStrings("p", m.receiver_name.?);

    try testing.expectEqual(@as(usize, 1), result.symbols.structs.len);
    const s = result.symbols.structs[0];
    try testing.expectEqualStrings("Point", s.name);
    try testing.expectEqual(@as(usize, 2), s.fields.len);
    try testing.expectEqualStrings("x", s.fields[0].field.name);
    try testing.expectEqualStrings("y", s.fields[1].field.name);
}

test "build recovers enum variant positions and import path position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try parseAndBuild(arena_state.allocator(),
        \\import "math.std.butter"
        \\enum Color { Red, Green, Blue }
        \\
    );

    try testing.expectEqual(@as(usize, 1), result.symbols.imports.len);
    try testing.expectEqualStrings("math.std.butter", result.symbols.imports[0].path);
    try testing.expectEqual(@as(u32, 0), result.symbols.imports[0].path_pos.line);

    try testing.expectEqual(@as(usize, 1), result.symbols.enums.len);
    const e = result.symbols.enums[0];
    try testing.expectEqual(@as(usize, 3), e.variants.len);
    try testing.expectEqualStrings("Red", e.variants[0].name);
    try testing.expectEqualStrings("Blue", e.variants[2].name);
}

test "findFunction never returns a method, findMethod requires a matching receiver" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const result = try parseAndBuild(arena_state.allocator(),
        \\struct Point { int x }
        \\func (Point p) get() -> int { return p.x }
        \\func get() -> int { return 0 }
        \\
    );

    const plain = result.symbols.findFunction("get");
    try testing.expect(plain != null);
    try testing.expect(!plain.?.isMethod());

    const method = result.symbols.findMethod("Point", "get");
    try testing.expect(method != null);
    try testing.expect(method.?.isMethod());
}
