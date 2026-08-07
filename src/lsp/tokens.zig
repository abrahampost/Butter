//! Position utilities for the language server. `ast.Expr` carries no
//! source position at all and `ast.Stmt` only a 1-based line (see
//! ast.zig) — deliberately not changed for this feature (see the LSP
//! design plan). Instead, every position-aware LSP feature re-tokenizes
//! the document with the real `lexer.zig` (which already stamps a 1-based
//! line+column on every token) and recovers whatever position it needs by
//! searching that token stream, anchored on the one position the AST does
//! carry (`Stmt.line`).
//!
//! `Position` (below) is zero-based, matching the LSP spec, and — same as
//! `lexer.zig`'s own `column` — a raw UTF-8 BYTE offset internally: every
//! comparison/search in this file, and every symbol position stored in
//! symbols.zig/scope.zig, lives in this space.
//!
//! The WIRE format is different: this server declares
//! `positionEncoding: "utf-16"` (protocol.zig's `ServerCapabilities`) —
//! the only encoding `vscode-languageclient` (and virtually every other
//! LSP client) actually supports; a server that declares anything else
//! gets its `initialize` response rejected outright. `fromUtf16`/
//! `toUtf16` below convert at that boundary — called once per incoming
//! request position (resolve.zig, completion.zig) and once per outgoing
//! response position (hover.zig, definition.zig, document_symbol.zig,
//! diagnostics.zig) — so everything in between stays in the simpler byte
//! space `lexer.zig` already speaks. Only lines with multi-byte UTF-8
//! content (string literals, comments — identifiers/keywords are
//! ASCII-only, see `lexer.zig`'s `isAlpha`) actually need the conversion;
//! elsewhere it's a no-op since byte offset == UTF-16 offset for ASCII.

const std = @import("std");
const butter = @import("butter");
const lexer = butter.lexer;

pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;

pub const Position = struct {
    line: u32,
    character: u32,

    pub fn fromToken(tok: Token) Position {
        return .{ .line = @intCast(tok.line - 1), .character = @intCast(tok.column - 1) };
    }

    /// The position just past `tok`'s last byte — the exclusive end of its
    /// range. Multi-line tokens (a string literal spanning lines via
    /// `${...}` interpolation, GRAMMAR.bnf design note 3ae) aren't handled
    /// precisely here — `tok.line`/`tok.column` are always the token's
    /// *start*, so this can only offset within that same line. Good enough
    /// for this server's uses (hover/definition ranges), which only ever
    /// wrap a single-line identifier/keyword/short literal.
    pub fn endOfToken(tok: Token) Position {
        return .{ .line = @intCast(tok.line - 1), .character = @intCast(tok.column - 1 + tok.lexeme.len) };
    }

    pub fn lessThanOrEqual(a: Position, b: Position) bool {
        return a.line < b.line or (a.line == b.line and a.character <= b.character);
    }

    pub fn lessThan(a: Position, b: Position) bool {
        return a.line < b.line or (a.line == b.line and a.character < b.character);
    }

    /// Converts a UTF-16 code-unit `pos` (as delivered by the LSP client)
    /// to the byte-offset `Position` used everywhere else in this server,
    /// by re-scanning `pos.line`'s own text in `source`. A `pos` past the
    /// end of `source` (or of its line) passes through unchanged — it
    /// already won't match any real token, in either encoding.
    pub fn fromUtf16(source: []const u8, pos: Position) Position {
        const line = lineText(source, pos.line) orelse return pos;
        return .{ .line = pos.line, .character = byteOffsetForUtf16(line, pos.character) };
    }

    /// The inverse of `fromUtf16`: converts an internal byte-offset `pos`
    /// to the UTF-16 code-unit `Position` the LSP wire format requires.
    pub fn toUtf16(source: []const u8, pos: Position) Position {
        const line = lineText(source, pos.line) orelse return pos;
        return .{ .line = pos.line, .character = utf16OffsetForByte(line, pos.character) };
    }
};

