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

    /// <top-level-decl> ::= <import-decl> | [ 'export' ] <function-decl> | <declaration>
    ///
    /// Function declarations (and now `import`/`export`) are only
    /// recognized here, never from inside `declaration` — that's what keeps
    /// them out of block/if/while bodies without needing a separate check
    /// anywhere else (Butter has no nested functions or closures, and no
    /// mechanism for importing partway through another declaration).
    fn topLevelDeclaration(self: *Parser) Error!ast.Stmt {
        if (self.check(.kw_import)) return self.importDeclaration();
        if (self.match(.kw_export)) {
            if (!self.check(.kw_func)) return self.fail("expected 'func' after 'export' — only functions can be exported");
            return self.functionDeclaration(true);
        }
        if (self.check(.kw_func)) return self.functionDeclaration(false);
        return self.declaration();
    }

    /// <import-decl> ::= 'import' STRING <end>
    ///
    /// `path` is left exactly as written (quotes stripped, same as a string
    /// literal in `primary`) — resolving it to an actual file is the
    /// module loader's job (module.zig), not the parser's.
    fn importDeclaration(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'import'
        const path_tok = try self.expect(.string, "expected a file path string after 'import'");
        const path = path_tok.lexeme[1 .. path_tok.lexeme.len - 1];
        try self.consumeEnd();
        return ast.Stmt{ .import_stmt = .{ .path = path } };
    }

    // ---- <declaration> -------------------------------------------------

    fn declaration(self: *Parser) Error!ast.Stmt {
        return switch (self.peek().type) {
            .kw_int, .kw_float, .kw_bool, .kw_string => self.varDeclaration(),
            .lbrace => self.block(),
            .kw_if => self.ifStatement(),
            .kw_while => self.whileStatement(),
            .kw_for => self.forStatement(),
            else => self.statement(),
        };
    }

    /// <type> ::= 'int' | 'float' | 'bool' | 'string'
    fn parseType(self: *Parser) Error!ast.ValueType {
        const tok = self.peek();
        const value_type: ast.ValueType = switch (tok.type) {
            .kw_int => .int,
            .kw_float => .float,
            .kw_bool => .bool,
            .kw_string => .string,
            else => return self.fail("expected a type"),
        };
        _ = self.advance();
        return value_type;
    }

    /// <function-decl> ::= 'func' IDENTIFIER '(' [ <param-list> ] ')'
    ///                     '->' <type> <block>
    /// <param-list>    ::= <type> IDENTIFIER { ',' <type> IDENTIFIER }
    ///
    /// `exported` is whatever `topLevelDeclaration` determined from an
    /// optional leading 'export' keyword, which this function itself never
    /// looks at (the 'func' token must already be the current token).
    fn functionDeclaration(self: *Parser, exported: bool) Error!ast.Stmt {
        _ = self.advance(); // 'func'
        const name_tok = try self.expect(.identifier, "expected a function name");

        _ = try self.expect(.lparen, "expected '(' after function name");
        var params: std.ArrayList(ast.Param) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                const param_type = try self.parseType();
                const param_name = try self.expect(.identifier, "expected a parameter name");
                try params.append(self.allocator(), .{ .type = param_type, .name = param_name.lexeme });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after parameters");
        _ = try self.expect(.arrow, "expected '->' before return type");
        const return_type = try self.parseType();

        const body_stmt = try self.block();

        return ast.Stmt{ .function_decl = .{
            .name = name_tok.lexeme,
            .params = try params.toOwnedSlice(self.allocator()),
            .return_type = return_type,
            .body = body_stmt.block,
            .exported = exported,
        } };
    }

    /// <var-declaration> ::= <type> [ '[' INT ']' ] IDENTIFIER
    ///                       [ ':=' <expression> ] <end>
    fn varDeclaration(self: *Parser) Error!ast.Stmt {
        const value_type = try self.parseType();

        var array_len: ?u32 = null;
        if (self.match(.lbracket)) {
            const size_tok = try self.expect(.int, "expected an array size");
            array_len = std.fmt.parseInt(u32, size_tok.lexeme, 10) catch return self.fail("array size is too large");
            _ = try self.expect(.rbracket, "expected ']' after array size");
        }

        const name_tok = try self.expect(.identifier, "expected a variable name");

        var initializer: ?*ast.Expr = null;
        if (self.match(.colon_equal)) initializer = try self.expression();

        try self.consumeEnd();
        return ast.Stmt{ .var_decl = .{ .type = value_type, .array_len = array_len, .name = name_tok.lexeme, .initializer = initializer } };
    }

    /// <block> ::= '{' { NEWLINE } { <declaration> { NEWLINE } } '}'
    fn block(self: *Parser) Error!ast.Stmt {
        _ = try self.expect(.lbrace, "expected '{'");
        self.skipNewlines();

        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (!self.check(.rbrace) and !self.isAtEnd()) {
            try stmts.append(self.allocator(), try self.declaration());
            self.skipNewlines();
        }

        _ = try self.expect(.rbrace, "expected '}' to close block");
        return ast.Stmt{ .block = try stmts.toOwnedSlice(self.allocator()) };
    }

    /// <if-stmt> ::= 'if' <expression> <declaration> { NEWLINE } [ 'else' <declaration> ]
    fn ifStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'if'
        const condition = try self.expression();
        const then_branch = try self.createStmt(try self.declaration());

        self.skipNewlines();
        var else_branch: ?*ast.Stmt = null;
        if (self.match(.kw_else)) else_branch = try self.createStmt(try self.declaration());

        return ast.Stmt{ .if_stmt = .{ .condition = condition, .then_branch = then_branch, .else_branch = else_branch } };
    }

    /// <while-stmt> ::= 'while' <expression> <declaration>
    fn whileStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'while'
        const condition = try self.expression();
        const body = try self.createStmt(try self.declaration());
        return ast.Stmt{ .while_stmt = .{ .condition = condition, .body = body } };
    }

    /// <for-stmt> ::= 'for' IDENTIFIER 'in' <expression> '..' <expression> <declaration>
    ///
    /// Always ascending, always step 1, end exclusive — see GRAMMAR.bnf
    /// design note 3f. `start`/`end` are arbitrary expressions, each
    /// evaluated exactly once at loop entry (not re-evaluated per
    /// iteration), matching typical for-range semantics.
    fn forStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'for'
        const name_tok = try self.expect(.identifier, "expected a loop variable name");
        _ = try self.expect(.kw_in, "expected 'in' after loop variable");
        const start = try self.expression();
        _ = try self.expect(.dot_dot, "expected '..' in for-loop range");
        const end = try self.expression();
        const body = try self.createStmt(try self.declaration());
        return ast.Stmt{ .for_stmt = .{ .var_name = name_tok.lexeme, .start = start, .end = end, .body = body } };
    }

    // ---- <statement> ---------------------------------------------------

    fn statement(self: *Parser) Error!ast.Stmt {
        if (self.check(.kw_print)) return self.printStatement();
        if (self.check(.kw_return)) return self.returnStatement();
        return self.exprStatement();
    }

    /// <print-stmt> ::= 'print' <expression> <end>
    fn printStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'print'
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .print_stmt = value };
    }

    /// <return-stmt> ::= 'return' <expression> <end>
    fn returnStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'return'
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .return_stmt = value };
    }

    /// <expr-stmt> ::= <expression> <end>
    fn exprStatement(self: *Parser) Error!ast.Stmt {
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .expr_stmt = value };
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
                return self.createExpr(.{ .index_assign = .{ .name = expr.index.name, .index = expr.index.index, .value = value } });
            }

            self.diagnostic = .{ .line = equals.line, .column = equals.column, .message = "invalid assignment target: only a bare identifier or an indexed array element may appear left of ':='" };
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

    /// <comparison> ::= <exponent> { ( '>' | '>=' | '<' | '<=' ) <exponent> }
    fn comparison(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(exponent, &.{
            .{ .token = .greater, .op = .gt },
            .{ .token = .greater_equal, .op = .gte },
            .{ .token = .less, .op = .lt },
            .{ .token = .less_equal, .op = .lte },
        });
    }

    /// <exponent> ::= <addition> { '**' <addition> }
    fn exponent(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(addition, &.{
            .{ .token = .star_star, .op = .pow },
        });
    }

    /// <addition> ::= <multiplication> { ( '+' | '-' ) <multiplication> }
    fn addition(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(multiplication, &.{
            .{ .token = .plus, .op = .add },
            .{ .token = .minus, .op = .sub },
        });
    }

    /// <multiplication> ::= <unary> { ( '*' | '/' | '%' ) <unary> }
    fn multiplication(self: *Parser) Error!*ast.Expr {
        return self.binaryLevel(unary, &.{
            .{ .token = .star, .op = .mul },
            .{ .token = .slash, .op = .div },
            .{ .token = .percent, .op = .mod },
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

    /// <primary> ::= INT | FLOAT | STRING | 'true' | 'false'
    ///            | '(' <expression> ')' | <call-expr> | <array-literal>
    ///            | IDENTIFIER
    fn primary(self: *Parser) Error!*ast.Expr {
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
                // Strip the surrounding quotes captured in the lexeme.
                const contents = tok.lexeme[1 .. tok.lexeme.len - 1];
                return self.createExpr(.{ .literal = .{ .string = contents } });
            },
            .kw_true => {
                _ = self.advance();
                return self.createExpr(.{ .literal = .{ .boolean = true } });
            },
            .kw_false => {
                _ = self.advance();
                return self.createExpr(.{ .literal = .{ .boolean = false } });
            },
            .identifier => {
                _ = self.advance();
                if (self.check(.lparen)) return self.finishCall(tok.lexeme);
                if (self.check(.lbracket)) return self.finishIndex(tok.lexeme);
                return self.createExpr(.{ .variable = tok.lexeme });
            },
            .lparen => {
                _ = self.advance();
                const inner = try self.expression();
                _ = try self.expect(.rparen, "expected ')' after expression");
                return self.createExpr(.{ .grouping = inner });
            },
            .lbracket => return self.arrayLiteral(),
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

    /// `<array-index> ::= IDENTIFIER '[' <expression> ']'`
    ///
    /// Called with the array name already consumed and '[' as the next
    /// token (see `primary`'s IDENTIFIER case). Produces an `.index` node
    /// regardless of whether it ends up being read or assigned to —
    /// `assignment` is what turns a trailing `':=' <expr>` into an
    /// `.index_assign` instead (matching how a bare `.variable` becomes
    /// `.assign`).
    fn finishIndex(self: *Parser, name: []const u8) Error!*ast.Expr {
        _ = self.advance(); // '['
        const index_expr = try self.expression();
        _ = try self.expect(.rbracket, "expected ']' after array index");
        return self.createExpr(.{ .index = .{ .name = name, .index = index_expr } });
    }

    /// <array-literal> ::= '[' [ <expression> { ',' <expression> } ] ']'
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

test "parses precedence: exponent binds tighter than addition (left-associative, per grammar)" {
    try expectExprSexpr("2 ** 3 ** 2", "(** (** 2 3) 2)");
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
    const decl = result.program[0].var_decl;
    try std.testing.expectEqual(ast.ValueType.int, decl.type);
    try std.testing.expectEqualStrings("x", decl.name);
    try std.testing.expect(decl.initializer != null);
    try std.testing.expectEqual(@as(i64, 5), decl.initializer.?.literal.int);
}

test "variable declaration without an initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "bool flag\n");
    defer result.parser.deinit();

    const decl = result.program[0].var_decl;
    try std.testing.expectEqual(ast.ValueType.bool, decl.type);
    try std.testing.expect(decl.initializer == null);
}

test "a single-line block does not require a newline after '{' (grammar fix d)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "{ print 1 }");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    const block = result.program[0].block;
    try std.testing.expectEqual(@as(usize, 1), block.len);
    try std.testing.expectEqual(@as(i64, 1), block[0].print_stmt.literal.int);
}

test "if/else with single-line blocks on one logical statement (grammar fix d)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "if x { print 1 } else { print 2 }");
    defer result.parser.deinit();

    const if_stmt = result.program[0].if_stmt;
    try std.testing.expectEqualStrings("x", if_stmt.condition.variable);
    try std.testing.expectEqual(@as(i64, 1), if_stmt.then_branch.block[0].print_stmt.literal.int);
    try std.testing.expectEqual(@as(i64, 2), if_stmt.else_branch.?.block[0].print_stmt.literal.int);
}

