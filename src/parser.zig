//! Recursive-descent parser for Butter, matching section 2 (SYNTAX GRAMMAR)
//! of GRAMMAR.bnf, including the fixes described in section 3 (unary
//! chaining, optional newline after '{', leading blank lines).

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

const Token = lexer.Token;
const TokenType = lexer.TokenType;

pub const Diagnostic = struct {
    line: usize,
    column: usize,
    message: []const u8,
};

/// The lone error tag the parser itself raises; detail is left in
/// `Parser.diagnostic`. Allocation failure is reported separately since it
/// carries no useful source position.
pub const SyntaxError = error{UnexpectedToken};
pub const Error = SyntaxError || std.mem.Allocator.Error;

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,
    diagnostic: ?Diagnostic = null,

    /// `tokens` must end with an `.eof` token (as produced by
    /// `lexer.Lexer.tokenizeAll`) and must outlive the parser.
    pub fn init(child_allocator: std.mem.Allocator, tokens: []const Token) Parser {
        std.debug.assert(tokens.len > 0 and tokens[tokens.len - 1].type == .eof);
        return .{ .tokens = tokens, .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    /// Frees every AST node produced by this parser.
    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    fn allocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn previous(self: *const Parser) Token {
        return self.tokens[self.pos - 1];
    }

    /// Looks `offset` tokens past the current one without consuming
    /// anything — clamped to the trailing `.eof` rather than indexing past
    /// it, the same "eof forever" safety `Lexer.next` already guarantees,
    /// just for a fixed token slice instead of a live scan.
    fn peekAt(self: *const Parser, offset: usize) Token {
        const i = @min(self.pos + offset, self.tokens.len - 1);
        return self.tokens[i];
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.peek().type == .eof;
    }

    fn check(self: *const Parser, token_type: TokenType) bool {
        return self.peek().type == token_type;
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.pos += 1;
        return self.previous();
    }

    fn match(self: *Parser, token_type: TokenType) bool {
        if (!self.check(token_type)) return false;
        _ = self.advance();
        return true;
    }

    fn expect(self: *Parser, token_type: TokenType, message: []const u8) Error!Token {
        if (self.check(token_type)) return self.advance();
        return self.fail(message);
    }

    fn fail(self: *Parser, message: []const u8) Error {
        const tok = self.peek();
        self.diagnostic = .{ .line = tok.line, .column = tok.column, .message = message };
        return Error.UnexpectedToken;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) _ = self.advance();
    }

    fn createExpr(self: *Parser, value: ast.Expr) Error!*ast.Expr {
        const node = try self.allocator().create(ast.Expr);
        node.* = value;
        return node;
    }

    fn createStmt(self: *Parser, value: ast.Stmt) Error!*ast.Stmt {
        const node = try self.allocator().create(ast.Stmt);
        node.* = value;
        return node;
    }

    /// Decodes `\n`/`\t`/`\\`/`\"`/`\$` in a STRING token's already-unquoted
    /// contents (GRAMMAR.bnf design note 3s, extended to five escapes by
    /// design note 3ae). The lexer has already validated that every
    /// backslash in `raw` starts one of those five sequences (`lexer.zig`'s
    /// `string()`), so this never fails — it just copies bytes through,
    /// shrinking two-character escapes to one. A literal with no backslash
    /// at all (the common case) returns `raw` unchanged, borrowed straight
    /// from the source text same as before this feature existed; only a
    /// literal that actually uses an escape pays for an arena allocation.
    ///
    /// Used for an `import` path and a map-literal key — unlike an ordinary
    /// string-literal atom (`parseStringOrInterp`), neither ever recognizes
    /// `${...}` as interpolation: both are static text by design (GRAMMAR.bnf
    /// design notes on imports/maps), so a literal `${` in either is left
    /// completely alone, ordinary text like any other character.
    fn unescapeString(self: *Parser, raw: []const u8) std.mem.Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;

        const buf = try self.allocator().alloc(u8, raw.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\') {
                buf[j] = switch (raw[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '$' => '$',
                    else => unreachable, // lexer guarantees only these five escapes reach here
                };
                i += 2;
            } else {
                buf[j] = c;
                i += 1;
            }
            j += 1;
        }
        return buf[0..j];
    }

    /// Splits a string-literal atom's raw (quote-stripped) contents into
    /// literal text and `${<expression>}` interpolation parts (GRAMMAR.bnf
    /// design note 3ae).
    ///
    /// Fast path: no `$` anywhere (most string literals) — falls straight
    /// through to `unescapeString`.
    ///
    /// Slow path: decodes `\n`/`\t`/`\\`/`\"`/`\$` in literal runs like
    /// `unescapeString`, and for each unescaped `${`, isolates its inner
    /// text (`findInterpEnd`) and recursively re-lexes/parses it as an
    /// independent `<expression>` (`parseInterpExpr`) — a full recursive
    /// parse, not a token splice, so any expression form works inside
    /// `${...}`. If every `$` turns out escaped or never followed by `{`,
    /// this still collapses to a plain `.literal.string` — only a genuine
    /// `${` produces `.string_interp`.
    fn parseStringOrInterp(self: *Parser, raw: []const u8, tok: Token) Error!*ast.Expr {
        if (std.mem.indexOfScalar(u8, raw, '$') == null) {
            return self.createExpr(.{ .literal = .{ .string = try self.unescapeString(raw) } });
        }

        var literal: std.ArrayList(u8) = .empty;
        var parts: std.ArrayList(ast.Expr.InterpPart) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\') {
                try literal.append(self.allocator(), switch (raw[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    '\\' => '\\',
                    '"' => '"',
                    '$' => '$',
                    else => unreachable, // lexer guarantees only these five escapes reach here
                });
                i += 2;
                continue;
            }
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                try parts.append(self.allocator(), .{ .literal = try literal.toOwnedSlice(self.allocator()) });
                const inner_start = i + 2;
                const inner_end = findInterpEnd(raw, inner_start);
                try parts.append(self.allocator(), .{ .expr = try self.parseInterpExpr(raw[inner_start..inner_end], tok) });
                i = inner_end + 1; // skip the closing '}'
                continue;
            }
            try literal.append(self.allocator(), raw[i]);
            i += 1;
        }

        if (parts.items.len == 0) {
            // Every '$' in `raw` was escaped or never followed by '{' — no
            // real interpolation after all.
            return self.createExpr(.{ .literal = .{ .string = try literal.toOwnedSlice(self.allocator()) } });
        }
        try parts.append(self.allocator(), .{ .literal = try literal.toOwnedSlice(self.allocator()) });
        return self.createExpr(.{ .string_interp = try parts.toOwnedSlice(self.allocator()) });
    }

    /// Finds the index in `raw` of the `}` that closes the `${` whose inner
    /// text starts at `start`, mirroring the exact recursive depth-tracking
    /// `lexer.zig`'s `scanStringBody` already performed once while first
    /// scanning this token: nested `{`/`}` (e.g. a map literal) nest, and a
    /// `"` opens a nested string skipped over whole via `skipNestedString`
    /// (below) — which may itself contain further interpolation, nested to
    /// any depth, exactly as the lexer allows. Trusted to always find a
    /// matching `}` — the lexer already rejected any STRING token where it
    /// wouldn't (`Error.UnterminatedString`), so this never needs to fail.
    fn findInterpEnd(raw: []const u8, start: usize) usize {
        var depth: usize = 0;
        var i = start;
        while (i < raw.len) {
            switch (raw[i]) {
                '{' => {
                    depth += 1;
                    i += 1;
                },
                '}' => {
                    if (depth == 0) return i;
                    depth -= 1;
                    i += 1;
                },
                '"' => i = skipNestedString(raw, i + 1),
                else => i += 1,
            }
        }
        unreachable; // lexer already guaranteed a matching '}' exists
    }

    /// Skips a string nested inside an interpolation, starting right after
    /// its opening `"` (already consumed by the caller, at `start`),
    /// returning the index right after its closing `"`. Recognizes the same
    /// five escapes and, recursively via `findInterpEnd`, the same `${...}`
    /// interpolation a top-level string literal does — the `skipNestedString`
    /// counterpart to `lexer.zig`'s `scanStringBody` recursing into itself
    /// for the same shape.
    fn skipNestedString(raw: []const u8, start: usize) usize {
        var i = start;
        while (i < raw.len and raw[i] != '"') {
            if (raw[i] == '\\') {
                i += 2;
            } else if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                i = findInterpEnd(raw, i + 2) + 1; // position just past the '}'
            } else {
                i += 1;
            }
        }
        return i + 1; // closing '"'
    }

    /// Parses `src` (an interpolation's inner text, already isolated by
    /// `findInterpEnd`) as one independent `<expression>`, reusing this same
    /// arena so the resulting nodes live exactly as long as the rest of this
    /// parse's AST — freed together by the outer `Parser.deinit`, never
    /// separately. Temporarily swaps in a fresh token stream (re-lexed from
    /// `src`) and restores the original one afterward, rather than
    /// constructing a whole second `Parser` — this reuses every existing
    /// grammar production (`expression`, `primary`, ...) as-is.
    ///
    /// A syntax error here (or trailing tokens after the expression, e.g.
    /// `${1 2}`) is reported at `outer_tok`'s own position, not an offset
    /// within `src` — the re-lexed source starts its own line/column count
    /// over from 1 (a string literal may itself already span multiple
    /// source lines), so rebasing it against the real file is out of scope
    /// for this pass; pointing at the whole string literal, with a message
    /// that says "inside string interpolation", is judged clear enough.
    fn parseInterpExpr(self: *Parser, src: []const u8, outer_tok: Token) Error!*ast.Expr {
        var sub_lexer = lexer.Lexer.init(src);
        const sub_tokens = sub_lexer.tokenizeAll(self.allocator()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.diagnostic = .{ .line = outer_tok.line, .column = outer_tok.column, .message = "invalid expression inside string interpolation" };
            return Error.UnexpectedToken;
        };

        const saved_tokens = self.tokens;
        const saved_pos = self.pos;
        self.tokens = sub_tokens;
        self.pos = 0;
        defer {
            self.tokens = saved_tokens;
            self.pos = saved_pos;
        }

        const expr = self.expression() catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.UnexpectedToken => {
                self.diagnostic = .{ .line = outer_tok.line, .column = outer_tok.column, .message = "invalid expression inside string interpolation" };
                return Error.UnexpectedToken;
            },
        };
        if (!self.isAtEnd()) {
            self.diagnostic = .{ .line = outer_tok.line, .column = outer_tok.column, .message = "unexpected trailing text inside string interpolation" };
            return Error.UnexpectedToken;
        }
        return expr;
    }

    // ---- <program> ---------------------------------------------------

    /// <program> ::= { NEWLINE } { <top-level-decl> { NEWLINE } }
    pub fn parseProgram(self: *Parser) Error!ast.Program {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        self.skipNewlines();
        while (!self.isAtEnd()) {
            try stmts.append(self.allocator(), try self.topLevelDeclaration());
            self.skipNewlines();
        }
        return stmts.toOwnedSlice(self.allocator());
    }

    /// <top-level-decl> ::= <import-decl> | [ 'export' ] <function-decl>
    ///                    | [ 'export' ] <struct-decl> | [ 'export' ] <enum-decl>
    ///                    | <declaration>
    ///
    /// Function/struct/enum declarations (and `import`/`export`) are only
    /// recognized here, never from inside `declaration` — that's what keeps
    /// them out of block/if/while bodies without needing a separate check
    /// anywhere else (Butter has no nested functions, closures, or local
    /// type declarations, and no mechanism for importing partway through
    /// another declaration).
    fn topLevelDeclaration(self: *Parser) Error!ast.Stmt {
        if (self.check(.kw_import)) return self.importDeclaration();
        if (self.match(.kw_export)) {
            if (self.isFunctionDeclStart()) return self.functionDeclaration(true);
            if (self.isMethodDeclStart()) return self.methodDeclaration(true);
            if (self.check(.kw_struct)) return self.structDeclaration(true);
            if (self.check(.kw_enum)) return self.enumDeclaration(true);
            return self.fail("expected 'func', 'struct', or 'enum' after 'export'");
        }
        if (self.isFunctionDeclStart()) return self.functionDeclaration(false);
        if (self.isMethodDeclStart()) return self.methodDeclaration(false);
        if (self.check(.kw_struct)) return self.structDeclaration(false);
        if (self.check(.kw_enum)) return self.enumDeclaration(false);
        return self.declaration();
    }

    /// `func` immediately followed by an IDENTIFIER is always a function
    /// DECLARATION (`func NAME(...) -> T { ... }`); `func` followed
    /// directly by `(` is either a method declaration's receiver clause
    /// (`isMethodDeclStart`, below) or a function-VALUE TYPE (GRAMMAR.bnf
    /// design note 3ad) leading an ordinary top-level var-declaration, e.g.
    /// `func(int) bool matcher := isEven` — `declaration`'s own `.kw_func`
    /// dispatch (below) handles that last case via `varDeclaration`/
    /// `parseType`. This one-token lookahead is exactly what keeps the
    /// `func`-led productions from colliding at the top level (a
    /// var-declaration doesn't get its own leading keyword the way
    /// struct/enum/import do).
    fn isFunctionDeclStart(self: *Parser) bool {
        return self.check(.kw_func) and self.peekAt(1).type == .identifier;
    }

    /// `func` followed by `(` then two consecutive IDENTIFIER tokens is a
    /// method declaration's receiver clause (GRAMMAR.bnf design note 3af,
    /// `<method-decl>` ::= `'func' '(' <type> IDENTIFIER ')' ...`, receiver
    /// type first — the same `<type> IDENTIFIER` order every other
    /// parameter/field in this grammar uses, not Go's `(name Type)`) —
    /// distinguished from a `<func-type>`-led var-declaration
    /// (`isFunctionDeclStart`'s doc comment), whose own parenthesized list
    /// is always bare `<type>`s, each one followed by `,` or `)`, never
    /// immediately by a second identifier (a func-type's parameters are
    /// never named). This is the same two-identifiers-in-a-row trick
    /// `declaration`'s own struct/enum-typed var-declaration lookahead
    /// already relies on.
    fn isMethodDeclStart(self: *Parser) bool {
        return self.check(.kw_func) and self.peekAt(1).type == .lparen and self.peekAt(2).type == .identifier and self.peekAt(3).type == .identifier;
    }

    /// <import-decl> ::= 'import' STRING <end>
    ///
    /// `path` is left exactly as written (quotes stripped, same as a string
    /// literal in `primary`) — resolving it to an actual file is the
    /// module loader's job (module.zig), not the parser's.
    fn importDeclaration(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'import'
        const path_tok = try self.expect(.string, "expected a file path string after 'import'");
        const path = try self.unescapeString(path_tok.lexeme[1 .. path_tok.lexeme.len - 1]);
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .import_stmt = .{ .path = path } }, .line = line };
    }

    // ---- <declaration> -------------------------------------------------

    fn declaration(self: *Parser) Error!ast.Stmt {
        return switch (self.peek().type) {
            .kw_int, .kw_float, .kw_bool, .kw_string, .kw_map, .kw_list, .kw_func => self.varDeclaration(),
            // A struct/enum-typed var-declaration (GRAMMAR.bnf design notes
            // 3z/3aa) has no keyword of its own to dispatch on — its
            // `<type>` is a bare IDENTIFIER (`parseType`'s `.named` case).
            // Two consecutive IDENTIFIER tokens with nothing between them
            // (no '(', '{', '.', or operator) can never be anything BUT
            // `<type> IDENTIFIER`: no expression-statement shape in this
            // grammar continues one bare identifier with a second one, so
            // this lookahead is never ambiguous with `<expr-stmt>` — the
            // same "parser doesn't resolve names" stance `parseType` itself
            // takes; if `IDENTIFIER` doesn't actually name a declared type,
            // that's `SemanticError.UndefinedType` in compiler.zig, not a
            // parse error here.
            .identifier => if (self.peekAt(1).type == .identifier) self.varDeclaration() else self.statement(),
            .lbrace => self.block(),
            .kw_if => self.ifStatement(),
            .kw_while => self.whileStatement(),
            .kw_for => self.forStatement(),
            .kw_try => self.tryStatement(),
            else => self.statement(),
        };
    }

    /// Bundles `parseType`'s result: the `ValueType` tag plus, only when
    /// that tag is `.named`, the bare (unresolved) type name text — see
    /// `ast.ValueType.named`'s doc comment for why these travel as a pair
    /// rather than being folded into one union.
    const ParsedType = struct {
        type: ast.ValueType,
        named_type: ?[]const u8 = null,
        /// Set only when `type == .func` — see `ast.ValueType.func`'s doc
        /// comment.
        func_sig: ?*const ast.FuncSig = null,
    };

    /// <type> ::= 'int' | 'float' | 'bool' | 'string' | 'map' | 'list'
    ///          | IDENTIFIER | <func-type>
    ///
    /// A bare IDENTIFIER (GRAMMAR.bnf design notes 3z/3aa) names a
    /// user-declared struct/enum type — never validated here (the parser
    /// resolves no names); compiler.zig rejects an identifier that doesn't
    /// name any declared struct/enum type (`SemanticError.UndefinedType`).
    fn parseType(self: *Parser) Error!ParsedType {
        if (self.check(.kw_func)) return self.parseFuncType();
        const tok = self.peek();
        const parsed: ParsedType = switch (tok.type) {
            .kw_int => .{ .type = .int },
            .kw_float => .{ .type = .float },
            .kw_bool => .{ .type = .bool },
            .kw_string => .{ .type = .string },
            .kw_map => .{ .type = .map },
            .kw_list => .{ .type = .list },
            .identifier => .{ .type = .named, .named_type = tok.lexeme },
            else => return self.fail("expected a type"),
        };
        _ = self.advance();
        return parsed;
    }

    /// <func-type> ::= 'func' '(' [ <type> { ',' <type> } ] ')' <type>
    ///
    /// A function-VALUE's type (GRAMMAR.bnf design note 3ad) — deliberately
    /// NOT the same shape as `functionDeclaration`'s own header (no name, no
    /// '->'): there is nothing to name and no block to follow, just a bare
    /// structural signature, e.g. `func(int, int) bool`. Every parameter/
    /// return type inside is restricted to a plain scalar
    /// (int/float/bool/string/map/list) — neither a struct/enum name nor a
    /// nested function type is allowed here, so that two signatures can
    /// always be compared structurally with no name resolution
    /// (compiler.zig's `funcSigEqual`/`funcSigMatchesInfo`).
    fn parseFuncType(self: *Parser) Error!ParsedType {
        _ = self.advance(); // 'func'
        _ = try self.expect(.lparen, "expected '(' after 'func'");
        var param_types: std.ArrayList(ast.ValueType) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                const pt = try self.parseType();
                if (pt.type == .func or pt.type == .named) return self.fail("a function type's parameters must be a plain scalar type (int, float, bool, string, map, or list)");
                try param_types.append(self.allocator(), pt.type);
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after function-type parameter list");
        const ret = try self.parseType();
        if (ret.type == .func or ret.type == .named) return self.fail("a function type's return type must be a plain scalar type (int, float, bool, string, map, or list)");

        const sig = try self.allocator().create(ast.FuncSig);
        sig.* = .{
            .param_types = try param_types.toOwnedSlice(self.allocator()),
            .return_type = ret.type,
        };
        return .{ .type = .func, .func_sig = sig };
    }

    /// <function-decl> ::= 'func' IDENTIFIER '(' [ <param-list> ] ')'
    ///                     '->' <type> [ '[' [ INT ] ']' ] <block>
    /// <param-list>    ::= <param> { ',' <param> }
    /// <param>         ::= <type> [ '[' [ INT ] ']' ] IDENTIFIER
    ///
    /// A parameter's or the return type's optional array suffix comes in
    /// two forms: `'[' INT ']'` (a fixed size, passed/returned by value —
    /// same syntax `varDeclaration` uses) or bare `'[' ']'` (no declared
    /// size — passed/returned by reference instead, see GRAMMAR.bnf design
    /// note 3e's generic-array addendum). Local var-declarations don't get
    /// the bare-`[]` form; `varDeclaration` still only ever calls
    /// `parseOptionalArraySize`, not this.
    ///
    /// `exported` is whatever `topLevelDeclaration` determined from an
    /// optional leading 'export' keyword, which this function itself never
    /// looks at (the 'func' token must already be the current token).
    /// The shared tail of `<function-decl>` and `<method-decl>`
    /// (GRAMMAR.bnf design note 3af) once each one's own leading keyword(s)
    /// and name(s) have already been consumed: `'(' [ <param-list> ] ')'
    /// '->' <type> [ '[' [ INT ] ']' ] <block>`.
    const ParsedSignatureTail = struct {
        params: []ast.Param,
        return_type: ast.ValueType,
        return_named_type: ?[]const u8,
        return_array_size: ?ast.ArraySpec,
        body: []ast.Stmt,
    };

    fn parseSignatureTail(self: *Parser) Error!ParsedSignatureTail {
        _ = try self.expect(.lparen, "expected '(' after function/method name");
        var params: std.ArrayList(ast.Param) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                const param_type = try self.parseType();
                // map/list/a named (struct/enum) type/a function type never
                // take the array suffix — they're always exactly one value,
                // never a run of raw slots (GRAMMAR.bnf design notes 3m, 3z,
                // 3aa, 3ad) — so this is simply never attempted for them,
                // the same way it's never attempted for a param name.
                const param_array_size = if (param_type.type == .map or param_type.type == .list or param_type.type == .named or param_type.type == .func) null else try self.parseArraySpec();
                const param_name = try self.expect(.identifier, "expected a parameter name");
                try params.append(self.allocator(), .{ .type = param_type.type, .named_type = param_type.named_type, .func_sig = param_type.func_sig, .name = param_name.lexeme, .array_size = param_array_size });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after parameters");
        _ = try self.expect(.arrow, "expected '->' before return type");
        const return_type = try self.parseType();
        // Not supported this pass (GRAMMAR.bnf design note 3ad) — a
        // function value's own return type stays a plain scalar/map/list.
        if (return_type.type == .func) return self.fail("a function or method cannot return a function type (not supported yet)");
        const return_array_size = if (return_type.type == .map or return_type.type == .list or return_type.type == .named) null else try self.parseArraySpec();

        const body_stmt = try self.block();

        return .{
            .params = try params.toOwnedSlice(self.allocator()),
            .return_type = return_type.type,
            .return_named_type = return_type.named_type,
            .return_array_size = return_array_size,
            .body = body_stmt.kind.block,
        };
    }

    fn functionDeclaration(self: *Parser, exported: bool) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'func'
        const name_tok = try self.expect(.identifier, "expected a function name");
        const tail = try self.parseSignatureTail();

        return ast.Stmt{ .kind = .{ .function_decl = .{
            .name = name_tok.lexeme,
            .params = tail.params,
            .return_type = tail.return_type,
            .return_named_type = tail.return_named_type,
            .return_array_size = tail.return_array_size,
            .body = tail.body,
            .exported = exported,
        } }, .line = line };
    }

    /// <method-decl> ::= 'func' '(' <type> IDENTIFIER ')' IDENTIFIER
    ///                    '(' [ <param-list> ] ')' '->' <type>
    ///                    [ '[' [ INT ] ']' ] <block>
    ///
    /// See `isMethodDeclStart`'s doc comment for why the receiver clause
    /// puts the type before the name (`<type> IDENTIFIER`, matching
    /// `<param>`/`<field>` everywhere else in this grammar) rather than
    /// Go's `(name Type)` order. `receiver_type` is left unresolved here
    /// (bare source text) — compiler.zig checks it actually names a
    /// declared struct, the same way a `<param>`'s own named type is only
    /// resolved once compilation begins.
    fn methodDeclaration(self: *Parser, exported: bool) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'func'
        _ = try self.expect(.lparen, "expected '(' to start a method's receiver clause");
        const receiver_type_tok = try self.expect(.identifier, "expected the receiver's struct type name");
        const receiver_name_tok = try self.expect(.identifier, "expected the receiver's parameter name");
        _ = try self.expect(.rparen, "expected ')' after the receiver clause");
        const name_tok = try self.expect(.identifier, "expected a method name");
        const tail = try self.parseSignatureTail();

        return ast.Stmt{ .kind = .{ .method_decl = .{
            .receiver_name = receiver_name_tok.lexeme,
            .receiver_type = receiver_type_tok.lexeme,
            .name = name_tok.lexeme,
            .params = tail.params,
            .return_type = tail.return_type,
            .return_named_type = tail.return_named_type,
            .return_array_size = tail.return_array_size,
            .body = tail.body,
            .exported = exported,
        } }, .line = line };
    }

    /// `[ '[' INT ']' ]` — used by `varDeclaration`, which only ever
    /// allows a fixed size (local arrays are never generic).
    fn parseOptionalArraySize(self: *Parser) Error!?u32 {
        if (!self.match(.lbracket)) return null;
        const size_tok = try self.expect(.int, "expected an array size");
        const size = std.fmt.parseInt(u32, size_tok.lexeme, 10) catch return self.fail("array size is too large");
        _ = try self.expect(.rbracket, "expected ']' after array size");
        return size;
    }

    /// `[ '[' [ INT ] ']' ]` — used by a parameter's type and a function's
    /// return type, where a bare `[]` (no INT) is also legal and means
    /// "generic, no fixed size" (`ast.ArraySpec.generic`).
    fn parseArraySpec(self: *Parser) Error!?ast.ArraySpec {
        if (!self.match(.lbracket)) return null;
        if (self.match(.rbracket)) return .generic;
        const size_tok = try self.expect(.int, "expected an array size or ']' for a generic array");
        const size = std.fmt.parseInt(u32, size_tok.lexeme, 10) catch return self.fail("array size is too large");
        _ = try self.expect(.rbracket, "expected ']' after array size");
        return ast.ArraySpec{ .fixed = size };
    }

    /// <var-declaration> ::= <type> [ '[' INT ']' ] IDENTIFIER
    ///                       [ ':=' <expression> ] <end>
    fn varDeclaration(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        const value_type = try self.parseType();
        // map/list/a named (struct/enum) type never take the array-size
        // suffix (GRAMMAR.bnf design notes 3m, 3z, 3aa) — writing `map[3] m`
        // simply never gets this far as an array declaration; the next
        // token (still `[`) fails the IDENTIFIER expectation below instead.
        // A function type (GRAMMAR.bnf design note 3ad) never takes the
        // array-size suffix either — same "always exactly one value" story.
        const array_len = if (value_type.type == .map or value_type.type == .list or value_type.type == .named or value_type.type == .func) null else try self.parseOptionalArraySize();
        const name_tok = try self.expect(.identifier, "expected a variable name");

        var initializer: ?*ast.Expr = null;
        if (self.match(.colon_equal)) initializer = try self.expression();

        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .var_decl = .{ .type = value_type.type, .named_type = value_type.named_type, .func_sig = value_type.func_sig, .array_len = array_len, .name = name_tok.lexeme, .initializer = initializer } }, .line = line };
    }

    /// <struct-decl> ::= 'struct' IDENTIFIER '{' { NEWLINE } [ <field-list> ] '}'
    /// <field-list>  ::= <field> { ( ',' | NEWLINE ) <field> } [ ',' ]
    /// <field>       ::= <type> IDENTIFIER
    ///
    /// Only ever reached from `topLevelDeclaration` (GRAMMAR.bnf design note
    /// 3z), matching `functionDeclaration`'s own restriction. Fields reuse
    /// exactly the `<type> IDENTIFIER` shape `<param>` uses — never an
    /// array suffix (a field is always exactly one `Value` slot, see
    /// `ast.FieldDecl`'s doc comment) — separated by a comma, a newline, or
    /// both, with an optional trailing comma before the closing `}`.
    fn structDeclaration(self: *Parser, exported: bool) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'struct'
        const name_tok = try self.expect(.identifier, "expected a struct name");
        _ = try self.expect(.lbrace, "expected '{' after struct name");
        self.skipNewlines();

        var fields: std.ArrayList(ast.FieldDecl) = .empty;
        if (!self.check(.rbrace)) {
            while (true) {
                const field_type = try self.parseType();
                // Not supported this pass (GRAMMAR.bnf design note 3ad).
                if (field_type.type == .func) return self.fail("a struct field cannot be function-typed (not supported yet)");
                const field_name = try self.expect(.identifier, "expected a field name");
                try fields.append(self.allocator(), .{ .type = field_type.type, .named_type = field_type.named_type, .name = field_name.lexeme });
                const had_newline = self.check(.newline);
                self.skipNewlines();
                const had_comma = self.match(.comma);
                if (had_comma) self.skipNewlines();
                if (!had_newline and !had_comma) break;
                if (self.check(.rbrace)) break; // trailing separator before '}'
            }
        }
        self.skipNewlines();
        _ = try self.expect(.rbrace, "expected '}' to close struct declaration");

        return ast.Stmt{ .kind = .{ .struct_decl = .{
            .name = name_tok.lexeme,
            .fields = try fields.toOwnedSlice(self.allocator()),
            .exported = exported,
        } }, .line = line };
    }

    /// <enum-decl>    ::= 'enum' IDENTIFIER '{' { NEWLINE } [ <variant-list> ] '}'
    /// <variant-list> ::= IDENTIFIER { ( ',' | NEWLINE ) IDENTIFIER } [ ',' ]
    ///
    /// Only ever reached from `topLevelDeclaration` (GRAMMAR.bnf design note
    /// 3aa), matching `structDeclaration`. A variant carries no payload —
    /// this is a plain named tag, not a data-carrying union.
    fn enumDeclaration(self: *Parser, exported: bool) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'enum'
        const name_tok = try self.expect(.identifier, "expected an enum name");
        _ = try self.expect(.lbrace, "expected '{' after enum name");
        self.skipNewlines();

        var variants: std.ArrayList([]const u8) = .empty;
        if (!self.check(.rbrace)) {
            while (true) {
                const variant_tok = try self.expect(.identifier, "expected a variant name");
                try variants.append(self.allocator(), variant_tok.lexeme);
                const had_newline = self.check(.newline);
                self.skipNewlines();
                const had_comma = self.match(.comma);
                if (had_comma) self.skipNewlines();
                if (!had_newline and !had_comma) break;
                if (self.check(.rbrace)) break; // trailing separator before '}'
            }
        }
        self.skipNewlines();
        _ = try self.expect(.rbrace, "expected '}' to close enum declaration");

        return ast.Stmt{ .kind = .{ .enum_decl = .{
            .name = name_tok.lexeme,
            .variants = try variants.toOwnedSlice(self.allocator()),
            .exported = exported,
        } }, .line = line };
    }

    /// <block> ::= '{' { NEWLINE } { <declaration> { NEWLINE } } '}'
    fn block(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = try self.expect(.lbrace, "expected '{'");
        self.skipNewlines();

        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (!self.check(.rbrace) and !self.isAtEnd()) {
            try stmts.append(self.allocator(), try self.declaration());
            self.skipNewlines();
        }

        _ = try self.expect(.rbrace, "expected '}' to close block");
        return ast.Stmt{ .kind = .{ .block = try stmts.toOwnedSlice(self.allocator()) }, .line = line };
    }

    /// <if-stmt> ::= 'if' <expression> <declaration> { NEWLINE } [ 'else' <declaration> ]
    fn ifStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'if'
        const condition = try self.expression();
        const then_branch = try self.createStmt(try self.declaration());

        self.skipNewlines();
        var else_branch: ?*ast.Stmt = null;
        if (self.match(.kw_else)) else_branch = try self.createStmt(try self.declaration());

        return ast.Stmt{ .kind = .{ .if_stmt = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } }, .line = line };
    }

    /// <while-stmt> ::= 'while' <expression> <declaration>
    fn whileStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'while'
        const condition = try self.expression();
        const body = try self.createStmt(try self.declaration());
        return ast.Stmt{ .kind = .{ .while_stmt = .{ .condition = condition, .body = body } }, .line = line };
    }

    /// <for-stmt> ::= 'for' IDENTIFIER 'in' <expression> '..' <expression> <declaration>
    ///
    /// Always ascending, always step 1, end exclusive — see GRAMMAR.bnf
    /// design note 3f. `start`/`end` are arbitrary expressions, each
    /// evaluated exactly once at loop entry (not re-evaluated per
    /// iteration), matching typical for-range semantics.
    fn forStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'for'
        const name_tok = try self.expect(.identifier, "expected a loop variable name");
        _ = try self.expect(.kw_in, "expected 'in' after loop variable");
        const start = try self.expression();
        _ = try self.expect(.dot_dot, "expected '..' in for-loop range");
        const end = try self.expression();
        const body = try self.createStmt(try self.declaration());
        return ast.Stmt{ .kind = .{ .for_stmt = .{ .var_name = name_tok.lexeme, .start = start, .end = end, .body = body } }, .line = line };
    }

    /// <try-stmt> ::= 'try' <block> { NEWLINE } 'catch' IDENTIFIER <block>
    ///
    /// Braces are mandatory on both halves — unlike `if`/`while`/`for`,
    /// neither takes a bare `<declaration>` — because both are load-bearing
    /// scopes (the catch block's is what the error binding lives in) and
    /// because a braceless try body reads ambiguously next to the `catch`
    /// that has to follow it. Both are checked for explicitly rather than
    /// left to `block`'s generic "expected '{'", since "you wrote `try`
    /// without braces" is the mistake worth naming.
    ///
    /// A NEWLINE between the two halves is allowed, matching how
    /// `ifStatement` lets `else` start its own line. The binding is
    /// mandatory: a program that doesn't want it writes `catch _ { ... }`.
    fn tryStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'try'

        if (!self.check(.lbrace)) return self.fail("expected '{' after 'try' — a try block always takes braces");
        const body = try self.block();

        self.skipNewlines();
        _ = try self.expect(.kw_catch, "expected 'catch' after the try block");
        const name_tok = try self.expect(.identifier, "expected a name to bind the caught error to after 'catch' (use '_' if unused)");

        if (!self.check(.lbrace)) return self.fail("expected '{' after the caught error's name — a catch block always takes braces");
        const handler = try self.block();

        return ast.Stmt{ .kind = .{ .try_stmt = .{
            .body = body.kind.block,
            .error_var = name_tok.lexeme,
            .handler = handler.kind.block,
        } }, .line = line };
    }

    // ---- <statement> ---------------------------------------------------

    fn statement(self: *Parser) Error!ast.Stmt {
        if (self.check(.kw_print)) return self.printStatement();
        if (self.check(.kw_return)) return self.returnStatement();
        if (self.check(.kw_close)) return self.closeStatement();
        if (self.check(.kw_exit)) return self.exitStatement();
        if (self.check(.kw_throw)) return self.throwStatement();
        return self.exprStatement();
    }

    /// <print-stmt> ::= 'print' <expression> <end>
    fn printStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'print'
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .print_stmt = value }, .line = line };
    }

    /// <close-stmt> ::= 'close' <expression> <end>
    ///
    /// A statement, not an expression, because closing produces no value —
    /// exactly the shape (and the reason) `print` has.
    fn closeStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'close'
        const stream = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .close_stmt = stream }, .line = line };
    }

    /// <exit-stmt> ::= 'exit' <expression> <end>
    ///
    /// A statement, not an expression, for the same reason `close` is —
    /// nothing after it can ever run, so there is no result to hand back to.
    fn exitStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'exit'
        const code = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .exit_stmt = code }, .line = line };
    }

    /// <throw-stmt> ::= 'throw' <expression> <end>
    ///
    /// A statement, not an expression, for the same reason `exit` is — a
    /// caught `throw` never returns control to what follows it, and an
    /// uncaught one halts the program outright.
    fn throwStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'throw'
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .throw_stmt = value }, .line = line };
    }

    /// <return-stmt> ::= 'return' <expression> <end>
    fn returnStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        _ = self.advance(); // 'return'
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .return_stmt = value }, .line = line };
    }

    /// <expr-stmt> ::= <expression> <end>
    fn exprStatement(self: *Parser) Error!ast.Stmt {
        const line = self.peek().line;
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .kind = .{ .expr_stmt = value }, .line = line };
    }

    /// <end> ::= NEWLINE | EOF | ε (only when the next token is '}')
    fn consumeEnd(self: *Parser) Error!void {
        if (self.check(.rbrace) or self.isAtEnd()) return;
        if (self.match(.newline)) return;
        return self.fail("expected a newline or end of input after statement");
    }

    // ---- Expressions, lowest to highest precedence --------------------

    fn expression(self: *Parser) Error!*ast.Expr {
        return self.assignment();
    }

    /// <assignment> ::= IDENTIFIER ':=' <assignment>
    ///                | IDENTIFIER '[' <expression> ']' ':=' <assignment>
    ///                | <expression> '.' IDENTIFIER ':=' <assignment>
    ///                | <logic-or>
    fn assignment(self: *Parser) Error!*ast.Expr {
        const expr = try self.logicOr();

        if (self.match(.colon_equal)) {
            const equals = self.previous();
            const value = try self.assignment();

            if (expr.* == .variable) {
                return self.createExpr(.{ .assign = .{ .name = expr.variable, .value = value } });
            }
            if (expr.* == .index) {
                return self.createExpr(.{ .index_assign = .{ .base = expr.index.base, .index = expr.index.index, .value = value } });
            }
            if (expr.* == .field_access) {
                return self.createExpr(.{ .field_assign = .{ .base = expr.field_access.base, .field = expr.field_access.field, .value = value } });
            }

            self.diagnostic = .{ .line = equals.line, .column = equals.column, .message = "invalid assignment target: only a bare identifier, an indexed array element, or a struct field may appear left of ':='" };
            return Error.UnexpectedToken;
        }

        return expr;
    }

    fn binaryLevel(
        self: *Parser,
        comptime next: fn (*Parser) Error!*ast.Expr,
        comptime operators: []const struct { token: TokenType, op: ast.BinaryOp },
    ) Error!*ast.Expr {
        var expr = try next(self);
        outer: while (true) {
            inline for (operators) |entry| {
                if (self.check(entry.token)) {
                    _ = self.advance();
                    const right = try next(self);
                    expr = try self.createExpr(.{ .binary = .{ .left = expr, .op = entry.op, .right = right } });
                    continue :outer;
                }
            }
            return expr;
        }
    }

    /// <logic-or> ::= <logic-and> { 'or' <logic-and> }
    fn logicOr(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(logicAnd, &.{
            .{ .token = .kw_or, .op = .logic_or },
        });
    }

    /// <logic-and> ::= <equality> { 'and' <equality> }
    fn logicAnd(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(equality, &.{
            .{ .token = .kw_and, .op = .logic_and },
        });
    }

    /// <equality> ::= <comparison> { ( '==' | '!=' ) <comparison> }
    fn equality(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(comparison, &.{
            .{ .token = .equal_equal, .op = .eq },
            .{ .token = .bang_equal, .op = .neq },
        });
    }

    /// <comparison> ::= <addition> { ( '>' | '>=' | '<' | '<=' ) <addition> }
    fn comparison(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(addition, &.{
            .{ .token = .greater, .op = .gt },
            .{ .token = .greater_equal, .op = .gte },
            .{ .token = .less, .op = .lt },
            .{ .token = .less_equal, .op = .lte },
        });
    }

    /// <addition> ::= <multiplication> { ( '+' | '-' ) <multiplication> }
    fn addition(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(multiplication, &.{
            .{ .token = .plus, .op = .add },
            .{ .token = .minus, .op = .sub },
        });
    }

    /// <multiplication> ::= <exponent> { ( '*' | '/' | '%' ) <exponent> }
    fn multiplication(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(exponent, &.{
            .{ .token = .star, .op = .mul },
            .{ .token = .slash, .op = .div },
            .{ .token = .percent, .op = .mod },
        });
    }

    /// <exponent> ::= <unary> { '**' <unary> }
    fn exponent(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(unary, &.{
            .{ .token = .star_star, .op = .pow },
        });
    }

    /// <unary> ::= ( '!' | '-' ) <unary> | <primary>
    fn unary(self: *Parser) Error!*ast.Expr {
        if (self.check(.bang) or self.check(.minus)) {
            const op_tok = self.advance();
            const op: ast.UnaryOp = if (op_tok.type == .bang) .not else .negate;
            const right = try self.unary();
            return self.createExpr(.{ .unary = .{ .op = op, .right = right } });
        }
        return self.primary();
    }

    /// <primary> ::= <atom> { '[' <expression> [ '..' <expression> ] ']' | '.' IDENTIFIER }
    ///
    /// The postfix `'[' <expression> ']'` suffix is what lets bracket-
    /// indexing CHAIN (`doc["a"]["b"]`, GRAMMAR.bnf design note 3m) — it's
    /// applied uniformly after ANY atom, not just an IDENTIFIER; a shape
    /// that doesn't actually name something indexable (`5[0]`) is rejected
    /// later, by the compiler (a statically-known non-array/collection bare
    /// local) or the VM (`RuntimeError.TypeMismatch` for anything else),
    /// the same "checked, not trusted" stance the rest of this VM already
    /// takes rather than trying to reject it here in the grammar. The `..`
    /// form is a SLICE (GRAMMAR.bnf's Strings design notes) — read-only, so
    /// unlike the single-index form it never becomes an assignment target.
    /// `'.' IDENTIFIER` (GRAMMAR.bnf design notes 3z/3aa) chains the exact
    /// same way, for the exact same reason (`p.a.b`, `xs[0].x` both fall out
    /// for free); a shape that doesn't name a struct/enum is likewise left
    /// to compiler.zig to reject (`NotAStruct`/`UnknownField`/
    /// `UnknownEnumVariant`), not this grammar.
    fn primary(self: *Parser) Error!*ast.Expr {
        var expr = try self.atom();
        while (true) {
            if (self.check(.lbracket)) {
                expr = try self.finishIndex(expr);
            } else if (self.check(.dot)) {
                expr = try self.finishField(expr);
            } else {
                break;
            }
        }
        return expr;
    }

    /// <atom> ::= INT | FLOAT | STRING | 'true' | 'false' | 'null'
    ///         | '(' <expression> ')' | <call-expr> | <array-literal>
    ///         | <map-literal> | <len-expr> | <read-expr> | <write-expr>
    ///         | <open-expr> | <push-expr> | <keys-expr> | <has-expr>
    ///         | <delete-expr> | <json-expr> | <stringify-expr>
    ///         | <int-expr> | <float-expr>
    ///         | <getenv-expr> | <hasenv-expr>
    ///         | <exists-expr> | <list-dir-expr> | <remove-expr> | <rename-expr>
    ///         | <exec-expr>
    ///         | <now-expr> | <random-expr>
    ///         | <ord-expr> | <chr-expr> | <join-expr>
    ///         | 'stdin' | 'stdout' | 'stderr' | 'args' | IDENTIFIER
    fn atom(self: *Parser) Error!*ast.Expr {
        const tok = self.peek();
        switch (tok.type) {
            .int => {
                _ = self.advance();
                const value = std.fmt.parseInt(i64, tok.lexeme, 10) catch return self.fail("malformed integer literal");
                return self.createExpr(.{ .literal = .{ .int = value } });
            },
            .float => {
                _ = self.advance();
                const value = std.fmt.parseFloat(f64, tok.lexeme) catch return self.fail("malformed float literal");
                return self.createExpr(.{ .literal = .{ .float = value } });
            },
            .string => {
                _ = self.advance();
                // Strip the surrounding quotes captured in the lexeme, then
                // split out any `${...}` interpolations (design note 3ae),
                // decoding \n/\t/\\/\"/\$ escapes (design note 3s) along the
                // way.
                const contents = tok.lexeme[1 .. tok.lexeme.len - 1];
                return self.parseStringOrInterp(contents, tok);
            },
            .kw_true => {
                _ = self.advance();
                return self.createExpr(.{ .literal = .{ .boolean = true } });
            },
            .kw_false => {
                _ = self.advance();
                return self.createExpr(.{ .literal = .{ .boolean = false } });
            },
            .kw_null => {
                _ = self.advance();
                return self.createExpr(.{ .literal = .null_value });
            },
            .identifier => {
                _ = self.advance();
                if (self.check(.lparen)) return self.finishCall(tok.lexeme);
                if (self.looksLikeStructLiteral()) return self.finishStructLiteral(tok.lexeme);
                return self.createExpr(.{ .variable = tok.lexeme });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.expression();
                _ = try self.expect(.rparen, "expected ')' after expression");
                return self.createExpr(.{ .grouping = inner });
            },
            .lbracket => return self.arrayLiteral(),
            .lbrace => return self.mapLiteral(),
            .kw_len => return self.lenExpr(),
            .kw_read => return self.readExpr(),
            .kw_write => return self.writeExpr(),
            .kw_open => return self.openExpr(),
            .kw_push => return self.pushExpr(),
            .kw_keys => return self.keysExpr(),
            .kw_has => return self.hasExpr(),
            .kw_delete => return self.deleteExpr(),
            .kw_json => return self.jsonExpr(),
            .kw_stringify => return self.stringifyExpr(),
            .kw_int => return self.intParseExpr(),
            .kw_float => return self.floatParseExpr(),
            .kw_getenv => return self.getenvExpr(),
            .kw_hasenv => return self.hasenvExpr(),
            .kw_exists => return self.existsExpr(),
            .kw_listdir => return self.listDirExpr(),
            .kw_remove => return self.removeExpr(),
            .kw_rename => return self.renameExpr(),
            .kw_mkdir => return self.mkdirExpr(),
            .kw_exec => return self.execExpr(),
            .kw_now => return self.nowExpr(),
            .kw_random => return self.randomExpr(),
            .kw_ord => return self.ordExpr(),
            .kw_chr => return self.chrExpr(),
            .kw_join => return self.joinExpr(),
            .kw_stdin => {
                _ = self.advance();
                return self.createExpr(.{ .stream_literal = .stdin });
            },
            .kw_stdout => {
                _ = self.advance();
                return self.createExpr(.{ .stream_literal = .stdout });
            },
            .kw_stderr => {
                _ = self.advance();
                return self.createExpr(.{ .stream_literal = .stderr });
            },
            .kw_args => {
                _ = self.advance();
                return self.createExpr(.args_literal);
            },
            else => return self.fail("expected an expression"),
        }
    }

    /// <call-expr> ::= IDENTIFIER '(' [ <arg-list> ] ')'
    /// <arg-list>  ::= <expression> { ',' <expression> }
    ///
    /// Called with the callee name already consumed and '(' as the next
    /// token (see `primary`'s IDENTIFIER case).
    fn finishCall(self: *Parser, name: []const u8) Error!*ast.Expr {
        _ = self.advance(); // '('
        var args: std.ArrayList(*ast.Expr) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                try args.append(self.allocator(), try self.expression());
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after arguments");
        return self.createExpr(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.allocator()) } });
    }

    /// `'[' <expression> [ '..' <expression> ] ']'` postfix suffix — see
    /// `primary`'s doc comment. Called with `base` already parsed and '['
    /// as the next token. Without a `..`, produces an `.index` node
    /// regardless of whether it ends up being read or assigned to —
    /// `assignment` is what turns a trailing `':=' <expr>` into an
    /// `.index_assign` instead (matching how a bare `.variable` becomes
    /// `.assign`). With a `..`, produces a `.slice` node instead — always a
    /// read: `assignment` has no slice-assign case, so a trailing `':='`
    /// after one falls through to its "invalid assignment target" error.
    fn finishIndex(self: *Parser, base: *ast.Expr) Error!*ast.Expr {
        _ = self.advance(); // '['
        const start_expr = try self.expression();
        if (self.match(.dot_dot)) {
            const end_expr = try self.expression();
            _ = try self.expect(.rbracket, "expected ']' after slice range");
            return self.createExpr(.{ .slice = .{ .base = base, .start = start_expr, .end = end_expr } });
        }
        _ = try self.expect(.rbracket, "expected ']' after array index");
        return self.createExpr(.{ .index = .{ .base = base, .index = start_expr } });
    }

    /// `'.' IDENTIFIER [ '(' [ <arg-list> ] ')' ]` postfix suffix
    /// (GRAMMAR.bnf design notes 3z/3aa/3af) — see `primary`'s doc comment.
    /// Called with `base` already parsed and '.' as the next token (mirrors
    /// `finishIndex`). A trailing '(' right after the identifier — nothing
    /// else in this grammar puts a call directly after a field/variant name
    /// — is what turns this into a `.method_call` instead of an ordinary
    /// `.field_access`; otherwise this always produces a `.field_access`
    /// node regardless of whether it ends up being read or assigned to —
    /// `assignment` is what turns a trailing `':=' <expr>` into a
    /// `.field_assign` instead, exactly mirroring `.index`/`.index_assign`
    /// (a `.method_call` is never an assignment target, so `assignment`
    /// never needs to know about it at all — it only ever recognizes a
    /// trailing `':='` right after the bare `.field_access` shape).
    /// Whether a resulting `.field_access` actually means a struct field or
    /// an enum variant reference is never decided here — see
    /// `ast.Expr.field_access`'s doc comment; the parser treats every plain
    /// `.`-postfix identically and leaves disambiguation to compiler.zig.
    fn finishField(self: *Parser, base: *ast.Expr) Error!*ast.Expr {
        _ = self.advance(); // '.'
        const field_tok = try self.expect(.identifier, "expected a field or method name after '.'");
        if (!self.check(.lparen)) {
            return self.createExpr(.{ .field_access = .{ .base = base, .field = field_tok.lexeme } });
        }
        _ = self.advance(); // '('
        var args: std.ArrayList(*ast.Expr) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                try args.append(self.allocator(), try self.expression());
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after arguments");
        return self.createExpr(.{ .method_call = .{ .base = base, .method = field_tok.lexeme, .args = try args.toOwnedSlice(self.allocator()) } });
    }

    /// Whether the `{` right after a just-consumed IDENTIFIER starts a
    /// struct literal (GRAMMAR.bnf design note 3z) rather than an unrelated
    /// STATEMENT block that happens to follow it — the real case being
    /// disambiguated is `for i in 0..n { ... }` / `if cond { ... }` /
    /// `while cond { ... }`, none of which need a separator before their
    /// body, so a bare identifier there is also followed directly by `{`.
    ///
    /// The disambiguator: a struct literal's `{` is always immediately
    /// followed (past newlines) by `IDENTIFIER ':'`, its first field — a
    /// shape no Butter statement begins with (assignment is `:=`, never a
    /// bare `:`), so this lookahead can't misfire on a real block's first
    /// statement.
    ///
    /// Consequence: `Type{}` (zero fields) isn't accepted here — it would
    /// be indistinguishable from `if cond {}`'s empty body, and isn't worth
    /// the ambiguity.
    fn looksLikeStructLiteral(self: *const Parser) bool {
        if (!self.check(.lbrace)) return false;
        var i: usize = 1;
        while (self.peekAt(i).type == .newline) i += 1;
        return self.peekAt(i).type == .identifier and self.peekAt(i + 1).type == .colon;
    }

    /// `TypeName '{' [ <field-init-list> ] '}'` (GRAMMAR.bnf design note 3z)
    /// — called with the type name already consumed and '{' as the next
    /// token (mirrors `finishCall`), and only once `looksLikeStructLiteral`
    /// has already confirmed the shape. `<field-init-list> ::= <field-init>
    /// { ( ',' | NEWLINE ) <field-init> } [ ',' ]`, `<field-init> ::=
    /// IDENTIFIER ':' <expression>` — fields are keyed by name, not
    /// position, and may appear in any order; compiler.zig is what checks
    /// every declared field is present exactly once and reorders the
    /// values into the struct's declared order before emitting
    /// `MAKE_STRUCT` (ISA.bnf section 19).
    fn finishStructLiteral(self: *Parser, type_name: []const u8) Error!*ast.Expr {
        _ = self.advance(); // '{'
        self.skipNewlines();
        var fields: std.ArrayList(ast.Expr.FieldInit) = .empty;
        if (!self.check(.rbrace)) {
            while (true) {
                const field_tok = try self.expect(.identifier, "expected a field name in struct literal");
                _ = try self.expect(.colon, "expected ':' after field name");
                const value = try self.expression();
                try fields.append(self.allocator(), .{ .name = field_tok.lexeme, .value = value });
                self.skipNewlines();
                if (!self.match(.comma)) break;
                self.skipNewlines();
                if (self.check(.rbrace)) break; // trailing comma
            }
        }
        self.skipNewlines();
        _ = try self.expect(.rbrace, "expected '}' after struct literal");
        return self.createExpr(.{ .struct_literal = .{ .type_name = type_name, .fields = try fields.toOwnedSlice(self.allocator()) } });
    }

    /// <len-expr> ::= 'len' '(' <expression> ')'
    ///
    /// Relaxed from a bare IDENTIFIER (GRAMMAR.bnf design note 3m) now that
    /// a map/list is a genuine first-class runtime value — the compiler
    /// still special-cases a bare `.variable` naming a fixed/generic array
    /// to fold at compile time, exactly as before; arrays themselves still
    /// aren't first-class (design note 3e).
    fn lenExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'len'
        _ = try self.expect(.lparen, "expected '(' after 'len'");
        const target = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the argument");
        return self.createExpr(.{ .len_of = target });
    }

    /// <read-expr> ::= 'read' '(' <expression> ',' IDENTIFIER ')'
    ///
    /// The stream is an arbitrary expression so that an `open`ed file works
    /// anywhere `stdin` does. The destination is still a bare array name,
    /// the same restriction `lenExpr`/`finishIndex` place on their own
    /// targets and for the same reason (GRAMMAR.bnf design note 3e) — there
    /// is no array-valued expression to read into.
    fn readExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'read'
        _ = try self.expect(.lparen, "expected '(' after 'read'");
        const stream = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the stream");
        const name_tok = try self.expect(.identifier, "expected a buffer (array) name to read into");
        _ = try self.expect(.rparen, "expected ')' after the buffer name");
        return self.createExpr(.{ .read_bytes = .{ .stream = stream, .buffer = name_tok.lexeme } });
    }

    /// <write-expr> ::= 'write' '(' <expression> ',' <expression> ')'
    ///                | 'write' '(' <expression> ',' IDENTIFIER ',' <expression> ')'
    ///
    /// The two forms are told apart by argument count alone: the second
    /// argument parses as an ordinary expression either way, and only if a
    /// ',' follows it (making this the three-argument buffer form) does it
    /// have to have been a bare array name.
    fn writeExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'write'
        _ = try self.expect(.lparen, "expected '(' after 'write'");
        const stream = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the stream");
        const second = try self.expression();

        if (self.match(.comma)) {
            if (second.* != .variable) {
                return self.fail("write's buffer argument must be a bare array name");
            }
            const count = try self.expression();
            _ = try self.expect(.rparen, "expected ')' after the byte count");
            return self.createExpr(.{ .write_bytes = .{ .stream = stream, .buffer = second.variable, .count = count } });
        }

        _ = try self.expect(.rparen, "expected ')' after the value to write");
        return self.createExpr(.{ .write_value = .{ .stream = stream, .value = second } });
    }

    /// <open-expr> ::= 'open' '(' <expression> ',' <open-mode> ')'
    /// <open-mode> ::= 'read' | 'write' | 'append'
    ///
    /// The mode is a bare keyword rather than an expression, so a file's
    /// direction is always known at compile time even though the stream
    /// value itself isn't (GRAMMAR.bnf design note 3l). `read` and `write`
    /// double as mode keywords here without ambiguity: this position only
    /// ever accepts a mode.
    fn openExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'open'
        _ = try self.expect(.lparen, "expected '(' after 'open'");
        const path = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the path");

        const mode: ast.OpenMode = switch (self.peek().type) {
            .kw_read => .read,
            .kw_write => .write,
            .kw_append => .append,
            else => return self.fail("expected an open mode: 'read', 'write', or 'append'"),
        };
        _ = self.advance();

        _ = try self.expect(.rparen, "expected ')' after the open mode");
        return self.createExpr(.{ .open_file = .{ .path = path, .mode = mode } });
    }

    /// <array-literal> ::= '[' [ <expression> { ',' <expression> } ] ']'
    ///
    /// Doubles as a `list` initializer (GRAMMAR.bnf design note 3m) — this
    /// production is unchanged either way; only the compiler's handling of
    /// it differs, based on what's being initialized.
    fn arrayLiteral(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // '['
        var elems: std.ArrayList(*ast.Expr) = .empty;
        if (!self.check(.rbracket)) {
            while (true) {
                try elems.append(self.allocator(), try self.expression());
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rbracket, "expected ']' after array literal");
        return self.createExpr(.{ .array_literal = try elems.toOwnedSlice(self.allocator()) });
    }

    /// <map-literal> ::= '{' [ <map-entry> { ',' <map-entry> } ] '}'
    /// <map-entry>   ::= STRING ':' <expression>
    ///
    /// Keys are STRING tokens (static text), not arbitrary expressions —
    /// this is never a conflict with `<block>` (which also starts with
    /// '{'): a block is only ever reached in statement position, a map
    /// literal only in expression position, so the parser never has to
    /// disambiguate the two at the same decision point.
    fn mapLiteral(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // '{'
        var entries: std.ArrayList(ast.Expr.MapEntry) = .empty;
        if (!self.check(.rbrace)) {
            while (true) {
                const key_tok = try self.expect(.string, "expected a string key in map literal");
                const key = try self.unescapeString(key_tok.lexeme[1 .. key_tok.lexeme.len - 1]);
                _ = try self.expect(.colon, "expected ':' after map key");
                const value = try self.expression();
                try entries.append(self.allocator(), .{ .key = key, .value = value });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rbrace, "expected '}' after map literal");
        return self.createExpr(.{ .map_literal = try entries.toOwnedSlice(self.allocator()) });
    }

    /// <push-expr> ::= 'push' '(' <expression> ',' <expression> ')'
    fn pushExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'push'
        _ = try self.expect(.lparen, "expected '(' after 'push'");
        const list = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the list");
        const value = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the value to push");
        return self.createExpr(.{ .list_push = .{ .list = list, .value = value } });
    }

    /// <keys-expr> ::= 'keys' '(' <expression> ')'
    fn keysExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'keys'
        _ = try self.expect(.lparen, "expected '(' after 'keys'");
        const map = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the map");
        return self.createExpr(.{ .map_keys = map });
    }

    /// <has-expr> ::= 'has' '(' <expression> ',' <expression> ')'
    fn hasExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'has'
        _ = try self.expect(.lparen, "expected '(' after 'has'");
        const map = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the map");
        const key = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the key");
        return self.createExpr(.{ .map_has = .{ .map = map, .key = key } });
    }

    /// <delete-expr> ::= 'delete' '(' <expression> ',' <expression> ')'
    fn deleteExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'delete'
        _ = try self.expect(.lparen, "expected '(' after 'delete'");
        const map = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the map");
        const key = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the key");
        return self.createExpr(.{ .map_delete = .{ .map = map, .key = key } });
    }

    /// <json-expr> ::= 'json' '(' IDENTIFIER ',' <expression> ')'
    ///
    /// The buffer is a bare identifier, the same restriction `read`'s
    /// destination and `write`'s buffer form have and for the same reason:
    /// arrays still aren't first-class (GRAMMAR.bnf design note 3e).
    fn jsonExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'json'
        _ = try self.expect(.lparen, "expected '(' after 'json'");
        const name_tok = try self.expect(.identifier, "expected a buffer (array) name to parse");
        _ = try self.expect(.comma, "expected ',' after the buffer name");
        const count = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the byte count");
        return self.createExpr(.{ .json_parse = .{ .buffer = name_tok.lexeme, .count = count } });
    }

    /// <stringify-expr> ::= 'stringify' '(' <expression> ')'
    fn stringifyExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'stringify'
        _ = try self.expect(.lparen, "expected '(' after 'stringify'");
        const value = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the value to stringify");
        return self.createExpr(.{ .json_stringify = value });
    }

    /// <int-expr> ::= 'int' '(' <expression> ')'
    ///
    /// Reached only from `atom` (an expression-position `.kw_int`) — a
    /// statement-position `.kw_int` is `declaration`'s var-declaration
    /// dispatch instead, which never reaches here (GRAMMAR.bnf design note
    /// 3r: `int(x)` can't stand alone as a top-level statement).
    fn intParseExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'int'
        _ = try self.expect(.lparen, "expected '(' after 'int'");
        const value = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the value to parse");
        return self.createExpr(.{ .int_parse = value });
    }

    /// <float-expr> ::= 'float' '(' <expression> ')'
    fn floatParseExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'float'
        _ = try self.expect(.lparen, "expected '(' after 'float'");
        const value = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the value to parse");
        return self.createExpr(.{ .float_parse = value });
    }

    /// <getenv-expr> ::= 'getenv' '(' <expression> ')'
    ///
    /// Unlike `int`/`float` above, `getenv` is a keyword in expression
    /// position ONLY — nothing dispatches on it before expression parsing
    /// begins — so a bare `getenv("HOME")` is a legal (if pointless)
    /// <expr-stmt> too, the same as `keys(m)` is.
    fn getenvExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'getenv'
        _ = try self.expect(.lparen, "expected '(' after 'getenv'");
        const name = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the variable name");
        return self.createExpr(.{ .env_get = name });
    }

    /// <hasenv-expr> ::= 'hasenv' '(' <expression> ')'
    fn hasenvExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'hasenv'
        _ = try self.expect(.lparen, "expected '(' after 'hasenv'");
        const name = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the variable name");
        return self.createExpr(.{ .env_has = name });
    }

    /// <ord-expr> ::= 'ord' '(' <expression> ')'
    ///
    /// Like `getenv`/`hasenv` above, `ord` is a keyword in expression
    /// position only — it isn't also a <type> keyword, so a bare
    /// `ord("x")` is a legal (if pointless) <expr-stmt> too.
    fn ordExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'ord'
        _ = try self.expect(.lparen, "expected '(' after 'ord'");
        const value = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the value to convert");
        return self.createExpr(.{ .char_ord = value });
    }

    /// <chr-expr> ::= 'chr' '(' <expression> ')'
    ///
    /// Like `ord` above, `chr` is a keyword in expression position only —
    /// it isn't also a <type> keyword, so a bare `chr(65)` is a legal (if
    /// pointless) <expr-stmt> too.
    fn chrExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'chr'
        _ = try self.expect(.lparen, "expected '(' after 'chr'");
        const value = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the value to convert");
        return self.createExpr(.{ .char_chr = value });
    }

    /// <join-expr> ::= 'join' '(' <expression> ',' <expression> ')'
    ///
    /// Like `has`/`delete` above, `join` is a keyword in expression
    /// position only — it isn't also a <type> keyword, so a bare
    /// `join(xs, ",")` is a legal (if pointless) <expr-stmt> too.
    fn joinExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'join'
        _ = try self.expect(.lparen, "expected '(' after 'join'");
        const list = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the list");
        const sep = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the separator");
        return self.createExpr(.{ .list_join = .{ .list = list, .sep = sep } });
    }

    /// <exists-expr> ::= 'exists' '(' <expression> ')'
    fn existsExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'exists'
        _ = try self.expect(.lparen, "expected '(' after 'exists'");
        const path = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the path");
        return self.createExpr(.{ .path_exists = path });
    }

    /// <list-dir-expr> ::= 'listDir' '(' <expression> ')'
    fn listDirExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'listDir'
        _ = try self.expect(.lparen, "expected '(' after 'listDir'");
        const path = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the path");
        return self.createExpr(.{ .list_dir = path });
    }

    /// <remove-expr> ::= 'remove' '(' <expression> ')'
    fn removeExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'remove'
        _ = try self.expect(.lparen, "expected '(' after 'remove'");
        const path = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the path");
        return self.createExpr(.{ .path_remove = path });
    }

    /// <rename-expr> ::= 'rename' '(' <expression> ',' <expression> ')'
    fn renameExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'rename'
        _ = try self.expect(.lparen, "expected '(' after 'rename'");
        const from = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the source path");
        const to = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the destination path");
        return self.createExpr(.{ .path_rename = .{ .from = from, .to = to } });
    }

    /// <mkdir-expr> ::= 'mkdir' '(' <expression> ')'
    fn mkdirExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'mkdir'
        _ = try self.expect(.lparen, "expected '(' after 'mkdir'");
        const path = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the path");
        return self.createExpr(.{ .path_mkdir = path });
    }

    /// <exec-expr> ::= 'exec' '(' <expression> ',' <expression> ')'
    ///
    /// Like `getenv`/`exists`/`rename`, `exec` is a keyword in expression
    /// position ONLY — nothing dispatches on it before expression parsing
    /// begins — so a bare `exec("true", [])` is a legal (if pointless)
    /// <expr-stmt> too.
    fn execExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'exec'
        _ = try self.expect(.lparen, "expected '(' after 'exec'");
        const command = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the command");
        const args = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the argument list");
        return self.createExpr(.{ .exec = .{ .command = command, .args = args } });
    }

    /// <now-expr> ::= 'now' '(' ')'
    ///
    /// Like `getenv`/`exists`/`exec`, `now` is a keyword in expression
    /// position ONLY — nothing dispatches on it before expression parsing
    /// begins — so a bare `now()` is a legal (if pointless) <expr-stmt> too.
    /// Unlike every other special form here, it takes no operand at all: the
    /// parens are still required (matching call syntax generally), just
    /// always empty.
    fn nowExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'now'
        _ = try self.expect(.lparen, "expected '(' after 'now'");
        _ = try self.expect(.rparen, "'now' takes no arguments; expected ')'");
        return self.createExpr(.time_now);
    }

    /// <random-expr> ::= 'random' '(' ')' | 'random' '(' <expression> ',' <expression> ')'
    ///
    /// Two forms distinguished purely by argument count, exactly the way
    /// `writeExpr` tells its two forms apart: an empty argument list is the
    /// `[0, 1)` float form, anything else must be exactly `start, end`.
    fn randomExpr(self: *Parser) Error!*ast.Expr {
        _ = self.advance(); // 'random'
        _ = try self.expect(.lparen, "expected '(' after 'random'");
        if (self.match(.rparen)) return self.createExpr(.random_float);

        const start = try self.expression();
        _ = try self.expect(.comma, "expected ',' after the range's start, or ')' to call random() with no arguments");
        const end = try self.expression();
        _ = try self.expect(.rparen, "expected ')' after the range's end");
        return self.createExpr(.{ .random_range = .{ .start = start, .end = end } });
    }
};