/// `source`'s zero-based `line_idx`'th line, without its trailing
/// newline — `null` if `source` has no such line.
fn lineText(source: []const u8, line_idx: u32) ?[]const u8 {
    var start: usize = 0;
    var current: u32 = 0;
    while (current < line_idx) : (current += 1) {
        const nl = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse return null;
        start = nl + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    return source[start..end];
}

/// Byte offset in `line` of the codepoint `target` UTF-16 code units in
/// (rounding down to a codepoint boundary if `target` would otherwise
/// land inside a surrogate pair — not reachable from a spec-conforming
/// client). Invalid UTF-8 is walked one byte at a time rather than
/// failing outright — a malformed buffer shouldn't be able to crash a
/// long-running server over a position lookup.
fn byteOffsetForUtf16(line: []const u8, target: u32) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < line.len and units < target) {
        const seq_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const len: usize = @min(@as(usize, seq_len), line.len - i);
        const cp = std.unicode.utf8Decode(line[i..][0..len]) catch std.unicode.replacement_character;
        units += if (cp > 0xFFFF) 2 else 1;
        i += len;
    }
    return @intCast(i);
}

/// The inverse of `byteOffsetForUtf16`: the number of UTF-16 code units
/// `line`'s content up to byte offset `target` (clamped to `line.len`)
/// encodes as.
fn utf16OffsetForByte(line: []const u8, target: u32) u32 {
    const end: usize = @min(target, line.len);
    var units: u32 = 0;
    var i: usize = 0;
    while (i < end) {
        const seq_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const len: usize = @min(@as(usize, seq_len), line.len - i);
        const cp = std.unicode.utf8Decode(line[i..][0..len]) catch std.unicode.replacement_character;
        units += if (cp > 0xFFFF) 2 else 1;
        i += len;
    }
    return units;
}

pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) (lexer.Error || std.mem.Allocator.Error)![]const Token {
    var lex = lexer.Lexer.init(source);
    return lex.tokenizeAll(allocator);
}

/// The token whose byte range strictly contains zero-based `pos` — the
/// token under the cursor for hover/go-to-definition. `null` when `pos`
/// falls in whitespace, at end-of-line, or past the end of the document.
pub fn tokenAt(tokens: []const Token, pos: Position) ?Token {
    var lo: usize = 0;
    var hi: usize = tokens.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (Position.lessThanOrEqual(Position.fromToken(tokens[mid]), pos)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo == 0) return null;
    const candidate = tokens[lo - 1];
    if (Position.lessThan(pos, Position.endOfToken(candidate))) return candidate;
    return null;
}

/// The index (into `tokens`) of the token `tokenAt` would return, or
/// `null` under the same conditions. Kept separate from `tokenAt` since
/// most callers that need the token also need to look at its neighbors
/// (`roleOf`, below).
pub fn tokenIndexAt(tokens: []const Token, pos: Position) ?usize {
    const idx = nearestIndexAtOrBefore(tokens, pos) orelse return null;
    if (Position.lessThan(pos, Position.endOfToken(tokens[idx]))) return idx;
    return null;
}

/// The index of the LAST token starting at or before `pos` — unlike
/// `tokenIndexAt`, doesn't require `pos` to fall strictly inside it.
/// completion.zig uses this directly: while the user is mid-word, the
/// cursor sits at the END of the identifier being typed (touching, not
/// strictly inside it), which is exactly the case hover/definition don't
/// care about but completion needs.
pub fn nearestIndexAtOrBefore(tokens: []const Token, pos: Position) ?usize {
    var lo: usize = 0;
    var hi: usize = tokens.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (Position.lessThanOrEqual(Position.fromToken(tokens[mid]), pos)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo == 0) return null;
    return lo - 1;
}

/// The syntactic role an identifier token plays, decided purely from its
/// immediate neighbors — enough to pick which symbol table(s)
/// hover/definition/completion should consult, in what order (a bare
/// `variable` is tried as a local, then a top-level function/struct/enum/
/// import name; `field_or_variant` as a struct field or enum variant of
/// the base's declared type; and so on).
pub const Role = enum {
    call,
    method_call,
    field_or_variant,
    import_path,
    variable,
    other,
};