test "else if chains without a dedicated elif keyword (design note c)" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\if a print 1
        \\else if b print 2
        \\else print 3
    );
    defer result.parser.deinit();

    const outer = result.program[0].if_stmt;
    try std.testing.expectEqualStrings("a", outer.condition.variable);
    const inner = outer.else_branch.?.if_stmt;
    try std.testing.expectEqualStrings("b", inner.condition.variable);
    try std.testing.expectEqual(@as(i64, 3), inner.else_branch.?.print_stmt.literal.int);
}

test "while loop parses condition and a block body" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\while x {
        \\  print x
        \\}
    );
    defer result.parser.deinit();

    const while_stmt = result.program[0].while_stmt;
    try std.testing.expectEqualStrings("x", while_stmt.condition.variable);
    try std.testing.expectEqual(@as(usize, 1), while_stmt.body.block.len);
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
    try std.testing.expectEqual(ast.ValueType.int, result.program[0].var_decl.type);
    try std.testing.expectEqual(ast.ValueType.int, result.program[1].var_decl.type);

    const while_stmt = result.program[2].while_stmt;
    try std.testing.expectEqual(ast.BinaryOp.lt, while_stmt.condition.binary.op);

    const while_body = while_stmt.body.block;
    try std.testing.expectEqual(@as(usize, 2), while_body.len);
    try std.testing.expectEqual(ast.BinaryOp.mod, while_body[0].if_stmt.condition.binary.left.binary.op);

    try std.testing.expectEqualStrings("total", result.program[3].print_stmt.variable);
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
    const f = result.program[0].function_decl;
    try std.testing.expectEqualStrings("add", f.name);
    try std.testing.expectEqual(ast.ValueType.int, f.return_type);
    try std.testing.expectEqual(@as(usize, 2), f.params.len);
    try std.testing.expectEqual(ast.ValueType.int, f.params[0].type);
    try std.testing.expectEqualStrings("a", f.params[0].name);
    try std.testing.expectEqualStrings("b", f.params[1].name);
    try std.testing.expectEqual(@as(usize, 1), f.body.len);
    try std.testing.expectEqualStrings("a", f.body[0].return_stmt.binary.left.variable);
}