// ---- Tests --------------------------------------------------------------

fn parseExprSource(allocator: std.mem.Allocator, source: []const u8) !struct { parser: Parser, expr: *ast.Expr } {
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const expr = try parser.expression();
    return .{ .parser = parser, .expr = expr };
}

fn expectExprSexpr(source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var result = try parseExprSource(allocator, source);
    defer result.parser.deinit();

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try ast.printExpr(&writer, result.expr);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "parses precedence: multiplication binds tighter than addition" {
    try expectExprSexpr("1 + 2 * 3", "(+ 1 (* 2 3))");
}

test "parses precedence: exponent binds tighter than multiplication and addition (left-associative)" {
    try expectExprSexpr("2 ** 3 ** 2", "(** (** 2 3) 2)");
    try expectExprSexpr("3 + 2 ** 2", "(+ 3 (** 2 2))");
    try expectExprSexpr("2 * 3 ** 2", "(* 2 (** 3 2))");
}

test "parses precedence: comparison binds tighter than equality" {
    try expectExprSexpr("1 < 2 == 3 < 4", "(== (< 1 2) (< 3 4))");
}

test "parses precedence: and binds tighter than or" {
    try expectExprSexpr("true or false and true", "(or true (and false true))");
}

test "unary chains arbitrarily (grammar fix a)" {
    try expectExprSexpr("!!true", "(! (! true))");
    try expectExprSexpr("--5", "(- (- 5))");
}

test "grouping overrides precedence" {
    try expectExprSexpr("(1 + 2) * 3", "(* (group (+ 1 2)) 3)");
}

test "assignment is right-associative and targets an identifier" {
    try expectExprSexpr("x := y := 1", "(:= x (:= y 1))");
}

test "assignment to a non-identifier is a parse error (design note b)" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("1 + 2 := 3");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.expression());
    try std.testing.expect(parser.diagnostic != null);
}

