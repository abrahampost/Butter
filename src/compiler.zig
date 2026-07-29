//! Lowers a parsed Butter `ast.Program` into a `chunk.Chunk` for the VM —
//! this is what makes the VM an actual compilation target for the
//! language rather than a standalone bytecode interpreter. See ISA.bnf
//! sections 4 and 5 for the codegen patterns and variable-resolution
//! scheme this implements.

const std = @import("std");
const ast = @import("ast.zig");
const chunk_mod = @import("chunk.zig");
const value_mod = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value_mod.Value;

/// Semantic errors the compiler itself raises; detail is left in
/// `Compiler.diagnostic`. Allocation failure is reported separately since
/// it carries no useful source position.
pub const SemanticError = error{
    UndefinedVariable,
    UndefinedFunction,
    DuplicateFunction,
    ArityMismatch,
    ReturnOutsideFunction,
    NotAnArray,
    ArrayUsedAsScalar,
    ArrayLengthMismatch,
    InvalidArrayInitializer,
    UnexpectedArrayLiteral,
    FunctionNotVisible,
    InvalidArrayArgument,
    InvalidArrayReturn,
    EscapingArrayReference,
};
pub const CompileError = SemanticError || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    name: []const u8,
    message: []const u8,
};

/// `slot` is explicit (not implied by position in the locals list) because
/// an array-typed local occupies more than one slot rather than exactly
/// one, so slot numbers and list position diverge once any array is in
/// scope (see ISA.bnf section 5).
const Local = struct {
    name: []const u8,
    depth: usize,
    slot: u32,
    /// null for a plain scalar (1 slot). `Some(.fixed(n))` means this
    /// local is a fixed-size array occupying `n` consecutive raw slots
    /// starting at `slot`, addressed via LOAD_INDEX/STORE_INDEX.
    /// `Some(.generic)` means this local holds a single-slot runtime
    /// `Value.array_ref` (always exactly 1 slot, whatever the referenced
    /// array's actual length turns out to be at runtime), addressed via
    /// LOAD_INDEX_REF/STORE_INDEX_REF/LOAD_REF_LEN instead (ISA.bnf
    /// section 6's generic-array addendum).
    array: ?ast.ArraySpec = null,
};

/// A local/parameter's width in stack slots: 1 for a plain scalar OR a
/// generic array reference (both are exactly one `Value`), `n` for a
/// fixed-size array of `n` elements.
fn arraySpecWidth(spec: ?ast.ArraySpec) u32 {
    return switch (spec orelse return 1) {
        .fixed => |n| n,
        .generic => 1,
    };
}

/// A function's compile-time signature, registered up front (before any
/// function body is compiled — see `compileModules`) so that calls resolve
/// regardless of declaration order. `index` is the position its compiled
/// `chunk_mod.Function` will occupy in the final `Program.functions`
/// slice, which is also the operand CALL instructions use to name it.
///
/// `params` is borrowed directly from the declaring `ast.Stmt.FunctionDecl`
/// (valid for as long as the parsed program it came from outlives
/// compilation, which it always does) so that a call site can see each
/// parameter's `array_size` — needed to compile an array argument
/// differently from a scalar one (see `compileCall`). `arity` is the total
/// stack-slot width all parameters occupy together (a fixed-size array
/// parameter costs its declared size in slots, a generic array parameter
/// costs exactly 1 — it's a single reference value — same as a scalar),
/// which is what the VM's CALL actually needs; it is deliberately NOT
/// `params.len` once any parameter is array-typed.
///
/// `module`/`exported` exist purely for cross-file visibility (see
/// `functionVisible`, GRAMMAR.bnf design note h) — the VM itself never
/// sees either; CALL's operand is still just a flat index into one
/// program-wide function table, same as before files could import each
/// other (ISA.bnf section 6/8).
const FunctionInfo = struct {
    name: []const u8,
    params: []const ast.Param,
    return_array_size: ?ast.ArraySpec,
    arity: u32,
    index: u32,
    module: usize,
    exported: bool,
};

fn totalParamWidth(params: []const ast.Param) u32 {
    var width: u32 = 0;
    for (params) |p| width += arraySpecWidth(p.array_size);
    return width;
}

/// One compilation unit passed to `compileModules`: a parsed file plus
/// which other units (by index into the same slice) it's allowed to call
/// `export`ed functions from — i.e. the modules it directly imports. There
/// is no automatic re-export: importing B, which itself imports C, does
/// not make C's exports visible here (GRAMMAR.bnf design note h).
///
/// `compileProgram` below treats a plain single-file `ast.Program` as one
/// `ModuleUnit` with no imports, which is why every function in it stays
/// visible to every other — exactly as it always has been, since a lone
/// module's own functions are always visible to itself regardless of
/// `exported` (see `functionVisible`).
pub const ModuleUnit = struct {
    program: ast.Program,
    imports: []const usize = &.{},
};

