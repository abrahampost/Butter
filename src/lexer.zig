//! Tokenizer for Butter, matching section 1 (LEXICAL GRAMMAR) of GRAMMAR.bnf.

const std = @import("std");

pub const TokenType = enum {
    // Literals
    identifier,
    int,
    float,
    string,

    // Keywords
    kw_print,
    kw_if,
    kw_else,
    kw_while,
    kw_or,
    kw_and,
    kw_true,
    kw_false,
    kw_int,
    kw_float,
    kw_bool,
    kw_string,
    kw_func,
    kw_return,
    kw_for,
    kw_in,
    kw_import,
    kw_export,
    kw_len,
    kw_read,
    kw_write,
    kw_stdin,
    kw_stdout,
    kw_stderr,
    kw_open,
    kw_close,
    kw_append,
    kw_map,
    kw_list,
    kw_push,
    kw_keys,
    kw_has,
    kw_delete,
    kw_json,
    kw_stringify,
    kw_null,
    kw_args,
    kw_getenv,
    kw_hasenv,
    kw_exit,
    kw_try,
    kw_catch,
    kw_exists,
    kw_listdir,
    kw_remove,
    kw_rename,

    // Operators and punctuation
    plus,
    minus,
    star,
    star_star,
    slash,
    percent,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    bang,
    bang_equal,
    equal_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    colon,
    colon_equal,
    arrow,
    comma,
    dot_dot,

    newline,
    eof,
};

const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "print", .kw_print },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "or", .kw_or },
    .{ "and", .kw_and },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "int", .kw_int },
    .{ "float", .kw_float },
    .{ "bool", .kw_bool },
    .{ "string", .kw_string },
    .{ "func", .kw_func },
    .{ "return", .kw_return },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "import", .kw_import },
    .{ "export", .kw_export },
    .{ "len", .kw_len },
    .{ "read", .kw_read },
    .{ "write", .kw_write },
    .{ "stdin", .kw_stdin },
    .{ "stdout", .kw_stdout },
    .{ "stderr", .kw_stderr },
    .{ "open", .kw_open },
    .{ "close", .kw_close },
    .{ "append", .kw_append },
    .{ "map", .kw_map },
    .{ "list", .kw_list },
    .{ "push", .kw_push },
    .{ "keys", .kw_keys },
    .{ "has", .kw_has },
    .{ "delete", .kw_delete },
    .{ "json", .kw_json },
    .{ "stringify", .kw_stringify },
    .{ "null", .kw_null },
    .{ "args", .kw_args },
    .{ "getenv", .kw_getenv },
    .{ "hasenv", .kw_hasenv },
    .{ "exit", .kw_exit },
    .{ "try", .kw_try },
    .{ "catch", .kw_catch },
    .{ "exists", .kw_exists },
    .{ "listDir", .kw_listdir },
    .{ "remove", .kw_remove },
    .{ "rename", .kw_rename },
});

pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    line: usize,
    column: usize,
};

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []const u8,
};

/// Errors the lexer can raise. Detail (line/column/message) is left in
/// `Lexer.diagnostic` at the point of failure since Zig error values carry
/// no payload of their own.
pub const Error = error{
    UnexpectedCharacter,
    UnterminatedString,
    MalformedNumber,
    LoneEqual,
    InvalidEscapeSequence,
};