test "a function with no parameters parses an empty param list" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\func answer() -> int {
        \\    return 42
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].function_decl;
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

    const decl = result.program[0].var_decl;
    try std.testing.expectEqual(ast.ValueType.int, decl.type);
    try std.testing.expectEqual(@as(?u32, 3), decl.array_len);
    try std.testing.expectEqualStrings("arr", decl.name);
    try std.testing.expect(decl.initializer == null);
}

test "parses an array declaration with a literal initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "int[3] arr := [1, 2, 3]\n");
    defer result.parser.deinit();

    const decl = result.program[0].var_decl;
    try std.testing.expectEqual(@as(?u32, 3), decl.array_len);
    const lit = decl.initializer.?.array_literal;
    try std.testing.expectEqual(@as(usize, 3), lit.len);
    try std.testing.expectEqual(@as(i64, 2), lit[1].literal.int);
}

test "a plain scalar declaration has a null array_len" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "int x := 5\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(?u32, null), result.program[0].var_decl.array_len);
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

test "parses a for loop over a range" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\for i in 0..3 {
        \\    print i
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].for_stmt;
    try std.testing.expectEqualStrings("i", f.var_name);
    try std.testing.expectEqual(@as(i64, 0), f.start.literal.int);
    try std.testing.expectEqual(@as(i64, 3), f.end.literal.int);
    try std.testing.expectEqual(@as(usize, 1), f.body.block.len);
}

test "parses an import declaration" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "import \"util.butter\"\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqualStrings("util.butter", result.program[0].import_stmt.path);
}

test "a plain function declaration is not exported" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "func f() -> int { return 1 }\n");
    defer result.parser.deinit();

    try std.testing.expect(!result.program[0].function_decl.exported);
}

test "'export' before 'func' marks the function exported" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "export func f() -> int { return 1 }\n");
    defer result.parser.deinit();

    try std.testing.expect(result.program[0].function_decl.exported);
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

test "a for loop's range bounds may be arbitrary expressions" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator,
        \\for i in start..(end + 1) {
        \\    print i
        \\}
    );
    defer result.parser.deinit();

    const f = result.program[0].for_stmt;
    try std.testing.expectEqualStrings("start", f.start.variable);
    try std.testing.expectEqualStrings("end", f.end.grouping.binary.left.variable);
}