/// Compiles one `ast.Program` into one `chunk_mod.Program`. Not reusable
/// across multiple programs — construct a fresh `Compiler` per compilation.
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    chunk: Chunk = .{},
    locals: std.ArrayList(Local) = .empty,
    scope_depth: usize = 0,
    /// The next free stack slot (relative to the current frame's base
    /// pointer) a new local will be assigned. Incremented by a local's
    /// width when it's declared and decremented back when it leaves scope
    /// (see `popLocalsAbove`), so sibling scopes reuse the same slots
    /// rather than growing the frame unboundedly.
    next_slot: u32 = 0,
    functions: std.ArrayList(FunctionInfo) = .empty,
    /// True while compiling a function body — the only context in which
    /// `return` is legal (see `SemanticError.ReturnOutsideFunction`).
    in_function: bool = false,
    /// Which `ModuleUnit` (by index, into the slice passed to
    /// `compileModules`) is currently being compiled — a call to one of
    /// its own functions is always visible regardless of `exported`
    /// (`functionVisible`'s same-module check).
    current_module: usize = 0,
    /// The modules `current_module` directly imports — a call to one of
    /// *their* functions is only visible if that function is `exported`
    /// (`functionVisible`). Borrowed from the `ModuleUnit` currently being
    /// compiled; never owned by the compiler.
    visible_imports: []const usize = &.{},
    /// Set for the duration of `compileFunctionBody` to the function
    /// currently being compiled's declared return array size (null for a
    /// plain scalar return) — `compileStmt`'s `.return_stmt` case consults
    /// this to decide whether a `return` needs `compileArrayReturn` instead
    /// of a plain `compileExpr`.
    current_return_array_size: ?ast.ArraySpec = null,
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: std.mem.Allocator) Compiler {
        return .{ .allocator = allocator };
    }

    /// Frees the compiler's scratch state. Does NOT free the
    /// `chunk_mod.Program` returned by `compileProgram` — that has been
    /// handed off to the caller, who owns it and must call
    /// `program.deinit` themselves.
    pub fn deinit(self: *Compiler) void {
        self.locals.deinit(self.allocator);
        self.functions.deinit(self.allocator);
    }

    /// Compiles a single, self-contained `ast.Program` with no imports —
    /// the entry point every pre-import-feature test still uses. Wraps it
    /// as one `ModuleUnit` with an empty import list, which (per
    /// `functionVisible`) makes every function in it visible to every
    /// other regardless of `exported`, exactly as before cross-file
    /// `import` existed.
    pub fn compileProgram(self: *Compiler, program: ast.Program) CompileError!chunk_mod.Program {
        const units = [_]ModuleUnit{.{ .program = program }};
        return self.compileModules(0, &units);
    }

    /// Three passes over `modules`, in order:
    ///
    ///   1. Register every function's name/arity/owning-module up front
    ///      (across ALL modules, not just the entry one), so that calls —
    ///      including a function calling itself, two functions calling
    ///      each other, or a call across files — resolve no matter which
    ///      order the functions, their callers, or the modules themselves
    ///      are compiled in.
    ///   2. Compile the entry module's top-level statements (everything
    ///      except function/import declarations) into the main chunk,
    ///      exactly as before functions or imports existed.
    ///   3. Compile every module's functions into their own chunks.
    ///
    /// `modules` must list each module exactly once — deduplicating a
    /// diamond-shaped import graph (the same file reached via more than
    /// one import path) down to one entry is the module loader's job
    /// (module.zig), not this function's; that's what makes a shared
    /// dependency's functions get compiled exactly once here rather than
    /// once per importer.
    pub fn compileModules(self: *Compiler, entry: usize, modules: []const ModuleUnit) CompileError!chunk_mod.Program {
        for (modules, 0..) |m, mi| {
            for (m.program) |*stmt| {
                if (stmt.* != .function_decl) continue;
                const f = stmt.function_decl;
                if (self.findFunction(f.name) != null) {
                    return self.fail(SemanticError.DuplicateFunction, f.name, "function already declared");
                }
                try self.functions.append(self.allocator, .{
                    .name = f.name,
                    .params = f.params,
                    .return_array_size = f.return_array_size,
                    .arity = totalParamWidth(f.params),
                    .index = @intCast(self.functions.items.len),
                    .module = mi,
                    .exported = f.exported,
                });
            }
        }

        self.current_module = entry;
        self.visible_imports = modules[entry].imports;

        // `main_chunk` and `compiled` are only handed to the caller (who
        // then owns them) once `compileModules` returns successfully; a
        // failure partway through pass 3 must free them here instead; each
        // `errdefer` below is scoped so it only fires for errors at or
        // after the point the resource it guards actually exists.
        var main_chunk: Chunk = blk: {
            errdefer self.chunk.deinit(self.allocator);
            for (modules[entry].program) |*stmt| {
                if (stmt.* == .function_decl or stmt.* == .import_stmt) continue;
                try self.compileStmt(stmt);
            }
            _ = try self.chunk.emit(self.allocator, .halt);
            const c = self.chunk;
            self.chunk = .{};
            break :blk c;
        };
        errdefer main_chunk.deinit(self.allocator);

        var compiled: std.ArrayList(chunk_mod.Function) = .empty;
        errdefer {
            for (compiled.items) |*f| f.deinit(self.allocator);
            compiled.deinit(self.allocator);
        }

        for (modules, 0..) |m, mi| {
            self.current_module = mi;
            self.visible_imports = m.imports;
            for (m.program) |*stmt| {
                if (stmt.* != .function_decl) continue;
                const f = stmt.function_decl;
                const info = self.findFunction(f.name).?; // registered in pass 1, above
                const body_chunk = try self.compileFunctionBody(f);
                try compiled.append(self.allocator, .{
                    .name = f.name,
                    .arity = info.arity,
                    .return_width = arraySpecWidth(f.return_array_size),
                    .chunk = body_chunk,
                });
            }
        }

        return .{ .main = main_chunk, .functions = try compiled.toOwnedSlice(self.allocator) };
    }

    /// Compiles one function's body into a fresh, self-contained chunk:
    /// params become locals 0..arity-1 (mirroring how a top-level
    /// var-decl's initializer becomes that local's runtime storage — see
    /// `compileVarDecl`), then every statement in the body compiles as
    /// usual. If control falls off the end without an explicit `return`,
    /// the return type's zero value is returned implicitly (the same
    /// `defaultValue` a var-decl without an initializer gets).
    fn compileFunctionBody(self: *Compiler, f: ast.Stmt.FunctionDecl) CompileError!Chunk {
        self.chunk = .{};
        errdefer self.chunk.deinit(self.allocator);
        self.locals.clearRetainingCapacity();
        self.scope_depth = 0;
        self.next_slot = 0;
        self.in_function = true;
        self.current_return_array_size = f.return_array_size;
        defer self.in_function = false;
        defer self.current_return_array_size = null;

        for (f.params) |p| {
            try self.locals.append(self.allocator, .{ .name = p.name, .depth = 0, .slot = self.next_slot, .array = p.array_size });
            self.next_slot += arraySpecWidth(p.array_size);
        }
        for (f.body) |*s| try self.compileStmt(s);

        // Falling off the end without an explicit `return`: the zero value
        // of the return type, repeated for a fixed-size array return
        // (matching how an uninitialized array var-decl gets zero-filled
        // in `compileVarDecl`), or an empty (base=0, len=0) reference for
        // a generic array return — a valid, safe "nothing here" reference
        // since any index into it immediately bounds-checks out.
        if (self.current_return_array_size) |spec| switch (spec) {
            .fixed => |n| {
                const idx = try self.chunk.addConstant(self.allocator, defaultValue(f.return_type));
                var i: u32 = 0;
                while (i < n) : (i += 1) _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
            .generic => {
                const idx = try self.chunk.addConstant(self.allocator, .{ .array_ref = .{ .base = 0, .len = 0 } });
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
        } else {
            const idx = try self.chunk.addConstant(self.allocator, defaultValue(f.return_type));
            _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
        }
        _ = try self.chunk.emit(self.allocator, .ret);

        return self.chunk;
    }

    fn findFunction(self: *const Compiler, name: []const u8) ?FunctionInfo {
        for (self.functions.items) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    fn fail(self: *Compiler, comptime err: SemanticError, name: []const u8, message: []const u8) CompileError {
        self.diagnostic = .{ .name = name, .message = message };
        return err;
    }

    fn compileStmt(self: *Compiler, stmt: *const ast.Stmt) CompileError!void {
        switch (stmt.*) {
            .var_decl => |d| try self.compileVarDecl(d),
            .block => |stmts| try self.compileBlock(stmts),
            .if_stmt => |i| try self.compileIf(i),
            .while_stmt => |w| try self.compileWhile(w),
            .print_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .print);
            },
            .expr_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .pop);
            },
            .return_stmt => |e| {
                if (!self.in_function) return self.fail(SemanticError.ReturnOutsideFunction, "return", "'return' used outside a function body");
                if (self.current_return_array_size) |spec| {
                    switch (spec) {
                        .fixed => |len| try self.compileArrayReturn(e, len),
                        .generic => try self.compileGenericArrayReturn(e),
                    }
                } else {
                    try self.compileExpr(e);
                }
                _ = try self.chunk.emit(self.allocator, .ret);
            },
            .function_decl => unreachable, // top-level only; compileModules never calls compileStmt on this
            .for_stmt => |f| try self.compileFor(f),
            .import_stmt => unreachable, // top-level only; compileModules never calls compileStmt on this
        }
    }

    fn defaultValue(value_type: ast.ValueType) Value {
        return switch (value_type) {
            .int => .{ .int = 0 },
            .float => .{ .float = 0.0 },
            .bool => .{ .boolean = false },
            .string => .{ .string = "" },
        };
    }

    /// A declared local's runtime storage IS the value its initializer
    /// (or its type's zero value) leaves on the stack — there is no
    /// separate store step at declaration time (ISA.bnf section 5).
    fn compileVarDecl(self: *Compiler, d: ast.Stmt.VarDecl) CompileError!void {
        const slot = self.next_slot;
        if (d.array_len) |len| {
            if (d.initializer) |init_expr| {
                switch (init_expr.*) {
                    .array_literal => |elems| {
                        if (elems.len != len) {
                            return self.fail(SemanticError.ArrayLengthMismatch, d.name, "array literal length does not match the declared size");
                        }
                        for (elems) |elem| try self.compileExpr(elem);
                    },
                    .call => |c| {
                        const info = try self.compileCallCommon(c);
                        const ret_spec = info.return_array_size orelse return self.fail(SemanticError.InvalidArrayInitializer, d.name, "function call does not return an array");
                        const ret_len = switch (ret_spec) {
                            .fixed => |n| n,
                            .generic => return self.fail(SemanticError.InvalidArrayInitializer, d.name, "a local array declaration needs a fixed size, but this function call returns a generic (unsized) array"),
                        };
                        if (ret_len != len) return self.fail(SemanticError.ArrayLengthMismatch, d.name, "the called function's returned array length does not match the declared size");
                    },
                    else => return self.fail(SemanticError.InvalidArrayInitializer, d.name, "an array declaration's initializer must be an array literal or a call to an array-returning function"),
                }
            } else {
                const idx = try self.chunk.addConstant(self.allocator, defaultValue(d.type));
                var i: u32 = 0;
                while (i < len) : (i += 1) _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            }
            try self.locals.append(self.allocator, .{ .name = d.name, .depth = self.scope_depth, .slot = slot, .array = .{ .fixed = len } });
            self.next_slot += len;
        } else {
            if (d.initializer) |init_expr| {
                try self.compileExpr(init_expr);
            } else {
                const idx = try self.chunk.addConstant(self.allocator, defaultValue(d.type));
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            }
            try self.locals.append(self.allocator, .{ .name = d.name, .depth = self.scope_depth, .slot = slot });
            self.next_slot += 1;
        }
    }

    /// Pops every local declared at a depth deeper than `depth` off both
    /// the compiler's bookkeeping list and the runtime stack (one POP per
    /// slot the local occupies — `arraySpecWidth(removed.array)`), and
    /// reclaims their slot numbers so a sibling scope that follows starts
    /// from the same `next_slot` rather than growing the frame unboundedly.
    fn popLocalsAbove(self: *Compiler, depth: usize) CompileError!void {
        while (self.locals.items.len > 0 and self.locals.items[self.locals.items.len - 1].depth > depth) {
            const removed = self.locals.pop().?;
            const width = arraySpecWidth(removed.array);
            self.next_slot -= width;
            var i: u32 = 0;
            while (i < width) : (i += 1) _ = try self.chunk.emit(self.allocator, .pop);
        }
    }

    fn compileBlock(self: *Compiler, stmts: []ast.Stmt) CompileError!void {
        self.scope_depth += 1;
        for (stmts) |*s| try self.compileStmt(s);
        self.scope_depth -= 1;
        try self.popLocalsAbove(self.scope_depth);
    }

    /// clox-style backpatched jumps (ISA.bnf section 4): emit the branch
    /// with a placeholder target, keep compiling, then patch the target
    /// once it's known.
    fn compileIf(self: *Compiler, i: ast.Stmt.If) CompileError!void {
        try self.compileExpr(i.condition);
        const then_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false, 0);
        _ = try self.chunk.emit(self.allocator, .pop);
        try self.compileStmt(i.then_branch);

        const else_jump = try self.chunk.emit(self.allocator, .jump);
        self.chunk.patchOperand(then_jump, @intCast(self.chunk.code.items.len));
        _ = try self.chunk.emit(self.allocator, .pop);

        if (i.else_branch) |eb| try self.compileStmt(eb);
        self.chunk.patchOperand(else_jump, @intCast(self.chunk.code.items.len));
    }

    fn compileWhile(self: *Compiler, w: ast.Stmt.While) CompileError!void {
        const loop_start = self.chunk.code.items.len;
        try self.compileExpr(w.condition);
        const exit_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false, 0);
        _ = try self.chunk.emit(self.allocator, .pop);

        try self.compileStmt(w.body);
        _ = try self.chunk.emitWithOperand(self.allocator, .jump, @intCast(loop_start));

        self.chunk.patchOperand(exit_jump, @intCast(self.chunk.code.items.len));
        _ = try self.chunk.emit(self.allocator, .pop);
    }

    /// `for v in start..end body` desugars directly to the same
    /// backpatched-jump while-loop pattern `compileWhile` uses (ISA.bnf
    /// section 4) — no new opcodes, exactly the same way `and`/`or` are
    /// "sugar" over JUMP_IF_FALSE/JUMP rather than dedicated instructions.
    /// It needs two hidden locals of its own, scoped to a wrapper block
    /// only `compileFor` knows about: the end bound (evaluated once, up
    /// front — not re-evaluated per iteration) and the loop variable
    /// itself, which the body resolves like any other local by name.
    fn compileFor(self: *Compiler, f: ast.Stmt.For) CompileError!void {
        self.scope_depth += 1;

        try self.compileExpr(f.end);
        const end_slot = self.next_slot;
        try self.locals.append(self.allocator, .{ .name = "", .depth = self.scope_depth, .slot = end_slot });
        self.next_slot += 1;

        try self.compileExpr(f.start);
        const var_slot = self.next_slot;
        try self.locals.append(self.allocator, .{ .name = f.var_name, .depth = self.scope_depth, .slot = var_slot });
        self.next_slot += 1;

        const loop_start = self.chunk.code.items.len;
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, var_slot);
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, end_slot);
        _ = try self.chunk.emit(self.allocator, .lt);
        const exit_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false, 0);
        _ = try self.chunk.emit(self.allocator, .pop);

        try self.compileStmt(f.body);

        const one_idx = try self.chunk.addConstant(self.allocator, .{ .int = 1 });
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, var_slot);
        _ = try self.chunk.emitWithOperand(self.allocator, .push_const, one_idx);
        _ = try self.chunk.emit(self.allocator, .add);
        _ = try self.chunk.emitWithOperand(self.allocator, .store_local, var_slot);
        _ = try self.chunk.emit(self.allocator, .pop);
        _ = try self.chunk.emitWithOperand(self.allocator, .jump, @intCast(loop_start));

        self.chunk.patchOperand(exit_jump, @intCast(self.chunk.code.items.len));
        _ = try self.chunk.emit(self.allocator, .pop);

        self.scope_depth -= 1;
        try self.popLocalsAbove(self.scope_depth);
    }

    fn compileExpr(self: *Compiler, expr: *const ast.Expr) CompileError!void {
        switch (expr.*) {
            .literal => |lit| try self.compileLiteral(lit),
            .variable => |name| _ = try self.emitLocalOp(name, .load_local),
            .unary => |u| {
                try self.compileExpr(u.right);
                _ = try self.chunk.emit(self.allocator, switch (u.op) {
                    .negate => .neg,
                    .not => .not,
                });
            },
            .binary => |b| try self.compileBinary(b),
            .grouping => |inner| try self.compileExpr(inner),
            .assign => |a| {
                try self.compileExpr(a.value);
                _ = try self.emitLocalOp(a.name, .store_local);
            },
            .call => |c| try self.compileCall(c),
            .array_literal => return self.fail(SemanticError.UnexpectedArrayLiteral, "", "an array literal may only initialize a matching array declaration"),
            .index => |ix| try self.compileIndex(ix),
            .index_assign => |ia| try self.compileIndexAssign(ia),
            .len_of => |name| try self.compileLenOf(name),
        }
    }

    /// Calls resolve against the function table built in `compileModules`'s
    /// first pass, not `self.locals` — a completely separate namespace
    /// from variables, which is why `x()` and `x` (a local named x) never
    /// collide. The arity check compares against `info.params.len` (the
    /// declared parameter COUNT), not `info.arity` (the total stack-slot
    /// WIDTH those parameters occupy) — the two diverge as soon as any
    /// parameter is array-typed.
    ///
    /// A call used as a plain expression (here) must return a scalar — an
    /// array-returning function's result has nowhere legal to go in a
    /// general expression context, since a `<value>` is always exactly one
    /// stack slot (ISA.bnf section 2). The three contexts that DO have
    /// somewhere for an array result to go — a matching array var-decl's
    /// initializer, a matching array-typed call argument, and a matching
    /// array return — each call `compileCallCommon` directly instead of
    /// going through this function.
    fn compileCall(self: *Compiler, c: ast.Expr.Call) CompileError!void {
        const info = try self.compileCallCommon(c);
        if (info.return_array_size != null) return self.fail(SemanticError.ArrayUsedAsScalar, c.name, "a function returning an array can't be used as a plain value here");
    }

    /// Resolves, checks visibility/arity, compiles every argument (using
    /// `compileArrayArgument`/`compileGenericArrayArgument` for array-typed
    /// parameters), and emits CALL. Shared by every call site regardless of
    /// what the call's own result is used for — plain-expression calls,
    /// array var-decl initializers, array call arguments, and array
    /// returns alike.
    fn compileCallCommon(self: *Compiler, c: ast.Expr.Call) CompileError!FunctionInfo {
        const info = self.findFunction(c.name) orelse return self.fail(SemanticError.UndefinedFunction, c.name, "undefined function");
        if (!self.functionVisible(info)) return self.fail(SemanticError.FunctionNotVisible, c.name, "function exists but isn't exported by a module this file imports");
        if (c.args.len != info.params.len) return self.fail(SemanticError.ArityMismatch, c.name, "wrong number of arguments");
        for (c.args, info.params) |arg, param| {
            if (param.array_size) |spec| {
                switch (spec) {
                    .fixed => |len| try self.compileArrayArgument(arg, len),
                    .generic => try self.compileGenericArrayArgument(arg),
                }
            } else {
                try self.compileExpr(arg);
            }
        }
        _ = try self.chunk.emitWithOperand(self.allocator, .call, info.index);
        return info;
    }

    /// A fixed-size array-valued expression — used for a fixed-size
    /// call argument, a fixed-size returned array, or a matching fixed-size
    /// array var-decl's initializer — may only ever be a bare array name
    /// (of a matching FIXED local; a generic local can't be used here,
    /// since its length isn't known at compile time) or a call to a
    /// function that itself returns a matching fixed-size array (arrays
    /// aren't first-class expressions, GRAMMAR.bnf design note 3e, so
    /// there's no other array-valued expression form to compile).
    /// `invalid_err` names the error to raise for anything else, since that
    /// reads differently for an argument vs. a return vs. a var-decl
    /// initializer.
    fn compileArrayValue(self: *Compiler, expr: *const ast.Expr, expected_len: u32, comptime invalid_err: SemanticError, invalid_msg: []const u8) CompileError!void {
        switch (expr.*) {
            .variable => |name| {
                const local = self.resolveLocal(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
                const spec = local.array orelse return self.fail(SemanticError.NotAnArray, name, "not an array");
                const len = switch (spec) {
                    .fixed => |n| n,
                    .generic => return self.fail(invalid_err, name, "a generic (unsized) array can't be used where a fixed-size array is required"),
                };
                if (len != expected_len) return self.fail(SemanticError.ArrayLengthMismatch, name, "array length does not match what was expected here");
                var i: u32 = 0;
                while (i < len) : (i += 1) _ = try self.chunk.emitWithOperand(self.allocator, .load_local, local.slot + i);
            },
            .call => |c| {
                const info = try self.compileCallCommon(c);
                const ret_spec = info.return_array_size orelse return self.fail(invalid_err, c.name, "function call does not return an array");
                const ret_len = switch (ret_spec) {
                    .fixed => |n| n,
                    .generic => return self.fail(invalid_err, c.name, "a generic (unsized) array can't be used where a fixed-size array is required"),
                };
                if (ret_len != expected_len) return self.fail(SemanticError.ArrayLengthMismatch, c.name, "the called function's returned array length does not match what was expected here");
            },
            else => return self.fail(invalid_err, "", invalid_msg),
        }
    }

    fn compileArrayArgument(self: *Compiler, arg: *const ast.Expr, expected_len: u32) CompileError!void {
        try self.compileArrayValue(arg, expected_len, SemanticError.InvalidArrayArgument, "an array argument must be a bare array name or a call to an array-returning function");
    }

    fn compileArrayReturn(self: *Compiler, expr: *const ast.Expr, expected_len: u32) CompileError!void {
        try self.compileArrayValue(expr, expected_len, SemanticError.InvalidArrayReturn, "a returned array must be a bare array name or a call to an array-returning function");
    }

    /// A generic array argument — passed BY REFERENCE, never copied. This
    /// is always safe regardless of where the reference points, because
    /// the callee only ever uses it for the duration of this (nested,
    /// shorter-lived) call: the frame owning the referenced slots — whether
    /// that's a fixed local right here, or some ancestor frame further up
    /// the call stack that an already-generic local's reference points
    /// into — is guaranteed to still be alive for as long as this call runs
    /// (ISA.bnf section 6's generic-array addendum). Two forms:
    ///   - a bare FIXED array name: synthesizes a fresh reference via
    ///     MAKE_ARRAY_REF, pointing at this frame's own slots.
    ///   - a bare GENERIC array name, or a call to a generic-returning
    ///     function: the reference already exists as a single value —
    ///     forward it as-is (LOAD_LOCAL, or just leave the call's own
    ///     result sitting there).
    /// Passing a call's FIXED-size result directly isn't supported (its
    /// values land in a transient stack position with no local slot to
    /// anchor a reference to) — assign it to a local array first.
    fn compileGenericArrayArgument(self: *Compiler, arg: *const ast.Expr) CompileError!void {
        switch (arg.*) {
            .variable => |name| {
                const local = self.resolveLocal(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
                const spec = local.array orelse return self.fail(SemanticError.InvalidArrayArgument, name, "not an array");
                switch (spec) {
                    .fixed => |len| _ = try self.chunk.emitWithOperand(self.allocator, .make_array_ref, chunk_mod.packIndexOperand(local.slot, len)),
                    .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_local, local.slot),
                }
            },
            .call => |c| {
                const info = try self.compileCallCommon(c);
                const ret_spec = info.return_array_size orelse return self.fail(SemanticError.InvalidArrayArgument, c.name, "function call does not return an array");
                switch (ret_spec) {
                    .generic => {}, // already exactly one reference value on the stack
                    .fixed => return self.fail(SemanticError.InvalidArrayArgument, c.name, "a fixed-size array result can't be forwarded directly into a generic array argument — assign it to a local array first"),
                }
            },
            else => return self.fail(SemanticError.InvalidArrayArgument, "", "an array argument must be a bare array name or a call to an array-returning function"),
        }
    }

    /// A generic array return — the one place references need a real
    /// soundness rule, since RET hands the reference to a caller who will
    /// keep using it after THIS frame is gone. Unlike an argument (used
    /// only during the callee's own, strictly shorter-lived call), a
    /// freshly-synthesized reference into this function's own frame —
    /// whether from a body-local or from one of its own FIXED array
    /// parameters, no difference — would dangle the instant this function
    /// returns and its frame's slots are reused. The only sound thing to
    /// return is a reference this function did NOT create: one it already
    /// received as a GENERIC parameter (or forwarded from a nested call
    /// that itself only ever forwards, by the same rule, all the way back
    /// to wherever it was first synthesized as some ancestor's call
    /// argument — see `compileGenericArrayArgument`).
    fn compileGenericArrayReturn(self: *Compiler, expr: *const ast.Expr) CompileError!void {
        switch (expr.*) {
            .variable => |name| {
                const local = self.resolveLocal(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
                const spec = local.array orelse return self.fail(SemanticError.InvalidArrayReturn, name, "a returned array must be a bare array name or a call to a generic-array-returning function");
                switch (spec) {
                    .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_local, local.slot),
                    .fixed => return self.fail(SemanticError.EscapingArrayReference, name, "cannot return a reference to this function's own array — its storage doesn't outlive the call; only a generic array received as a parameter (or forwarded from one) can be returned"),
                }
            },
            .call => |c| {
                const info = try self.compileCallCommon(c);
                const ret_spec = info.return_array_size orelse return self.fail(SemanticError.InvalidArrayReturn, c.name, "function call does not return an array");
                switch (ret_spec) {
                    .generic => {}, // already exactly one reference value on the stack
                    .fixed => return self.fail(SemanticError.EscapingArrayReference, c.name, "a fixed-size array result can't be forwarded as a generic return — its storage doesn't outlive this call either"),
                }
            },
            else => return self.fail(SemanticError.InvalidArrayReturn, "", "a returned array must be a bare array name or a call to a generic-array-returning function"),
        }
    }

    /// A function is callable from wherever `self.current_module` is right
    /// now if it belongs to that same module (regardless of `exported` —
    /// a module's own private helpers are always usable by itself), or if
    /// it's `exported` by one of that module's *direct* imports. There is
    /// no automatic re-export: an import's own imports are not
    /// transitively visible here (GRAMMAR.bnf design note h).
    fn functionVisible(self: *const Compiler, info: FunctionInfo) bool {
        if (info.module == self.current_module) return true;
        if (!info.exported) return false;
        for (self.visible_imports) |m| {
            if (m == info.module) return true;
        }
        return false;
    }

    fn compileLiteral(self: *Compiler, lit: ast.Literal) CompileError!void {
        if (lit == .boolean) {
            _ = try self.chunk.emit(self.allocator, if (lit.boolean) .push_true else .push_false);
            return;
        }
        const value: Value = switch (lit) {
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .string => |v| .{ .string = v },
            .boolean => unreachable,
        };
        const idx = try self.chunk.addConstant(self.allocator, value);
        _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
    }

    /// Innermost-declaration-wins lookup: walk backwards so a shadowing
    /// declaration in a nested block is found before the outer one it
    /// shadows (ISA.bnf section 5).
    fn resolveLocal(self: *const Compiler, name: []const u8) ?Local {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i];
        }
        return null;
    }

    fn emitLocalOp(self: *Compiler, name: []const u8, op: OpCode) CompileError!usize {
        const local = self.resolveLocal(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
        if (local.array != null) return self.fail(SemanticError.ArrayUsedAsScalar, name, "an array must be indexed, not used as a plain value");
        return self.chunk.emitWithOperand(self.allocator, op, local.slot);
    }

    /// `arr[i]` reads. For a FIXED-size local: LOAD_INDEX with the array's
    /// compile-time-known base slot and length packed into the operand
    /// (ISA.bnf section 3) so the VM can bounds-check at runtime. For a
    /// GENERIC local: LOAD_INDEX_REF instead, whose operand is just the
    /// slot holding the reference itself — the base and length aren't
    /// known until runtime, read out of the reference value there (ISA.bnf
    /// section 6's generic-array addendum).
    fn compileIndex(self: *Compiler, ix: ast.Expr.Index) CompileError!void {
        const local = self.resolveLocal(ix.name) orelse return self.fail(SemanticError.UndefinedVariable, ix.name, "undefined variable");
        const spec = local.array orelse return self.fail(SemanticError.NotAnArray, ix.name, "not an array");
        try self.compileExpr(ix.index);
        switch (spec) {
            .fixed => |len| _ = try self.chunk.emitWithOperand(self.allocator, .load_index, chunk_mod.packIndexOperand(local.slot, len)),
            .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_index_ref, local.slot),
        }
    }

    /// `arr[i] := value`: the index must be compiled before the value so
    /// the runtime stack order matches STORE_INDEX/STORE_INDEX_REF's stack
    /// effect `( index v -- v )` (ISA.bnf section 3). Fixed vs. generic
    /// dispatch mirrors `compileIndex`.
    fn compileIndexAssign(self: *Compiler, ia: ast.Expr.IndexAssign) CompileError!void {
        const local = self.resolveLocal(ia.name) orelse return self.fail(SemanticError.UndefinedVariable, ia.name, "undefined variable");
        const spec = local.array orelse return self.fail(SemanticError.NotAnArray, ia.name, "not an array");
        try self.compileExpr(ia.index);
        try self.compileExpr(ia.value);
        switch (spec) {
            .fixed => |len| _ = try self.chunk.emitWithOperand(self.allocator, .store_index, chunk_mod.packIndexOperand(local.slot, len)),
            .generic => _ = try self.chunk.emitWithOperand(self.allocator, .store_index_ref, local.slot),
        }
    }

    /// `len(arr)` on a FIXED-size local compiles to a plain PUSH_CONST of
    /// its declared size — no runtime check at all, since that length is
    /// fixed at compile time and never changes (GRAMMAR.bnf design note
    /// 3e). On a GENERIC local, the length genuinely isn't known until
    /// runtime (it depends on whatever array the caller actually passed),
    /// so this instead emits LOAD_REF_LEN, which reads it out of the
    /// reference value at runtime (ISA.bnf section 6's generic-array
    /// addendum).
    fn compileLenOf(self: *Compiler, name: []const u8) CompileError!void {
        const local = self.resolveLocal(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
        const spec = local.array orelse return self.fail(SemanticError.NotAnArray, name, "not an array");
        switch (spec) {
            .fixed => |len| {
                const idx = try self.chunk.addConstant(self.allocator, .{ .int = @intCast(len) });
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
            .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_ref_len, local.slot),
        }
    }

    fn compileBinary(self: *Compiler, b: ast.Expr.Binary) CompileError!void {
        switch (b.op) {
            .logic_and => return self.compileLogicAnd(b),
            .logic_or => return self.compileLogicOr(b),
            else => {},
        }
        try self.compileExpr(b.left);
        try self.compileExpr(b.right);
        const op: OpCode = switch (b.op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .pow => .pow,
            .eq => .eq,
            .neq => .neq,
            .lt => .lt,
            .lte => .lte,
            .gt => .gt,
            .gte => .gte,
            .logic_and, .logic_or => unreachable,
        };
        _ = try self.chunk.emit(self.allocator, op);
    }

    fn compileLogicAnd(self: *Compiler, b: ast.Expr.Binary) CompileError!void {
        try self.compileExpr(b.left);
        const end_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false, 0);
        _ = try self.chunk.emit(self.allocator, .pop);
        try self.compileExpr(b.right);
        self.chunk.patchOperand(end_jump, @intCast(self.chunk.code.items.len));
    }

    fn compileLogicOr(self: *Compiler, b: ast.Expr.Binary) CompileError!void {
        try self.compileExpr(b.left);
        const else_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false, 0);
        const end_jump = try self.chunk.emit(self.allocator, .jump);
        self.chunk.patchOperand(else_jump, @intCast(self.chunk.code.items.len));
        _ = try self.chunk.emit(self.allocator, .pop);
        try self.compileExpr(b.right);
        self.chunk.patchOperand(end_jump, @intCast(self.chunk.code.items.len));
    }
};