pub const Lexer = struct {
    source: []const u8,
    start: usize = 0,
    current: usize = 0,
    line: usize = 1,
    column: usize = 1,
    start_line: usize = 1,
    start_column: usize = 1,
    diagnostic: ?Diagnostic = null,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    fn isAtEnd(self: *const Lexer) bool {
        return self.current >= self.source.len;
    }

    fn peek(self: *const Lexer) u8 {
        return if (self.isAtEnd()) 0 else self.source[self.current];
    }

    fn peekNext(self: *const Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd() or self.source[self.current] != expected) return false;
        _ = self.advance();
        return true;
    }

    fn makeToken(self: *const Lexer, token_type: TokenType) Token {
        return .{
            .type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.start_line,
            .column = self.start_column,
        };
    }

    fn fail(self: *Lexer, err: Error, message: []const u8) Error {
        self.diagnostic = .{ .line = self.start_line, .column = self.start_column, .message = message };
        return err;
    }

    fn skipInsignificantWhitespace(self: *Lexer) void {
        // Space, tab, and carriage return are discarded; '\n' is significant
        // (it becomes a NEWLINE token) and is handled by `next`. A '#'
        // starts a comment that runs through (but does not include) the
        // next '\n', so the newline afterward is still tokenized normally.
        while (!self.isAtEnd()) {
            switch (self.peek()) {
                ' ', '\t', '\r' => _ = self.advance(),
                '#' => while (!self.isAtEnd() and self.peek() != '\n') {
                    _ = self.advance();
                },
                else => return,
            }
        }
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }

    fn number(self: *Lexer) Token {
        while (isDigit(self.peek())) _ = self.advance();

        if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance(); // consume '.'
            while (isDigit(self.peek())) _ = self.advance();
            return self.makeToken(.float);
        }

        return self.makeToken(.int);
    }

    fn identifierOrKeyword(self: *Lexer) Token {
        while (isAlphaNumeric(self.peek())) _ = self.advance();
        const text = self.source[self.start..self.current];
        const token_type = keywords.get(text) orelse .identifier;
        return self.makeToken(token_type);
    }

    /// Scans string content up to (not including) the closing '"'. The
    /// lexeme still carries escape sequences un-decoded (`\n` stays the two
    /// characters '\' and 'n') — `parser.zig` decodes them once the
    /// surrounding quotes are stripped, mirroring how INT/FLOAT lexemes are
    /// handed to `std.fmt.parseInt`/`parseFloat` there rather than here.
    /// This scan still has to recognize `\"` and `\\` itself, though: an
    /// escaped quote must not end the string early, and a `\\` immediately
    /// before a real closing `"` must not be misread as `\"`.
    fn string(self: *Lexer) Error!Token {
        while (!self.isAtEnd() and self.peek() != '"') {
            if (self.peek() == '\\') {
                _ = self.advance(); // consume '\'
                if (self.isAtEnd()) break; // reported as UnterminatedString below
                switch (self.peek()) {
                    'n', 't', '\\', '"' => _ = self.advance(),
                    else => return self.fail(Error.InvalidEscapeSequence, "invalid escape sequence (only \\n, \\t, \\\\, \\\" are supported)"),
                }
            } else {
                _ = self.advance();
            }
        }

        if (self.isAtEnd()) return self.fail(Error.UnterminatedString, "unterminated string literal");

        _ = self.advance(); // consume closing '"'
        return self.makeToken(.string);
    }

    /// Scans and returns the next token. Returns a `.eof` token forever
    /// once the source is exhausted, so callers can safely call `next`
    /// in a loop without tracking end-of-input separately.
    pub fn next(self: *Lexer) Error!Token {
        self.skipInsignificantWhitespace();
        self.start = self.current;
        self.start_line = self.line;
        self.start_column = self.column;

        if (self.isAtEnd()) return self.makeToken(.eof);

        const c = self.advance();

        if (isDigit(c)) return self.number();
        if (isAlpha(c)) return self.identifierOrKeyword();

        return switch (c) {
            '\n' => self.makeToken(.newline),
            '"' => self.string(),
            '+' => self.makeToken(.plus),
            '-' => self.makeToken(if (self.match('>')) .arrow else .minus),
            '*' => self.makeToken(if (self.match('*')) .star_star else .star),
            '/' => self.makeToken(.slash),
            '%' => self.makeToken(.percent),
            '(' => self.makeToken(.lparen),
            ')' => self.makeToken(.rparen),
            '{' => self.makeToken(.lbrace),
            '}' => self.makeToken(.rbrace),
            '[' => self.makeToken(.lbracket),
            ']' => self.makeToken(.rbracket),
            ',' => self.makeToken(.comma),
            '.' => if (self.match('.')) self.makeToken(.dot_dot) else self.fail(Error.UnexpectedCharacter, "unexpected character"),
            '!' => self.makeToken(if (self.match('=')) .bang_equal else .bang),
            '<' => self.makeToken(if (self.match('=')) .less_equal else .less),
            '>' => self.makeToken(if (self.match('=')) .greater_equal else .greater),
            '=' => if (self.match('=')) self.makeToken(.equal_equal) else self.fail(Error.LoneEqual, "'=' must be followed by '=' (did you mean '=='?)"),
            // Unlike '=', a lone ':' is legal on its own now (GRAMMAR.bnf
            // design note 3m) — it's what separates a key from its value in
            // a map literal (`{"a": 1}`) — so only ':=' gets its own token;
            // a bare ':' is simply `.colon`, not an error.
            ':' => self.makeToken(if (self.match('=')) .colon_equal else .colon),
            else => self.fail(Error.UnexpectedCharacter, "unexpected character"),
        };
    }

    /// Scans the entire source into a caller-owned slice of tokens,
    /// including a trailing `.eof` token. On lexical error, `self.diagnostic`
    /// describes what went wrong and where.
    pub fn tokenizeAll(self: *Lexer, allocator: std.mem.Allocator) (Error || std.mem.Allocator.Error)![]Token {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(allocator);

        while (true) {
            const tok = try self.next();
            try tokens.append(allocator, tok);
            if (tok.type == .eof) break;
        }

        return tokens.toOwnedSlice(allocator);
    }
};