fn parseProgramSource(allocator: std.mem.Allocator, source: []const u8) !struct { parser: Parser, program: ast.Program } {
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    const program = try parser.parseProgram();
    return .{ .parser = parser, .program = program };
}

test "parses a variable declaration with an initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "int x := 5\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    const decl = result.program[0].kind.var_decl;
    try std.testing.expectEqual(ast.ValueType.int, decl.type);
    try std.testing.expectEqualStrings("x", decl.name);
    try std.testing.expect(decl.initializer != null);
    try std.testing.expectEqual(@as(i64, 5), decl.initializer.?.literal.int);
}

test "variable declaration without an initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "bool flag\n");
    defer result.parser.deinit();

    const decl = result.program[0].kind.var_decl;
    try std.testing.expectEqual(ast.ValueType.bool, decl.type);
    try std.testing.expect(decl.initializer == null);
}

test "a single-line block does not require a newline after '{' (grammar fix d)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "{ print 1 }");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    const block = result.program[0].kind.block;
    try std.testing.expectEqual(@as(usize, 1), block.len);
    try std.testing.expectEqual(@as(i64, 1), block[0].kind.print_stmt.literal.int);
}

test "if/else with single-line blocks on one logical statement (grammar fix d)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "if x { print 1 } else { print 2 }");
    defer result.parser.deinit();

    const if_stmt = result.program[0].kind.if_stmt;
    try std.testing.expectEqualStrings("x", if_stmt.condition.variable);
    try std.testing.expectEqual(@as(i64, 1), if_stmt.then_branch.kind.block[0].kind.print_stmt.literal.int);
    try std.testing.expectEqual(@as(i64, 2), if_stmt.else_branch.?.kind.block[0].kind.print_stmt.literal.int);
}