/// Compiles `program` into a fresh `chunk_mod.Program`, which the caller
/// owns (free it with `program.deinit(allocator)`).
pub fn compile(allocator: std.mem.Allocator, program: ast.Program) CompileError!chunk_mod.Program {
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    return compiler.compileProgram(program);
}

// ---- Tests ---------------------------------------------------------------

const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const vm_mod = @import("vm.zig");

/// Lexes, parses, compiles, and runs `source` end to end, returning
/// whatever it printed. This is the integration point proving the VM is
/// an actual target for the language, not just a standalone interpreter.
fn runProgram(allocator: std.mem.Allocator, source: []const u8, buf: []u8) ![]const u8 {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init();
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, &writer);
    return writer.buffered();
}

/// Lexes and parses `source` in isolation, for building up the
/// `ModuleUnit` lists the `compileModules` tests below hand-assemble
/// directly — these tests exercise cross-module visibility without going
/// through the real file-based module loader (module.zig has its own
/// tests for that).
fn parseSource(allocator: std.mem.Allocator, source: []const u8) !struct { parser: parser_mod.Parser, program: ast.Program } {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    const program = try parser.parseProgram();
    return .{ .parser = parser, .program = program };
}

test "compiles and runs a variable declaration and print" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "int x := 40 + 2\nprint x\n", &buf);
    try std.testing.expectEqualStrings("42\n", output);
}

