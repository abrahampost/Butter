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
            .kw_int, .kw_float, .kw_bool, .kw_string, .kw_map, .kw_list => self.varDeclaration(),
            .lbrace => self.block(),
            .kw_if => self.ifStatement(),
            .kw_while => self.whileStatement(),
            .kw_for => self.forStatement(),
            else => self.statement(),
        };
    }

    /// <type> ::= 'int' | 'float' | 'bool' | 'string' | 'map' | 'list'
    fn parseType(self: *Parser) Error!ast.ValueType {
        const tok = self.peek();
        const value_type: ast.ValueType = switch (tok.type) {
            .kw_int => .int,
            .kw_float => .float,
            .kw_bool => .bool,
            .kw_string => .string,
            .kw_map => .map,
            .kw_list => .list,
            else => return self.fail("expected a type"),
        };
        _ = self.advance();
        return value_type;
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
    fn functionDeclaration(self: *Parser, exported: bool) Error!ast.Stmt {
        _ = self.advance(); // 'func'
        const name_tok = try self.expect(.identifier, "expected a function name");

        _ = try self.expect(.lparen, "expected '(' after function name");
        var params: std.ArrayList(ast.Param) = .empty;
        if (!self.check(.rparen)) {
            while (true) {
                const param_type = try self.parseType();
                // map/list never take the array suffix — they're always
                // exactly one value, never a run of raw slots (GRAMMAR.bnf
                // design note 3m) — so this is simply never attempted for
                // them, the same way it's never attempted for a param name.
                const param_array_size = if (param_type == .map or param_type == .list) null else try self.parseArraySpec();
                const param_name = try self.expect(.identifier, "expected a parameter name");
                try params.append(self.allocator(), .{ .type = param_type, .name = param_name.lexeme, .array_size = param_array_size });
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' after parameters");
        _ = try self.expect(.arrow, "expected '->' before return type");
        const return_type = try self.parseType();
        const return_array_size = if (return_type == .map or return_type == .list) null else try self.parseArraySpec();

        const body_stmt = try self.block();

        return ast.Stmt{ .function_decl = .{
            .name = name_tok.lexeme,
            .params = try params.toOwnedSlice(self.allocator()),
            .return_type = return_type,
            .return_array_size = return_array_size,
            .body = body_stmt.block,
            .exported = exported,
        } };
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
        const value_type = try self.parseType();
        // map/list never take the array-size suffix (GRAMMAR.bnf design
        // note 3m) — writing `map[3] m` simply never gets this far as an
        // array declaration; the next token (still `[`) fails the
        // IDENTIFIER expectation below instead.
        const array_len = if (value_type == .map or value_type == .list) null else try self.parseOptionalArraySize();
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
        if (self.check(.kw_close)) return self.closeStatement();
        if (self.check(.kw_exit)) return self.exitStatement();
        return self.exprStatement();
    }

    /// <print-stmt> ::= 'print' <expression> <end>
    fn printStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'print'
        const value = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .print_stmt = value };
    }

    /// <close-stmt> ::= 'close' <expression> <end>
    ///
    /// A statement, not an expression, because closing produces no value —
    /// exactly the shape (and the reason) `print` has.
    fn closeStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'close'
        const stream = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .close_stmt = stream };
    }

    /// <exit-stmt> ::= 'exit' <expression> <end>
    ///
    /// A statement, not an expression, for the same reason `close` is —
    /// nothing after it can ever run, so there is no result to hand back to.
    fn exitStatement(self: *Parser) Error!ast.Stmt {
        _ = self.advance(); // 'exit'
        const code = try self.expression();
        try self.consumeEnd();
        return ast.Stmt{ .exit_stmt = code };
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
                return self.createExpr(.{ .index_assign = .{ .base = expr.index.base, .index = expr.index.index, .value = value } });
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

    /// <primary> ::= <atom> { '[' <expression> [ '..' <expression> ] ']' }
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
    fn primary(self: *Parser) Error!*ast.Expr {
        var expr = try self.atom();
        while (self.check(.lbracket)) expr = try self.finishIndex(expr);
        return expr;
    }

    /// <atom> ::= INT | FLOAT | STRING | 'true' | 'false' | 'null'
    ///         | '(' <expression> ')' | <call-expr> | <array-literal>
    ///         | <map-literal> | <len-expr> | <read-expr> | <write-expr>
    ///         | <open-expr> | <push-expr> | <keys-expr> | <has-expr>
    ///         | <delete-expr> | <json-expr> | <stringify-expr>
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
            .kw_null => {
                _ = self.advance();
                return self.createExpr(.{ .literal = .null_value });
            },
            .identifier => {
                _ = self.advance();
                if (self.check(.lparen)) return self.finishCall(tok.lexeme);
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
                const key = key_tok.lexeme[1 .. key_tok.lexeme.len - 1];
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

    const first = result.program[0].function_decl;
    try std.testing.expectEqual(@as(usize, 1), first.params.len);
    try std.testing.expectEqual(@as(u32, 3), first.params[0].array_size.?.fixed);
    try std.testing.expectEqual(@as(?ast.ArraySpec, null), first.return_array_size);

    const pair = result.program[1].function_decl;
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

    const sum_fn = result.program[0].function_decl;
    try std.testing.expectEqual(ast.ArraySpec.generic, sum_fn.params[0].array_size.?);
    try std.testing.expectEqual(@as(?ast.ArraySpec, null), sum_fn.return_array_size);

    const identity_fn = result.program[1].function_decl;
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

    const decl = result.program[0].var_decl;
    try std.testing.expectEqual(ast.ValueType.map, decl.type);
    try std.testing.expectEqual(@as(?u32, null), decl.array_len);
    try std.testing.expect(decl.initializer == null);
}

test "parses a list declaration with an array-literal initializer" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "list xs := [1, 2, 3]\n");
    defer result.parser.deinit();

    const decl = result.program[0].var_decl;
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

    const f = result.program[0].for_stmt;
    try std.testing.expectEqualStrings("i", f.var_name);
    try std.testing.expectEqual(@as(i64, 0), f.start.literal.int);
    try std.testing.expectEqual(@as(i64, 3), f.end.literal.int);
    try std.testing.expectEqual(@as(usize, 1), f.body.block.len);
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
    try std.testing.expectEqualStrings("f", result.program[0].close_stmt.variable);
}

test "parses exit as a statement" {
    const allocator = std.testing.allocator;
    var result = try parseProgramSource(allocator, "exit 1\n");
    defer result.parser.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.program.len);
    try std.testing.expectEqual(@as(i64, 1), result.program[0].exit_stmt.literal.int);
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