pub fn roleOf(tokens: []const Token, idx: usize) Role {
    const tok = tokens[idx];
    if (tok.type == .string) {
        if (idx > 0 and tokens[idx - 1].type == .kw_import) return .import_path;
        return .other;
    }
    if (tok.type != .identifier) return .other;

    const prev: ?Token = if (idx > 0) tokens[idx - 1] else null;
    const next: ?Token = if (idx + 1 < tokens.len) tokens[idx + 1] else null;
    const followed_by_call = next != null and next.?.type == .lparen;
    const preceded_by_dot = prev != null and prev.?.type == .dot;

    if (preceded_by_dot) return if (followed_by_call) .method_call else .field_or_variant;
    return if (followed_by_call) .call else .variable;
}

/// Finds the first token on 1-based source `line` with type `kw` — the
/// anchor every declaration-position lookup in symbols.zig/scope.zig
/// starts from, given only the `ast.Stmt.line` the AST provides.
pub fn findKeywordOnLine(tokens: []const Token, line: usize, kw: TokenType) ?usize {
    for (tokens, 0..) |tok, i| {
        if (tok.line == line and tok.type == kw) return i;
        if (tok.line > line) break;
    }
    return null;
}

/// The first token on 1-based source `line`, regardless of its type — used
/// to anchor a `<var-declaration>`'s own scan (unlike a top-level
/// declaration, it has no single fixed leading keyword: it could start
/// with a scalar type keyword, a named-type IDENTIFIER, or `func` for a
/// func-type).
pub fn firstTokenOnLine(tokens: []const Token, line: usize) ?usize {
    for (tokens, 0..) |tok, i| {
        if (tok.line == line) return i;
        if (tok.line > line) break;
    }
    return null;
}

/// Nearest index at or after `from` whose token type is `tt`. Used to find
/// a declaration's opening `(`/`{` once its leading keyword's index is
/// known.
pub fn findFrom(tokens: []const Token, from: usize, tt: TokenType) ?usize {
    var i = from;
    while (i < tokens.len) : (i += 1) {
        if (tokens[i].type == tt) return i;
    }
    return null;
}

fn closeFor(open: TokenType) ?TokenType {
    return switch (open) {
        .lparen => .rparen,
        .lbracket => .rbracket,
        .lbrace => .rbrace,
        else => null,
    };
}

/// The index of the token closing the bracket/brace/paren opened at
/// `open_idx`, tracking nested pairs of the SAME kind (any bracket kind
/// may nest inside; only a matching close at depth 0 ends the scan). Used
/// to find a top-level declaration's real extent (its closing '}') for a
/// `DocumentSymbol.range`, beyond just the declared name's own position.
pub fn matchingClose(tokens: []const Token, open_idx: usize) ?usize {
    const open_type = tokens[open_idx].type;
    const close_type = closeFor(open_type) orelse return null;
    var depth: usize = 1;
    var i = open_idx + 1;
    while (i < tokens.len) : (i += 1) {
        const t = tokens[i].type;
        if (t == open_type) {
            depth += 1;
        } else if (t == close_type) {
            depth -= 1;
            if (depth == 0) return i;
        } else if (t == .eof) {
            return null;
        }
    }
    return null;
}

/// Scans a delimited list of declaration segments (struct fields, enum
/// variants, function/method parameters) starting just after the opening
/// '('/'{' at `open_idx`, splitting on a top-level ',' or NEWLINE (depth
/// tracked over '(' '[' '{' / ')' ']' '}', so a nested func-type
/// parameter list's own commas don't split the outer list), and returns
/// each segment's declared NAME token — the LAST '.identifier' token in
/// that segment.
///
/// This one routine covers every one of this grammar's
/// `<type> [ '[' ... ']' ] IDENTIFIER`-shaped declaration lists
/// (GRAMMAR.bnf's <param-list>/<field-list>), because the declared name is
/// always the final identifier before the next separator, regardless of
/// how many leading identifier-shaped tokens the TYPE portion itself
/// contributes (a named type like `Point p` also lexes as two identifiers
/// in a row — only the second is the field's own name). A bare-identifier
/// segment (an enum's <variant-list>) degenerates to "the last identifier
/// is its only token", so this same routine covers that too. A missing
/// name (malformed input) comes back as `null` in that slot rather than
/// shifting every later index — callers zip the result 1:1 against the
/// AST's own field/param/variant slice by index.
pub fn segmentNames(allocator: std.mem.Allocator, tokens: []const Token, open_idx: usize) ![]?Token {
    var names: std.ArrayList(?Token) = .empty;
    errdefer names.deinit(allocator);

    var depth: usize = 0;
    var current: ?Token = null;
    var have_any: bool = false;
    var i = open_idx + 1;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        switch (tok.type) {
            .lparen, .lbracket, .lbrace => {
                depth += 1;
                have_any = true;
            },
            .rparen, .rbracket, .rbrace => {
                if (depth == 0) {
                    if (have_any or current != null) try names.append(allocator, current);
                    return names.toOwnedSlice(allocator);
                }
                depth -= 1;
            },
            .comma => {
                if (depth == 0) {
                    try names.append(allocator, current);
                    current = null;
                    have_any = false;
                } else {
                    have_any = true;
                }
            },
            .newline => {
                if (depth == 0) {
                    if (have_any) {
                        try names.append(allocator, current);
                        current = null;
                        have_any = false;
                    }
                } else {
                    have_any = true;
                }
            },
            .identifier => {
                have_any = true;
                if (depth == 0) current = tok;
            },
            .eof => break,
            else => have_any = true,
        }
    }
    if (have_any or current != null) try names.append(allocator, current);
    return names.toOwnedSlice(allocator);
}