test "compiles arithmetic precedence correctly" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "print 1 + 2 * 3\n", &buf);
    try std.testing.expectEqualStrings("7\n", output);
}

test "compiles if/else, taking the else branch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "if false { print 1 } else { print 2 }\n", &buf);
    try std.testing.expectEqualStrings("2\n", output);
}

test "compiles a while loop" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int i := 0
        \\while i < 3 {
        \\    print i
        \\    i := i + 1
        \\}
    , &buf);
    try std.testing.expectEqualStrings("0\n1\n2\n", output);
}

test "and short-circuits: a false left operand skips evaluating the right" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    // The right operand would raise DivisionByZero if it were ever
    // actually executed; compiling it is fine (compilation always
    // generates code for both sides — see the codegen pattern in
    // ISA.bnf section 4), but a working short circuit must never run it.
    const output = try runProgram(allocator, "print false and (1 / 0 == 0)\n", &buf);
    try std.testing.expectEqualStrings("false\n", output);
}

test "or short-circuits: a true left operand skips evaluating the right" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "print true or (1 / 0 == 0)\n", &buf);
    try std.testing.expectEqualStrings("true\n", output);
}

test "assignment is usable as an expression value" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "int x := 1\nprint (x := 5)\nprint x\n", &buf);
    try std.testing.expectEqualStrings("5\n5\n", output);
}