test "else if chains without a dedicated elif keyword (design note c)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\if a print 1
        \\else if b print 2
        \\else print 3
    );
    defer result.parser.deinit();

    const outer = result.program[0].kind.if_stmt;
    try std.testing.expectEqualStrings("a", outer.condition.variable);
    const inner = outer.else_branch.?.kind.if_stmt;
    try std.testing.expectEqualStrings("b", inner.condition.variable);
    try std.testing.expectEqual(@as(i64, 3), inner.else_branch.?.kind.print_stmt.literal.int);
}

test "while loop parses condition and a block body" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\while x {
        \\  print x
        \\}
    );
    defer result.parser.deinit();

    const while_stmt = result.program[0].kind.while_stmt;
    try std.testing.expectEqualStrings("x", while_stmt.condition.variable);
    try std.testing.expectEqual(@as(usize, 1), while_stmt.body.kind.block.len);
}

test "blank lines are allowed before the first declaration (grammar fix e)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "\n\n\nprint 1\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
}

test "blank lines are allowed between declarations" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "print 1\n\n\nprint 2\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.program.len);
}

test "two statements may not share a line" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("print 1 print 2");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "unclosed block is a parse error" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("{ print 1\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
    const diag = parser.diagnostic.?;
    try std.testing.expectEqualStrings("expected '}' to close block", diag.message);
}