/// The declared-name position for a single un-bracketed declaration
/// segment — a `<var-declaration>`'s or `<for-stmt>`'s loop variable.
/// Scans forward from `start_idx` (the statement's own first token) for
/// the last top-level '.identifier' before the segment ends (':=',
/// NEWLINE, EOF, or an enclosing '}' — whichever comes first). Depth is
/// tracked the same way as `segmentNames`, so a `[N]` array-size suffix's
/// own tokens are skipped correctly.
pub fn singleDeclarationName(tokens: []const Token, start_idx: usize) ?Token {
    var depth: usize = 0;
    var current: ?Token = null;
    var i = start_idx;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];
        switch (tok.type) {
            .lparen, .lbracket => depth += 1,
            .rparen, .rbracket => {
                if (depth > 0) depth -= 1;
            },
            .rbrace => {
                if (depth == 0) return current;
                depth -= 1;
            },
            .colon_equal, .newline, .eof => {
                if (depth == 0) return current;
            },
            .identifier => {
                if (depth == 0) current = tok;
            },
            else => {},
        }
    }
    return current;
}

// ---- Tests -----------------------------------------------------------

const testing = std.testing;

test "tokenAt finds the identifier token under a cursor position" {
    const allocator = testing.allocator;
    const source = "int x := foo(1)\n";
    const toks = try tokenize(allocator, source);
    defer allocator.free(toks);

    // "foo" starts at 0-based column 9 on line 0.
    const tok = tokenAt(toks, .{ .line = 0, .character = 10 });
    try testing.expect(tok != null);
    try testing.expectEqualStrings("foo", tok.?.lexeme);
}

test "tokenAt returns null in whitespace between tokens" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "int x\n");
    defer allocator.free(toks);

    try testing.expect(tokenAt(toks, .{ .line = 0, .character = 3 }) == null);
}

test "roleOf classifies a call, a field access, and a method call" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "foo(1)\np.field\np.method(1)\n");
    defer allocator.free(toks);

    // token 0 = "foo"
    try testing.expectEqual(Role.call, roleOf(toks, 0));

    var idx: usize = 0;
    for (toks, 0..) |t, i| {
        if (std.mem.eql(u8, t.lexeme, "field")) idx = i;
    }
    try testing.expectEqual(Role.field_or_variant, roleOf(toks, idx));

    for (toks, 0..) |t, i| {
        if (std.mem.eql(u8, t.lexeme, "method")) idx = i;
    }
    try testing.expectEqual(Role.method_call, roleOf(toks, idx));
}

test "segmentNames recovers each parameter's own name, including a named-type param" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "func f(int a, Point p, int[5] arr) -> int {\n}\n");
    defer allocator.free(toks);

    const open = findFrom(toks, 0, .lparen).?;
    const names = try segmentNames(allocator, toks, open);
    defer allocator.free(names);

    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("a", names[0].?.lexeme);
    try testing.expectEqualStrings("p", names[1].?.lexeme);
    try testing.expectEqualStrings("arr", names[2].?.lexeme);
}