test "inner block shadows an outer variable without clobbering it" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int x := 1
        \\{
        \\    int x := 2
        \\    print x
        \\}
        \\print x
    , &buf);
    try std.testing.expectEqualStrings("2\n1\n", output);
}

test "referencing an undeclared variable is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("print nope\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.UndefinedVariable, compiler.compileProgram(program));
    try std.testing.expectEqualStrings("nope", compiler.diagnostic.?.name);
}

test "a variable declared without an initializer gets its type's zero value" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "int x\nprint x\n", &buf);
    try std.testing.expectEqualStrings("0\n", output);
}

test "compiles and calls a function with parameters" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func add(int a, int b) -> int {
        \\    return a + b
        \\}
        \\print add(3, 4)
    , &buf);
    try std.testing.expectEqualStrings("7\n", output);
}

test "a function may be called before its own declaration appears" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\print square(5)
        \\func square(int n) -> int {
        \\    return n * n
        \\}
    , &buf);
    try std.testing.expectEqualStrings("25\n", output);
}

test "recursive fibonacci" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func fib(int n) -> int {
        \\    if n < 2 {
        \\        return n
        \\    }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\print fib(10)
    , &buf);
    try std.testing.expectEqualStrings("55\n", output);
}

test "mutual recursion between two functions declared in either order" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func isEven(int n) -> bool {
        \\    if n == 0 {
        \\        return true
        \\    }
        \\    return isOdd(n - 1)
        \\}
        \\func isOdd(int n) -> bool {
        \\    if n == 0 {
        \\        return false
        \\    }
        \\    return isEven(n - 1)
        \\}
        \\print isEven(10)
    , &buf);
    try std.testing.expectEqualStrings("true\n", output);
}