test "a full program with nested control flow" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\int total := 0
        \\int i := 0
        \\while i < 10 {
        \\    if i % 2 == 0 {
        \\        total := total + i
        \\    }
        \\    i := i + 1
        \\}
        \\print total
    );
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.program.len);
    try std.testing.expectEqual(ast.ValueType.int, result.program[0].kind.var_decl.type);
    try std.testing.expectEqual(ast.ValueType.int, result.program[1].kind.var_decl.type);

    const while_stmt = result.program[2].kind.while_stmt;
    try std.testing.expectEqual(ast.BinaryOp.lt, while_stmt.condition.binary.op);

    const while_body = while_stmt.body.kind.block;
    try std.testing.expectEqual(@as(usize, 2), while_body.len);
    try std.testing.expectEqual(ast.BinaryOp.mod, while_body[0].kind.if_stmt.condition.binary.left.binary.op);

    try std.testing.expectEqualStrings("total", result.program[3].kind.print_stmt.variable);
}

test "parses a function declaration with parameters and a return type" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func add(int a, int b) -> int {
        \\    return a + b
        \\}
    );
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    const f = result.program[0].kind.function_decl;
    try std.testing.expectEqualStrings("add", f.name);
    try std.testing.expectEqual(ast.ValueType.int, f.return_type);
    try std.testing.expectEqual(@as(usize, 2), f.params.len);
    try std.testing.expectEqual(ast.ValueType.int, f.params[0].type);
    try std.testing.expectEqualStrings("a", f.params[0].name);
    try std.testing.expectEqualStrings("b", f.params[1].name);
    try std.testing.expectEqual(@as(usize, 1), f.body.len);
    try std.testing.expectEqualStrings("a", f.body[0].kind.return_stmt.binary.left.variable);
}