test "segmentNames does not split on a nested func-type parameter list's own commas" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "func f(func(int,int) bool matcher, int b) -> int {\n}\n");
    defer allocator.free(toks);

    const open = findFrom(toks, 0, .lparen).?;
    const names = try segmentNames(allocator, toks, open);
    defer allocator.free(names);

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("matcher", names[0].?.lexeme);
    try testing.expectEqualStrings("b", names[1].?.lexeme);
}

test "segmentNames handles an empty list" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "func f() -> int {\n}\n");
    defer allocator.free(toks);

    const open = findFrom(toks, 0, .lparen).?;
    const names = try segmentNames(allocator, toks, open);
    defer allocator.free(names);

    try testing.expectEqual(@as(usize, 0), names.len);
}

test "segmentNames recovers bare enum variant names" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "enum Color {\n    Red, Green\n    Blue\n}\n");
    defer allocator.free(toks);

    const open = findFrom(toks, 0, .lbrace).?;
    const names = try segmentNames(allocator, toks, open);
    defer allocator.free(names);

    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("Red", names[0].?.lexeme);
    try testing.expectEqualStrings("Green", names[1].?.lexeme);
    try testing.expectEqualStrings("Blue", names[2].?.lexeme);
}

test "singleDeclarationName finds a var-declaration's name, stopping before its initializer" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "int total := foo(a, b) + 1\n");
    defer allocator.free(toks);

    const name = singleDeclarationName(toks, 0);
    try testing.expect(name != null);
    try testing.expectEqualStrings("total", name.?.lexeme);
}

test "singleDeclarationName handles an array declaration's [N] suffix" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "int[5] arr\n");
    defer allocator.free(toks);

    const name = singleDeclarationName(toks, 0);
    try testing.expect(name != null);
    try testing.expectEqualStrings("arr", name.?.lexeme);
}

test "matchingClose finds a function body's closing brace, skipping nested blocks" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "func f() -> int {\n    if true {\n        return 1\n    }\n    return 0\n}\n");
    defer allocator.free(toks);

    const open = findFrom(toks, 0, .lbrace).?;
    const close = matchingClose(toks, open).?;
    try testing.expectEqual(TokenType.rbrace, toks[close].type);
    try testing.expectEqual(@as(usize, 6), toks[close].line);
}

test "fromUtf16 and toUtf16 round-trip across a line with multi-byte UTF-8 content" {
    // "a" é " bc" — é (U+00E9) is 2 UTF-8 bytes but 1 UTF-16 unit.
    // UTF-16 offsets: a=0 é=1 ' '=2 b=3 c=4
    // UTF-8 byte offsets:  a=0 é=1..3 ' '=3 b=4 c=5
    const source = "a\u{00e9} bc\n";

    const byte_pos = Position.fromUtf16(source, .{ .line = 0, .character = 4 });
    try testing.expectEqual(@as(u32, 5), byte_pos.character);

    const utf16_pos = Position.toUtf16(source, .{ .line = 0, .character = 5 });
    try testing.expectEqual(@as(u32, 4), utf16_pos.character);
}

test "fromUtf16 and toUtf16 are identity on an ASCII-only line" {
    const source = "int x := foo(1)\n";
    const byte_pos = Position.fromUtf16(source, .{ .line = 0, .character = 9 });
    try testing.expectEqual(@as(u32, 9), byte_pos.character);
    const utf16_pos = Position.toUtf16(source, .{ .line = 0, .character = 9 });
    try testing.expectEqual(@as(u32, 9), utf16_pos.character);
}

test "fromUtf16 handles a position past the end of the source gracefully" {
    const source = "int x\n";
    const pos = Position.fromUtf16(source, .{ .line = 5, .character = 2 });
    try testing.expectEqual(@as(u32, 5), pos.line);
    try testing.expectEqual(@as(u32, 2), pos.character);
}

test "findKeywordOnLine locates a declaration's leading keyword by line" {
    const allocator = testing.allocator;
    const toks = try tokenize(allocator, "int x := 1\nfunc f() -> int {\n    return 1\n}\n");
    defer allocator.free(toks);

    const idx = findKeywordOnLine(toks, 2, .kw_func);
    try testing.expect(idx != null);
    try testing.expectEqual(@as(usize, 2), toks[idx.?].line);
}