test "falling off the end of a function without a return yields the return type's zero value" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func noop() -> int {
        \\    int x := 1
        \\}
        \\print noop()
    , &buf);
    try std.testing.expectEqualStrings("0\n", output);
}

test "a function's locals are isolated from the top level (no global access)" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\int total := 0
        \\func addToTotal(int n) -> int {
        \\    return total + n
        \\}
        \\print addToTotal(1)
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.UndefinedVariable, compiler.compileProgram(program));
    try std.testing.expectEqualStrings("total", compiler.diagnostic.?.name);
}

test "calling an undefined function is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("print nope(1)\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.UndefinedFunction, compiler.compileProgram(program));
    try std.testing.expectEqualStrings("nope", compiler.diagnostic.?.name);
}

test "calling a function with the wrong number of arguments is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func add(int a, int b) -> int {
        \\    return a + b
        \\}
        \\print add(1)
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.ArityMismatch, compiler.compileProgram(program));
}

test "declaring two functions with the same name is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func f() -> int { return 1 }
        \\func f() -> int { return 2 }
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.DuplicateFunction, compiler.compileProgram(program));
}

test "'return' outside a function body is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("return 1\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.ReturnOutsideFunction, compiler.compileProgram(program));
}

test "compiles an array literal, indexing, and indexed assignment" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int[3] arr := [10, 20, 30]
        \\arr[1] := 99
        \\print arr[0]
        \\print arr[1]
        \\print arr[2]
    , &buf);
    try std.testing.expectEqualStrings("10\n99\n30\n", output);
}