test "parses a function with an array parameter and an array return type" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func first(int[3] arr) -> int {
        \\    return arr[0]
        \\}
        \\func pair() -> int[2] {
        \\    return arr
        \\}
    );
    defer result.parser.deinit();

    const first = result.program[0].kind.function_decl;
    try std.testing.expectEqual(@as(usize, 1), first.params.len);
    try std.testing.expectEqual(@as(u32, 3), first.params[0].array_size.?.fixed);
    try std.testing.expectEqual(@as(?ast.ArraySpec, null), first.return_array_size);

    const pair = result.program[1].kind.function_decl;
    try std.testing.expectEqual(@as(usize, 0), pair.params.len);
    try std.testing.expectEqual(@as(u32, 2), pair.return_array_size.?.fixed);
    try std.testing.expectEqual(ast.ValueType.int, pair.return_type);
}

test "parses a generic array parameter and a generic array return type" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func sum(int[] arr) -> int {
        \\    return len(arr)
        \\}
        \\func identity(int[] arr) -> int[] {
        \\    return arr
        \\}
    );
    defer result.parser.deinit();

    const sum_fn = result.program[0].kind.function_decl;
    try std.testing.expectEqual(ast.ArraySpec.generic, sum_fn.params[0].array_size.?);
    try std.testing.expectEqual(@as(?ast.ArraySpec, null), sum_fn.return_array_size);

    const identity_fn = result.program[1].kind.function_decl;
    try std.testing.expectEqual(ast.ArraySpec.generic, identity_fn.params[0].array_size.?);
    try std.testing.expectEqual(ast.ArraySpec.generic, identity_fn.return_array_size.?);
}

test "a function with no parameters parses an empty param list" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func answer() -> int {
        \\    return 42
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].kind.function_decl;
    try std.testing.expectEqual(@as(usize, 0), f.params.len);
}

test "function declarations are only recognized at the top level" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init(
        \\if true {
        \\    func nested() -> int {
        \\        return 1
        \\    }
        \\}
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    // `declaration` (used inside if/while/block bodies) never dispatches on
    // 'func', so this is a parse error rather than a nested function decl.
    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "parses a call expression with arguments" {
    try expectExprSexpr("add(1, 2)", "(call add 1 2)");
}

test "parses a call expression with no arguments" {
    try expectExprSexpr("answer()", "(call answer)");
}

test "call arguments may themselves be arbitrary expressions" {
    try expectExprSexpr("add(1 + 2, fib(n - 1))", "(call add (+ 1 2) (call fib (- n 1)))");
}

test "a bare identifier not followed by '(' is still a variable reference" {
    try expectExprSexpr("x", "x");
}

test "parses a fixed-size array declaration" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "int[3] arr\n");
    defer result.parser.deinit();

    const decl = result.program[0].kind.var_decl;
    try std.testing.expectEqual(ast.ValueType.int, decl.type);
    try std.testing.expectEqual(@as(?u32, 3), decl.array_len);
    try std.testing.expectEqualStrings("arr", decl.name);
    try std.testing.expect(decl.initializer == null);
}

test "parses an array declaration with a literal initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "int[3] arr := [1, 2, 3]\n");
    defer result.parser.deinit();

    const decl = result.program[0].kind.var_decl;
    try std.testing.expectEqual(@as(?u32, 3), decl.array_len);
    const lit = decl.initializer.?.array_literal;
    try std.testing.expectEqual(@as(usize, 3), lit.len);
    try std.testing.expectEqual(@as(i64, 2), lit[1].literal.int);
}

test "a plain scalar declaration has a null array_len" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "int x := 5\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(?u32, null), result.program[0].kind.var_decl.array_len);
}

test "parses array indexing" {
    try expectExprSexpr("arr[0]", "(index arr 0)");
}

test "array index may be an arbitrary expression" {
    try expectExprSexpr("arr[i + 1]", "(index arr (+ i 1))");
}

test "parses an array literal expression" {
    try expectExprSexpr("[1, 2, 3]", "(array 1 2 3)");
}

test "parses an empty array literal" {
    try expectExprSexpr("[]", "(array)");
}

test "parses indexed assignment" {
    try expectExprSexpr("arr[0] := 9", "(:= (index arr 0) 9)");
}

test "parses a string slice" {
    try expectExprSexpr("s[1..4]", "(slice s 1 4)");
}

test "a slice's bounds may be arbitrary expressions" {
    try expectExprSexpr("s[i..i + 1]", "(slice s i (+ i 1))");
}

test "slicing chains off any expression, not just a bare identifier" {
    try expectExprSexpr("s[0..2][0..1]", "(slice (slice s 0 2) 0 1)");
}

test "a slice is not a valid assignment target" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("s[0..1] := \"x\"\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();
    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

// ---- Maps, lists, and JSON (GRAMMAR.bnf design notes 3m/3n) -------------

test "parses a map declaration with no initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "map m\n");
    defer result.parser.deinit();

    const decl = result.program[0].kind.var_decl;
    try std.testing.expectEqual(ast.ValueType.map, decl.type);
    try std.testing.expectEqual(@as(?u32, null), decl.array_len);
    try std.testing.expect(decl.initializer == null);
}

test "parses a list declaration with an array-literal initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "list xs := [1, 2, 3]\n");
    defer result.parser.deinit();

    const decl = result.program[0].kind.var_decl;
    try std.testing.expectEqual(ast.ValueType.list, decl.type);
    try std.testing.expectEqual(@as(usize, 3), decl.initializer.?.array_literal.len);
}

test "map/list never take an array-size suffix" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("map[3] m\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "parses an empty map literal" {
    try expectExprSexpr("{}", "(map)");
}

test "parses a map literal with string keys" {
    try expectExprSexpr(
        \\{"a": 1, "b": 2}
    , "(map (\"a\" 1) (\"b\" 2))");
}

test "parses push/keys/has/delete/json/stringify as expressions" {
    try expectExprSexpr("push(xs, 1)", "(push xs 1)");
    try expectExprSexpr("keys(m)", "(keys m)");
    try expectExprSexpr("has(m, \"a\")", "(has m \"a\")");
    try expectExprSexpr("delete(m, \"a\")", "(delete m \"a\")");
    try expectExprSexpr("json(buf, n)", "(json buf n)");
    try expectExprSexpr("stringify(m)", "(stringify m)");
}

test "parses int(...)/float(...) as expressions, reusing the type keywords" {
    try expectExprSexpr("int(s)", "(int s)");
    try expectExprSexpr("float(s)", "(float s)");
    try expectExprSexpr("int(\"42\")", "(int \"42\")");
}

test "int(...)/float(...)'s argument may be an arbitrary expression" {
    try expectExprSexpr("int(s[0..2])", "(int (slice s 0 2))");
    try expectExprSexpr("float(a + b)", "(float (+ a b))");
}