fn expectTokenTypes(source: []const u8, expected: []const TokenType) !void {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init(source);
    const tokens = try lexer.tokenizeAll(allocator);
    defer allocator.free(tokens);

    try std.testing.expectEqual(expected.len, tokens.len);
    for (expected, tokens) |want, got| {
        try std.testing.expectEqual(want, got.type);
    }
}

test "lexes single-character operators" {
    try expectTokenTypes("+-*/%(){}", &.{
        .plus, .minus, .star, .slash, .percent, .lparen, .rparen, .lbrace, .rbrace, .eof,
    });
}

test "lexes multi-character operators" {
    try expectTokenTypes("** != == <= >= := < > !", &.{
        .star_star, .bang_equal, .equal_equal, .less_equal, .greater_equal, .colon_equal, .less, .greater, .bang, .eof,
    });
}

test "distinguishes int and float literals" {
    var lexer = Lexer.init("42 3.14");
    const a = try lexer.next();
    try std.testing.expectEqual(TokenType.int, a.type);
    try std.testing.expectEqualStrings("42", a.lexeme);

    const b = try lexer.next();
    try std.testing.expectEqual(TokenType.float, b.type);
    try std.testing.expectEqualStrings("3.14", b.lexeme);
}

test "a dot not followed by a digit does not start a float" {
    var lexer = Lexer.init("5.");
    const a = try lexer.next();
    try std.testing.expectEqual(TokenType.int, a.type);
    try std.testing.expectEqualStrings("5", a.lexeme);

    try std.testing.expectError(Error.UnexpectedCharacter, lexer.next());
}

test "lexes string literals" {
    var lexer = Lexer.init(
        \\"hello, world"
    );
    const tok = try lexer.next();
    try std.testing.expectEqual(TokenType.string, tok.type);
    try std.testing.expectEqualStrings("\"hello, world\"", tok.lexeme);
}

test "unterminated string is an error" {
    var lexer = Lexer.init("\"hello");
    try std.testing.expectError(Error.UnterminatedString, lexer.next());
    try std.testing.expect(lexer.diagnostic != null);
}

test "an escaped quote does not end the string early" {
    var lexer = Lexer.init(
        \\"a\"b"
    );
    const tok = try lexer.next();
    try std.testing.expectEqual(TokenType.string, tok.type);
    try std.testing.expectEqualStrings(
        \\"a\"b"
    , tok.lexeme);
}