test "an array declared without an initializer is zero-filled" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int[3] arr
        \\print arr[0]
        \\print arr[2]
    , &buf);
    try std.testing.expectEqualStrings("0\n0\n", output);
}

test "an array literal with the wrong number of elements is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int[3] arr := [1, 2]\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.ArrayLengthMismatch, compiler.compileProgram(program));
}

test "initializing an array declaration with a non-array-literal expression is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int[3] arr := 5\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.InvalidArrayInitializer, compiler.compileProgram(program));
}

test "indexing a non-array local is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int x := 1\nprint x[0]\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.NotAnArray, compiler.compileProgram(program));
}

test "using an array's bare name as a scalar value is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int[3] arr\nprint arr\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.ArrayUsedAsScalar, compiler.compileProgram(program));
}

test "len(arr) compiles to the array's declared size" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int[5] arr
        \\print len(arr)
    , &buf);
    try std.testing.expectEqualStrings("5\n", output);
}

test "len(arr) can drive a for-loop's bound instead of a hardcoded size" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int[4] arr := [1, 2, 3, 4]
        \\int total := 0
        \\for i in 0..len(arr) {
        \\    total := total + arr[i]
        \\}
        \\print total
    , &buf);
    try std.testing.expectEqualStrings("10\n", output);
}

test "len() on a non-array local is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int x := 1\nprint len(x)\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.NotAnArray, compiler.compileProgram(program));
}

test "len() on an undeclared name is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("print len(nope)\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.UndefinedVariable, compiler.compileProgram(program));
}

test "an array literal outside a matching array declaration is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("print [1, 2, 3]\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.UnexpectedArrayLiteral, compiler.compileProgram(program));
}

test "indexing out of bounds is a runtime error" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.IndexOutOfBounds, runProgram(allocator,
        \\int[3] arr := [1, 2, 3]
        \\print arr[5]
    , &buf));
}

test "compiles and runs a basic for loop" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\for i in 0..3 {
        \\    print i
        \\}
    , &buf);
    try std.testing.expectEqualStrings("0\n1\n2\n", output);
}

test "a for loop's range bounds are evaluated once, not re-evaluated per iteration" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int n := 3
        \\int count := 0
        \\for i in 0..n {
        \\    count := count + 1
        \\    n := 0
        \\}
        \\print count
    , &buf);
    try std.testing.expectEqualStrings("3\n", output);
}

test "the for-loop variable does not leak outside the loop" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\for i in 0..3 {
        \\    print i
        \\}
        \\print i
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.UndefinedVariable, compiler.compileProgram(program));
}

test "a for loop iterating over an array sums its elements" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int[4] arr := [1, 2, 3, 4]
        \\int total := 0
        \\for i in 0..4 {
        \\    total := total + arr[i]
        \\}
        \\print total
    , &buf);
    try std.testing.expectEqualStrings("10\n", output);
}

test "sibling scopes reuse slots instead of growing the frame unboundedly" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\{
        \\    int[100] a
        \\}
        \\{
        \\    int[100] b
        \\    b[0] := 7
        \\    print b[0]
        \\}
    , &buf);
    try std.testing.expectEqualStrings("7\n", output);
}

test "a recursive function's local array is isolated per call frame" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func makeAndSum(int n) -> int {
        \\    int[2] pair := [n, n * 2]
        \\    if n == 0 {
        \\        return pair[0] + pair[1]
        \\    }
        \\    return pair[0] + pair[1] + makeAndSum(n - 1)
        \\}
        \\print makeAndSum(2)
    , &buf);
    // n=2: pair=[2,4]=6 + n=1: pair=[1,2]=3 + n=0: pair=[0,0]=0  => 9
    try std.testing.expectEqualStrings("9\n", output);
}

test "a function can take an array parameter and sum its elements" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func sum(int[4] arr) -> int {
        \\    int total := 0
        \\    for i in 0..len(arr) {
        \\        total := total + arr[i]
        \\    }
        \\    return total
        \\}
        \\int[4] nums := [1, 2, 3, 4]
        \\print sum(nums)
    , &buf);
    try std.testing.expectEqualStrings("10\n", output);
}

test "an array parameter is passed by value: mutating it inside the function doesn't affect the caller's array" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func zeroOut(int[3] arr) -> int {
        \\    arr[0] := 0
        \\    return arr[0]
        \\}
        \\int[3] nums := [1, 2, 3]
        \\print zeroOut(nums)
        \\print nums[0]
    , &buf);
    try std.testing.expectEqualStrings("0\n1\n", output);
}

test "a function can return an array, assigned directly into a matching array declaration" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func makePair(int a, int b) -> int[2] {
        \\    int[2] result := [a, b]
        \\    return result
        \\}
        \\int[2] p := makePair(3, 4)
        \\print p[0]
        \\print p[1]
    , &buf);
    try std.testing.expectEqualStrings("3\n4\n", output);
}

test "an array-returning function may take an array parameter too (transform-and-return)" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func doubleAll(int[3] arr) -> int[3] {
        \\    int[3] result
        \\    for i in 0..3 {
        \\        result[i] := arr[i] * 2
        \\    }
        \\    return result
        \\}
        \\int[3] nums := [1, 2, 3]
        \\int[3] doubled := doubleAll(nums)
        \\print doubled[0]
        \\print doubled[1]
        \\print doubled[2]
    , &buf);
    try std.testing.expectEqualStrings("2\n4\n6\n", output);
}

test "an array-returning call can compose directly as another array-returning function's argument" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func doubleAll(int[2] arr) -> int[2] {
        \\    int[2] result := [arr[0] * 2, arr[1] * 2]
        \\    return result
        \\}
        \\func sum(int[2] arr) -> int {
        \\    return arr[0] + arr[1]
        \\}
        \\int[2] nums := [3, 4]
        \\print sum(doubleAll(nums))
    , &buf);
    try std.testing.expectEqualStrings("14\n", output);
}

test "a recursive function may take and return arrays, each call frame isolated" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func addN(int[2] arr, int n) -> int[2] {
        \\    if n == 0 {
        \\        return arr
        \\    }
        \\    int[2] bumped := [arr[0] + 1, arr[1] + 1]
        \\    return addN(bumped, n - 1)
        \\}
        \\int[2] start := [0, 0]
        \\int[2] result := addN(start, 3)
        \\print result[0]
        \\print result[1]
        \\print start[0]
    , &buf);
    try std.testing.expectEqualStrings("3\n3\n0\n", output);
}

test "falling off the end of an array-returning function yields a zero-filled array" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func noop() -> int[2] {
        \\    int x := 1
        \\}
        \\int[2] r := noop()
        \\print r[0]
        \\print r[1]
    , &buf);
    try std.testing.expectEqualStrings("0\n0\n", output);
}

test "an array argument's length must match the parameter's declared size" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func sum(int[4] arr) -> int {
        \\    return arr[0]
        \\}
        \\int[3] nums := [1, 2, 3]
        \\print sum(nums)
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.ArrayLengthMismatch, compiler.compileProgram(program));
}

test "passing a non-array-name expression as an array argument is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func sum(int[3] arr) -> int {
        \\    return arr[0]
        \\}
        \\print sum(1 + 2)
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.InvalidArrayArgument, compiler.compileProgram(program));
}