test "int(x) cannot stand alone as a top-level statement (design note 3r)" {
    // 'int' at statement position is always the START of a var-declaration
    // (declaration()'s dispatch on kw_int); it never reaches intParseExpr,
    // so this fails past the missing variable name rather than parsing a
    // call.
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("int(x)\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "int(...)/float(...) work fine nested inside a statement" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "print int(\"42\")\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("42", result.program[0].kind.print_stmt.int_parse.literal.string);
}

test "parses getenv(...)/hasenv(...) as expressions" {
    try expectExprSexpr("getenv(\"HOME\")", "(getenv \"HOME\")");
    try expectExprSexpr("hasenv(\"HOME\")", "(hasenv \"HOME\")");
    try expectExprSexpr("getenv(name)", "(getenv name)");
    try expectExprSexpr("getenv(\"BUTTER_\" + suffix)", "(getenv (+ \"BUTTER_\" suffix))");
}

test "parses ord(...) as an expression" {
    try expectExprSexpr("ord(\"A\")", "(ord \"A\")");
    try expectExprSexpr("ord(s)", "(ord s)");
}

test "ord(x) CAN stand alone as a top-level statement, unlike int(x)" {
    // Same reasoning as getenv(x) above: 'ord' isn't also a <type>
    // keyword, so nothing dispatches on it before expression parsing
    // begins.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "ord(\"A\")\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("A", result.program[0].kind.expr_stmt.char_ord.literal.string);
}

test "parses chr(...) as an expression" {
    try expectExprSexpr("chr(65)", "(chr 65)");
    try expectExprSexpr("chr(n)", "(chr n)");
}

test "chr(x) CAN stand alone as a top-level statement, unlike int(x)" {
    // Same reasoning as ord(x) above: 'chr' isn't also a <type> keyword,
    // so nothing dispatches on it before expression parsing begins.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "chr(65)\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqual(@as(i64, 65), result.program[0].kind.expr_stmt.char_chr.literal.int);
}

test "parses join(...) as an expression" {
    try expectExprSexpr("join(xs, \",\")", "(join xs \",\")");
    try expectExprSexpr("join(xs, sep)", "(join xs sep)");
}

test "join(xs, sep) CAN stand alone as a top-level statement, unlike int(x)" {
    // Same reasoning as ord(x) above: 'join' isn't also a <type> keyword,
    // so nothing dispatches on it before expression parsing begins.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "join(xs, \",\")\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("xs", result.program[0].kind.expr_stmt.list_join.list.variable);
    try std.testing.expectEqualStrings(",", result.program[0].kind.expr_stmt.list_join.sep.literal.string);
}

test "getenv(x) CAN stand alone as a top-level statement, unlike int(x)" {
    // Nothing dispatches on kw_getenv before expression parsing begins (it
    // isn't a <type> keyword the way `int`/`float` are), so this reaches
    // exprStatement and parses as an ordinary discarded expression.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "getenv(\"HOME\")\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("HOME", result.program[0].kind.expr_stmt.env_get.literal.string);
}

test "parses exists(...)/listDir(...)/remove(...)/rename(...)/mkdir(...) as expressions" {
    try expectExprSexpr("exists(\"a.txt\")", "(exists \"a.txt\")");
    try expectExprSexpr("listDir(\"dir\")", "(listDir \"dir\")");
    try expectExprSexpr("remove(\"a.txt\")", "(remove \"a.txt\")");
    try expectExprSexpr("rename(\"a.txt\", \"b.txt\")", "(rename \"a.txt\" \"b.txt\")");
    try expectExprSexpr("mkdir(\"dir\")", "(mkdir \"dir\")");
    try expectExprSexpr("exists(dir + \"/a.txt\")", "(exists (+ dir \"/a.txt\"))");
}

test "exists(x)/listDir(x)/remove(x)/rename(x, y)/mkdir(x) CAN each stand alone as a top-level statement" {
    // None of `exists`/`listDir`/`remove`/`rename`/`mkdir` is a <type>
    // keyword, so (like `getenv`) nothing dispatches on them before
    // expression parsing begins — each reaches exprStatement and parses as
    // an ordinary discarded expression.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "exists(\"a\")\nlistDir(\"a\")\nremove(\"a\")\nrename(\"a\", \"b\")\nmkdir(\"a\")\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 5), result.program.len);
}

test "parses exec(...) as an expression" {
    try expectExprSexpr("exec(\"true\", [])", "(exec \"true\" (array))");
    try expectExprSexpr("exec(cmd, argv)", "(exec cmd argv)");
    try expectExprSexpr("exec(\"echo\", [\"hi\"])", "(exec \"echo\" (array \"hi\"))");
}

test "exec(x, y) CAN stand alone as a top-level statement, unlike int(x)" {
    // Same reasoning as getenv/exists/rename above: `exec` isn't a <type>
    // keyword, so nothing dispatches on it before expression parsing
    // begins.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "exec(\"true\", [])\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("true", result.program[0].kind.expr_stmt.exec.command.literal.string);
}

test "parses now()/random()/random(a, b) as expressions" {
    try expectExprSexpr("now()", "(now)");
    try expectExprSexpr("random()", "(random)");
    try expectExprSexpr("random(0, 10)", "(random 0 10)");
    try expectExprSexpr("random(lo, hi)", "(random lo hi)");
}

test "now()/random() CAN stand alone as a top-level statement, unlike int(x)" {
    // Neither `now` nor `random` is a <type> keyword, so (like `getenv`)
    // nothing dispatches on them before expression parsing begins.
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "now()\nrandom()\nrandom(0, 1)\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.program.len);
}

test "now() requires empty parens" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("now(1)\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "random(a) with exactly one argument is a parse error" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("random(1)\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "'listDir' without '(' is a parse error, not a bare identifier" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("listDir\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "parses 'null' as a literal" {
    try expectExprSexpr("null", "null");
}

test "bracket indexing chains off any expression, not just a bare identifier" {
    try expectExprSexpr("doc[\"a\"][\"b\"]", "(index (index doc \"a\") \"b\")");
}

test "chained indexing may be an assignment target" {
    try expectExprSexpr("doc[\"a\"][\"b\"] := 1", "(:= (index (index doc \"a\") \"b\") 1)");
}

test "a lone '{' after an expression position starts a map literal, not a block" {
    // Never ambiguous with <block>: a block is only ever reached in
    // statement position (declaration/if/while/for/function bodies), a map
    // literal only in expression position — this exercises the latter.
    try expectExprSexpr("push(xs, {})", "(push xs (map))");
}

test "parses a for loop over a range" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\for i in 0..3 {
        \\    print i
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].kind.for_stmt;
    try std.testing.expectEqualStrings("i", f.var_name);
    try std.testing.expectEqual(@as(i64, 0), f.start.literal.int);
    try std.testing.expectEqual(@as(i64, 3), f.end.literal.int);
    try std.testing.expectEqual(@as(usize, 1), f.body.kind.block.len);
}

test "parses len(...) with a bare array name" {
    try expectExprSexpr("len(arr)", "(len arr)");
}

test "len(...) accepts an arbitrary expression, not just a bare identifier (design note 3m)" {
    // Relaxed once a map/list made `len`'s argument a genuine runtime value
    // in the general case — a bare array name still gets special
    // compile-time treatment (ISA.bnf section 2), but that's now a
    // compiler-level pattern match on the parsed shape, not a parser-level
    // restriction. Whether `len(1 + 2)` is actually valid at RUNTIME (it
    // isn't — TypeMismatch, since an int isn't a list or a map) is a
    // compiler.zig-level concern, not this one.
    try expectExprSexpr("len(1 + 2)", "(len (+ 1 2))");
}

test "parses read(...) with each stream and a bare buffer name" {
    try expectExprSexpr("read(stdin, buf)", "(read stdin buf)");
}

test "parses the two-argument write(...) value form" {
    try expectExprSexpr("write(stdout, 1 + 2)", "(write stdout (+ 1 2))");
    try expectExprSexpr("write(stderr, \"oops\")", "(write stderr \"oops\")");
}

test "parses the three-argument write(...) buffer form" {
    try expectExprSexpr("write(stdout, buf, n)", "(write stdout buf n)");
}

test "read/write are expressions, so their result is usable" {
    try expectExprSexpr("read(stdin, buf) > 0", "(> (read stdin buf) 0)");
}

fn expectExprParseError(source: []const u8) !void {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.expression());
    try std.testing.expect(parser.diagnostic != null);
}

test "read/write's stream may be an arbitrary expression, not just a keyword" {
    // Since a stream is a value now (an `open`ed file is one), the parser
    // accepts any expression here; whether it actually IS a stream is a
    // runtime question the VM answers.
    try expectExprSexpr("read(f, buf)", "(read f buf)");
    try expectExprSexpr("write(files[0], 1)", "(write (index files 0) 1)");
}

test "read's destination must be a bare identifier, not an expression" {
    try expectExprParseError("read(stdin, buf[0])");
    try expectExprParseError("read(stdin, 1 + 2)");
}

test "the three-argument write's buffer must be a bare array name" {
    try expectExprParseError("write(stdout, 1 + 2, 3)");
}

test "a stream name is an expression in its own right" {
    try expectExprSexpr("stdout", "stdout");
    try expectExprSexpr("stdin", "stdin");
    try expectExprSexpr("stderr", "stderr");
}

test "'args' is a bare expression, like the stream names" {
    try expectExprSexpr("args", "args");
    try expectExprSexpr("len(args)", "(len args)");
    try expectExprSexpr("args[0]", "(index args 0)");
}

test "parses open(...) in each mode" {
    try expectExprSexpr("open(\"f.txt\", read)", "(open \"f.txt\" read)");
    try expectExprSexpr("open(\"f.txt\", write)", "(open \"f.txt\" write)");
    try expectExprSexpr("open(\"f.txt\", append)", "(open \"f.txt\" append)");
}

test "open's path may be an arbitrary expression, but its mode may not" {
    try expectExprSexpr("open(name, read)", "(open name read)");
    try expectExprParseError("open(\"f.txt\", banana)");
    try expectExprParseError("open(\"f.txt\")");
}

test "an opened file is usable directly as read/write's stream" {
    try expectExprSexpr("read(open(\"f.txt\", read), buf)", "(read (open \"f.txt\" read) buf)");
}

test "parses close as a statement" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "close f\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("f", result.program[0].kind.close_stmt.variable);
}

test "parses exit as a statement" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "exit 1\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqual(@as(i64, 1), result.program[0].kind.exit_stmt.literal.int);
}

test "exit takes an arbitrary expression, not just a literal" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "exit code + 1\n");
    defer result.parser.deinit();

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try ast.printProgram(&writer, result.program);
    try std.testing.expectEqualStrings("(exit (+ code 1))\n", writer.buffered());
}

test "parses an import declaration" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "import \"util.butter\"\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("util.butter", result.program[0].kind.import_stmt.path);
}

// ---- String escape sequences (GRAMMAR.bnf design note 3s) --------------

test "a string literal with no backslash is unaffected" {
    var result = try parseProgramSource(std.testing.allocator, "print \"hello\"\n");
    defer result.parser.deinit();
    try std.testing.expectEqualStrings("hello", result.program[0].kind.print_stmt.literal.string);
}

test "decodes \\n, \\t, \\\\, and \\\" in a string literal" {
    var result = try parseProgramSource(std.testing.allocator,
        \\print "a\nb\tc\\d\"e"
        \\
    );
    defer result.parser.deinit();
    try std.testing.expectEqualStrings("a\nb\tc\\d\"e", result.program[0].kind.print_stmt.literal.string);
}

test "an escaped quote inside a string literal is decoded, not a terminator" {
    var result = try parseProgramSource(std.testing.allocator,
        \\print "say \"hi\""
        \\
    );
    defer result.parser.deinit();
    try std.testing.expectEqualStrings("say \"hi\"", result.program[0].kind.print_stmt.literal.string);
}

test "escapes decode in an import path the same as in an ordinary string literal" {
    var result = try parseProgramSource(std.testing.allocator,
        \\import "a\tb.butter"
        \\
    );
    defer result.parser.deinit();
    try std.testing.expectEqualStrings("a\tb.butter", result.program[0].kind.import_stmt.path);
}

test "escapes decode in a map-literal string key" {
    try expectExprSexpr(
        \\{"a\nb": 1}
    ,
        \\(map ("a
        \\b" 1))
    );
}

// ---- String interpolation (GRAMMAR.bnf design note 3ae) ----------------

test "a string with no '$' at all parses as a plain literal, unaffected" {
    var result = try parseProgramSource(std.testing.allocator, "print \"hello\"\n");
    defer result.parser.deinit();
    try std.testing.expect(result.program[0].kind.print_stmt.* == .literal);
    try std.testing.expectEqualStrings("hello", result.program[0].kind.print_stmt.literal.string);
}

test "a lone '$' or an escaped '\\$' never produces interpolation" {
    try expectExprSexpr(
        \\"$5 and \$6"
    ,
        \\"$5 and $6"
    );
}

test "parses a single interpolation into literal/expr/literal parts" {
    try expectExprSexpr(
        \\"hello ${name}!"
    ,
        \\(interp "hello " name "!")
    );
}

test "an interpolation glued to the quotes produces empty literal parts" {
    try expectExprSexpr(
        \\"${x}"
    ,
        \\(interp "" x "")
    );
}

test "multiple interpolations in one string" {
    try expectExprSexpr(
        \\"${a} + ${b} = ${a + b}"
    ,
        \\(interp "" a " + " b " = " (+ a b) "")
    );
}

test "an interpolation's inner text is parsed as a full expression, not just a name" {
    try expectExprSexpr(
        \\"sum: ${1 + 2 * 3}"
    ,
        \\(interp "sum: " (+ 1 (* 2 3)) "")
    );
}

test "nested '{'/'}' (a map literal) inside an interpolation nest correctly" {
    try expectExprSexpr(
        \\"${ {"a": 1}["a"] }"
    ,
        \\(interp "" (index (map ("a" 1)) "a") "")
    );
}

test "interpolation nests arbitrarily deep — a string inside '${...}' may itself interpolate" {
    try expectExprSexpr(
        \\"${ "${x}" }"
    ,
        \\(interp "" (interp "" x "") "")
    );
}

test "a syntax error inside '${...}' is a parse error" {
    try expectExprParseError(
        \\"bad: ${1 +}"
    );
}

test "trailing tokens after the expression inside '${...}' are a parse error" {
    try expectExprParseError(
        \\"bad: ${1 2}"
    );
}

test "a call, indexing, and field access all work inside an interpolation" {
    try expectExprSexpr(
        \\"${len(xs)} ${xs[0]} ${p.field}"
    ,
        \\(interp "" (len xs) " " (index xs 0) " " (. p field) "")
    );
}

test "a plain function declaration is not exported" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "func f() -> int { return 1 }\n");
    defer result.parser.deinit();

    try std.testing.expect(!result.program[0].kind.function_decl.exported);
}