test "a string ending in an escaped backslash is not mistaken for an escaped quote" {
    // "a\\" is the two literal characters a, \ — the '"' right after ends
    // the string; it must NOT be consumed as part of a (nonexistent) \" here.
    var lexer = Lexer.init(
        \\"a\\"
    );
    const tok = try lexer.next();
    try std.testing.expectEqual(TokenType.string, tok.type);
    try std.testing.expectEqualStrings(
        \\"a\\"
    , tok.lexeme);
}

test "a string ending right after a backslash is unterminated" {
    var lexer = Lexer.init("\"a\\");
    try std.testing.expectError(Error.UnterminatedString, lexer.next());
}

test "an unrecognized escape sequence is a lexer error" {
    var lexer = Lexer.init(
        \\"a\xb"
    );
    try std.testing.expectError(Error.InvalidEscapeSequence, lexer.next());
    try std.testing.expect(lexer.diagnostic != null);
}

test "\\n, \\t, \\\\, and \\\" all scan as part of the same string token" {
    var lexer = Lexer.init(
        \\"\n\t\\\""
    );
    const tok = try lexer.next();
    try std.testing.expectEqual(TokenType.string, tok.type);
    try std.testing.expectEqualStrings(
        \\"\n\t\\\""
    , tok.lexeme);
}

test "keywords are recognized distinctly from identifiers" {
    try expectTokenTypes("print if else while or and true false int float bool string func return foo", &.{
        .kw_print,   .kw_if,  .kw_else,  .kw_while, .kw_or,     .kw_and,  .kw_true,
        .kw_false,   .kw_int, .kw_float, .kw_bool,  .kw_string, .kw_func, .kw_return,
        .identifier, .eof,
    });
}

test "lexes '->' as a single arrow token, distinct from '-'" {
    try expectTokenTypes("-> - ->", &.{ .arrow, .minus, .arrow, .eof });
}

test "lexes ',' as a comma token" {
    try expectTokenTypes("a, b", &.{ .identifier, .comma, .identifier, .eof });
}

test "lexes '[' and ']' as bracket tokens" {
    try expectTokenTypes("[1]", &.{ .lbracket, .int, .rbracket, .eof });
}

test "lexes '..' as a single range token" {
    try expectTokenTypes("0..10", &.{ .int, .dot_dot, .int, .eof });
}

test "a lone '.' is a lexer error" {
    var lexer = Lexer.init(".");
    try std.testing.expectError(Error.UnexpectedCharacter, lexer.next());
}

test "'for' and 'in' are recognized as keywords" {
    try expectTokenTypes("for in forin", &.{ .kw_for, .kw_in, .identifier, .eof });
}

test "'import' and 'export' are recognized as keywords" {
    try expectTokenTypes("import export importer", &.{ .kw_import, .kw_export, .identifier, .eof });
}

test "'len' is recognized as a keyword" {
    try expectTokenTypes("len length", &.{ .kw_len, .identifier, .eof });
}

test "identifiers may contain digits but not start with one" {
    var lexer = Lexer.init("x1 y2z");
    const a = try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, a.type);
    try std.testing.expectEqualStrings("x1", a.lexeme);

    const b = try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, b.type);
    try std.testing.expectEqualStrings("y2z", b.lexeme);
}

test "identifiers may contain or start with underscores" {
    var lexer = Lexer.init("_foo bar_baz _1a __");
    const a = try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, a.type);
    try std.testing.expectEqualStrings("_foo", a.lexeme);

    const b = try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, b.type);
    try std.testing.expectEqualStrings("bar_baz", b.lexeme);

    const c = try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, c.type);
    try std.testing.expectEqualStrings("_1a", c.lexeme);

    const d = try lexer.next();
    try std.testing.expectEqual(TokenType.identifier, d.type);
    try std.testing.expectEqualStrings("__", d.lexeme);
}