test "returning a non-array-name expression from an array-returning function is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func f() -> int[2] {
        \\    return 1 + 2
        \\}
        \\int[2] r := f()
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.InvalidArrayReturn, compiler.compileProgram(program));
}

test "using an array-returning call as a plain scalar value is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func pair() -> int[2] {
        \\    int[2] r := [1, 2]
        \\    return r
        \\}
        \\print pair()
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.ArrayUsedAsScalar, compiler.compileProgram(program));
}

test "a generic array parameter accepts fixed-size arrays of different lengths" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func sum(int[] arr) -> int {
        \\    int total := 0
        \\    for i in 0..len(arr) {
        \\        total := total + arr[i]
        \\    }
        \\    return total
        \\}
        \\int[4] a := [1, 2, 3, 4]
        \\int[3] b := [10, 20, 30]
        \\print sum(a)
        \\print sum(b)
    , &buf);
    try std.testing.expectEqualStrings("10\n60\n", output);
}

test "len() on a generic array parameter is a runtime read, reflecting the actual argument's length" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func report(int[] arr) -> int {
        \\    return len(arr)
        \\}
        \\int[2] a := [1, 2]
        \\int[5] b := [1, 2, 3, 4, 5]
        \\print report(a)
        \\print report(b)
    , &buf);
    try std.testing.expectEqualStrings("2\n5\n", output);
}

test "a generic array parameter is passed by reference: mutations are visible to the caller" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func zeroOut(int[] arr) -> int {
        \\    arr[0] := 0
        \\    return arr[0]
        \\}
        \\int[3] nums := [1, 2, 3]
        \\print zeroOut(nums)
        \\print nums[0]
    , &buf);
    try std.testing.expectEqualStrings("0\n0\n", output);
}

test "a generic array return forwards the caller's own array by reference" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func identity(int[] arr) -> int[] {
        \\    return arr
        \\}
        \\func sum(int[] arr) -> int {
        \\    int total := 0
        \\    for i in 0..len(arr) {
        \\        total := total + arr[i]
        \\    }
        \\    return total
        \\}
        \\int[3] nums := [1, 2, 3]
        \\print sum(identity(nums))
    , &buf);
    try std.testing.expectEqualStrings("6\n", output);
}

test "a generic function may call another generic function recursively over the same array" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func sumFrom(int[] arr, int i) -> int {
        \\    if i == len(arr) {
        \\        return 0
        \\    }
        \\    return arr[i] + sumFrom(arr, i + 1)
        \\}
        \\int[4] nums := [1, 2, 3, 4]
        \\print sumFrom(nums, 0)
    , &buf);
    try std.testing.expectEqualStrings("10\n", output);
}

test "returning a reference to this function's own fixed-size local array is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func makeDangling() -> int[] {
        \\    int[3] local := [1, 2, 3]
        \\    return local
        \\}
        \\func wrapper() -> int[] {
        \\    return makeDangling()
        \\}
        \\print 1
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.EscapingArrayReference, compiler.compileProgram(program));
}

test "forwarding a fixed-size array result as a generic return is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func makeFixed() -> int[3] {
        \\    int[3] local := [1, 2, 3]
        \\    return local
        \\}
        \\func wrapper() -> int[] {
        \\    return makeFixed()
        \\}
        \\print 1
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.EscapingArrayReference, compiler.compileProgram(program));
}

test "passing a generic array where a fixed size is required is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func needsFixed(int[3] arr) -> int {
        \\    return arr[0]
        \\}
        \\func wrapper(int[] arr) -> int {
        \\    return needsFixed(arr)
        \\}
        \\print 1
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.InvalidArrayArgument, compiler.compileProgram(program));
}

test "compileModules: a module may call an exported function from a directly imported module" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;

    var lib = try parseSource(allocator, "export func double(int n) -> int { return n * 2 }\n");
    defer lib.parser.deinit();
    var main = try parseSource(allocator, "print double(21)\n");
    defer main.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{1} },
        .{ .program = lib.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(0, &units);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init();
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, &writer);
    try std.testing.expectEqualStrings("42\n", writer.buffered());
}

test "compileModules: calling a non-exported function from an imported module is a compile error" {
    const allocator = std.testing.allocator;
    var lib = try parseSource(allocator, "func helper() -> int { return 1 }\n");
    defer lib.parser.deinit();
    var main = try parseSource(allocator, "print helper()\n");
    defer main.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{1} },
        .{ .program = lib.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.FunctionNotVisible, compiler.compileModules(0, &units));
}

test "compileModules: no automatic re-export — a transitive import's exports aren't visible" {
    const allocator = std.testing.allocator;
    var c_mod = try parseSource(allocator, "export func base() -> int { return 1 }\n");
    defer c_mod.parser.deinit();
    var b_mod = try parseSource(allocator, "export func mid() -> int { return base() }\n");
    defer b_mod.parser.deinit();
    var a_mod = try parseSource(allocator, "print base()\n");
    defer a_mod.parser.deinit();

    // a imports b, b imports c; a does NOT import c directly, so a can't
    // call c's `base` even though b can (and even though base IS exported).
    const units = [_]ModuleUnit{
        .{ .program = a_mod.program, .imports = &.{1} },
        .{ .program = b_mod.program, .imports = &.{2} },
        .{ .program = c_mod.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.FunctionNotVisible, compiler.compileModules(0, &units));
}

test "compileModules: a duplicate function name across two different modules is a compile error" {
    const allocator = std.testing.allocator;
    var a_mod = try parseSource(allocator, "func f() -> int { return 1 }\n");
    defer a_mod.parser.deinit();
    var b_mod = try parseSource(allocator, "func f() -> int { return 2 }\n");
    defer b_mod.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = a_mod.program },
        .{ .program = b_mod.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.DuplicateFunction, compiler.compileModules(0, &units));
}

test "compileModules: two modules importing the same module both see one compiled copy of it" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;

    var d_mod = try parseSource(allocator, "export func ten() -> int { return 10 }\n");
    defer d_mod.parser.deinit();
    var b_mod = try parseSource(allocator, "export func fromB() -> int { return ten() }\n");
    defer b_mod.parser.deinit();
    var c_mod = try parseSource(allocator, "export func fromC() -> int { return ten() }\n");
    defer c_mod.parser.deinit();
    var main = try parseSource(allocator, "print fromB() + fromC()\n");
    defer main.parser.deinit();

    // main(0) imports b(1) and c(2); b and c both import d(3) — in the
    // real pipeline the module loader (module.zig) is what guarantees d
    // appears only once here despite being reachable via two import
    // paths; compileModules just trusts that its input is already deduped.
    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{ 1, 2 } },
        .{ .program = b_mod.program, .imports = &.{3} },
        .{ .program = c_mod.program, .imports = &.{3} },
        .{ .program = d_mod.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(0, &units);
    defer compiled.deinit(allocator);

    // Exactly one compiled Function per declared function across the whole
    // graph — `ten` is not duplicated despite being reachable via two
    // different import paths, which is the dedup guarantee this feature
    // is for.
    try std.testing.expectEqual(@as(usize, 3), compiled.functions.len);

    var vm = vm_mod.Vm.init();
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, &writer);
    try std.testing.expectEqualStrings("20\n", writer.buffered());
}