test "'export' before 'func' marks the function exported" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "export func f() -> int { return 1 }\n");
    defer result.parser.deinit();

    try std.testing.expect(result.program[0].kind.function_decl.exported);
}

test "'export' before anything other than 'func' is a parse error" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init("export int x\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "import is only recognized at the top level" {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init(
        \\if true {
        \\    import "nope.butter"
        \\}
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

// ---- try/catch (design note 3u) -------------------------------------

/// Parses `source` as a whole program and asserts its FIRST statement
/// renders as `expected`. Unlike `expectExprSexpr`, statements can't be
/// parsed standalone, and a try/catch is too many lines to assert field by
/// field without losing sight of the shape.
fn expectFirstStmtSexpr(source: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, source);
    defer result.parser.deinit();

    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try ast.printStmt(&writer, &result.program[0], 0);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn expectParseError(source: []const u8) !void {
    const allocator = std.testing.allocator;
    var lex = lexer.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = Parser.init(allocator, tokens);
    defer parser.deinit();

    try std.testing.expectError(Error.UnexpectedToken, parser.parseProgram());
}

test "parses a try/catch statement" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\try {
        \\    print 1
        \\} catch e {
        \\    print 2
        \\}
    );
    defer result.parser.deinit();

    const t = result.program[0].kind.try_stmt;
    try std.testing.expectEqual(@as(usize, 1), t.body.len);
    try std.testing.expectEqualStrings("e", t.error_var);
    try std.testing.expectEqual(@as(usize, 1), t.handler.len);
    try std.testing.expectEqual(@as(i64, 1), t.body[0].kind.print_stmt.literal.int);
    try std.testing.expectEqual(@as(i64, 2), t.handler[0].kind.print_stmt.literal.int);
}

test "printStmt renders a try/catch with both halves indented" {
    try expectFirstStmtSexpr(
        \\try {
        \\    print 1
        \\} catch e {
        \\    print 2
        \\}
    ,
        \\(try
        \\  (print 1)
        \\  (catch e
        \\    (print 2)))
    );
}

test "both halves of a try/catch may be empty" {
    try expectFirstStmtSexpr("try {} catch _ {}\n",
        \\(try
        \\  (catch _))
    );
}

test "'catch' may start its own line" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\try {
        \\    print 1
        \\}
        \\catch e {
        \\    print 2
        \\}
    );
    defer result.parser.deinit();

    try std.testing.expectEqualStrings("e", result.program[0].kind.try_stmt.error_var);
}

test "a try block's declarations parse like any other block's" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\try {
        \\    int x := 1
        \\    if x > 0 {
        \\        print x
        \\    }
        \\} catch e {
        \\    print e["message"]
        \\}
    );
    defer result.parser.deinit();

    const t = result.program[0].kind.try_stmt;
    try std.testing.expectEqual(@as(usize, 2), t.body.len);
    try std.testing.expectEqualStrings("x", t.body[0].kind.var_decl.name);
    try std.testing.expect(t.body[1].kind == .if_stmt);
    // The binding is an ordinary variable reference in the handler.
    const read = t.handler[0].kind.print_stmt.index;
    try std.testing.expectEqualStrings("e", read.base.variable);
    try std.testing.expectEqualStrings("message", read.index.literal.string);
}

test "try/catch nests" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\try {
        \\    try {
        \\        print 1
        \\    } catch inner {
        \\        print 2
        \\    }
        \\} catch outer {
        \\    print 3
        \\}
    );
    defer result.parser.deinit();

    const outer = result.program[0].kind.try_stmt;
    try std.testing.expectEqualStrings("outer", outer.error_var);
    try std.testing.expectEqualStrings("inner", outer.body[0].kind.try_stmt.error_var);
}

test "try/catch is legal inside a function body" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func f() -> int {
        \\    try {
        \\        return 1
        \\    } catch e {
        \\        return 0
        \\    }
        \\}
    );
    defer result.parser.deinit();

    try std.testing.expect(result.program[0].kind.function_decl.body[0].kind == .try_stmt);
}

test "a try block without braces is a parse error" {
    try expectParseError("try print 1\ncatch e {}\n");
}

test "a catch block without braces is a parse error" {
    try expectParseError("try { print 1 } catch e print 2\n");
}

test "a try with no catch is a parse error" {
    try expectParseError("try { print 1 }\n");
}

test "the caught error's binding is mandatory" {
    try expectParseError("try { print 1 } catch { print 2 }\n");
}

test "'try' and 'catch' are no longer usable as identifiers" {
    try expectParseError("int try := 1\n");
    try expectParseError("int catch := 1\n");
}

test "a for loop's range bounds may be arbitrary expressions" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\for i in start..(end + 1) {
        \\    print i
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].kind.for_stmt;
    try std.testing.expectEqualStrings("start", f.start.variable);
    try std.testing.expectEqualStrings("end", f.end.grouping.binary.left.variable);
}

test "parses a struct declaration with typed fields" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\struct Point {
        \\    int x,
        \\    int y
        \\}
    );
    defer result.parser.deinit();

    const s = result.program[0].kind.struct_decl;
    try std.testing.expectEqualStrings("Point", s.name);
    try std.testing.expect(!s.exported);
    try std.testing.expectEqual(@as(usize, 2), s.fields.len);
    try std.testing.expectEqual(ast.ValueType.int, s.fields[0].type);
    try std.testing.expectEqualStrings("x", s.fields[0].name);
    try std.testing.expectEqualStrings("y", s.fields[1].name);
}

test "a struct field may be another named (struct/enum) type" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\struct Line {
        \\    Point start,
        \\    Point end
        \\}
    );
    defer result.parser.deinit();

    const s = result.program[0].kind.struct_decl;
    try std.testing.expectEqual(ast.ValueType.named, s.fields[0].type);
    try std.testing.expectEqualStrings("Point", s.fields[0].named_type.?);
}

test "parses a function-type parameter, with its signature captured" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func apply(func(int, int) bool cmp, int a, int b) -> bool {
        \\    return cmp(a, b)
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].kind.function_decl;
    try std.testing.expectEqual(ast.ValueType.func, f.params[0].type);
    const sig = f.params[0].func_sig.?;
    try std.testing.expectEqual(@as(usize, 2), sig.param_types.len);
    try std.testing.expectEqual(ast.ValueType.int, sig.param_types[0]);
    try std.testing.expectEqual(ast.ValueType.int, sig.param_types[1]);
    try std.testing.expectEqual(ast.ValueType.bool, sig.return_type);
}

test "a top-level func-typed variable declaration is distinguished from a function declaration" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "func(int) bool matcher := isEven\n");
    defer result.parser.deinit();

    const d = result.program[0].kind.var_decl;
    try std.testing.expectEqual(ast.ValueType.func, d.type);
    try std.testing.expectEqualStrings("matcher", d.name);
    try std.testing.expectEqual(@as(usize, 1), d.func_sig.?.param_types.len);
}

test "a function type's parameters can't be struct/enum-typed" {
    try expectParseError("func(Point) bool wrong\n");
}

test "a function type's return type can't itself be function-typed" {
    try expectParseError("func() func(int) bool wrong\n");
}

test "a function cannot return a function type" {
    try expectParseError("func f() -> func(int) bool { return isEven }\n");
}

test "a struct field cannot be function-typed" {
    try expectParseError("struct S { func(int) bool f }\n");
}

test "'export' works on a struct declaration" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "export struct Point { int x, int y }\n");
    defer result.parser.deinit();

    try std.testing.expect(result.program[0].kind.struct_decl.exported);
}

test "parses an enum declaration with variants" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\enum Color {
        \\    Red,
        \\    Green,
        \\    Blue
        \\}
    );
    defer result.parser.deinit();

    const e = result.program[0].kind.enum_decl;
    try std.testing.expectEqualStrings("Color", e.name);
    try std.testing.expect(!e.exported);
    try std.testing.expectEqual(@as(usize, 3), e.variants.len);
    try std.testing.expectEqualStrings("Red", e.variants[0]);
    try std.testing.expectEqualStrings("Blue", e.variants[2]);
}

test "'export' works on an enum declaration" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "export enum Color { Red, Green }\n");
    defer result.parser.deinit();

    try std.testing.expect(result.program[0].kind.enum_decl.exported);
}

test "a struct/enum declaration allows a trailing comma" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "struct Point { int x, int y, }\nenum Color { Red, Green, }\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.program[0].kind.struct_decl.fields.len);
    try std.testing.expectEqual(@as(usize, 2), result.program[1].kind.enum_decl.variants.len);
}

test "a struct/enum field list may be separated by newlines alone, with no commas" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\struct Queue {
        \\    map items
        \\    int head
        \\    int tail
        \\}
        \\enum Color {
        \\    Red
        \\    Green
        \\    Blue
        \\}
    );
    defer result.parser.deinit();

    const s = result.program[0].kind.struct_decl;
    try std.testing.expectEqual(@as(usize, 3), s.fields.len);
    try std.testing.expectEqualStrings("items", s.fields[0].name);
    try std.testing.expectEqualStrings("head", s.fields[1].name);
    try std.testing.expectEqualStrings("tail", s.fields[2].name);

    const e = result.program[1].kind.enum_decl;
    try std.testing.expectEqual(@as(usize, 3), e.variants.len);
    try std.testing.expectEqualStrings("Red", e.variants[0]);
    try std.testing.expectEqualStrings("Blue", e.variants[2]);
}

test "a struct/enum field list may be separated by commas alone, on a single line" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "struct Point { int x, int y }\nenum Color { Red, Green, Blue }\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.program[0].kind.struct_decl.fields.len);
    try std.testing.expectEqual(@as(usize, 3), result.program[1].kind.enum_decl.variants.len);
}

test "a struct/enum field list may mix commas and newlines as separators" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\struct Point {
        \\    int x,
        \\    int y
        \\    int z,
        \\    int w
        \\}
        \\enum Color {
        \\    Red,
        \\    Green
        \\    Blue,
        \\    Yellow
        \\}
    );
    defer result.parser.deinit();

    const s = result.program[0].kind.struct_decl;
    try std.testing.expectEqual(@as(usize, 4), s.fields.len);
    try std.testing.expectEqualStrings("x", s.fields[0].name);
    try std.testing.expectEqualStrings("y", s.fields[1].name);
    try std.testing.expectEqualStrings("z", s.fields[2].name);
    try std.testing.expectEqualStrings("w", s.fields[3].name);

    const e = result.program[1].kind.enum_decl;
    try std.testing.expectEqual(@as(usize, 4), e.variants.len);
}

test "a struct/enum declaration allows a trailing comma followed by a newline before '}'" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\struct Point {
        \\    int x,
        \\    int y,
        \\}
        \\enum Color {
        \\    Red,
        \\    Green,
        \\}
    );
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.program[0].kind.struct_decl.fields.len);
    try std.testing.expectEqual(@as(usize, 2), result.program[1].kind.enum_decl.variants.len);
}

test "'export' requires 'func', 'struct', or 'enum'" {
    try expectParseError("export int x := 1\n");
}

test "parses a struct literal keyed by field name, any order" {
    try expectExprSexpr("Point{y: 2, x: 1}", "(struct Point (y 2) (x 1))");
}

test "a struct literal may span multiple lines with a trailing comma" {
    const allocator = std.testing.allocator;
    var result = try parseExprSource(allocator,
        \\Point{
        \\    x: 1,
        \\    y: 2,
        \\}
    );
    defer result.parser.deinit();

    try std.testing.expectEqualStrings("Point", result.expr.struct_literal.type_name);
    try std.testing.expectEqual(@as(usize, 2), result.expr.struct_literal.fields.len);
}

test "parses a field read, chainable like bracket-indexing" {
    try expectExprSexpr("p.x", "(. p x)");
    try expectExprSexpr("p.a.b", "(. (. p a) b)");
    try expectExprSexpr("xs[0].x", "(. (index xs 0) x)");
}

test "parses an enum variant reference using the same '.' syntax" {
    try expectExprSexpr("Color.Red", "(. Color Red)");
}

test "parses a field assignment" {
    try expectExprSexpr("p.x := 5", "(:= (. p x) 5)");
}

test "assigning to a non-lvalue field-ish shape still fails (e.g. a slice)" {
    try expectParseError("s[0..1] := \"x\"\n");
}

test "'if'/'while'/'for' with a bare-identifier condition/bound followed directly by '{' still parses as condition + block, not a struct literal" {
    const allocator = std.testing.allocator;

    var if_result = try parseProgramSource(allocator, "if flag {\n  print 1\n}\n");
    defer if_result.parser.deinit();
    try std.testing.expectEqualStrings("flag", if_result.program[0].kind.if_stmt.condition.variable);
    try std.testing.expectEqual(@as(i64, 1), if_result.program[0].kind.if_stmt.then_branch.kind.block[0].kind.print_stmt.literal.int);

    var while_result = try parseProgramSource(allocator, "while flag {\n  print 1\n}\n");
    defer while_result.parser.deinit();
    try std.testing.expectEqualStrings("flag", while_result.program[0].kind.while_stmt.condition.variable);

    var for_result = try parseProgramSource(allocator, "for i in 0..n {\n  print i\n}\n");
    defer for_result.parser.deinit();
    try std.testing.expectEqualStrings("n", for_result.program[0].kind.for_stmt.end.variable);
}

test "'if flag {}' (an empty body) is a bare identifier condition plus an empty block, not an empty struct literal" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "if flag {}\n");
    defer result.parser.deinit();

    const if_stmt = result.program[0].kind.if_stmt;
    try std.testing.expectEqualStrings("flag", if_stmt.condition.variable);
    try std.testing.expectEqual(@as(usize, 0), if_stmt.then_branch.kind.block.len);
}