test "newline is a significant token, other whitespace is not" {
    try expectTokenTypes(" \t1 \r\n 2\n", &.{ .int, .newline, .int, .newline, .eof });
}

test "lone '=' is a lexer error" {
    var lexer = Lexer.init("=");
    try std.testing.expectError(Error.LoneEqual, lexer.next());
}

test "a lone ':' lexes as its own token (map-literal key separator)" {
    try expectTokenTypes(":", &.{ .colon, .eof });
}

test "':=' still lexes as one token, distinct from a lone ':'" {
    try expectTokenTypes(": :=", &.{ .colon, .colon_equal, .eof });
}

test "diagnostic reports line and column of the failure" {
    var lexer = Lexer.init("x := 1\n@");
    _ = try lexer.next(); // x
    _ = try lexer.next(); // :=
    _ = try lexer.next(); // 1
    _ = try lexer.next(); // NEWLINE
    try std.testing.expectError(Error.UnexpectedCharacter, lexer.next());
    const diag = lexer.diagnostic.?;
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectEqual(@as(usize, 1), diag.column);
}

test "tokenizeAll includes a trailing eof token" {
    const allocator = std.testing.allocator;
    var lexer = Lexer.init("1 + 1");
    const tokens = try lexer.tokenizeAll(allocator);
    defer allocator.free(tokens);
    try std.testing.expectEqual(TokenType.eof, tokens[tokens.len - 1].type);
}

test "empty source produces only eof" {
    try expectTokenTypes("", &.{.eof});
}

test "'read' and 'write' are recognized as keywords" {
    try expectTokenTypes("read write reader writer", &.{ .kw_read, .kw_write, .identifier, .identifier, .eof });
}

test "the three stream names are recognized as keywords" {
    try expectTokenTypes("stdin stdout stderr stdinx", &.{ .kw_stdin, .kw_stdout, .kw_stderr, .identifier, .eof });
}

test "'args' is recognized as a keyword" {
    try expectTokenTypes("args argsx", &.{ .kw_args, .identifier, .eof });
}

test "'getenv' and 'hasenv' are recognized as keywords" {
    try expectTokenTypes("getenv hasenv getenvx hasenvx env", &.{
        .kw_getenv, .kw_hasenv, .identifier, .identifier, .identifier, .eof,
    });
}

test "'exists'/'listDir'/'remove'/'rename' are recognized as keywords" {
    try expectTokenTypes("exists listDir remove rename existsx listdir Remove", &.{
        .kw_exists,  .kw_listdir, .kw_remove,  .kw_rename,
        .identifier, .identifier, .identifier, .eof,
    });
}

test "'exit' is recognized as a keyword" {
    try expectTokenTypes("exit exitx", &.{ .kw_exit, .identifier, .eof });
}

test "'try' and 'catch' are recognized as keywords" {
    try expectTokenTypes("try catch trying catcher", &.{ .kw_try, .kw_catch, .identifier, .identifier, .eof });
}

test "'#' starts a comment that runs to end of line" {
    try expectTokenTypes("1 # this is ignored\n2", &.{ .int, .newline, .int, .eof });
}

test "a comment-only line still produces its newline" {
    try expectTokenTypes("# just a comment\n1", &.{ .newline, .int, .eof });
}

test "a comment with no trailing newline runs to eof" {
    try expectTokenTypes("1 # comment at eof", &.{ .int, .eof });
}

test "'#' immediately followed by newline is an empty comment" {
    try expectTokenTypes("1 #\n2", &.{ .int, .newline, .int, .eof });
}

test "map/list and their builtins are recognized as keywords" {
    try expectTokenTypes("map list push keys has delete json stringify null mapx", &.{
        .kw_map, .kw_list, .kw_push, .kw_keys, .kw_has, .kw_delete, .kw_json, .kw_stringify, .kw_null, .identifier, .eof,
    });
}
