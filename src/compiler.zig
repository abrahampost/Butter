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
    /// Bracket-indexing (or `len`'s relaxed position) on a bare local that's
    /// statically known to be neither an array, a list, a map, nor a string
    /// (ISA.bnf section 11) — e.g. `x[0]` where `x` is a plain `int`. Also
    /// covers slicing (`x[a..b]`) a bare ARRAY-typed local specifically,
    /// which `compileIndex`'s single-element read would otherwise allow but
    /// `compileSlice` never does (a raw array still isn't a first-class
    /// value to slice into a new one, GRAMMAR.bnf design note 3e). A non-
    /// identifier base that turns out to be a scalar only at RUNTIME (e.g.
    /// chaining off a fixed-array element) is `RuntimeError.TypeMismatch`
    /// instead; this is only for the case the compiler can already rule out.
    NotIndexable,
    FunctionNotVisible,
    InvalidArrayArgument,
    InvalidArrayReturn,
    EscapingArrayReference,
    WrongStreamDirection,
    CannotCloseStandardStream,
    /// A statically-known expression type doesn't fit where it's used —
    /// a var-decl/array-literal-element initializer, an assignment, a call
    /// argument, a return value, a binary/unary/logical operator's operand,
    /// an if/while condition (must be `bool`), a for-loop bound (must be
    /// `int`), or an `exit` code (must be `int`) — design note 3t. Only
    /// raised when `inferType` can actually pin down the expression's type;
    /// anything it can't (a map/list element, `json`'s parsed root, ...)
    /// is left to the existing runtime `RuntimeError.TypeMismatch` checks,
    /// same as before this feature existed.
    TypeMismatch,
    /// A `<type>` position (var-decl, param, return type, struct field)
    /// names an IDENTIFIER that isn't any declared struct/enum type
    /// (GRAMMAR.bnf design notes 3z/3aa) — the struct/enum counterpart to
    /// `UndefinedFunction`.
    UndefinedType,
    /// A struct or enum is declared with a name another struct or enum
    /// already has, anywhere in the compiled program (they share one
    /// namespace) — the struct/enum counterpart to `DuplicateFunction`.
    DuplicateTypeName,
    /// A struct declaration repeats the same field name twice.
    DuplicateField,
    /// An enum declaration repeats the same variant name twice.
    DuplicateVariant,
    /// A `.field` read/write, or a struct literal's key, names a field the
    /// struct doesn't have. Never a `RuntimeError` — this is the entire
    /// point of alternative C's compile-time-resolved field access (design
    /// note 3z): a wrong field name is always caught here, never surfaces
    /// as a runtime `KeyNotFound`-style failure the way a bad map key would.
    UnknownField,
    /// A struct literal doesn't supply a value for one of its declared
    /// fields — every field is required (design note 3z).
    MissingField,
    /// A struct literal gives the same field a value more than once.
    DuplicateFieldInLiteral,
    /// A `.field` access's base is statically known to be something other
    /// than a struct (or its type can't be pinned down at compile time at
    /// all) — field access, unlike bracket-indexing, is never left to a
    /// runtime check: the field's slot has to be known here (design note
    /// 3z), so there is nothing for the VM to check instead.
    NotAStruct,
    /// `EnumType.name` where `name` isn't one of that enum's declared
    /// variants.
    UnknownEnumVariant,
    /// A struct/enum type exists but isn't exported by a module this file
    /// imports — the struct/enum counterpart to `FunctionNotVisible`.
    TypeNotVisible,
    /// A bare function-name expression (GRAMMAR.bnf design note 3ad) names
    /// a function that has an array-typed parameter, a struct/enum-typed
    /// parameter or return type, or an array return type — none of which a
    /// function VALUE can describe (`func(...)...`'s own signature is
    /// scalar-only).
    InvalidFunctionValue,
    /// A function-typed (`func(...)...`) local/parameter has no initializer
    /// — unlike every other type, there is no default "zero" function
    /// value to fall back to (design note 3ad).
    MissingFunctionInitializer,
    /// A method declaration's receiver clause names an enum, not a struct
    /// (GRAMMAR.bnf design note 3af) — enums are compile-time constants
    /// with no instance for a receiver parameter to bind. A receiver
    /// clause naming no declared type at all is `UndefinedType`/
    /// `TypeNotVisible` instead, exactly like any other named-type
    /// position (`resolveDeclaredType`); a method call whose base isn't
    /// statically a struct is `NotAStruct`, exactly like an ordinary field
    /// access (`resolveStructBase`).
    ReceiverNotAStruct,
    /// A struct declares a field and a method (or two methods) with the
    /// same name — the two would otherwise be ambiguous wherever a bare
    /// `.name` (no trailing call) is read, since only one of them can win
    /// (GRAMMAR.bnf design note 3af).
    DuplicateFieldOrMethod,
    /// A `.method(...)` call names a method its base's struct type doesn't
    /// have — the method counterpart of `UnknownField`.
    UnknownMethod,
};
pub const CompileError = SemanticError || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    /// The `ModuleUnit.path` of whichever module was being compiled when
    /// this diagnostic was raised (`Compiler.current_module_path`) — for
    /// the single-file `compileProgram` convenience wrapper, always
    /// `ModuleUnit`'s own default. The CLI (main.zig) surfaces this so a
    /// compile error inside an imported file names that file, not just an
    /// ambiguous line number relative to some unstated module.
    path: []const u8,
    line: usize,
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
    /// A separate, orthogonal axis from `array`: null for anything that
    /// isn't a map/list, `.map`/`.list` otherwise (ISA.bnf section 11). Kept
    /// distinct from `array` rather than folded into `ArraySpec` because
    /// `map`/`list` are entirely new `<type>` keywords that never take the
    /// `[N]`/`[]` suffix `ArraySpec` represents — they're always exactly one
    /// heap-reference slot, addressed via INDEX_GET/INDEX_SET instead of any
    /// of the array opcodes.
    collection: ?CollectionKind = null,
    /// A third, independent axis from `array`/`collection`: true for a
    /// plain `string` local (GRAMMAR.bnf's Strings design notes). Also
    /// always exactly one heap-reference slot, but kept separate from
    /// `CollectionKind` rather than folded in — a string is indexable/
    /// sliceable (INDEX_GET/INDEX_SLICE) but, unlike a map/list, never
    /// assignable through a bracket (no INDEX_SET case for it).
    is_string: bool = false,
    /// This local's declared `<type>` — for an array-typed local, its
    /// scalar ELEMENT type (design note 3e: an array's element is always a
    /// plain scalar), not "array of N". Used by the static type checker
    /// (design note 3t) to type-check a bare-variable read/write and, for
    /// a bare-array-name index, the element type `compileIndex`'s
    /// LOAD_INDEX/LOAD_INDEX_REF path produces.
    value_type: ast.ValueType,
    /// Set only when `value_type == .named` (a struct/enum-typed local or
    /// parameter — always exactly one heap-reference or scalar slot, same
    /// as `collection`/`is_string`, so never combined with `array`) — which
    /// registered type this is and whether it's a struct or an enum. See
    /// `ast.ValueType.named`'s doc comment for why this travels as a
    /// sibling field rather than being folded into `value_type` itself.
    named_ref: ?NamedTypeRef = null,
    /// Set only when `value_type == .func` (GRAMMAR.bnf design note 3ad) —
    /// the declared signature any function value stored here must match.
    /// Borrowed straight from the declaring `ast.Param`/`ast.Stmt.VarDecl`
    /// (needs no resolution the way `named_ref` does, since a signature's
    /// own param/return types are always plain scalars).
    func_sig: ?*const ast.FuncSig = null,
};

/// Which registered type (in `Compiler.types`) a `.named` `ast.ValueType`
/// resolves to, and whether it's a struct or an enum (GRAMMAR.bnf design
/// notes 3z/3aa) — see `ast.ValueType.named`'s doc comment for why this
/// travels as a sibling value rather than being folded into `ast.ValueType`
/// itself.
const NamedTypeRef = struct {
    index: u32,
    is_enum: bool,
};

/// The compiler's own working currency wherever `ast.ValueType` alone
/// denoted a fully-resolved DECLARED type before struct/enum existed (a
/// local's/parameter's/field's own type, a function's return type):
/// `named_ref` is set (and `type == .named`) for a struct/enum-typed
/// position, resolved once (`resolveDeclaredType`) rather than re-resolved
/// by name on every use.
const DeclaredType = struct {
    type: ast.ValueType,
    named_ref: ?NamedTypeRef = null,
    /// Set only when `type == .func` — see `Local.func_sig`'s doc comment.
    func_sig: ?*const ast.FuncSig = null,

    fn builtin(t: ast.ValueType) DeclaredType {
        std.debug.assert(t != .named and t != .func);
        return .{ .type = t };
    }
};

/// The declared type `throw <expression>` (design note 3u) checks its
/// operand against — the built-in `Error` struct, the same static type
/// `compileTry`'s catch binding uses. Can't be `DeclaredType.builtin`, which
/// asserts away `.named` types entirely.
fn errorDeclaredType() DeclaredType {
    return .{ .type = .named, .named_ref = .{ .index = error_type_index, .is_enum = false } };
}

/// One field of a registered struct type — `type` is already fully
/// resolved (never a bare unresolved name), unlike `ast.FieldDecl`.
const FieldInfo = struct {
    name: []const u8,
    type: DeclaredType,
};

const TypeKind = union(enum) {
    struct_decl: struct {
        /// Allocator-owned (`Compiler.allocator`) — freed by `Compiler.deinit`.
        /// Empty until stage 2 of `compileModules`'s type pre-pass resolves
        /// it (stage 1 only registers the NAME, so mutually/forward-
        /// referencing struct fields can resolve regardless of declaration
        /// order — same reasoning `FunctionInfo`'s own up-front registration
        /// pass already relies on).
        fields: []const FieldInfo,
    },
    /// Borrowed directly from the declaring `ast.Stmt.EnumDecl` — never
    /// needs resolution the way a struct's fields do (a variant is just a
    /// name, not itself a `<type>`), so nothing to freshly allocate here.
    enum_decl: struct {
        variants: []const []const u8,
    },
};

/// A registered struct or enum type (GRAMMAR.bnf design notes 3z/3aa) —
/// struct and enum names share one namespace, program-wide, exactly
/// mirroring how function names are unique across the whole compiled
/// program regardless of which module declares them.
const TypeDecl = struct {
    name: []const u8,
    module: usize,
    exported: bool,
    kind: TypeKind,
    /// True only for the compiler-synthesized `Error` type (design note 3u)
    /// registered by `compileModules` before any user module is processed —
    /// never set by the struct/enum-declaration pre-pass. Unlike a user
    /// type, it belongs to no module at all, so `typeVisible` grants it
    /// unconditionally rather than checking `module`/`exported`/imports the
    /// normal way; nothing else treats this type differently; it goes
    /// through the same `struct_decl`/field-index machinery as any other.
    builtin: bool = false,
};

const CollectionKind = enum { map, list };

/// `self.types`/`Program.struct_types` index the built-in `Error` struct
/// type (design note 3u) always occupies — `compileModules` registers it
/// first, before any user struct/enum, specifically so this stays valid.
/// vm.zig's `errorValue` hardcodes the same index when building a caught
/// error's runtime record.
const error_type_index: u32 = 0;

/// A local/parameter's width in stack slots: 1 for a plain scalar OR a
/// generic array reference (both are exactly one `Value`), `n` for a
/// fixed-size array of `n` elements.
fn arraySpecWidth(spec: ?ast.ArraySpec) u32 {
    return switch (spec orelse return 1) {
        .fixed => |n| n,
        .generic => 1,
    };
}

/// `Local.collection`/`FunctionInfo` registration for a declared `<type>` —
/// null for the four scalar types, `.map`/`.list` for the two heap types.
fn collectionKind(value_type: ast.ValueType) ?CollectionKind {
    return switch (value_type) {
        .map => .map,
        .list => .list,
        .int, .float, .bool, .string, .named, .func => null,
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
    /// Parallel to `params` (same length, same index correspondence) —
    /// `params[i].named_type` resolved once at registration time, rather
    /// than by name on every call site. Allocator-owned; freed by
    /// `Compiler.deinit`.
    param_named_refs: []const ?NamedTypeRef,
    return_array_size: ?ast.ArraySpec,
    /// The declared return type — for an array-returning function, its
    /// scalar ELEMENT type (same convention as `Local.value_type`). Used by
    /// the static type checker (design note 3t) to type a `.call` expression
    /// and to check an array-returning call's element type against a
    /// declared array local's.
    return_type: ast.ValueType,
    /// Set only when `return_type == .named` — see `Local.named_ref`'s doc
    /// comment for why this travels as a sibling field.
    return_named_ref: ?NamedTypeRef,
    arity: u32,
    index: u32,
    module: usize,
    exported: bool,
};

/// A registered struct method (GRAMMAR.bnf design note 3af) — the
/// `(receiver_type_index, name)` pair method calls resolve against, kept
/// entirely separate from `Compiler.functions`' own by-bare-name lookup
/// (`findFunction`) so that two different structs can each declare a
/// method with the same name without colliding, and so a bare `dist()`
/// call can never accidentally resolve to some struct's `dist` method.
/// `function_index` is where the desugared method (receiver prepended as
/// parameter 0 — see `compileModules`) actually lives in
/// `Compiler.functions`/`Program.functions`, exactly like any other
/// `FunctionInfo.index`; a method call compiles to an ordinary CALL
/// against it, no different from a plain function call.
const MethodInfo = struct {
    receiver_type_index: usize,
    /// Borrowed from the declaring `ast.StmtKind.MethodDecl.name`, same
    /// lifetime convention as `FunctionInfo.name`.
    name: []const u8,
    /// `[receiver_param] ++ declared_params` — synthesized fresh at
    /// registration time (there is no existing `ast.Param` slice already
    /// shaped this way to borrow, unlike a plain function's own `params`).
    /// Allocator-owned; freed by `Compiler.deinit`. `Compiler.functions`'
    /// own entry for this method borrows this exact same slice as its
    /// `.params` — freed here, not there, since `FunctionInfo.params` is
    /// otherwise always a borrow with nothing for `deinit` to free.
    params: []ast.Param,
    function_index: u32,
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
    /// This module's own path/name, purely for `Diagnostic.path` — the
    /// module loader (module.zig) sets this to the same canonical path it
    /// tracks its own diagnostics against, so a compile error inside an
    /// imported file names that file, not the entry program. The default
    /// is what `compileProgram`'s single-file wrapper (and every
    /// hand-built `ModuleUnit` in this file's own tests) gets.
    path: []const u8 = "<program>",
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
    /// Every struct method registered across all modules (GRAMMAR.bnf
    /// design note 3af), built by its own pre-pass in `compileModules`
    /// after `functions` (a method may call an ordinary function or another
    /// method, but nothing calls a method before every struct type — and
    /// therefore every method's receiver — is known). See `MethodInfo`'s
    /// own doc comment for why this is a separate table from `functions`
    /// rather than folded into it.
    methods: std.ArrayList(MethodInfo) = .empty,
    /// Every struct/enum type registered across all modules (GRAMMAR.bnf
    /// design notes 3z/3aa), built by a two-stage pre-pass in
    /// `compileModules` before functions are even registered (a param/
    /// return type may itself be a struct/enum, so type names must already
    /// be known by the time functions are registered).
    types: std.ArrayList(TypeDecl) = .empty,
    /// True while compiling a function body — the only context in which
    /// `return` is legal (see `SemanticError.ReturnOutsideFunction`).
    in_function: bool = false,
    /// Which `ModuleUnit` (by index, into the slice passed to
    /// `compileModules`) is currently being compiled — a call to one of
    /// its own functions is always visible regardless of `exported`
    /// (`functionVisible`'s same-module check).
    current_module: usize = 0,
    /// `current_module`'s own `ModuleUnit.path`, stamped onto every
    /// diagnostic `fail()` raises while it's compiling (`Diagnostic.path`).
    current_module_path: []const u8 = "<program>",
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
    /// Set for the duration of `compileFunctionBody` to the function
    /// currently being compiled's declared return type (its scalar element
    /// type when `current_return_array_size` isn't null) — a scalar
    /// `return`'s static type check (design note 3t) is against this.
    current_return_type: ast.ValueType = .int,
    /// Set alongside `current_return_type` for the duration of
    /// `compileFunctionBody` — see `Local.named_ref`'s doc comment for why
    /// this travels as a sibling field.
    current_return_named_ref: ?NamedTypeRef = null,
    /// The line number of the statement currently being compiled, used by
    /// `fail()` to stamp error diagnostics with accurate source locations.
    current_line: usize = 0,
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
        for (self.functions.items) |f| self.allocator.free(f.param_named_refs);
        self.functions.deinit(self.allocator);
        for (self.methods.items) |m| self.allocator.free(m.params);
        self.methods.deinit(self.allocator);
        for (self.types.items) |t| switch (t.kind) {
            .struct_decl => |sd| self.allocator.free(sd.fields),
            .enum_decl => {},
        };
        self.types.deinit(self.allocator);
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
        // Pass 0: register the built-in `Error` struct type (design note 3u)
        // — the type `try`/`catch`'s binding is typed as — before any user
        // struct/enum name, so it always lands at `self.types.items[0]` /
        // `Program.struct_types[0]`, the fixed index vm.zig's `errorValue`
        // hardcodes. `builtin = true` is what makes it visible from every
        // module unconditionally (`typeVisible`), unlike a real declared
        // type, which only reaches modules that import it. Field order/
        // names/count must exactly match vm.zig's `errorValue`.
        const error_fields = try self.allocator.dupe(FieldInfo, &[_]FieldInfo{
            .{ .name = "error", .type = DeclaredType.builtin(.string) },
            .{ .name = "message", .type = DeclaredType.builtin(.string) },
            .{ .name = "operation", .type = DeclaredType.builtin(.string) },
            .{ .name = "path", .type = DeclaredType.builtin(.string) },
        });
        try self.types.append(self.allocator, .{
            .name = "Error",
            .module = entry,
            .exported = true,
            .builtin = true,
            .kind = .{ .struct_decl = .{ .fields = error_fields } },
        });
        std.debug.assert(self.types.items.len - 1 == @as(usize, error_type_index));

        // Pass 0a: collect every struct/enum type's NAME across all modules
        // (GRAMMAR.bnf design notes 3z/3aa) before resolving any of them —
        // this is what lets a struct's field (stage 0b, below), or a
        // function's param/return type (pass 1), reference a struct/enum
        // declared later in the same file or in another module entirely,
        // exactly the way functions can already call each other regardless
        // of declaration order.
        for (modules, 0..) |m, mi| {
            for (m.program) |*stmt| {
                const name, const exported = switch (stmt.kind) {
                    .struct_decl => |s| .{ s.name, s.exported },
                    .enum_decl => |e| .{ e.name, e.exported },
                    else => continue,
                };
                self.current_line = stmt.line;
                if (self.findTypeIndex(name) != null) {
                    return self.fail(SemanticError.DuplicateTypeName, name, "a struct or enum with this name already exists");
                }
                const kind: TypeKind = switch (stmt.kind) {
                    .struct_decl => .{ .struct_decl = .{ .fields = &.{} } }, // resolved in stage 0b, below
                    .enum_decl => |e| blk: {
                        for (e.variants, 0..) |v, i| {
                            for (e.variants[0..i]) |prev| {
                                if (std.mem.eql(u8, prev, v)) return self.fail(SemanticError.DuplicateVariant, v, "a variant with this name is already declared in this enum");
                            }
                        }
                        break :blk .{ .enum_decl = .{ .variants = e.variants } };
                    },
                    else => unreachable,
                };
                try self.types.append(self.allocator, .{ .name = name, .module = mi, .exported = exported, .kind = kind });
            }
        }

        // Pass 0b: resolve every struct's field types now that every type's
        // NAME (from every module) is registered. Each struct is resolved
        // from its own declaring module's visibility perspective
        // (`resolveDeclaredType`/`typeVisible`, mirroring `functionVisible`).
        for (modules, 0..) |m, mi| {
            self.current_module = mi;
            self.visible_imports = m.imports;
            for (m.program) |*stmt| {
                if (stmt.kind != .struct_decl) continue;
                const s = stmt.kind.struct_decl;
                self.current_line = stmt.line;
                const type_index = self.findTypeIndex(s.name).?; // registered in stage 0a, above

                const fields = try self.allocator.alloc(FieldInfo, s.fields.len);
                errdefer self.allocator.free(fields);
                for (s.fields, 0..) |fd, i| {
                    for (s.fields[0..i]) |prev| {
                        if (std.mem.eql(u8, prev.name, fd.name)) return self.fail(SemanticError.DuplicateField, fd.name, "a field with this name is already declared in this struct");
                    }
                    fields[i] = .{ .name = fd.name, .type = try self.resolveDeclaredType(fd.type, fd.named_type) };
                }
                self.types.items[type_index].kind.struct_decl.fields = fields;
            }
        }

        for (modules, 0..) |m, mi| {
            self.current_module = mi;
            self.visible_imports = m.imports;
            for (m.program) |*stmt| {
                if (stmt.kind != .function_decl) continue;
                const f = stmt.kind.function_decl;
                if (self.findFunction(f.name) != null) {
                    self.current_line = stmt.line;
                    return self.fail(SemanticError.DuplicateFunction, f.name, "function already declared");
                }
                self.current_line = stmt.line;
                const param_named_refs = try self.allocator.alloc(?NamedTypeRef, f.params.len);
                for (f.params, 0..) |p, i| {
                    param_named_refs[i] = if (p.type == .named) (try self.resolveDeclaredType(p.type, p.named_type)).named_ref else null;
                }
                const return_named_ref: ?NamedTypeRef = if (f.return_type == .named) (try self.resolveDeclaredType(f.return_type, f.return_named_type)).named_ref else null;
                try self.functions.append(self.allocator, .{
                    .name = f.name,
                    .params = f.params,
                    .param_named_refs = param_named_refs,
                    .return_array_size = f.return_array_size,
                    .return_type = f.return_type,
                    .return_named_ref = return_named_ref,
                    .arity = totalParamWidth(f.params),
                    .index = @intCast(self.functions.items.len),
                    .module = mi,
                    .exported = f.exported,
                });
            }
        }

        // Pass 1b: register every method (GRAMMAR.bnf design note 3af), now
        // that every struct's fields (pass 0b) and every plain function
        // (pass 1, above) are known — a method's receiver clause needs the
        // former to resolve/validate against, and its body may call the
        // latter. Desugars each one into an ordinary `FunctionInfo` whose
        // parameter 0 is the receiver (`params[0]`, built fresh below) and
        // registers it into `self.functions` exactly like a plain function
        // — so pass 3's body compilation, `compileFunctionBody`'s local-slot
        // assignment, and CALL's own operand all keep working completely
        // unchanged; only resolving a `.method(...)` CALL SITE to this
        // function index goes through the separate `self.methods` table
        // (`MethodInfo`'s doc comment) instead of `findFunction`.
        for (modules, 0..) |m, mi| {
            self.current_module = mi;
            self.visible_imports = m.imports;
            for (m.program) |*stmt| {
                if (stmt.kind != .method_decl) continue;
                const md = stmt.kind.method_decl;
                self.current_line = stmt.line;

                const recv_declared = try self.resolveDeclaredType(.named, md.receiver_type);
                const recv_ref = recv_declared.named_ref.?;
                if (recv_ref.is_enum) return self.fail(SemanticError.ReceiverNotAStruct, md.receiver_type, "a method's receiver must be a struct, not an enum");
                const recv_type_index: usize = recv_ref.index;

                // Field/method name collision (GRAMMAR.bnf design note
                // 3af) — checked against the receiver struct's ALREADY-
                // RESOLVED fields (pass 0b ran before this pass) and every
                // method already registered for the same receiver, so
                // declaration order never matters (same "declare, then
                // validate regardless of source order" stance every other
                // pre-pass in `compileModules` already takes).
                const recv_fields = self.types.items[recv_type_index].kind.struct_decl.fields;
                for (recv_fields) |fld| {
                    if (std.mem.eql(u8, fld.name, md.name)) return self.fail(SemanticError.DuplicateFieldOrMethod, md.name, "this struct already declares a field with this name");
                }
                for (self.methods.items) |existing| {
                    if (existing.receiver_type_index == recv_type_index and std.mem.eql(u8, existing.name, md.name)) {
                        return self.fail(SemanticError.DuplicateFieldOrMethod, md.name, "this struct already declares a method with this name");
                    }
                }

                const params = try self.allocator.alloc(ast.Param, md.params.len + 1);
                errdefer self.allocator.free(params);
                params[0] = .{ .type = .named, .named_type = md.receiver_type, .name = md.receiver_name };
                @memcpy(params[1..], md.params);

                const param_named_refs = try self.allocator.alloc(?NamedTypeRef, params.len);
                param_named_refs[0] = recv_ref;
                for (md.params, 0..) |p, i| {
                    param_named_refs[i + 1] = if (p.type == .named) (try self.resolveDeclaredType(p.type, p.named_type)).named_ref else null;
                }
                const return_named_ref: ?NamedTypeRef = if (md.return_type == .named) (try self.resolveDeclaredType(md.return_type, md.return_named_type)).named_ref else null;

                const function_index: u32 = @intCast(self.functions.items.len);
                try self.functions.append(self.allocator, .{
                    .name = md.name,
                    .params = params,
                    .param_named_refs = param_named_refs,
                    .return_array_size = md.return_array_size,
                    .return_type = md.return_type,
                    .return_named_ref = return_named_ref,
                    .arity = totalParamWidth(params),
                    .index = function_index,
                    .module = mi,
                    .exported = md.exported,
                });
                try self.methods.append(self.allocator, .{
                    .receiver_type_index = recv_type_index,
                    .name = md.name,
                    .params = params,
                    .function_index = function_index,
                });
            }
        }

        self.current_module = entry;
        self.current_module_path = modules[entry].path;
        self.visible_imports = modules[entry].imports;

        // `main_chunk` and `compiled` are only handed to the caller (who
        // then owns them) once `compileModules` returns successfully; a
        // failure partway through pass 3 must free them here instead; each
        // `errdefer` below is scoped so it only fires for errors at or
        // after the point the resource it guards actually exists.
        var main_chunk: Chunk = blk: {
            errdefer self.chunk.deinit(self.allocator);
            for (modules[entry].program) |*stmt| {
                if (stmt.kind == .function_decl or stmt.kind == .method_decl or stmt.kind == .import_stmt or stmt.kind == .struct_decl or stmt.kind == .enum_decl) continue;
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
            self.current_module_path = m.path;
            self.visible_imports = m.imports;
            for (m.program) |*stmt| {
                if (stmt.kind != .function_decl) continue;
                const f = stmt.kind.function_decl;
                const info = self.findFunction(f.name).?; // registered in pass 1, above
                const body_chunk = try self.compileFunctionBody(f, info);
                try compiled.append(self.allocator, .{
                    .name = f.name,
                    .arity = info.arity,
                    .return_width = arraySpecWidth(f.return_array_size),
                    .chunk = body_chunk,
                });
            }
        }

        // Same shape as the plain-function loop just above, but for methods
        // (GRAMMAR.bnf design note 3af) — traverses `modules`/`m.program`
        // identically (filtered to `.method_decl` instead), which is what
        // keeps this loop's `compiled.append` order lined up with pass 1b's
        // own registration order: `compiled.items[k]`'s index must equal
        // `FunctionInfo.index`/`MethodInfo.function_index` for whichever
        // method is the k-th one appended overall, and both passes visit
        // every module's methods in this same order. Builds a synthetic
        // `ast.StmtKind.FunctionDecl` — `compileFunctionBody` neither knows
        // nor cares that a method's `params`/`info` differ from a plain
        // function's only by the receiver already folded into `params[0]`.
        for (modules, 0..) |m, mi| {
            self.current_module = mi;
            self.current_module_path = m.path;
            self.visible_imports = m.imports;
            for (m.program) |*stmt| {
                if (stmt.kind != .method_decl) continue;
                const md = stmt.kind.method_decl;
                const type_index = self.findTypeIndex(md.receiver_type).?; // registered in pass 1b, above
                const method = self.findMethod(type_index, md.name).?; // likewise
                const info = self.functions.items[method.function_index];
                const synthetic_decl: ast.StmtKind.FunctionDecl = .{
                    .name = md.name,
                    .params = method.params,
                    .return_type = md.return_type,
                    .return_named_type = md.return_named_type,
                    .return_array_size = md.return_array_size,
                    .body = md.body,
                    .exported = md.exported,
                };
                const body_chunk = try self.compileFunctionBody(synthetic_decl, info);
                try compiled.append(self.allocator, .{
                    .name = md.name,
                    .arity = info.arity,
                    .return_width = arraySpecWidth(md.return_array_size),
                    .chunk = body_chunk,
                });
            }
        }

        // Builds the runtime-facing struct-type table MAKE_STRUCT's operand
        // indexes into (ISA.bnf section 19) — indexed identically to
        // `self.types` itself (one entry per registered type, struct OR
        // enum) so a type_index resolved anywhere in this compiler is
        // always valid here unchanged; an enum's own entry is never
        // actually read (MAKE_STRUCT's operand, by construction, only ever
        // names a struct's own type_index) but is filled in anyway rather
        // than left a gap, so this table's shape needs no separate
        // struct-only renumbering pass.
        var struct_types_list: std.ArrayList(chunk_mod.StructType) = .empty;
        errdefer {
            for (struct_types_list.items) |st| self.allocator.free(st.field_names);
            struct_types_list.deinit(self.allocator);
        }
        for (self.types.items) |t| {
            switch (t.kind) {
                .struct_decl => |sd| {
                    const field_names = try self.allocator.alloc([]const u8, sd.fields.len);
                    for (sd.fields, 0..) |f, j| field_names[j] = f.name;
                    try struct_types_list.append(self.allocator, .{ .type_name = t.name, .field_names = field_names });
                },
                .enum_decl => try struct_types_list.append(self.allocator, .{ .type_name = t.name, .field_names = &.{} }),
            }
        }

        return .{
            .main = main_chunk,
            .functions = try compiled.toOwnedSlice(self.allocator),
            .struct_types = try struct_types_list.toOwnedSlice(self.allocator),
        };
    }

    /// Compiles one function's body into a fresh, self-contained chunk:
    /// params become locals 0..arity-1 (mirroring how a top-level
    /// var-decl's initializer becomes that local's runtime storage — see
    /// `compileVarDecl`), then every statement in the body compiles as
    /// usual. If control falls off the end without an explicit `return`,
    /// the return type's zero value is returned implicitly (the same
    /// `defaultValue` a var-decl without an initializer gets).
    ///
    /// `info` is `f`'s own already-registered `FunctionInfo` (pass 1/1b),
    /// passed in directly by the caller rather than re-derived here via
    /// `findFunction(f.name)` — a method's own `FunctionInfo.name` is just
    /// its bare method name (GRAMMAR.bnf design note 3af), which two
    /// different structs' methods may share, so a by-name lookup here could
    /// resolve the wrong one; a plain function's name is always unique
    /// (`DuplicateFunction`), so this changes nothing observable for it.
    fn compileFunctionBody(self: *Compiler, f: ast.StmtKind.FunctionDecl, info: FunctionInfo) CompileError!Chunk {
        self.chunk = .{};
        errdefer self.chunk.deinit(self.allocator);
        self.locals.clearRetainingCapacity();
        self.scope_depth = 0;
        self.next_slot = 0;
        self.in_function = true;
        self.current_return_array_size = f.return_array_size;
        self.current_return_type = f.return_type;
        self.current_return_named_ref = info.return_named_ref;
        defer self.in_function = false;
        defer self.current_return_array_size = null;

        for (f.params, 0..) |p, i| {
            try self.locals.append(self.allocator, .{
                .name = p.name,
                .depth = 0,
                .slot = self.next_slot,
                .array = p.array_size,
                .collection = collectionKind(p.type),
                .is_string = p.type == .string,
                .value_type = p.type,
                .named_ref = info.param_named_refs[i],
                .func_sig = p.func_sig,
            });
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
                // Array element types are always plain scalars (design note
                // 3e — a named struct/enum type never takes the array
                // suffix), so `f.return_type` is never `.named` here.
                const idx = try self.chunk.addConstant(self.allocator, try self.defaultValue(DeclaredType.builtin(f.return_type)));
                var i: u32 = 0;
                while (i < n) : (i += 1) _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
            .generic => {
                const idx = try self.chunk.addConstant(self.allocator, .{ .array_ref = .{ .base = 0, .len = 0 } });
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
        } else {
            // An empty map/list, or a struct instance, isn't a compile-time
            // constant (each is a genuine heap allocation), so this can't
            // route through `defaultValue`+PUSH_CONST the way every scalar
            // (including an enum's own zero value) can —
            // `compileDefaultValue` is what tells these apart.
            const dt: DeclaredType = if (f.return_type == .named) .{ .type = .named, .named_ref = self.current_return_named_ref } else DeclaredType.builtin(f.return_type);
            try self.compileDefaultValue(dt);
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

    /// Resolves a struct method by `(receiver_type_index, name)` — see
    /// `MethodInfo`'s doc comment for why this is a dedicated scan over
    /// `self.methods` rather than `findFunction`'s bare-name lookup.
    fn findMethod(self: *const Compiler, receiver_type_index: usize, name: []const u8) ?MethodInfo {
        for (self.methods.items) |m| {
            if (m.receiver_type_index == receiver_type_index and std.mem.eql(u8, m.name, name)) return m;
        }
        return null;
    }

    fn findTypeIndex(self: *const Compiler, name: []const u8) ?usize {
        for (self.types.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, name)) return i;
        }
        return null;
    }

    fn findType(self: *const Compiler, name: []const u8) ?TypeDecl {
        const i = self.findTypeIndex(name) orelse return null;
        return self.types.items[i];
    }

    /// Mirrors `functionVisible` exactly (GRAMMAR.bnf design note h,
    /// extended to type declarations by design notes 3z/3aa): a struct/enum
    /// is nameable from wherever `self.current_module` is right now if it
    /// belongs to that same module (regardless of `exported`), or if it's
    /// `exported` by one of that module's *direct* imports.
    fn typeVisible(self: *const Compiler, decl: TypeDecl) bool {
        if (decl.builtin) return true;
        if (decl.module == self.current_module) return true;
        if (!decl.exported) return false;
        for (self.visible_imports) |m| {
            if (m == decl.module) return true;
        }
        return false;
    }

    /// Resolves a parsed `<type>` (an `ast.ValueType` plus its sibling
    /// `named_type` string — see `ast.ValueType.named`'s doc comment) into
    /// this compiler's own `DeclaredType`. Every non-`.named` type passes
    /// through unchanged; a `.named` one is looked up by name against
    /// `self.types` (registered by `compileModules`'s pre-pass) and its
    /// visibility checked the same way a called function's is.
    fn resolveDeclaredType(self: *Compiler, t: ast.ValueType, named_type: ?[]const u8) CompileError!DeclaredType {
        if (t != .named) return DeclaredType.builtin(t);
        const name = named_type.?;
        const index = self.findTypeIndex(name) orelse return self.fail(SemanticError.UndefinedType, name, "no struct or enum with this name is declared");
        const decl = self.types.items[index];
        if (!self.typeVisible(decl)) return self.fail(SemanticError.TypeNotVisible, name, "type exists but isn't exported by a module this file imports");
        return .{ .type = .named, .named_ref = .{ .index = @intCast(index), .is_enum = decl.kind == .enum_decl } };
    }

    fn fail(self: *Compiler, comptime err: SemanticError, name: []const u8, message: []const u8) CompileError {
        self.diagnostic = .{ .path = self.current_module_path, .line = self.current_line, .name = name, .message = message };
        return err;
    }

    // ---- Static type checking (design note 3t) ---------------------------
    //
    // Butter has no runtime concept of a local's "declared type" — a local
    // is just a raw stack slot, and every fallible shape mismatch (wrong
    // operand to `+`, a non-bool `if` condition, ...) has always been a
    // `RuntimeError.TypeMismatch` the VM raises on the ACTUAL value it sees
    // (ISA.bnf, "checked, not trusted"). What follows adds a purely
    // compile-time, best-effort layer on top: wherever an expression's type
    // can be pinned down from what's already known at compile time (a
    // local's/parameter's/return's declared `<type>`, a literal, an
    // operator's own semantics), a mismatch against a declared type is now
    // `SemanticError.TypeMismatch` instead of waiting for the VM to notice.
    // It deliberately does NOT reach into a map/list's element type or
    // `json`'s parsed root — those stay fully dynamic, exactly as before.

    /// A statically-known type, when one is determinable at compile time.
    /// `.stream` doesn't correspond to any `<type>` keyword — Butter has no
    /// syntax to declare a stream-typed local — but the established
    /// convention throughout this codebase (examples/files.butter,
    /// examples/json.butter) is to declare a variable holding an `open()`
    /// result as `int`; `typeCompatible` honors that rather than breaking
    /// every existing file-I/O example. `.null_type` is `null`'s own literal
    /// type: it never satisfies any declared `<type>`, since there is no
    /// nullable variant of any of the six.
    const StaticType = union(enum) {
        scalar: ast.ValueType,
        stream,
        null_type,
        /// A struct-typed value — index into `Compiler.types` (GRAMMAR.bnf
        /// design note 3z). Never coerces to/from anything else, including
        /// a different struct type: `typeCompatible` requires an exact
        /// index match, the same "own exact type only, no coercions"
        /// treatment `bool`/`string`/`map`/`list` already get.
        struct_type: u32,
        /// An enum-typed value — index into `Compiler.types` (GRAMMAR.bnf
        /// design note 3aa). Same exact-match-only treatment as
        /// `struct_type`.
        enum_type: u32,
        /// A bare reference to one SPECIFIC top-level function (GRAMMAR.bnf
        /// design note 3ad) — e.g. `myCompare` used directly as an
        /// expression, not through a func-typed local/parameter. Carries
        /// that function's own full `FunctionInfo` so `typeCompatible` can
        /// check its actual signature structurally against a declared
        /// `func(...)...` type.
        func_value: FunctionInfo,
        /// The type of a func-typed local/parameter (GRAMMAR.bnf design
        /// note 3ad) — any function matching this signature could be
        /// stored there, not one specific function.
        func_sig: *const ast.FuncSig,
    };

    fn isNumericType(t: StaticType) bool {
        return switch (t) {
            .scalar => |v| v == .int or v == .float,
            .stream, .null_type, .struct_type, .enum_type, .func_value, .func_sig => false,
        };
    }

    fn isScalarType(t: StaticType, v: ast.ValueType) bool {
        return switch (t) {
            .scalar => |s| s == v,
            .stream, .null_type, .struct_type, .enum_type, .func_value, .func_sig => false,
        };
    }

    /// Converts an already-resolved `DeclaredType` (e.g. a struct field's
    /// own type) into the `StaticType` an inferred expression would carry —
    /// the two are the same information, just addressed from opposite
    /// ends (a declared position vs. an expression's inferred type).
    fn declaredToStatic(dt: DeclaredType) StaticType {
        if (dt.type == .func) return StaticType{ .func_sig = dt.func_sig.? };
        if (dt.named_ref) |ref| return if (ref.is_enum) StaticType{ .enum_type = ref.index } else StaticType{ .struct_type = ref.index };
        return StaticType{ .scalar = dt.type };
    }

    /// Whether a function with `info`'s own signature can be used as a
    /// function VALUE at all — every parameter and the return type must be
    /// a plain scalar (int/float/bool/string/map/list), never an array, a
    /// struct/enum, or (recursively) another function type (GRAMMAR.bnf
    /// design note 3ad). Structural, so this doubles as the base check
    /// `funcSigMatchesInfo` builds on: a function that fails this can never
    /// match any declared `FuncSig` either.
    fn functionIsValueEligible(info: FunctionInfo) bool {
        for (info.params) |p| {
            if (p.array_size != null or p.type == .named or p.type == .func) return false;
        }
        return info.return_array_size == null and info.return_type != .named and info.return_type != .func;
    }

    /// Whether two function-value TYPES (both structural, scalar-only
    /// signatures — GRAMMAR.bnf design note 3ad) describe the same shape.
    fn funcSigEqual(a: ast.FuncSig, b: ast.FuncSig) bool {
        if (a.param_types.len != b.param_types.len) return false;
        for (a.param_types, b.param_types) |x, y| {
            if (x != y) return false;
        }
        return a.return_type == b.return_type;
    }

    /// Whether a concrete function's own signature (`info`) matches a
    /// declared function-value type (`sig`) — used wherever a bare
    /// function-name expression (`StaticType.func_value`) is checked
    /// against an expected `func(...)...` position. Requires
    /// `functionIsValueEligible(info)` implicitly: an array/struct/enum
    /// param or return type can never equal any plain-scalar `sig` entry.
    fn funcSigMatchesInfo(sig: *const ast.FuncSig, info: FunctionInfo) bool {
        if (!functionIsValueEligible(info)) return false;
        if (info.params.len != sig.param_types.len) return false;
        for (info.params, sig.param_types) |p, t| {
            if (p.type != t) return false;
        }
        return info.return_type == sig.return_type;
    }

    /// Whether a value of static type `actual` may be used where `expected`
    /// (a declared `<type>`) is required: an exact scalar match, `int`
    /// widening to `float` (matching the VM's existing runtime int->float
    /// promotion in add/sub/mul/div/mod/pow — ISA.bnf), a stream satisfying
    /// `int` (the codebase's existing convention for holding an `open()`
    /// result — see `StaticType`), or an exact struct/enum type-index match
    /// (GRAMMAR.bnf design notes 3z/3aa — no coercions between struct/enum
    /// types, not even between two otherwise-identical-shaped structs).
    /// Note that widening is a compile-time ACCEPTANCE only, not a runtime
    /// conversion: `float x := 5` still stores a raw `Value.int` in `x`'s
    /// slot, same as it always has — arithmetic already promotes int/float
    /// dynamically regardless of what a local was declared as, so this
    /// changes nothing observable.
    fn typeCompatible(expected: DeclaredType, actual: StaticType) bool {
        if (expected.type == .func) {
            const esig = expected.func_sig.?;
            return switch (actual) {
                .func_value => |info| funcSigMatchesInfo(esig, info),
                .func_sig => |asig| funcSigEqual(esig.*, asig.*),
                .scalar, .stream, .null_type, .struct_type, .enum_type => false,
            };
        }
        if (expected.named_ref) |eref| {
            return switch (actual) {
                .struct_type => |i| !eref.is_enum and i == eref.index,
                .enum_type => |i| eref.is_enum and i == eref.index,
                .scalar, .stream, .null_type, .func_value, .func_sig => false,
            };
        }
        return switch (actual) {
            .scalar => |v| v == expected.type or (expected.type == .float and v == .int),
            .stream => expected.type == .int,
            .null_type, .struct_type, .enum_type, .func_value, .func_sig => false,
        };
    }

    fn promoteNumeric(l: StaticType, r: StaticType) ast.ValueType {
        if (isScalarType(l, .int) and isScalarType(r, .int)) return .int;
        return .float;
    }

    /// Fails with `SemanticError.TypeMismatch` if `expr`'s statically-
    /// inferred type can't be used where `expected` (a declared `<type>`)
    /// is required (see `typeCompatible`). A `null` inference — the
    /// expression's type genuinely depends on a runtime value this compiler
    /// doesn't track, e.g. a map/list element or `json`'s parsed root — is
    /// silently allowed here; the existing runtime checks remain the only
    /// guard for those, same as before this feature existed.
    fn checkExpectedType(self: *Compiler, expr: *const ast.Expr, expected: DeclaredType, name: []const u8, message: []const u8) CompileError!void {
        if (try self.inferType(expr)) |actual| {
            if (!typeCompatible(expected, actual)) return self.fail(SemanticError.TypeMismatch, name, message);
        }
    }

    /// Statically infers `expr`'s type where possible. Called both from the
    /// specific "declared type" checkpoints (`checkExpectedType`'s callers:
    /// a var-decl/array-literal-element initializer, an assignment, a call
    /// argument, a return, an if/while condition, a for-loop bound, an exit
    /// code) AND from `compileExpr`'s `.binary`/`.unary` arms on every such
    /// node as it's compiled — which is what makes operator-operand
    /// checking blanket-cover the whole program (a bad `+` buried inside a
    /// `push(...)`/`read(...)`/anything-else argument is still visited by
    /// ordinary codegen, which recurses into every expression node exactly
    /// once) without this function needing to eagerly recurse into every
    /// child of every non-operator expression itself.
    fn inferType(self: *Compiler, expr: *const ast.Expr) CompileError!?StaticType {
        return switch (expr.*) {
            .literal => |lit| switch (lit) {
                .int => StaticType{ .scalar = .int },
                .float => StaticType{ .scalar = .float },
                .string => StaticType{ .scalar = .string },
                .boolean => StaticType{ .scalar = .bool },
                .null_value => StaticType.null_type,
            },
            .variable => |name| blk: {
                if (self.resolveLocal(name)) |local| {
                    if (local.array != null) return self.fail(SemanticError.ArrayUsedAsScalar, name, "an array must be indexed, not used as a plain value");
                    if (local.value_type == .func) break :blk StaticType{ .func_sig = local.func_sig.? };
                    if (local.value_type == .named) {
                        const ref = local.named_ref.?;
                        break :blk if (ref.is_enum) StaticType{ .enum_type = ref.index } else StaticType{ .struct_type = ref.index };
                    }
                    break :blk StaticType{ .scalar = local.value_type };
                }
                // Not a local — does this name a top-level function instead
                // (GRAMMAR.bnf design note 3ad)? Whether it's actually
                // eligible to be used as a value (no array/struct/enum
                // param or return type) is checked when this expression is
                // actually compiled (`compileVariable`), same as `.call`'s
                // own "real error raised when this call is actually
                // compiled" stance below.
                if (self.findFunction(name)) |info| break :blk StaticType{ .func_value = info };
                return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
            },
            .unary => |u| blk: {
                const rt = try self.inferType(u.right) orelse break :blk null;
                switch (u.op) {
                    .negate => {
                        if (!isNumericType(rt)) return self.fail(SemanticError.TypeMismatch, "-", "'-' requires a numeric (int or float) operand");
                        break :blk rt;
                    },
                    .not => {
                        if (!isScalarType(rt, .bool)) return self.fail(SemanticError.TypeMismatch, "!", "'!' requires a bool operand");
                        break :blk StaticType{ .scalar = .bool };
                    },
                }
            },
            .binary => |b| try self.inferBinaryType(b),
            .grouping => |inner| try self.inferType(inner),
            .assign => |a| try self.inferType(a.value),
            .call => |c| blk: {
                // A dynamic call through a func-typed local/parameter
                // (GRAMMAR.bnf design note 3ad) — its result is always a
                // plain scalar/map/list, per the signature restriction.
                if (self.resolveLocal(c.name)) |local| {
                    if (local.value_type == .func) break :blk StaticType{ .scalar = local.func_sig.?.return_type };
                }
                const info = self.findFunction(c.name) orelse break :blk null; // real error raised when this call is actually compiled
                if (info.return_array_size != null) break :blk null; // likewise ArrayUsedAsScalar, raised there
                if (info.return_type == .named) {
                    const ref = info.return_named_ref.?;
                    break :blk if (ref.is_enum) StaticType{ .enum_type = ref.index } else StaticType{ .struct_type = ref.index };
                }
                break :blk StaticType{ .scalar = info.return_type };
            },
            // Same shape as `.call`, above, but resolving `mc.method`
            // against `mc.base`'s own inferred struct type instead of the
            // bare-name function table (GRAMMAR.bnf design note 3af) — real
            // errors (`NotAStruct`/`UnknownMethod`/`ArrayUsedAsScalar`) are
            // likewise deferred to `compileMethodCall`, once this node is
            // actually compiled.
            .method_call => |mc| blk: {
                const bt = try self.inferType(mc.base) orelse break :blk null;
                const type_index = switch (bt) {
                    .struct_type => |i| i,
                    else => break :blk null,
                };
                const method = self.findMethod(type_index, mc.method) orelse break :blk null;
                const info = self.functions.items[method.function_index];
                if (info.return_array_size != null) break :blk null;
                if (info.return_type == .named) {
                    const ref = info.return_named_ref.?;
                    break :blk if (ref.is_enum) StaticType{ .enum_type = ref.index } else StaticType{ .struct_type = ref.index };
                }
                break :blk StaticType{ .scalar = info.return_type };
            },
            .array_literal => StaticType{ .scalar = .list },
            .map_literal => StaticType{ .scalar = .map },
            .index => |ix| try self.inferIndexType(ix),
            .index_assign => |ia| try self.inferType(ia.value),
            .struct_literal => |sl| blk: {
                const idx = self.findTypeIndex(sl.type_name) orelse break :blk null; // real error raised when this is actually compiled
                break :blk StaticType{ .struct_type = @intCast(idx) };
            },
            .field_access => |fa| try self.inferFieldAccessType(fa),
            .field_assign => |fa| try self.inferType(fa.value),
            .slice => StaticType{ .scalar = .string },
            .len_of => StaticType{ .scalar = .int },
            .stream_literal => StaticType.stream,
            .args_literal => StaticType{ .scalar = .list },
            .read_bytes => StaticType{ .scalar = .int },
            .write_value => StaticType{ .scalar = .int },
            .write_bytes => StaticType{ .scalar = .int },
            .open_file => StaticType.stream,
            .list_push => StaticType{ .scalar = .int },
            .map_has => StaticType{ .scalar = .bool },
            .map_delete => StaticType{ .scalar = .bool },
            .map_keys => StaticType{ .scalar = .list },
            .json_parse => null, // the parsed root can be any JSON shape
            .json_stringify => StaticType{ .scalar = .string },
            .int_parse => StaticType{ .scalar = .int },
            .float_parse => StaticType{ .scalar = .float },
            // Always a string, even for a variable that isn't set — an
            // unset one reads as `""`, never `null` (design note 3v).
            .env_get => StaticType{ .scalar = .string },
            .env_has => StaticType{ .scalar = .bool },
            .path_exists => StaticType{ .scalar = .bool },
            .list_dir => StaticType{ .scalar = .list },
            .path_remove => StaticType{ .scalar = .bool },
            .path_rename => StaticType{ .scalar = .bool },
            .path_mkdir => StaticType{ .scalar = .bool },
            .exec => StaticType{ .scalar = .map },
            .time_now => StaticType{ .scalar = .float },
            .random_float => StaticType{ .scalar = .float },
            .random_range => StaticType{ .scalar = .int },
            .char_ord => StaticType{ .scalar = .int },
            .list_join => StaticType{ .scalar = .string },
            .string_interp => StaticType{ .scalar = .string },
        };
    }

    /// `<base>[index]`'s static type: a bare array-local name types to the
    /// array's own scalar element type (design note 3e); a bare string-local
    /// name (or, recursively, any other expression whose own type is
    /// `string`) types to `string`, matching `s[i]`'s "always a fresh
    /// length-1 STRING" rule (Strings design notes); a map/list index is
    /// genuinely dynamic (`null`, unknown).
    fn inferIndexType(self: *Compiler, ix: ast.Expr.Index) CompileError!?StaticType {
        if (ix.base.* == .variable) {
            const local = self.resolveLocal(ix.base.variable) orelse return null; // real error raised when this is actually compiled
            if (local.array != null) return StaticType{ .scalar = local.value_type };
            if (local.is_string) return StaticType{ .scalar = .string };
            return null; // a map/list element is dynamically typed
        }
        if (try self.inferType(ix.base)) |bt| {
            if (isScalarType(bt, .string)) return StaticType{ .scalar = .string };
        }
        return null;
    }

    /// `<base>.field`'s static type where determinable: if `field_access`
    /// resolves to an enum variant reference (`Color.Red`) the WHOLE
    /// expression's type is that enum; if it resolves to a struct field
    /// read, the field's own declared type. Never raises here even for a
    /// shape that will turn out to be invalid — `compileFieldAccess` is the
    /// authoritative check (`NotAStruct`/`UnknownField`/`UnknownEnumVariant`)
    /// once the node is actually compiled; this is purely a best-effort hint
    /// for the SURROUNDING expression's own type check, the same stance
    /// `inferIndexType` already takes on a genuinely dynamic base.
    fn inferFieldAccessType(self: *Compiler, fa: ast.Expr.FieldAccess) CompileError!?StaticType {
        if (fa.base.* == .variable and self.resolveLocal(fa.base.variable) == null) {
            const decl = self.findType(fa.base.variable) orelse return null; // undefined variable — real error raised when compiled
            if (decl.kind != .enum_decl) return null;
            for (decl.kind.enum_decl.variants) |v| {
                if (std.mem.eql(u8, v, fa.field)) return StaticType{ .enum_type = @intCast(self.findTypeIndex(fa.base.variable).?) };
            }
            return null;
        }
        const base_type = try self.inferType(fa.base) orelse return null;
        const type_index = switch (base_type) {
            .struct_type => |i| i,
            else => return null,
        };
        const fields = self.types.items[type_index].kind.struct_decl.fields;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, fa.field)) return declaredToStatic(f.type);
        }
        return null;
    }

    /// `+`/`-`/`*`/`/`/`%`/`**`/`<`/`<=`/`>`/`>=`/`==`/`!=`/`and`/`or`'s
    /// static type and operand validation, mirroring the VM's own runtime
    /// rules (`add`/`compare` in vm.zig): `+` and the four ordering
    /// comparisons accept two numbers OR two strings; every other
    /// arithmetic operator requires two numbers; `and`/`or` require two
    /// bools; `==`/`!=` are deliberately left unchecked here (they're valid,
    /// and simply `false`, across any two types at runtime — vm.zig's
    /// `Value.eql` — so there's nothing to reject). A `null` operand
    /// inference (genuinely dynamic) skips validation for that operand
    /// rather than failing, same as `checkExpectedType`.
    fn inferBinaryType(self: *Compiler, b: ast.Expr.Binary) CompileError!?StaticType {
        if (b.op == .logic_and or b.op == .logic_or) {
            const op_name = ast.binaryOpLexeme(b.op);
            if (try self.inferType(b.left)) |l| if (!isScalarType(l, .bool)) return self.fail(SemanticError.TypeMismatch, op_name, "'and'/'or' requires bool operands");
            if (try self.inferType(b.right)) |r| if (!isScalarType(r, .bool)) return self.fail(SemanticError.TypeMismatch, op_name, "'and'/'or' requires bool operands");
            return StaticType{ .scalar = .bool };
        }
        const lt = try self.inferType(b.left);
        const rt = try self.inferType(b.right);
        const op_name = ast.binaryOpLexeme(b.op);
        switch (b.op) {
            .add => {
                const l = lt orelse return null;
                const r = rt orelse return null;
                if (isNumericType(l) and isNumericType(r)) return StaticType{ .scalar = promoteNumeric(l, r) };
                if (isScalarType(l, .string) and isScalarType(r, .string)) return StaticType{ .scalar = .string };
                return self.fail(SemanticError.TypeMismatch, op_name, "'+' requires two numbers or two strings");
            },
            .sub, .mul, .div, .mod, .pow => {
                const l = lt orelse return null;
                const r = rt orelse return null;
                if (!isNumericType(l) or !isNumericType(r)) return self.fail(SemanticError.TypeMismatch, op_name, "arithmetic operators require two numbers");
                return StaticType{ .scalar = promoteNumeric(l, r) };
            },
            .lt, .lte, .gt, .gte => {
                if (lt) |l| if (rt) |r| {
                    const both_numeric = isNumericType(l) and isNumericType(r);
                    const both_string = isScalarType(l, .string) and isScalarType(r, .string);
                    if (!both_numeric and !both_string) return self.fail(SemanticError.TypeMismatch, op_name, "comparison requires two numbers or two strings");
                };
                return StaticType{ .scalar = .bool };
            },
            .eq, .neq => return StaticType{ .scalar = .bool },
            .logic_and, .logic_or => unreachable, // handled above
        }
    }

    fn compileStmt(self: *Compiler, stmt: *const ast.Stmt) CompileError!void {
        self.current_line = stmt.line;
        self.chunk.current_line = @intCast(stmt.line);
        switch (stmt.kind) {
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
                    try self.checkExpectedType(e, .{ .type = self.current_return_type, .named_ref = self.current_return_named_ref }, "return", "returned value's type does not match the function's declared return type");
                    try self.compileExpr(e);
                }
                _ = try self.chunk.emit(self.allocator, .ret);
            },
            .function_decl => unreachable, // top-level only; compileModules never calls compileStmt on this
            .method_decl => unreachable, // top-level only; compileModules never calls compileStmt on this
            .for_stmt => |f| try self.compileFor(f),
            .import_stmt => unreachable, // top-level only; compileModules never calls compileStmt on this
            .struct_decl => unreachable, // top-level only; compileModules never calls compileStmt on this
            .enum_decl => unreachable, // top-level only; compileModules never calls compileStmt on this
            .close_stmt => |e| try self.compileCloseStmt(e),
            .exit_stmt => |e| {
                try self.checkExpectedType(e, DeclaredType.builtin(.int), "exit", "exit code must be an int");
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .exit);
            },
            .throw_stmt => |e| {
                try self.checkExpectedType(e, errorDeclaredType(), "throw", "thrown value must be the built-in Error struct");
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .throw);
            },
            .try_stmt => |t| try self.compileTry(t),
        }
    }

    /// Never actually called with `.map`/`.list`, or a struct-typed
    /// `DeclaredType` — every call site routes those through
    /// `compileDefaultValue` instead, since none of the three is a
    /// compile-time constant `PUSH_CONST` could hold (an empty map/list or
    /// a struct instance is a genuine heap allocation). An enum-typed
    /// `DeclaredType` defaults to its first-declared variant (index 0) —
    /// consistent with "falling off without return yields the declared
    /// type's zero value" for every other type (GRAMMAR.bnf design note 3aa).
    fn defaultValue(self: *Compiler, dt: DeclaredType) !Value {
        if (dt.named_ref) |ref| {
            std.debug.assert(ref.is_enum);
            const decl = self.types.items[ref.index];
            const variant_name = decl.kind.enum_decl.variants[0];
            return .{ .enum_value = .{ .type_index = ref.index, .variant = 0, .type_name = decl.name, .variant_name = variant_name } };
        }
        return switch (dt.type) {
            .int => .{ .int = 0 },
            .float => .{ .float = 0.0 },
            .bool => .{ .boolean = false },
            .string => try Value.newString(self.allocator, ""),
            // `.func` never reaches here either: a function-typed local
            // always requires an initializer (`compileVarDecl`) and a
            // function-typed return type is rejected at parse time — there
            // is no meaningful "zero" function value to fall back to.
            .map, .list, .named, .func => unreachable,
        };
    }

    /// Emits the bytecode that leaves `dt`'s zero value on the stack —
    /// PUSH_CONST for every scalar/enum type (`defaultValue`), MAKE_MAP/
    /// MAKE_LIST for the two heap collection types, or a recursive
    /// `compileStructDefault` for a struct type. The single place every
    /// "no initializer" / "fell off the end of a function" default value
    /// goes through, regardless of shape (GRAMMAR.bnf design notes 3z/3aa).
    fn compileDefaultValue(self: *Compiler, dt: DeclaredType) CompileError!void {
        if (dt.named_ref) |ref| {
            if (ref.is_enum) {
                const idx = try self.chunk.addConstant(self.allocator, try self.defaultValue(dt));
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            } else {
                try self.compileStructDefault(ref.index);
            }
            return;
        }
        switch (dt.type) {
            .map => _ = try self.chunk.emitWithOperand(self.allocator, .make_map, 0),
            .list => _ = try self.chunk.emitWithOperand(self.allocator, .make_list, 0),
            else => {
                const idx = try self.chunk.addConstant(self.allocator, try self.defaultValue(dt));
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
        }
    }

    /// A struct-typed default value (no initializer, or falling off a
    /// function body without an explicit return) is always a fresh
    /// MAKE_STRUCT, never a compile-time constant — same reason map/list's
    /// own defaults are special-cased outside `defaultValue` (GRAMMAR.bnf
    /// design note 3z: a struct instance is a genuine heap allocation).
    /// Each field's own default is computed recursively — a struct field
    /// that is itself another struct type gets its own fresh MAKE_STRUCT,
    /// and so on.
    fn compileStructDefault(self: *Compiler, type_index: u32) CompileError!void {
        const fields = self.types.items[type_index].kind.struct_decl.fields;
        for (fields) |f| try self.compileDefaultValue(f.type);
        _ = try self.chunk.emitWithOperand(self.allocator, .make_struct, type_index);
    }

    /// A declared local's runtime storage IS the value its initializer
    /// (or its type's zero value) leaves on the stack — there is no
    /// separate store step at declaration time (ISA.bnf section 5).
    fn compileVarDecl(self: *Compiler, d: ast.StmtKind.VarDecl) CompileError!void {
        const slot = self.next_slot;
        if (collectionKind(d.type)) |kind| {
            // Always exactly one heap-reference slot — an initializer, if
            // present, is just an ordinary expression (a map/list literal
            // compiles to MAKE_MAP/MAKE_LIST via compileExpr, same as any
            // other expression that happens to evaluate to one); with none,
            // a fresh empty map/list is what a bare `map m`/`list xs`
            // declaration means, and (like the function-return case above)
            // can't route through `defaultValue`+PUSH_CONST since it isn't a
            // compile-time constant.
            if (d.initializer) |init_expr| {
                try self.checkExpectedType(init_expr, DeclaredType.builtin(d.type), d.name, "initializer's type does not match the declared type");
                try self.compileExpr(init_expr);
            } else switch (kind) {
                .map => _ = try self.chunk.emitWithOperand(self.allocator, .make_map, 0),
                .list => _ = try self.chunk.emitWithOperand(self.allocator, .make_list, 0),
            }
            try self.locals.append(self.allocator, .{ .name = d.name, .depth = self.scope_depth, .slot = slot, .collection = kind, .value_type = d.type });
            self.next_slot += 1;
            return;
        }
        if (d.array_len) |len| {
            // Array element types are always plain scalars (design note
            // 3e — a named struct/enum type never takes the array suffix),
            // so `d.type` is never `.named` anywhere in this branch.
            if (d.initializer) |init_expr| {
                switch (init_expr.*) {
                    .array_literal => |elems| {
                        if (elems.len != len) {
                            return self.fail(SemanticError.ArrayLengthMismatch, d.name, "array literal length does not match the declared size");
                        }
                        for (elems) |elem| {
                            try self.checkExpectedType(elem, DeclaredType.builtin(d.type), d.name, "array literal element's type does not match the array's declared element type");
                            try self.compileExpr(elem);
                        }
                    },
                    .call => |c| {
                        const info = try self.compileCallCommon(c);
                        const ret_spec = info.return_array_size orelse return self.fail(SemanticError.InvalidArrayInitializer, d.name, "function call does not return an array");
                        const ret_len = switch (ret_spec) {
                            .fixed => |n| n,
                            .generic => return self.fail(SemanticError.InvalidArrayInitializer, d.name, "a local array declaration needs a fixed size, but this function call returns a generic (unsized) array"),
                        };
                        if (ret_len != len) return self.fail(SemanticError.ArrayLengthMismatch, d.name, "the called function's returned array length does not match the declared size");
                        if (!typeCompatible(DeclaredType.builtin(d.type), StaticType{ .scalar = info.return_type })) return self.fail(SemanticError.TypeMismatch, d.name, "the called function's returned array's element type does not match the declared element type");
                    },
                    else => return self.fail(SemanticError.InvalidArrayInitializer, d.name, "an array declaration's initializer must be an array literal or a call to an array-returning function"),
                }
            } else {
                const idx = try self.chunk.addConstant(self.allocator, try self.defaultValue(DeclaredType.builtin(d.type)));
                var i: u32 = 0;
                while (i < len) : (i += 1) _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            }
            try self.locals.append(self.allocator, .{ .name = d.name, .depth = self.scope_depth, .slot = slot, .array = .{ .fixed = len }, .value_type = d.type });
            self.next_slot += len;
        } else {
            // The plain-scalar branch — this is also where a struct/enum-
            // typed local (`d.type == .named`) or a function-typed local
            // (`d.type == .func`, GRAMMAR.bnf design note 3ad) lands, since
            // neither `collectionKind` nor `d.array_len` ever apply to
            // either.
            if (d.type == .func and d.initializer == null) {
                return self.fail(SemanticError.MissingFunctionInitializer, d.name, "a function-typed variable must be initialized; there is no default function value");
            }
            const named_ref: ?NamedTypeRef = if (d.type == .named) (try self.resolveDeclaredType(d.type, d.named_type)).named_ref else null;
            const dt: DeclaredType = .{ .type = d.type, .named_ref = named_ref, .func_sig = d.func_sig };
            if (d.initializer) |init_expr| {
                try self.checkExpectedType(init_expr, dt, d.name, "initializer's type does not match the declared type");
                try self.compileExpr(init_expr);
            } else {
                try self.compileDefaultValue(dt);
            }
            try self.locals.append(self.allocator, .{ .name = d.name, .depth = self.scope_depth, .slot = slot, .is_string = d.type == .string, .value_type = d.type, .named_ref = named_ref, .func_sig = d.func_sig });
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
    fn compileIf(self: *Compiler, i: ast.StmtKind.If) CompileError!void {
        try self.checkExpectedType(i.condition, DeclaredType.builtin(.bool), "if", "condition must be a bool");
        try self.compileExpr(i.condition);
        const then_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false_pop, 0);
        try self.compileStmt(i.then_branch);

        const else_jump = try self.chunk.emit(self.allocator, .jump);
        self.chunk.patchOperand(then_jump, @intCast(self.chunk.code.items.len));

        if (i.else_branch) |eb| try self.compileStmt(eb);
        self.chunk.patchOperand(else_jump, @intCast(self.chunk.code.items.len));
    }

    /// `try <body> catch <name> <handler>` (design note 3u), on the same
    /// backpatched-jump skeleton as `compileIf`:
    ///
    /// ```
    ///        PUSH_HANDLER  catch_target
    ///        <body>                  (* its own scope; locals POPped at its end *)
    ///        POP_HANDLER
    ///        JUMP  end_target
    ///      catch_target:
    ///        <handler>               (* the error map is ALREADY on the stack *)
    ///        POP                     (* the binding, via popLocalsAbove *)
    ///      end_target:
    /// ```
    ///
    /// The binding needs neither a STORE_LOCAL nor an opcode of its own.
    /// At the `try` statement `next_slot` is some N; the body's own locals
    /// occupy N upward and `compileBlock` pops them at its end, so the
    /// handler is compiled with `next_slot` back at N and declares the
    /// binding as an ordinary local at slot N. At run time, a statement
    /// boundary always has `sp == bp + next_slot` (locals below, no live
    /// temporaries), so the `sp` PUSH_HANDLER recorded is exactly `bp + N` —
    /// and unwinding restores that `sp` and then pushes the error map,
    /// landing it precisely in slot N. `popLocalsAbove` then discards it at
    /// the end of the handler's scope with no special case.
    ///
    /// Nothing here emits a POP_HANDLER before a `return` inside the body:
    /// RET drops the departing frame's handlers itself (ISA.bnf section 14),
    /// which covers every way out of a frame by construction. Butter has no
    /// `break`/`continue`, so `return`, `exit`, and falling off the end are
    /// the only other exits, and the latter two need nothing.
    fn compileTry(self: *Compiler, t: ast.StmtKind.Try) CompileError!void {
        const catch_jump = try self.chunk.emitWithOperand(self.allocator, .push_handler, 0);

        try self.compileBlock(t.body);

        _ = try self.chunk.emit(self.allocator, .pop_handler);
        const end_jump = try self.chunk.emit(self.allocator, .jump);
        self.chunk.patchOperand(catch_jump, @intCast(self.chunk.code.items.len));

        // The handler's scope, opened by hand rather than via `compileBlock`
        // so the binding can be declared inside it before its statements
        // are compiled. Typed as the built-in `Error` struct (design notes
        // 3t/3u/3z, `Compiler.compileModules`'s pass 0), always registered
        // at type index 0 — so reading a field out of it (`e.message`) is
        // an ordinary, compile-time-resolved struct field read, and a
        // typo'd field name is `SemanticError.UnknownField`, not a runtime
        // surprise the way a bad map key would be.
        self.scope_depth += 1;
        try self.locals.append(self.allocator, .{
            .name = t.error_var,
            .depth = self.scope_depth,
            .slot = self.next_slot,
            .value_type = .named,
            .named_ref = .{ .index = error_type_index, .is_enum = false },
        });
        self.next_slot += 1;
        for (t.handler) |*s| try self.compileStmt(s);
        self.scope_depth -= 1;
        try self.popLocalsAbove(self.scope_depth);

        self.chunk.patchOperand(end_jump, @intCast(self.chunk.code.items.len));
    }

    fn compileWhile(self: *Compiler, w: ast.StmtKind.While) CompileError!void {
        const loop_start = self.chunk.code.items.len;
        try self.checkExpectedType(w.condition, DeclaredType.builtin(.bool), "while", "condition must be a bool");
        try self.compileExpr(w.condition);
        const exit_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false_pop, 0);

        try self.compileStmt(w.body);
        _ = try self.chunk.emitWithOperand(self.allocator, .jump, @intCast(loop_start));

        self.chunk.patchOperand(exit_jump, @intCast(self.chunk.code.items.len));
    }

    /// `for v in start..end body` desugars directly to the same
    /// backpatched-jump while-loop pattern `compileWhile` uses (ISA.bnf
    /// section 4), condition and all — both use JUMP_IF_FALSE_POP the same
    /// way. It needs two hidden locals of its own, scoped to a wrapper block
    /// only `compileFor` knows about: the end bound (evaluated once, up
    /// front — not re-evaluated per iteration) and the loop variable
    /// itself, which the body resolves like any other local by name.
    fn compileFor(self: *Compiler, f: ast.StmtKind.For) CompileError!void {
        self.scope_depth += 1;

        try self.checkExpectedType(f.end, DeclaredType.builtin(.int), f.var_name, "for-loop end must be an int");
        try self.compileExpr(f.end);
        const end_slot = self.next_slot;
        try self.locals.append(self.allocator, .{ .name = "", .depth = self.scope_depth, .slot = end_slot, .value_type = .int });
        self.next_slot += 1;

        try self.checkExpectedType(f.start, DeclaredType.builtin(.int), f.var_name, "for-loop start must be an int");
        try self.compileExpr(f.start);
        const var_slot = self.next_slot;
        try self.locals.append(self.allocator, .{ .name = f.var_name, .depth = self.scope_depth, .slot = var_slot, .value_type = .int });
        self.next_slot += 1;

        const loop_start = self.chunk.code.items.len;
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, var_slot);
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, end_slot);
        _ = try self.chunk.emit(self.allocator, .lt);
        const exit_jump = try self.chunk.emitWithOperand(self.allocator, .jump_if_false_pop, 0);

        try self.compileStmt(f.body);

        const one_idx = try self.chunk.addConstant(self.allocator, .{ .int = 1 });
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, var_slot);
        _ = try self.chunk.emitWithOperand(self.allocator, .push_const, one_idx);
        _ = try self.chunk.emit(self.allocator, .add);
        _ = try self.chunk.emitWithOperand(self.allocator, .store_local, var_slot);
        _ = try self.chunk.emit(self.allocator, .pop);
        _ = try self.chunk.emitWithOperand(self.allocator, .jump, @intCast(loop_start));

        self.chunk.patchOperand(exit_jump, @intCast(self.chunk.code.items.len));

        self.scope_depth -= 1;
        try self.popLocalsAbove(self.scope_depth);
    }

    fn compileExpr(self: *Compiler, expr: *const ast.Expr) CompileError!void {
        switch (expr.*) {
            .literal => |lit| try self.compileLiteral(lit),
            .variable => |name| try self.compileVariable(name),
            .unary => |u| {
                _ = try self.inferType(expr);
                try self.compileExpr(u.right);
                _ = try self.chunk.emit(self.allocator, switch (u.op) {
                    .negate => .neg,
                    .not => .not,
                });
            },
            .binary => |b| {
                _ = try self.inferType(expr);
                try self.compileBinary(b);
            },
            .grouping => |inner| try self.compileExpr(inner),
            .assign => |a| {
                if (self.resolveLocal(a.name)) |local| {
                    if (local.array == null) {
                        try self.checkExpectedType(a.value, .{ .type = local.value_type, .named_ref = local.named_ref, .func_sig = local.func_sig }, a.name, "assigned value's type does not match the variable's declared type");
                    }
                }
                try self.compileExpr(a.value);
                _ = try self.emitLocalOp(a.name, .store_local);
            },
            .call => |c| try self.compileCall(c),
            .method_call => |mc| try self.compileMethodCall(mc),
            // Reached only when a bracketed literal ISN'T a fixed-array
            // initializer (compileVarDecl/the array/generic-array value
            // helpers all intercept `.array_literal` themselves before ever
            // calling generic compileExpr on it) — which means it's always
            // safe, from here, to treat it as "build a list" (GRAMMAR.bnf
            // design note 3m). This is what makes `list xs := [1, 2, 3]`'s
            // initializer, and a bare `[1, 2, 3]` anywhere else, both work
            // via the exact same production.
            .array_literal => |elems| {
                for (elems) |elem| try self.compileExpr(elem);
                _ = try self.chunk.emitWithOperand(self.allocator, .make_list, @intCast(elems.len));
            },
            .map_literal => |entries| {
                for (entries) |entry| {
                    const idx = try self.chunk.addConstant(self.allocator, try Value.newString(self.allocator, entry.key));
                    _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
                    try self.compileExpr(entry.value);
                }
                _ = try self.chunk.emitWithOperand(self.allocator, .make_map, @intCast(entries.len));
            },
            .index => |ix| try self.compileIndex(ix),
            .index_assign => |ia| try self.compileIndexAssign(ia),
            .struct_literal => |sl| try self.compileStructLiteral(sl),
            .field_access => |fa| try self.compileFieldAccess(fa),
            .field_assign => |fa| try self.compileFieldAssign(fa),
            .slice => |sl| try self.compileSlice(sl),
            .len_of => |e| try self.compileLenOf(e),
            .stream_literal => |s| {
                const idx = try self.chunk.addConstant(self.allocator, .{ .stream = .ofStandard(s) });
                _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            },
            .args_literal => _ = try self.chunk.emit(self.allocator, .push_args),
            .read_bytes => |r| try self.compileReadBytes(r),
            .write_value => |w| try self.compileWriteValue(w),
            .write_bytes => |w| try self.compileWriteBytes(w),
            .open_file => |o| try self.compileOpenFile(o),
            .list_push => |p| {
                try self.compileExpr(p.list);
                try self.compileExpr(p.value);
                _ = try self.chunk.emit(self.allocator, .list_push);
            },
            .map_has => |h| {
                try self.compileExpr(h.map);
                try self.compileExpr(h.key);
                _ = try self.chunk.emit(self.allocator, .map_has);
            },
            .map_delete => |d| {
                try self.compileExpr(d.map);
                try self.compileExpr(d.key);
                _ = try self.chunk.emit(self.allocator, .map_delete);
            },
            .map_keys => |m| {
                try self.compileExpr(m);
                _ = try self.chunk.emit(self.allocator, .map_keys);
            },
            .json_parse => |j| {
                try self.emitArrayRef(j.buffer, SemanticError.NotAnArray, "json's buffer must be an array");
                try self.compileExpr(j.count);
                _ = try self.chunk.emit(self.allocator, .json_parse);
            },
            .json_stringify => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .json_stringify);
            },
            .int_parse => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .parse_int);
            },
            .float_parse => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .parse_float);
            },
            .env_get => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .get_env);
            },
            .env_has => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .has_env);
            },
            .char_ord => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .ord);
            },
            .list_join => |j| {
                try self.compileExpr(j.list);
                try self.compileExpr(j.sep);
                _ = try self.chunk.emit(self.allocator, .join);
            },
            .path_exists => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .path_exists);
            },
            .list_dir => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .list_dir);
            },
            .path_remove => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .path_remove);
            },
            .path_rename => |r| {
                try self.compileExpr(r.from);
                try self.compileExpr(r.to);
                _ = try self.chunk.emit(self.allocator, .path_rename);
            },
            .path_mkdir => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(self.allocator, .path_mkdir);
            },
            .exec => |x| {
                try self.compileExpr(x.command);
                try self.compileExpr(x.args);
                _ = try self.chunk.emit(self.allocator, .exec);
            },
            .time_now => _ = try self.chunk.emit(self.allocator, .now),
            .random_float => _ = try self.chunk.emit(self.allocator, .random_float),
            .random_range => |r| {
                try self.checkExpectedType(r.start, DeclaredType.builtin(.int), "random", "random's start must be an int");
                try self.checkExpectedType(r.end, DeclaredType.builtin(.int), "random", "random's end must be an int");
                try self.compileExpr(r.start);
                try self.compileExpr(r.end);
                _ = try self.chunk.emit(self.allocator, .random_range);
            },
            .string_interp => |parts| try self.compileStringInterp(parts),
        }
    }

    /// Desugars `"literal ${expr} literal"` (GRAMMAR.bnf design note 3ae)
    /// into PUSH_CONST/TO_STRING per part followed by one INTERP_CONCAT
    /// (ISA.bnf section 23) — no new heap value kind (still just ordinary
    /// heap strings, same as `join`), but ONE allocation for the whole
    /// result rather than a chain of ADDs that would re-copy the growing
    /// prefix at every step (the same O(n^2) shape `join`'s own design note,
    /// GRAMMAR.bnf design note 3ac, calls out for a RUNTIME loop of
    /// concatenation — avoidable here too, since the piece count is fixed at
    /// COMPILE time, exactly like MAKE_LIST/MAKE_MAP's own count operand).
    ///
    /// An empty literal part (the common case of an interpolation glued
    /// directly to the opening/closing quote, or to another `${...}`) is
    /// skipped rather than pushed — `parts` always has at least one `.expr`
    /// part (that's the only reason this node exists at all), so `count` is
    /// always at least 1. Exactly one surviving part (`"${x}"` alone, with
    /// nothing but empty literal parts around it) skips INTERP_CONCAT
    /// entirely — that one part's own value is already the whole result, so
    /// there's nothing to concatenate it with.
    fn compileStringInterp(self: *Compiler, parts: []ast.Expr.InterpPart) CompileError!void {
        var count: u32 = 0;
        for (parts) |part| {
            switch (part) {
                .literal => |s| {
                    if (s.len == 0) continue;
                    const idx = try self.chunk.addConstant(self.allocator, try Value.newString(self.allocator, s));
                    _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
                },
                .expr => |e| {
                    try self.compileExpr(e);
                    _ = try self.chunk.emit(self.allocator, .to_string);
                },
            }
            count += 1;
        }
        if (count > 1) _ = try self.chunk.emitWithOperand(self.allocator, .interp_concat, count);
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
        // A dynamic call through a func-typed local/parameter (GRAMMAR.bnf
        // design note 3ad) takes priority over a same-named top-level
        // function — the same shadowing precedent an ordinary local already
        // gets over anything else in an outer scope. Every OTHER
        // local/function name collision is unaffected: a non-func-typed
        // local sharing a function's name still doesn't change which one a
        // call resolves to, exactly as before this feature existed.
        if (self.resolveLocal(c.name)) |local| {
            if (local.value_type == .func) return self.compileDynamicCall(c, local);
        }
        const info = self.findFunction(c.name) orelse return self.fail(SemanticError.UndefinedFunction, c.name, "undefined function");
        if (!self.functionVisible(info)) return self.fail(SemanticError.FunctionNotVisible, c.name, "function exists but isn't exported by a module this file imports");
        try self.compileArgs(c.name, info.params, info.param_named_refs, c.args);
        _ = try self.chunk.emitWithOperand(self.allocator, .call, info.index);
        return info;
    }

    /// Checks arity, then type-checks and compiles each argument against
    /// `params`/`param_named_refs` (using `compileArrayArgument`/
    /// `compileGenericArrayArgument` for array-typed parameters, exactly
    /// like an ordinary call) — the part of resolving a call that's
    /// identical whether the callee is an ordinary top-level function
    /// (`compileCallCommon`) or a struct method (`compileMethodCall`); the
    /// two differ only in how the CALLEE itself resolves and in whether a
    /// receiver value needs pushing before these arguments do.
    /// `diag_name` is whatever `self.fail` should name the call by (a
    /// function's or method's own name) if an argument doesn't fit.
    fn compileArgs(self: *Compiler, diag_name: []const u8, params: []const ast.Param, param_named_refs: []const ?NamedTypeRef, args: []const *ast.Expr) CompileError!void {
        if (args.len != params.len) return self.fail(SemanticError.ArityMismatch, diag_name, "wrong number of arguments");
        for (args, params, param_named_refs) |arg, param, named_ref| {
            if (param.array_size) |spec| {
                switch (spec) {
                    .fixed => |len| try self.compileArrayArgument(arg, len),
                    .generic => try self.compileGenericArrayArgument(arg),
                }
            } else {
                const dt: DeclaredType = .{ .type = param.type, .named_ref = named_ref, .func_sig = param.func_sig };
                try self.checkExpectedType(arg, dt, diag_name, "argument's type does not match the parameter's declared type");
                try self.compileExpr(arg);
            }
        }
    }

    /// `base.method(args)` (GRAMMAR.bnf design note 3af) — resolves `base`'s
    /// static struct type exactly like `compileFieldAccess` does
    /// (`resolveStructBase`), looks up `method` against that struct's own
    /// registered methods (`findMethod`, never `findFunction` — see
    /// `MethodInfo`'s doc comment), then compiles `base` itself as the
    /// desugared function's first argument (the receiver, `params[0]`)
    /// followed by `args` against `params[1..]` (`compileArgs`) — same CALL
    /// opcode an ordinary function call emits, just against the method's own
    /// resolved function index. Never reached for a method call used
    /// somewhere an ARRAY result is needed (a matching array var-decl
    /// initializer, array argument, or array return) — unlike `.call`,
    /// those three contexts don't have a `.method_call` case of their own;
    /// not supported this pass (GRAMMAR.bnf design note 3af).
    fn compileMethodCall(self: *Compiler, mc: ast.Expr.MethodCall) CompileError!void {
        const type_index = try self.resolveStructBase(mc.base);
        const method = self.findMethod(type_index, mc.method) orelse return self.fail(SemanticError.UnknownMethod, mc.method, "this struct has no method with this name");
        const info = self.functions.items[method.function_index];
        if (!self.functionVisible(info)) return self.fail(SemanticError.FunctionNotVisible, mc.method, "method exists but isn't exported by a module this file imports");
        if (info.return_array_size != null) return self.fail(SemanticError.ArrayUsedAsScalar, mc.method, "a method returning an array can't be used as a plain value here");

        try self.compileExpr(mc.base);
        try self.compileArgs(mc.method, info.params[1..], info.param_named_refs[1..], mc.args);
        _ = try self.chunk.emitWithOperand(self.allocator, .call, info.index);
    }

    /// Calls through a func-typed local/parameter's own runtime value
    /// (GRAMMAR.bnf design note 3ad) rather than a compile-time function
    /// index: compiles each argument against the LOCAL's declared
    /// `FuncSig` (not any one concrete function's params — the value could
    /// hold any function matching that signature), then pushes the callee
    /// value itself on top of the already-pushed arguments and emits
    /// CALL_VALUE (ISA.bnf section 6). Returns a synthetic `FunctionInfo`
    /// carrying just enough (`return_type`, `return_array_size == null`)
    /// for every existing `compileCallCommon` caller
    /// (`compileArrayValue`/`compileGenericArrayArgument`/
    /// `compileGenericArrayReturn`/`compileVarDecl`'s array branch) to keep
    /// working unchanged — `return_array_size` staying `null` is exactly
    /// what correctly forbids a dynamic call from feeding an array context,
    /// since a function value's signature can never describe an array
    /// return.
    fn compileDynamicCall(self: *Compiler, c: ast.Expr.Call, local: Local) CompileError!FunctionInfo {
        const sig = local.func_sig.?;
        if (c.args.len != sig.param_types.len) return self.fail(SemanticError.ArityMismatch, c.name, "wrong number of arguments");
        for (c.args, sig.param_types) |arg, t| {
            try self.checkExpectedType(arg, DeclaredType.builtin(t), c.name, "argument's type does not match the parameter's declared type");
            try self.compileExpr(arg);
        }
        _ = try self.chunk.emitWithOperand(self.allocator, .load_local, local.slot);
        _ = try self.chunk.emit(self.allocator, .call_value);
        return FunctionInfo{
            .name = c.name,
            .params = &.{},
            .param_named_refs = &.{},
            .return_array_size = null,
            .return_type = sig.return_type,
            .return_named_ref = null,
            .arity = @intCast(sig.param_types.len),
            .index = 0,
            .module = self.current_module,
            .exported = false,
        };
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
    /// Leaves exactly one ARRAY_REF value on the stack for the array local
    /// named `name`, whichever kind it is: a FIXED local needs a fresh
    /// reference synthesized to its slots (MAKE_ARRAY_REF), while a GENERIC
    /// local already holds one, so LOAD_LOCAL forwarding it along is enough.
    /// Shared by every context that wants an array by reference rather than
    /// by value — a generic call argument, and `read`/`write`'s buffer
    /// (ISA.bnf section 9) — which is exactly why neither the I/O opcodes
    /// nor CALL need a fixed-vs-generic variant of their own.
    /// `not_array_err` differs per context, the same way `compileArrayValue`
    /// parameterizes its own invalid-form error.
    fn emitArrayRef(self: *Compiler, name: []const u8, comptime not_array_err: SemanticError, not_array_msg: []const u8) CompileError!void {
        const local = self.resolveLocal(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
        const spec = local.array orelse return self.fail(not_array_err, name, not_array_msg);
        switch (spec) {
            .fixed => |len| _ = try self.chunk.emitWithOperand(self.allocator, .make_array_ref, chunk_mod.packIndexOperand(local.slot, len)),
            .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_local, local.slot),
        }
    }

    fn compileGenericArrayArgument(self: *Compiler, arg: *const ast.Expr) CompileError!void {
        switch (arg.*) {
            .variable => |name| try self.emitArrayRef(name, SemanticError.InvalidArrayArgument, "not an array"),
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
            .string => |v| try Value.newString(self.allocator, v),
            .null_value => .null_value,
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

    /// Compiles a bare `.variable` READ (`compileExpr`'s counterpart to
    /// `emitLocalOp`, which also covers `.assign`'s store side): a local
    /// loads as always, but a name that resolves to no local instead falls
    /// back to a top-level FUNCTION (GRAMMAR.bnf design note 3ad) — pushed
    /// as a compile-time `Value.function` constant, exactly like an enum
    /// variant (`compileEnumVariant`). This is the one place
    /// `SemanticError.InvalidFunctionValue` is raised: the only path a bare
    /// function-name expression is guaranteed to go through regardless of
    /// context (a bare `print someFunc` or `someFunc;` expression statement
    /// never runs through `checkExpectedType`/`inferType` at all).
    fn compileVariable(self: *Compiler, name: []const u8) CompileError!void {
        if (self.resolveLocal(name)) |local| {
            if (local.array != null) return self.fail(SemanticError.ArrayUsedAsScalar, name, "an array must be indexed, not used as a plain value");
            _ = try self.chunk.emitWithOperand(self.allocator, .load_local, local.slot);
            return;
        }
        const info = self.findFunction(name) orelse return self.fail(SemanticError.UndefinedVariable, name, "undefined variable");
        if (!self.functionVisible(info)) return self.fail(SemanticError.FunctionNotVisible, name, "function exists but isn't exported by a module this file imports");
        if (!functionIsValueEligible(info)) return self.fail(SemanticError.InvalidFunctionValue, name, "this function can't be used as a value: array, struct/enum, or function-typed parameters/return aren't supported for function values");
        const idx = try self.chunk.addConstant(self.allocator, .{ .function = .{ .index = info.index, .name = info.name } });
        _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
    }

    /// `<base>[i]` reads. For a FIXED-size array local: LOAD_INDEX with the
    /// array's compile-time-known base slot and length packed into the
    /// operand (ISA.bnf section 3) so the VM can bounds-check at runtime.
    /// For a GENERIC array local: LOAD_INDEX_REF instead, whose operand is
    /// just the slot holding the reference itself. Both only ever apply
    /// when `base` is a bare identifier naming such a local — a fixed/
    /// generic array element is always scalar (GRAMMAR.bnf design note 3e),
    /// so there's no way to reach this case with a non-identifier base (a
    /// chained `.index` node), and none is attempted.
    ///
    /// Everything else — a map/list/string local (bare name or not), or ANY
    /// non-identifier base, including a chained `doc["a"]["b"]` — falls
    /// through to the generic INDEX_GET path: `base` compiles as an
    /// ordinary expression (LOAD_LOCAL for a bare collection/string name, or
    /// recursively for a nested index/call/whatever else), and INDEX_GET
    /// dispatches on whatever kind of value that turns out to be at
    /// runtime (ISA.bnf section 11) — including rejecting it, the same
    /// "checked, not trusted" way an out-of-bounds array index already is.
    fn compileIndex(self: *Compiler, ix: ast.Expr.Index) CompileError!void {
        if (ix.base.* == .variable) {
            const local = self.resolveLocal(ix.base.variable) orelse return self.fail(SemanticError.UndefinedVariable, ix.base.variable, "undefined variable");
            if (local.array) |spec| {
                try self.compileExpr(ix.index);
                switch (spec) {
                    .fixed => |len| _ = try self.chunk.emitWithOperand(self.allocator, .load_index, chunk_mod.packIndexOperand(local.slot, len)),
                    .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_index_ref, local.slot),
                }
                return;
            }
            if (local.collection == null and !local.is_string) {
                return self.fail(SemanticError.NotIndexable, ix.base.variable, "not indexable — expected an array, list, map, or string");
            }
        }
        try self.compileExpr(ix.base);
        try self.compileExpr(ix.index);
        _ = try self.chunk.emit(self.allocator, .index_get);
    }

    /// `<base>[i] := value`. Dispatch mirrors `compileIndex` exactly; the
    /// generic INDEX_SET path pushes `base`, `index`, then `value`, matching
    /// its `( container index v -- v )` stack effect (ISA.bnf section 11) —
    /// the fixed/generic-array path keeps STORE_INDEX/STORE_INDEX_REF's
    /// existing `( index v -- v )` order unchanged.
    fn compileIndexAssign(self: *Compiler, ia: ast.Expr.IndexAssign) CompileError!void {
        if (ia.base.* == .variable) {
            const local = self.resolveLocal(ia.base.variable) orelse return self.fail(SemanticError.UndefinedVariable, ia.base.variable, "undefined variable");
            if (local.array) |spec| {
                try self.compileExpr(ia.index);
                try self.compileExpr(ia.value);
                switch (spec) {
                    .fixed => |len| _ = try self.chunk.emitWithOperand(self.allocator, .store_index, chunk_mod.packIndexOperand(local.slot, len)),
                    .generic => _ = try self.chunk.emitWithOperand(self.allocator, .store_index_ref, local.slot),
                }
                return;
            }
            if (local.collection == null and !local.is_string) {
                return self.fail(SemanticError.NotIndexable, ia.base.variable, "not indexable — expected an array, list, map, or string");
            }
            // A bare string local compiles through to INDEX_SET like any
            // other collection would; strings are read-only via bracket
            // syntax (GRAMMAR.bnf's Strings design notes), so this is
            // deliberately left a `RuntimeError.TypeMismatch` (indexSet's
            // `.string` case) rather than rejected here at compile time —
            // the same "checked, not trusted" stance every other
            // container/operation mismatch already gets.
        }
        try self.compileExpr(ia.base);
        try self.compileExpr(ia.index);
        try self.compileExpr(ia.value);
        _ = try self.chunk.emit(self.allocator, .index_set);
    }

    /// `TypeName{field1: expr1, ...}` (GRAMMAR.bnf design note 3z). Resolves
    /// `type_name` against the program's registered struct types, checks the
    /// literal supplies EXACTLY the struct's declared fields (no more, no
    /// fewer, no duplicates), then compiles each field's value in the
    /// struct's OWN declared order (regardless of what order the literal
    /// listed them in), so MAKE_STRUCT's popped values always land in the
    /// order `Program.struct_types` records for this type (ISA.bnf
    /// section 19).
    fn compileStructLiteral(self: *Compiler, sl: ast.Expr.StructLiteral) CompileError!void {
        const type_index = self.findTypeIndex(sl.type_name) orelse return self.fail(SemanticError.UndefinedType, sl.type_name, "no struct with this name is declared");
        const decl = self.types.items[type_index];
        if (!self.typeVisible(decl)) return self.fail(SemanticError.TypeNotVisible, sl.type_name, "type exists but isn't exported by a module this file imports");
        if (decl.kind != .struct_decl) return self.fail(SemanticError.NotAStruct, sl.type_name, "this name is an enum, not a struct — it can't be constructed with '{...}'");
        const fields = decl.kind.struct_decl.fields;

        for (fields) |f| {
            var found: ?*ast.Expr = null;
            for (sl.fields) |init_field| {
                if (!std.mem.eql(u8, init_field.name, f.name)) continue;
                if (found != null) return self.fail(SemanticError.DuplicateFieldInLiteral, f.name, "this field is given a value more than once in this struct literal");
                found = init_field.value;
            }
            const value_expr = found orelse return self.fail(SemanticError.MissingField, f.name, "this struct literal is missing a required field");
            try self.checkExpectedType(value_expr, f.type, f.name, "field value's type does not match the field's declared type");
            try self.compileExpr(value_expr);
        }
        for (sl.fields) |init_field| {
            var known = false;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, init_field.name)) known = true;
            }
            if (!known) return self.fail(SemanticError.UnknownField, init_field.name, "this struct has no field with this name");
        }

        _ = try self.chunk.emitWithOperand(self.allocator, .make_struct, @intCast(type_index));
    }

    /// `<base>.field` — either a struct field read or an enum variant
    /// reference (`Color.Red`); see `ast.Expr.field_access`'s doc comment
    /// for the disambiguation rule this implements: a bare `.variable` base
    /// that names no local in scope, but does name a declared enum type, is
    /// a variant reference; everything else must be a struct field read.
    fn compileFieldAccess(self: *Compiler, fa: ast.Expr.FieldAccess) CompileError!void {
        if (fa.base.* == .variable and self.resolveLocal(fa.base.variable) == null) {
            if (self.findTypeIndex(fa.base.variable)) |type_index| {
                return self.compileEnumVariant(type_index, fa.base.variable, fa.field);
            }
            return self.fail(SemanticError.UndefinedVariable, fa.base.variable, "undefined variable");
        }
        const type_index = try self.resolveStructBase(fa.base);
        const field_index = try self.findFieldIndex(type_index, fa.field);
        try self.compileExpr(fa.base);
        _ = try self.chunk.emitWithOperand(self.allocator, .field_get, field_index);
    }

    /// `<base>.field := value` — the `.field_assign` counterpart to
    /// `compileFieldAccess`'s struct-field-read path. There is no enum-
    /// variant assignment: `resolveStructBase` requires a struct-typed
    /// base, so `Color.Red := x` (base names no local, and isn't a struct)
    /// fails there, the same as any other invalid field-access base would.
    fn compileFieldAssign(self: *Compiler, fa: ast.Expr.FieldAssign) CompileError!void {
        const type_index = try self.resolveStructBase(fa.base);
        const field_index = try self.findFieldIndex(type_index, fa.field);
        const field_type = self.types.items[type_index].kind.struct_decl.fields[field_index].type;
        try self.checkExpectedType(fa.value, field_type, fa.field, "assigned value's type does not match the field's declared type");
        try self.compileExpr(fa.base);
        try self.compileExpr(fa.value);
        _ = try self.chunk.emitWithOperand(self.allocator, .field_set, field_index);
    }

    /// Resolves `enum_name.variant_name` to a compile-time `Value.enum_value`
    /// constant, pushed via ordinary PUSH_CONST — an enum value needs no
    /// dedicated opcode; it's a compile-time constant exactly like an int or
    /// string literal (ISA.bnf section 20).
    fn compileEnumVariant(self: *Compiler, type_index: usize, type_name: []const u8, variant_name: []const u8) CompileError!void {
        const decl = self.types.items[type_index];
        if (!self.typeVisible(decl)) return self.fail(SemanticError.TypeNotVisible, type_name, "type exists but isn't exported by a module this file imports");
        if (decl.kind != .enum_decl) return self.fail(SemanticError.NotAStruct, type_name, "this name is a struct, not an enum — it has no variants");
        for (decl.kind.enum_decl.variants, 0..) |v, i| {
            if (!std.mem.eql(u8, v, variant_name)) continue;
            const value = Value{ .enum_value = .{ .type_index = @intCast(type_index), .variant = @intCast(i), .type_name = decl.name, .variant_name = v } };
            const idx = try self.chunk.addConstant(self.allocator, value);
            _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
            return;
        }
        return self.fail(SemanticError.UnknownEnumVariant, variant_name, "this enum has no variant with this name");
    }

    /// Resolves a `.field_access`/`.field_assign` base to the struct-type
    /// index it must be, using the compiler's own static type inference —
    /// field access, unlike bracket-indexing, is never left to a runtime
    /// check (`SemanticError.NotAStruct` covers both "knowably not a
    /// struct" and "not knowable at compile time at all"), since the
    /// field's slot has to be resolved here (GRAMMAR.bnf design note 3z).
    fn resolveStructBase(self: *Compiler, base: *const ast.Expr) CompileError!usize {
        const bt = try self.inferType(base) orelse return self.fail(SemanticError.NotAStruct, "", "not a struct — its type can't be determined at compile time");
        return switch (bt) {
            .struct_type => |i| i,
            else => self.fail(SemanticError.NotAStruct, "", "not a struct — expected a struct value"),
        };
    }

    fn findFieldIndex(self: *Compiler, type_index: usize, field: []const u8) CompileError!u32 {
        const fields = self.types.items[type_index].kind.struct_decl.fields;
        for (fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, field)) return @intCast(i);
        }
        return self.fail(SemanticError.UnknownField, field, "this struct has no field with this name");
    }

    /// `<base>[start..end]` (GRAMMAR.bnf's Strings design notes) — always a
    /// read; there is no slice-assign counterpart, so unlike `compileIndex`
    /// there's no `local.array` branch that could ever emit a STORE. A bare
    /// ARRAY-typed local is rejected here even though `compileIndex` would
    /// happily emit LOAD_INDEX for a single-element read of one: a raw
    /// fixed/generic array still isn't a first-class value (GRAMMAR.bnf
    /// design note 3e), so there is no array-shaped VALUE here to slice into
    /// a new one, unlike a single scalar element. A bare non-string,
    /// non-collection local (a plain int/float/bool) is rejected the same
    /// way `compileIndex` rejects one. Everything else — a string (bare or
    /// not), a map/list, or any non-identifier base — compiles through to
    /// INDEX_SLICE, which TypeMismatches at runtime for anything but a
    /// string container (map/list slicing isn't supported in this pass).
    fn compileSlice(self: *Compiler, sl: ast.Expr.Slice) CompileError!void {
        if (sl.base.* == .variable) {
            const local = self.resolveLocal(sl.base.variable) orelse return self.fail(SemanticError.UndefinedVariable, sl.base.variable, "undefined variable");
            if (local.array != null or (local.collection == null and !local.is_string)) {
                return self.fail(SemanticError.NotIndexable, sl.base.variable, "not sliceable — expected a string");
            }
        }
        try self.compileExpr(sl.base);
        try self.compileExpr(sl.start);
        try self.compileExpr(sl.end);
        _ = try self.chunk.emit(self.allocator, .index_slice);
    }

    /// `len(<expression>)`. A bare identifier naming a FIXED-size array
    /// local compiles to a plain PUSH_CONST of its declared size — no
    /// runtime check at all, since that length is fixed at compile time and
    /// never changes (GRAMMAR.bnf design note 3e). A bare GENERIC array
    /// local instead emits LOAD_REF_LEN, reading the length out of the
    /// reference value at runtime (ISA.bnf section 6's generic-array
    /// addendum). Anything else — a map/list/string (bare name or not), or
    /// any other expression entirely — compiles as an ordinary expression
    /// followed by LEN_VALUE, a genuine runtime operation returning element
    /// count (list), entry count (map), or byte length (string)
    /// (`RuntimeError.TypeMismatch` if the value it's handed turns out not
    /// to be any of those): unlike bracket-indexing, `len` on a
    /// statically-known plain scalar local is deliberately NOT a compile
    /// error here, matching design note 3m's framing of this as a runtime
    /// question once anything past a bare fixed/generic array is involved.
    fn compileLenOf(self: *Compiler, expr: *const ast.Expr) CompileError!void {
        if (expr.* == .variable) {
            if (self.resolveLocal(expr.variable)) |local| {
                if (local.array) |spec| {
                    switch (spec) {
                        .fixed => |len| {
                            const idx = try self.chunk.addConstant(self.allocator, .{ .int = @intCast(len) });
                            _ = try self.chunk.emitWithOperand(self.allocator, .push_const, idx);
                        },
                        .generic => _ = try self.chunk.emitWithOperand(self.allocator, .load_ref_len, local.slot),
                    }
                    return;
                }
            } else {
                return self.fail(SemanticError.UndefinedVariable, expr.variable, "undefined variable");
            }
        }
        try self.compileExpr(expr);
        _ = try self.chunk.emit(self.allocator, .len_value);
    }

    /// Compiles the stream an I/O operation acts on, and — where the answer
    /// is knowable now — rejects using it in a direction it doesn't support.
    ///
    /// A stream is a runtime value (it can be an opened file, whose
    /// direction depends on the mode it was opened with), so the VM checks
    /// direction too and is the only line of defence in general. But when
    /// the source names one of the three standard streams by keyword the
    /// answer IS static, and catching `read(stdout, buf)` at compile time —
    /// where it can be reported against the keyword the program actually
    /// wrote — beats catching it on the first execution.
    fn compileStreamOperand(self: *Compiler, stream: *const ast.Expr, comptime dir: enum { read, write }) CompileError!void {
        if (stream.* == .stream_literal) {
            const standard = stream.stream_literal;
            const ok = switch (dir) {
                .read => standard == .stdin,
                .write => standard == .stdout or standard == .stderr,
            };
            if (!ok) return switch (dir) {
                .read => self.fail(SemanticError.WrongStreamDirection, standard.name(), "cannot read from this stream — of the standard streams only 'stdin' is readable"),
                .write => self.fail(SemanticError.WrongStreamDirection, standard.name(), "cannot write to this stream — of the standard streams only 'stdout' and 'stderr' are writable"),
            };
        }
        try self.compileExpr(stream);
    }

    /// `read(stream, buf)` — the stream is pushed first, then the buffer as
    /// an ARRAY_REF (`emitArrayRef`, so a fixed and a generic buffer both
    /// work and READ needs only one form), matching READ's
    /// `( stream ref -- count )` stack effect.
    fn compileReadBytes(self: *Compiler, r: ast.Expr.ReadBytes) CompileError!void {
        try self.compileStreamOperand(r.stream, .read);
        try self.emitArrayRef(r.buffer, SemanticError.NotAnArray, "read's destination must be an array");
        _ = try self.chunk.emit(self.allocator, .read);
    }

    /// `write(stream, expr)` — an ordinary scalar expression, so this is
    /// just its codegen followed by WRITE. Unlike `print`, no newline is
    /// emitted; the value is rendered exactly as PRINT renders it and
    /// nothing more.
    fn compileWriteValue(self: *Compiler, w: ast.Expr.WriteValue) CompileError!void {
        try self.compileStreamOperand(w.stream, .write);
        try self.compileExpr(w.value);
        _ = try self.chunk.emit(self.allocator, .write);
    }

    /// `write(stream, buf, count)` — mirrors `compileReadBytes`, with the
    /// count pushed after the reference so the runtime stack order matches
    /// WRITE_BYTES's `( stream ref count -- written )` stack effect.
    fn compileWriteBytes(self: *Compiler, w: ast.Expr.WriteBytes) CompileError!void {
        try self.compileStreamOperand(w.stream, .write);
        try self.emitArrayRef(w.buffer, SemanticError.NotAnArray, "write's buffer must be an array");
        try self.compileExpr(w.count);
        _ = try self.chunk.emit(self.allocator, .write_bytes);
    }

    /// `open(path, mode)` — the path is an ordinary expression (it has to be
    /// a string at runtime, which the VM checks), while the mode is a
    /// compile-time keyword and so becomes OPEN's operand.
    fn compileOpenFile(self: *Compiler, o: ast.Expr.OpenFile) CompileError!void {
        try self.compileExpr(o.path);
        _ = try self.chunk.emitWithOperand(self.allocator, .open, @intFromEnum(o.mode));
    }

    /// `close <expr>` — CLOSE consumes the stream and leaves nothing, so
    /// unlike the other I/O forms there is no result to pop afterwards
    /// (which is exactly why `close` is a statement).
    fn compileCloseStmt(self: *Compiler, stream: *const ast.Expr) CompileError!void {
        if (stream.* == .stream_literal) {
            return self.fail(SemanticError.CannotCloseStandardStream, stream.stream_literal.name(), "cannot close a standard stream — it belongs to whoever ran this program");
        }
        try self.compileExpr(stream);
        _ = try self.chunk.emit(self.allocator, .close);
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

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, .{ .out = &writer });
    return writer.buffered();
}

const IoResult = struct { out: []const u8, err: []const u8 };

/// `runProgram` with the other two streams wired up too: `input` is what
/// the program's `read(stdin, ...)` sees, and stdout/stderr come back
/// separately so a test can tell which stream a `write` actually reached.
fn runProgramWithIo(
    allocator: std.mem.Allocator,
    source: []const u8,
    input: []const u8,
    out_buf: []u8,
    err_buf: []u8,
) !IoResult {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var out = std.Io.Writer.fixed(out_buf);
    var err = std.Io.Writer.fixed(err_buf);
    var in = std.Io.Reader.fixed(input);
    try vm.run(&compiled, .{ .out = &out, .err = &err, .in = &in });
    return .{ .out = out.buffered(), .err = err.buffered() };
}

/// Compiles `source` expecting it to fail, returning the semantic error —
/// for the I/O tests below, which are mostly about what the compiler
/// rejects statically rather than what the VM does at runtime.
fn expectCompileError(allocator: std.mem.Allocator, source: []const u8, expected: SemanticError) !void {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(expected, compiler.compileProgram(program));
    try std.testing.expect(compiler.diagnostic != null);
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

test "compiles 'exit', which halts immediately and sets the VM's exit_code" {
    const allocator = std.testing.allocator;

    var lex = lexer_mod.Lexer.init("print 1\nexit 2\nprint 3\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, .{ .out = &writer });

    // "3" is never printed: exit halts the whole program right where it's
    // called, not just the statement it's part of.
    try std.testing.expectEqualStrings("1\n", writer.buffered());
    try std.testing.expectEqual(@as(?u8, 2), vm.exit_code);
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

test "indexing a non-array, non-collection local is a compile error" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int x := 1\nprint x[0]\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.NotIndexable, compiler.compileProgram(program));
}

test "a bare string local can be indexed and sliced" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\string s := "hello"
        \\print s[1]
        \\print s[1..4]
    , &buf);
    try std.testing.expectEqualStrings("e\nell\n", output);
}

test "assigning through a bare string local's index compiles fine but is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("string s := \"hi\"\ns[0] := \"X\"\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileProgram(program); // must not raise NotIndexable
    defer compiled.deinit(allocator);
}

test "slicing a plain scalar local is a compile-time NotIndexable error" {
    try expectCompileError(std.testing.allocator, "int x := 1\nprint x[0..1]\n", SemanticError.NotIndexable);
}

test "slicing a bare fixed-array local is a compile-time NotIndexable error" {
    try expectCompileError(std.testing.allocator, "int[3] arr\nprint arr[0..2]\n", SemanticError.NotIndexable);
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

test "len(s) on a string returns its byte length" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\string s := "hello"
        \\print len(s)
        \\print len("")
        \\print len("Hello, " + "world")
    , &buf);
    try std.testing.expectEqualStrings("5\n0\n12\n", output);
}

test "len() on a non-array, non-collection local compiles fine but is a runtime TypeMismatch" {
    // Relaxed from a compile error (design note 3m): a bare scalar local is
    // no longer statically rejected here the way bracket-indexing rejects
    // one — `len` on anything but a fixed/generic array is now a genuine
    // runtime question, same as `len` on any other non-array expression.
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator, "int x := 1\nprint len(x)\n", &buf));
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

test "a bracketed literal outside a matching array declaration builds a list (design note 3m)" {
    // This used to be `CompileError.UnexpectedArrayLiteral` — now that a
    // bracketed literal reaching general expression position always means
    // "build a list" instead, it runs and prints one.
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "print [1, 2, 3]\n", &buf);
    try std.testing.expectEqualStrings("[1, 2, 3]\n", output);
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

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, .{ .out = &writer });
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

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, .{ .out = &writer });
    try std.testing.expectEqualStrings("20\n", writer.buffered());
}

// ---- Records and enums (GRAMMAR.bnf design notes 3z, 3aa) ---------------

test "struct: declare, construct, and read fields" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point {
        \\    int x,
        \\    int y
        \\}
        \\Point p := Point{x: 1, y: 2}
        \\print p.x
        \\print p.y
        \\
    , &buf);
    try std.testing.expectEqualStrings("1\n2\n", output);
}

test "struct: field write mutates in place" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\Point p := Point{x: 1, y: 2}
        \\p.x := 99
        \\print p.x
        \\
    , &buf);
    try std.testing.expectEqualStrings("99\n", output);
}

test "struct: fields may be keyed in any order in a literal" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\Point p := Point{y: 2, x: 1}
        \\print p.x
        \\print p.y
        \\
    , &buf);
    try std.testing.expectEqualStrings("1\n2\n", output);
}

test "struct: assignment aliases — mutation through one is visible through the other" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\Point a := Point{x: 1, y: 2}
        \\Point b := a
        \\b.x := 99
        \\print a.x
        \\
    , &buf);
    try std.testing.expectEqualStrings("99\n", output);
}

test "struct: a field may itself be another struct type (nesting)" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\struct Line { Point start, Point end }
        \\Line l := Line{start: Point{x: 1, y: 2}, end: Point{x: 3, y: 4}}
        \\print l.start.x
        \\print l.end.y
        \\
    , &buf);
    try std.testing.expectEqualStrings("1\n4\n", output);
}

test "struct: a field's type may forward-reference a struct declared later in the file" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Line { Point start, Point end }
        \\struct Point { int x, int y }
        \\Line l := Line{start: Point{x: 1, y: 2}, end: Point{x: 3, y: 4}}
        \\print l.start.x
        \\
    , &buf);
    try std.testing.expectEqualStrings("1\n", output);
}

test "struct: print renders it like a JSON object, keyed by declared field names" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\print Point{x: 1, y: 2}
        \\
    , &buf);
    try std.testing.expectEqualStrings("{\"x\": 1, \"y\": 2}\n", output);
}

test "struct: a struct-typed local with no initializer defaults to every field recursively defaulted" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\Point p
        \\print p.x
        \\print p.y
        \\
    , &buf);
    try std.testing.expectEqualStrings("0\n0\n", output);
}

test "struct: can be passed to and returned from a function" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\func make(int x, int y) -> Point {
        \\    return Point{x: x, y: y}
        \\}
        \\func sum(Point p) -> int {
        \\    return p.x + p.y
        \\}
        \\print sum(make(3, 4))
        \\
    , &buf);
    try std.testing.expectEqualStrings("7\n", output);
}

test "struct: unknown field on read is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nPoint p := Point{x: 1, y: 2}\nprint p.z\n", SemanticError.UnknownField);
}

test "struct: unknown field in a literal is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nPoint p := Point{x: 1, y: 2, z: 3}\n", SemanticError.UnknownField);
}

test "struct: a literal missing a required field is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nPoint p := Point{x: 1}\n", SemanticError.MissingField);
}

test "struct: a literal repeating the same field is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nPoint p := Point{x: 1, x: 2, y: 3}\n", SemanticError.DuplicateFieldInLiteral);
}

test "struct: a duplicate field name in the declaration itself is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int x }\n", SemanticError.DuplicateField);
}

test "struct: a field's type not matching the declared type is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nPoint p := Point{x: \"a\", y: 2}\n", SemanticError.TypeMismatch);
}

test "struct: assigning to a field with the wrong type is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nPoint p := Point{x: 1, y: 2}\np.x := \"a\"\n", SemanticError.TypeMismatch);
}

test "struct: field access on a statically non-struct value is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int x := 5\nprint x.y\n", SemanticError.NotAStruct);
}

test "referencing an undeclared type name is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "Foo x := 1\n", SemanticError.UndefinedType);
}

test "declaring two types (struct or enum) with the same name is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x }\nstruct Point { int y }\n", SemanticError.DuplicateTypeName);
    try expectCompileError(allocator, "struct Point { int x }\nenum Point { Red }\n", SemanticError.DuplicateTypeName);
}

test "enum: declare, reference a variant, and print by name" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\enum Color { Red, Green, Blue }
        \\Color c := Color.Red
        \\print c
        \\
    , &buf);
    try std.testing.expectEqualStrings("Red\n", output);
}

test "enum: a local with no initializer defaults to the first-declared variant" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\enum Color { Red, Green, Blue }
        \\Color c
        \\print c
        \\
    , &buf);
    try std.testing.expectEqualStrings("Red\n", output);
}

test "enum: == is true only for the same type and variant, false (not an error) otherwise" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\enum Color { Red, Green }
        \\enum Size { Red, Small }
        \\print Color.Red == Color.Red
        \\print Color.Red == Color.Green
        \\print Color.Red == Size.Red
        \\print Color.Red == 0
        \\
    , &buf);
    try std.testing.expectEqualStrings("true\nfalse\nfalse\nfalse\n", output);
}

test "enum: assigning a bare int where an enum is expected is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "enum Color { Red, Green }\nColor c := 5\n", SemanticError.TypeMismatch);
}

test "enum: passing an int argument where an enum parameter is expected is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\enum Color { Red, Green }
        \\func show(Color c) -> int { return 0 }
        \\show(1)
        \\
    , SemanticError.TypeMismatch);
}

test "enum: referencing an unknown variant is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "enum Color { Red, Green }\nprint Color.Purple\n", SemanticError.UnknownEnumVariant);
}

test "enum: a duplicate variant name in the declaration is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "enum Color { Red, Red }\n", SemanticError.DuplicateVariant);
}

// ---- Struct methods (GRAMMAR.bnf design note 3af) ------------------------

test "method: declare and call on a struct value, receiver reads its own fields" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\func (Point p) sum() -> int {
        \\    return p.x + p.y
        \\}
        \\Point pt := Point{x: 3, y: 4}
        \\print pt.sum()
        \\
    , &buf);
    try std.testing.expectEqualStrings("7\n", output);
}

test "method: takes its own parameters alongside the receiver" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\func (Point p) scaled(int f) -> Point {
        \\    return Point{x: p.x * f, y: p.y * f}
        \\}
        \\Point pt := Point{x: 3, y: 4}
        \\Point doubled := pt.scaled(2)
        \\print doubled.x
        \\print doubled.y
        \\
    , &buf);
    try std.testing.expectEqualStrings("6\n8\n", output);
}

test "method: mutating a field through the receiver is visible to the caller (reference semantics)" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Counter { int n }
        \\func (Counter c) inc() -> int {
        \\    c.n := c.n + 1
        \\    return c.n
        \\}
        \\Counter counter := Counter{n: 0}
        \\counter.inc()
        \\counter.inc()
        \\print counter.n
        \\
    , &buf);
    try std.testing.expectEqualStrings("2\n", output);
}

test "method: a method body may call another method and an ordinary function" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\func double(int n) -> int { return n * 2 }
        \\func (Point p) sum() -> int { return p.x + p.y }
        \\func (Point p) doubledSum() -> int { return double(p.sum()) }
        \\Point pt := Point{x: 3, y: 4}
        \\print pt.doubledSum()
        \\
    , &buf);
    try std.testing.expectEqualStrings("14\n", output);
}

test "method: two different structs may each declare a method with the same name" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x }
        \\struct Vector { int x }
        \\func (Point p) dist() -> int { return p.x }
        \\func (Vector v) dist() -> int { return v.x * 2 }
        \\Point p := Point{x: 5}
        \\Vector v := Vector{x: 5}
        \\print p.dist()
        \\print v.dist()
        \\
    , &buf);
    try std.testing.expectEqualStrings("5\n10\n", output);
}

test "method: a struct declaring both a field and a method with the same name is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x, int y }\nfunc (Point p) x() -> int { return p.x }\n", SemanticError.DuplicateFieldOrMethod);
}

test "method: a struct declaring two methods with the same name is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x }\nfunc (Point p) dist() -> int { return 0 }\nfunc (Point p) dist() -> int { return 1 }\n", SemanticError.DuplicateFieldOrMethod);
}

test "method: a receiver naming an enum instead of a struct is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "enum Color { Red, Blue }\nfunc (Color c) name() -> string { return \"x\" }\n", SemanticError.ReceiverNotAStruct);
}

test "method: a receiver naming an undeclared type is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "func (Foo f) bar() -> int { return 0 }\n", SemanticError.UndefinedType);
}

test "method: calling a method the struct doesn't have is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x }\nPoint p := Point{x: 1}\nprint p.bogus()\n", SemanticError.UnknownMethod);
}

test "method: calling a method on a statically non-struct value is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int x := 5\nprint x.dist()\n", SemanticError.NotAStruct);
}

test "method: calling with the wrong number of arguments is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x }\nfunc (Point p) add(int a, int b) -> int { return p.x + a + b }\nPoint p := Point{x: 1}\nprint p.add(1)\n", SemanticError.ArityMismatch);
}

test "method: calling with an argument of the wrong type is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "struct Point { int x }\nfunc (Point p) add(int a) -> int { return p.x + a }\nPoint p := Point{x: 1}\nprint p.add(\"oops\")\n", SemanticError.TypeMismatch);
}

test "method: exported from a directly imported module is callable" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;

    var lib = try parseSource(allocator, "export struct Point { int x, int y }\nexport func (Point p) sum() -> int { return p.x + p.y }\n");
    defer lib.parser.deinit();
    var main = try parseSource(allocator, "Point p := Point{x: 3, y: 4}\nprint p.sum()\n");
    defer main.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{1} },
        .{ .program = lib.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(0, &units);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, .{ .out = &writer });
    try std.testing.expectEqualStrings("7\n", writer.buffered());
}

test "method: a non-exported method from an imported module is not visible" {
    const allocator = std.testing.allocator;

    var lib = try parseSource(allocator, "export struct Point { int x, int y }\nfunc (Point p) sum() -> int { return p.x + p.y }\n");
    defer lib.parser.deinit();
    var main = try parseSource(allocator, "Point p := Point{x: 3, y: 4}\nprint p.sum()\n");
    defer main.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{1} },
        .{ .program = lib.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.FunctionNotVisible, compiler.compileModules(0, &units));
}

test "compileModules: a struct exported by a directly imported module is usable" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;

    var lib = try parseSource(allocator, "export struct Point { int x, int y }\n");
    defer lib.parser.deinit();
    var main = try parseSource(allocator, "Point p := Point{x: 1, y: 2}\nprint p.x\n");
    defer main.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{1} },
        .{ .program = lib.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(0, &units);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, .{ .out = &writer });
    try std.testing.expectEqualStrings("1\n", writer.buffered());
}

test "compileModules: a non-exported struct from an imported module is a compile error" {
    const allocator = std.testing.allocator;
    var lib = try parseSource(allocator, "struct Point { int x, int y }\n");
    defer lib.parser.deinit();
    var main = try parseSource(allocator, "Point p := Point{x: 1, y: 2}\n");
    defer main.parser.deinit();

    const units = [_]ModuleUnit{
        .{ .program = main.program, .imports = &.{1} },
        .{ .program = lib.program },
    };

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    try std.testing.expectError(CompileError.TypeNotVisible, compiler.compileModules(0, &units));
}

// ---- Byte-stream I/O (GRAMMAR.bnf design note 3k) -----------------------

test "write emits a value with no trailing newline, unlike print" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\write(stdout, 1)
        \\write(stdout, 2)
        \\print 3
    , "", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("123\n", result.out);
}

test "write to stderr stays out of stdout" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\write(stdout, "to out")
        \\write(stderr, "to err")
    , "", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("to out", result.out);
    try std.testing.expectEqualStrings("to err", result.err);
}

test "write evaluates to the number of bytes it wrote" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\print write(stderr, "hello")
        \\print write(stderr, 1000)
        \\print write(stderr, true)
    , "", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("5\n4\n4\n", result.out);
    try std.testing.expectEqualStrings("hello1000true", result.err);
}

test "read fills a fixed-size buffer and evaluates to the byte count" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\int[4] buf
        \\int n := read(stdin, buf)
        \\print n
        \\print buf[0]
        \\print buf[3]
    , "ABCD", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("4\n65\n68\n", result.out);
}

test "read then write round-trips bytes through a buffer" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\int[16] buf
        \\int n := read(stdin, buf)
        \\write(stdout, buf, n)
    , "round trip", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("round trip", result.out);
}

test "a read/write loop copies input larger than the buffer" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    // A 3-byte buffer against 10 bytes of input: only a loop that keeps
    // reading until `read` reports 0 copies all of it.
    const result = try runProgramWithIo(allocator,
        \\int[3] buf
        \\int n := read(stdin, buf)
        \\while n > 0 {
        \\    write(stdout, buf, n)
        \\    n := read(stdin, buf)
        \\}
    , "0123456789", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("0123456789", result.out);
}

test "read at end of input evaluates to 0" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\int[4] buf
        \\print read(stdin, buf)
    , "", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("0\n", result.out);
}

test "a generic (unsized) buffer works for I/O, and by reference" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    // `fill` reads into the CALLER's own slots — a generic array parameter
    // is a reference, not a copy (design note 3j) — so the bytes are still
    // there to write back out after the call returns.
    const result = try runProgramWithIo(allocator,
        \\func fill(int[] b) -> int {
        \\    return read(stdin, b)
        \\}
        \\int[8] buf
        \\int n := fill(buf)
        \\print n
        \\write(stdout, buf, n)
    , "hey", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("3\nhey", result.out);
}

test "a buffer of byte values writes exactly those bytes" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    // 72/105/10 are 'H', 'i', and a newline — how a program emits a raw
    // newline, since Butter string literals have no escape sequences.
    const result = try runProgramWithIo(allocator,
        \\int[3] line := [72, 105, 10]
        \\write(stdout, line, 3)
    , "", &out_buf, &err_buf);
    try std.testing.expectEqualStrings("Hi\n", result.out);
}

test "reading from a non-readable stream is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int[2] b\nread(stdout, b)\n", SemanticError.WrongStreamDirection);
    try expectCompileError(allocator, "int[2] b\nread(stderr, b)\n", SemanticError.WrongStreamDirection);
}

test "writing to a non-writable stream is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "write(stdin, 1)\n", SemanticError.WrongStreamDirection);
    try expectCompileError(allocator, "int[2] b\nwrite(stdin, b, 1)\n", SemanticError.WrongStreamDirection);
}

test "read/write's buffer must name an array, not a scalar" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int x := 1\nread(stdin, x)\n", SemanticError.NotAnArray);
    try expectCompileError(allocator, "int x := 1\nwrite(stdout, x, 1)\n", SemanticError.NotAnArray);
}

test "read/write's buffer must be a declared name" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "read(stdin, nope)\n", SemanticError.UndefinedVariable);
    try expectCompileError(allocator, "write(stdout, nope, 1)\n", SemanticError.UndefinedVariable);
}

// ---- Files (GRAMMAR.bnf design note 3l) ----------------------------------

/// `runProgramWithIo` with real filesystem access wired up too, rooted at
/// `dir` (a test's own `std.testing.tmpDir`) — what `open` needs to do
/// anything at all (`Host.fs`).
fn runProgramWithFs(
    allocator: std.mem.Allocator,
    source: []const u8,
    dir: std.Io.Dir,
    out_buf: []u8,
    err_buf: []u8,
) !IoResult {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var out = std.Io.Writer.fixed(out_buf);
    var err = std.Io.Writer.fixed(err_buf);
    try vm.run(&compiled, .{
        .out = &out,
        .err = &err,
        .fs = .{ .io = std.testing.io, .dir = dir },
    });
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "open/write/close, then reopen/read/close, round-trips a file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int f := open("greeting.txt", write)
        \\write(f, "hello")
        \\close f
        \\int g := open("greeting.txt", read)
        \\int[16] buf
        \\int n := read(g, buf)
        \\close g
        \\print n
        \\write(stdout, buf, n)
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("5\nhello", result.out);
}

test "append mode adds to a file's existing content instead of truncating it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int f := open("log.txt", write)
        \\write(f, "one")
        \\close f
        \\int g := open("log.txt", append)
        \\write(g, "two")
        \\close g
        \\int h := open("log.txt", read)
        \\int[16] buf
        \\int n := read(h, buf)
        \\close h
        \\write(stdout, buf, n)
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("onetwo", result.out);
}

test "write mode truncates an existing file rather than appending to it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int f := open("log.txt", write)
        \\write(f, "first version, quite long")
        \\close f
        \\int g := open("log.txt", write)
        \\write(g, "short")
        \\close g
        \\int h := open("log.txt", read)
        \\int[64] buf
        \\int n := read(h, buf)
        \\close h
        \\print n
        \\write(stdout, buf, n)
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("5\nshort", result.out);
}

test "opening a nonexistent file for reading is a runtime error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.FileOpenFailed, runProgramWithFs(allocator,
        \\open("does-not-exist.txt", read)
    , tmp.dir, &out_buf, &err_buf));
}

test "using a file after it's been closed is a clean error, not a stale handle" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.StreamClosed, runProgramWithFs(allocator,
        \\int f := open("data.txt", write)
        \\close f
        \\close f
    , tmp.dir, &out_buf, &err_buf));
}

test "opening more files at once than the table holds is a runtime error" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TooManyOpenFiles, runProgramWithFs(allocator,
        \\int f := open("data.txt", write)
        \\close f
        \\for i in 0..9 {
        \\    open("data.txt", read)
        \\}
    , tmp.dir, &out_buf, &err_buf));
}

test "a program run with no filesystem access can't open files" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.FilesUnavailable, runProgramWithIo(allocator,
        \\open("anything.txt", read)
    , "", &out_buf, &err_buf));
}

test "closing a standard stream named directly is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "close stdout\n", SemanticError.CannotCloseStandardStream);
    try expectCompileError(allocator, "close stdin\n", SemanticError.CannotCloseStandardStream);
    try expectCompileError(allocator, "close stderr\n", SemanticError.CannotCloseStandardStream);
}

test "closing a standard stream reached through a variable is a runtime error instead" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.CannotCloseStandardStream, runProgramWithIo(allocator,
        \\int s := stdout
        \\close s
    , "", &out_buf, &err_buf));
}

test "an opened file's direction is checked at runtime, not compile time" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.StreamNotReadable, runProgramWithFs(allocator,
        \\int f := open("data.txt", write)
        \\int[4] buf
        \\read(f, buf)
    , tmp.dir, &out_buf, &err_buf));
}

// ---- Directory and filesystem metadata (GRAMMAR.bnf design note 3w) -----

test "exists(...) is true for a file and a directory, false for neither" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int f := open("a.txt", write)
        \\close f
        \\print exists("a.txt")
        \\print exists("no-such-file.txt")
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("true\nfalse\n", result.out);
}

test "exists(...) static type is bool, and it's a legal bare statement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\bool b := exists("no-such-file.txt")
        \\print b
        \\exists("also-nope.txt")
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("false\n", result.out);
}

test "listDir(...) lists a directory's own entries, order aside" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [256]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int a := open("a.txt", write)
        \\close a
        \\int b := open("b.txt", write)
        \\close b
        \\list entries := listDir(".")
        \\print len(entries)
        \\bool has_a := false
        \\bool has_b := false
        \\for i in 0..len(entries) {
        \\    if entries[i] == "a.txt" { has_a := true }
        \\    if entries[i] == "b.txt" { has_b := true }
        \\}
        \\print has_a
        \\print has_b
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("2\ntrue\ntrue\n", result.out);
}

test "listDir(...) on a missing or non-directory path is ListDirFailed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.ListDirFailed, runProgramWithFs(allocator,
        \\listDir("no-such-dir")
    , tmp.dir, &out_buf, &err_buf));

    const result2 = runProgramWithFs(allocator,
        \\int f := open("a.txt", write)
        \\close f
        \\listDir("a.txt")
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectError(vm_mod.RuntimeError.ListDirFailed, result2);
}

test "remove(...) deletes a file or empty directory, evaluating to whether one was there" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int f := open("a.txt", write)
        \\close f
        \\print remove("a.txt")
        \\print exists("a.txt")
        \\print remove("a.txt")
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("true\nfalse\nfalse\n", result.out);
}

test "remove(...) on a non-empty directory is RemoveFailed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub = try tmp.dir.createDirPathOpen(std.testing.io, "sub", .{});
    var f = try sub.createFile(std.testing.io, "inside.txt", .{});
    f.close(std.testing.io);
    sub.close(std.testing.io);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.RemoveFailed, runProgramWithFs(allocator,
        \\remove("sub")
    , tmp.dir, &out_buf, &err_buf));
}

test "rename(...) moves a file, evaluating to whether the source existed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\int f := open("a.txt", write)
        \\write(f, "hi")
        \\close f
        \\print rename("a.txt", "b.txt")
        \\print exists("a.txt")
        \\print exists("b.txt")
        \\print rename("a.txt", "c.txt")
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("true\nfalse\ntrue\nfalse\n", result.out);
}

test "rename(...) into a missing destination directory is RenameFailed, not a silent 'false'" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.RenameFailed, runProgramWithFs(allocator,
        \\int f := open("a.txt", write)
        \\close f
        \\rename("a.txt", "no-such-dir/b.txt")
    , tmp.dir, &out_buf, &err_buf));
}

test "a program run with no filesystem access can't use exists/listDir/remove/rename/mkdir" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.FilesUnavailable, runProgramWithIo(allocator,
        \\exists("anything.txt")
    , "", &out_buf, &err_buf));
    try std.testing.expectError(vm_mod.RuntimeError.FilesUnavailable, runProgramWithIo(allocator,
        \\listDir(".")
    , "", &out_buf, &err_buf));
    try std.testing.expectError(vm_mod.RuntimeError.FilesUnavailable, runProgramWithIo(allocator,
        \\remove("anything.txt")
    , "", &out_buf, &err_buf));
    try std.testing.expectError(vm_mod.RuntimeError.FilesUnavailable, runProgramWithIo(allocator,
        \\rename("a.txt", "b.txt")
    , "", &out_buf, &err_buf));
    try std.testing.expectError(vm_mod.RuntimeError.FilesUnavailable, runProgramWithIo(allocator,
        \\mkdir("anything")
    , "", &out_buf, &err_buf));
}

test "listDir(...)'s static type is list, remove/rename/mkdir's is bool" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int n := listDir(\".\")\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "int n := remove(\"a\")\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "int n := rename(\"a\", \"b\")\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "int n := mkdir(\"a\")\n", SemanticError.TypeMismatch);
}

test "mkdir(...) creates a directory, evaluating to whether it was newly made" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithFs(allocator,
        \\print exists("sub")
        \\print mkdir("sub")
        \\print exists("sub")
        \\print mkdir("sub")
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("false\ntrue\ntrue\nfalse\n", result.out);
}

test "mkdir(...) is not recursive: a missing parent directory is MkdirFailed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.MkdirFailed, runProgramWithFs(allocator,
        \\mkdir("no-such-parent/sub")
    , tmp.dir, &out_buf, &err_buf));
}

test "mkdir(...) on a path that already exists as a file is MkdirFailed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.MkdirFailed, runProgramWithFs(allocator,
        \\int f := open("blocker.txt", write)
        \\close f
        \\mkdir("blocker.txt")
    , tmp.dir, &out_buf, &err_buf));
}

// ---- Subprocess execution (GRAMMAR.bnf design note 3x, ISA.bnf section 17)

/// `runProgramWithFs`'s counterpart for `Host.process` — a real
/// `std.testing.tmpDir` grants `exec` permission to spawn processes AND a
/// working directory to spawn them in, mirroring `Host.fs`'s own two
/// fields exactly (`Host.Process` and `Host.Fs` have the same shape).
fn runProgramWithProcess(
    allocator: std.mem.Allocator,
    source: []const u8,
    dir: std.Io.Dir,
    out_buf: []u8,
    err_buf: []u8,
) !IoResult {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var out = std.Io.Writer.fixed(out_buf);
    var err = std.Io.Writer.fixed(err_buf);
    try vm.run(&compiled, .{
        .out = &out,
        .err = &err,
        .process = .{ .io = std.testing.io, .dir = dir },
    });
    return .{ .out = out.buffered(), .err = err.buffered() };
}

test "exec(...)'s static type is map" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int n := exec(\"a\", [])\n", SemanticError.TypeMismatch);
}

test "a program run with no process access can't use exec" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.ProcessesUnavailable, runProgramWithIo(allocator,
        \\exec("anything", [])
    , "", &out_buf, &err_buf));
}

test "exec(...) with a non-string element in args is TypeMismatch, even once process access is granted" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgramWithProcess(allocator,
        \\list bad_args := [1]
        \\exec("anything", bad_args)
    , tmp.dir, &out_buf, &err_buf));
}

test "exec(...) on a program that doesn't exist is ProcessSpawnFailed, not a crash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.ProcessSpawnFailed, runProgramWithProcess(allocator,
        \\exec("this-program-definitely-does-not-exist-anywhere-42", [])
    , tmp.dir, &out_buf, &err_buf));
}

test "exec(...)'s ProcessSpawnFailed is catchable, naming 'exec' as the operation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out_buf: [128]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithProcess(allocator,
        \\try {
        \\    exec("this-program-definitely-does-not-exist-anywhere-42", [])
        \\} catch e {
        \\    print e.error
        \\    print e.operation
        \\}
    , tmp.dir, &out_buf, &err_buf);
    try std.testing.expectEqualStrings("ProcessSpawnFailed\nexec\n", result.out);
}

// ---- Maps, lists, and JSON (GRAMMAR.bnf design notes 3m/3n) -------------

test "a map/list literal compiles and prints" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list xs := [1, 2, 3]
        \\print xs
        \\map m := {"a": 1, "b": 2}
        \\print m
    , &buf);
    try std.testing.expectEqualStrings("[1, 2, 3]\n{\"a\": 1, \"b\": 2}\n", output);
}

test "a bare map/list declaration with no initializer starts empty" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\map m
        \\list xs
        \\print len(m)
        \\print len(xs)
    , &buf);
    try std.testing.expectEqualStrings("0\n0\n", output);
}

test "bracket read/write work on both list and map" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list xs := [1, 2, 3]
        \\xs[1] := 20
        \\print xs[1]
        \\map m := {"a": 1}
        \\m["a"] := 10
        \\m["b"] := 2
        \\print m["a"]
        \\print m["b"]
    , &buf);
    try std.testing.expectEqualStrings("20\n10\n2\n", output);
}

test "bracket indexing chains through nested maps/lists, for both reads and writes" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\map doc := {"tags": ["math", "logic"], "meta": {"count": 1}}
        \\print doc["tags"][0]
        \\print doc["meta"]["count"]
        \\doc["meta"]["count"] := 2
        \\print doc["meta"]["count"]
    , &buf);
    try std.testing.expectEqualStrings("math\n1\n2\n", output);
}

test "indexing a plain scalar local is a compile-time NotIndexable error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int x := 1\nprint x[0]\n", SemanticError.NotIndexable);
}

test "map[3] (or list[]) is a parse error: neither ever takes an array suffix" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("map[3] m\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);
    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    try std.testing.expectError(parser_mod.Error.UnexpectedToken, parser.parseProgram());
}

test "push grows a list across a loop, and keys()/has()/delete() round-trip a map" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list xs
        \\for i in 0..3 {
        \\    push(xs, i * 10)
        \\}
        \\for i in 0..len(xs) {
        \\    print xs[i]
        \\}
        \\
        \\map m := {"a": 1, "b": 2}
        \\list ks := keys(m)
        \\for i in 0..len(ks) {
        \\    print ks[i]
        \\}
        \\print has(m, "a")
        \\print delete(m, "a")
        \\print has(m, "a")
        \\print delete(m, "a")
    , &buf);
    try std.testing.expectEqualStrings("0\n10\n20\na\nb\ntrue\ntrue\nfalse\nfalse\n", output);
}

test "a list/map value is a shared reference, not a copy" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list a := [1]
        \\list b := a
        \\push(b, 2)
        \\print len(a)
        \\
        \\map m := {"x": 1}
        \\map n := m
        \\n["x"] := 99
        \\print m["x"]
    , &buf);
    try std.testing.expectEqualStrings("2\n99\n", output);
}

test "a map/list may be nested inside another and passed to/returned from a function" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func wrap(list xs) -> map {
        \\    map m := {}
        \\    m["items"] := xs
        \\    return m
        \\}
        \\list nested := [1, 2]
        \\map result := wrap(nested)
        \\list items := result["items"]
        \\print items[1]
    , &buf);
    try std.testing.expectEqualStrings("2\n", output);
}

test "json(...) parses stdin bytes into a map/list tree" {
    const allocator = std.testing.allocator;
    var out_buf: [256]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\int[128] buf
        \\int n := read(stdin, buf)
        \\map doc := json(buf, n)
        \\print doc["name"]
        \\list tags := doc["tags"]
        \\print len(tags)
        \\print tags[0]
        \\print has(doc, "missing")
    ,
        \\{"name": "Ada", "tags": ["math", "logic"]}
    , &out_buf, &err_buf);
    try std.testing.expectEqualStrings("Ada\n2\nmath\nfalse\n", result.out);
}

test "json(...) on malformed input is a runtime error" {
    const allocator = std.testing.allocator;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.JsonParseFailed, runProgramWithIo(allocator,
        \\int[32] buf
        \\int n := read(stdin, buf)
        \\map doc := json(buf, n)
    , "{not valid json", &out_buf, &err_buf));
}

test "stringify(...) renders a map/list value as JSON text" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\map doc := {"name": "Ada", "tags": [1, 2]}
        \\print stringify(doc)
    , &buf);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\",\"tags\":[1,2]}\n", output);
}

// Butter's own string literals have no escape sequences at all (a string
// just reads to the next literal '"' — lexer.zig's `string()`), so the only
// way a runtime string value ever contains a `"` or `\` is heap-built, e.g.
// by `json(...)` unescaping one out of parsed input (json.zig's `convert`).
// This chains json(...) -> stringify(...) to exercise escaping through a
// path an actual Butter program can express, rather than a source literal.
test "stringify(...) round-trips a json(...)-parsed string's escapes" {
    const allocator = std.testing.allocator;
    var out_buf: [128]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    const result = try runProgramWithIo(allocator,
        \\int[64] buf
        \\int n := read(stdin, buf)
        \\map doc := json(buf, n)
        \\print stringify(doc["name"])
    ,
        \\{"name": "Ada \"the\" great\n"}
    , &out_buf, &err_buf);
    try std.testing.expectEqualStrings("\"Ada \\\"the\\\" great\\n\"\n", result.out);
}

test "stringify(...) on a stream is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print stringify(stdout)
    , &buf));
}

test "int(...)/float(...) parse a string into a number" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\print int("42")
        \\print int("-7")
        \\print float("3.5")
        \\print float("-2.25")
        \\print float("42")
    , &buf);
    try std.testing.expectEqualStrings("42\n-7\n3.5\n-2.25\n42\n", output);
}

test "int(...)/float(...) compose with stringify/concatenation like any other expression" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int x := int("10")
        \\print x + 5
    , &buf);
    try std.testing.expectEqualStrings("15\n", output);
}

test "int(...) on a malformed string is a runtime NumberParseFailed" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.NumberParseFailed, runProgram(allocator,
        \\print int("abc")
    , &buf));
}

test "int(...) rejects a decimal string (no truncation) as NumberParseFailed" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.NumberParseFailed, runProgram(allocator,
        \\print int("3.5")
    , &buf));
}

test "float(...) on a malformed string is a runtime NumberParseFailed" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.NumberParseFailed, runProgram(allocator,
        \\print float("not a number")
    , &buf));
}

test "int(...)/float(...) on a non-string value is TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print int(5)
    , &buf));
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print float(true)
    , &buf));
}

test "int(...)/float(...) reject surrounding whitespace" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.NumberParseFailed, runProgram(allocator,
        \\print int(" 42")
    , &buf));
    try std.testing.expectError(vm_mod.RuntimeError.NumberParseFailed, runProgram(allocator,
        \\print float("42 ")
    , &buf));
}

test "int(x) truncates a computed float toward zero" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\float a := 7.0
        \\float b := 2.0
        \\print int(a / b)
        \\print int(-a / b)
        \\print int(4.0)
    , &buf);
    try std.testing.expectEqualStrings("3\n-3\n4\n", output);
}

test "int(x) on a float outside i64's range is a runtime Overflow" {
    // Butter float literals have no exponent syntax (GRAMMAR.bnf section 1),
    // so this spells the out-of-range magnitude out in plain decimal.
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.Overflow, runProgram(allocator,
        \\print int(99999999999999999999999999999999.0)
    , &buf));
}

test "int(x) on an already-int value is TypeMismatch (no implicit identity cast)" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\int x := 5
        \\print int(x)
    , &buf));
}

// ---- Environment variables (GRAMMAR.bnf design note 3v) -----------------

/// `runProgram` with an environment available to `getenv`/`hasenv`.
fn runProgramWithEnv(
    allocator: std.mem.Allocator,
    source: []const u8,
    env: []const vm_mod.Host.EnvVar,
    buf: []u8,
) ![]const u8 {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, .{ .out = &writer, .env = env });
    return writer.buffered();
}

const compiler_test_env = [_]vm_mod.Host.EnvVar{
    .{ .name = "EDITOR", .value = "vi" },
    .{ .name = "QUIET", .value = "" },
};

test "getenv(...) reads a set variable and hasenv(...) reports it present" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgramWithEnv(allocator,
        \\print getenv("EDITOR")
        \\print hasenv("EDITOR")
    , &compiler_test_env, &buf);
    try std.testing.expectEqualStrings("vi\ntrue\n", output);
}

test "getenv(...) on an unset variable is \"\", and hasenv(...) is false" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgramWithEnv(allocator,
        \\print "[" + getenv("NOPE") + "]"
        \\print hasenv("NOPE")
    , &compiler_test_env, &buf);
    try std.testing.expectEqualStrings("[]\nfalse\n", output);
}

test "hasenv(...) is what tells an empty-valued variable from a missing one" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgramWithEnv(allocator,
        \\print getenv("QUIET") == getenv("NOPE")
        \\print hasenv("QUIET")
        \\print hasenv("NOPE")
    , &compiler_test_env, &buf);
    try std.testing.expectEqualStrings("true\ntrue\nfalse\n", output);
}

test "getenv/hasenv's static types let them initialize a string/bool local" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgramWithEnv(allocator,
        \\string editor := getenv("EDITOR")
        \\bool present := hasenv("EDITOR")
        \\print editor + " " + stringify(present)
    , &compiler_test_env, &buf);
    try std.testing.expectEqualStrings("vi true\n", output);
}

test "getenv/hasenv's static types are checked against the declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int n := getenv(\"EDITOR\")\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "string s := hasenv(\"EDITOR\")\n", SemanticError.TypeMismatch);
}

test "getenv's name may be any expression, not just a literal" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgramWithEnv(allocator,
        \\string prefix := "EDIT"
        \\print getenv(prefix + "OR")
    , &compiler_test_env, &buf);
    try std.testing.expectEqualStrings("vi\n", output);
}

test "getenv/hasenv on a non-string name is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print getenv(5)
    , &buf));
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print hasenv(true)
    , &buf));
}

test "a program run with no environment sees every variable as unset" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // `runProgram` supplies no `Host.env` at all — the embedder default.
    const output = try runProgram(allocator,
        \\print hasenv("EDITOR")
        \\print len(getenv("EDITOR"))
    , &buf);
    try std.testing.expectEqualStrings("false\n0\n", output);
}

// ---- Character conversion (GRAMMAR.bnf design note 3ab) ------------------

test "ord(...) returns a single-character string's byte value" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\print ord("A")
        \\print ord("a")
        \\print ord("0")
    , &buf);
    try std.testing.expectEqualStrings("65\n97\n48\n", output);
}

test "ord(...)'s static type lets it initialize an int local" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int code := ord("A")
        \\print code
    , &buf);
    try std.testing.expectEqualStrings("65\n", output);
}

test "ord(...)'s static type is checked against the declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "string s := ord(\"A\")\n", SemanticError.TypeMismatch);
}

test "ord(...) on a multi-character or empty string is a runtime InvalidCharLength" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.InvalidCharLength, runProgram(allocator,
        \\print ord("ab")
    , &buf));
    try std.testing.expectError(vm_mod.RuntimeError.InvalidCharLength, runProgram(allocator,
        \\print ord("")
    , &buf));
}

test "ord(...) on a non-string value is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print ord(65)
    , &buf));
}

test "ord(...)'s argument may be any expression, not just a literal" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\string s := "Z"
        \\print ord(s[0..1])
    , &buf);
    try std.testing.expectEqualStrings("90\n", output);
}

// ---- String join (GRAMMAR.bnf design note 3ac) ---------------------------

test "join(...) concatenates a list of strings with a separator between each" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list parts := ["a", "b", "c"]
        \\print join(parts, ", ")
    , &buf);
    try std.testing.expectEqualStrings("a, b, c\n", output);
}

test "join(...) on a single-element list needs no separator" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list parts := ["only"]
        \\print join(parts, ", ")
    , &buf);
    try std.testing.expectEqualStrings("only\n", output);
}

test "join(...) on an empty list is the empty string" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list parts := []
        \\print join(parts, ", ")
    , &buf);
    try std.testing.expectEqualStrings("\n", output);
}

test "join(...)'s static type lets it initialize a string local" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list parts := ["x", "y"]
        \\string s := join(parts, "-")
        \\print s
    , &buf);
    try std.testing.expectEqualStrings("x-y\n", output);
}

test "join(...)'s static type is checked against the declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "list parts := []\nint n := join(parts, \",\")\n", SemanticError.TypeMismatch);
}

test "join(...) on a non-list first argument is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\print join("not a list", ",")
    , &buf));
}

test "join(...) on a non-string separator is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\list parts := ["a", "b"]
        \\print join(parts, 1)
    , &buf));
}

test "join(...) on a list containing a non-string element is a runtime TypeMismatch" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgram(allocator,
        \\list parts := ["a", 1]
        \\print join(parts, ",")
    , &buf));
}

test "join(...) leaves the source list untouched — it's read, not consumed" {
    // join only borrows the list (an ordinary LOAD_LOCAL incref, the same
    // way MAP_KEYS/LIST_PUSH do); the caller's own variable must still
    // hold every original element afterward.
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\list parts := ["a", "b"]
        \\print join(parts, "-")
        \\push(parts, "c")
        \\print join(parts, "-")
    , &buf);
    try std.testing.expectEqualStrings("a-b\na-b-c\n", output);
}

test "join(...)'s arguments may be arbitrary expressions, not just literals" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func makeParts() -> list {
        \\    list p := ["1", "2", "3"]
        \\    return p
        \\}
        \\print join(makeParts(), "" + "-")
    , &buf);
    try std.testing.expectEqualStrings("1-2-3\n", output);
}

// ---- Time and randomness (GRAMMAR.bnf design note 3y) --------------------

/// `runProgram` with clock access (`std.testing.io` — a real clock, since
/// there's no meaningful fake one to inject at this layer) available to
/// `now()`/an unseeded `random()`.
fn runProgramWithClock(allocator: std.mem.Allocator, source: []const u8, buf: []u8) ![]const u8 {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, .{ .out = &writer, .clock = std.testing.io });
    return writer.buffered();
}

/// `runProgram` with `Host.rng_seed` set, so `random()`/`random(start, end)`
/// are exactly reproducible without needing any clock access at all.
fn runProgramWithSeed(allocator: std.mem.Allocator, source: []const u8, seed: u64, buf: []u8) ![]const u8 {
    var lex = lexer_mod.Lexer.init(source);
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var writer = std.Io.Writer.fixed(buf);
    try vm.run(&compiled, .{ .out = &writer, .rng_seed = seed });
    return writer.buffered();
}

test "now()'s static type lets it initialize a float local" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgramWithClock(allocator,
        \\float t := now()
        \\print t > 0.0
    , &buf);
    try std.testing.expectEqualStrings("true\n", output);
}

test "random()/random(a, b)'s static types let them initialize float/int locals" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgramWithSeed(allocator,
        \\float f := random()
        \\int n := random(0, 10)
        \\print f >= 0.0 and f < 1.0
        \\print n >= 0 and n < 10
    , 7, &buf);
    try std.testing.expectEqualStrings("true\ntrue\n", output);
}

test "now()/random()/random(a, b)'s static types are checked against the declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int n := now()\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "string s := random()\n", SemanticError.TypeMismatch);
    // `random(a, b)`'s own static type is `int`, which is NOT what's wrong
    // with `float f := random(0, 10)` — `int` widens to `float` wherever one
    // is expected (design note 3t), so that assignment is legal. `bool`
    // never accepts either, which is what actually exercises the check.
    try expectCompileError(allocator, "bool b := random(0, 10)\n", SemanticError.TypeMismatch);
}

test "int widens to float for random(a, b) too, matching design note 3t" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgramWithSeed(allocator,
        \\float f := random(0, 10)
        \\print f >= 0.0 and f < 10.0
    , 7, &buf);
    try std.testing.expectEqualStrings("true\n", output);
}

test "random(start, end)'s bounds are checked at compile time, like a for-loop's" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "random(\"a\", 10)\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "random(0, 3.5)\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "random(0.0, 10)\n", SemanticError.TypeMismatch);
}

test "random(start, end)'s bounds may be any expression, not just a literal" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgramWithSeed(allocator,
        \\int lo := 0
        \\int hi := lo + 10
        \\int n := random(lo, hi)
        \\print n >= lo and n < hi
    , 3, &buf);
    try std.testing.expectEqualStrings("true\n", output);
}

test "now()/random() without clock access or a seed are a runtime ClockUnavailable" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.ClockUnavailable, runProgram(allocator, "print now()\n", &buf));
    try std.testing.expectError(vm_mod.RuntimeError.ClockUnavailable, runProgram(allocator, "print random()\n", &buf));
}

test "random(start, end) with start >= end is a runtime InvalidRange" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.InvalidRange, runProgram(allocator, "print random(5, 5)\n", &buf));
}

// ---- Static type checking (GRAMMAR.bnf design note 3t) -------------------

test "a var-decl initializer's type must match the declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int a := \"apples\"\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "bool b := \"true\"\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "string s := 5\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "int a := null\n", SemanticError.TypeMismatch);
}

test "int widens to float, but float never narrows to int" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    // Widening is a compile-time acceptance only: the slot still holds a
    // raw int value (nothing here emits a conversion), so it prints "5",
    // not "5.0" — see `typeCompatible`'s doc comment.
    const output = try runProgram(allocator, "float x := 5\nprint x\n", &buf);
    try std.testing.expectEqualStrings("5\n", output);

    try expectCompileError(allocator, "int a := 3.0\n", SemanticError.TypeMismatch);
}

test "map/list are checked exactly against each other, no cross-widening" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "map m := [1, 2]\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "list l := {\"a\": 1}\n", SemanticError.TypeMismatch);
}

test "a fixed-array literal's elements are checked against the declared element type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int[2] a := [1, \"x\"]\n", SemanticError.TypeMismatch);
}

test "a fixed-array initializer from a call is checked against the returned array's element type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\func giveFloats() -> float[2] {
        \\    float[2] r := [1.0, 2.0]
        \\    return r
        \\}
        \\int[2] a := giveFloats()
    , SemanticError.TypeMismatch);
}

test "an assignment's value type must match the variable's declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int x := 1\nx := \"nope\"\n", SemanticError.TypeMismatch);
}

test "a call argument's type must match the parameter's declared type, but int still widens to float" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\func needsInt(int x) -> int {
        \\    return x
        \\}
        \\print needsInt("nope")
    , SemanticError.TypeMismatch);

    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func needsFloat(float x) -> float {
        \\    return x
        \\}
        \\print needsFloat(5)
    , &buf);
    try std.testing.expectEqualStrings("5\n", output);
}

test "a return value's type must match the function's declared return type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\func f() -> int {
        \\    return "x"
        \\}
        \\print f()
    , SemanticError.TypeMismatch);
}

test "if/while conditions must be bool" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "if 1 {\n  print 1\n}\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "while 1 {\n  print 1\n}\n", SemanticError.TypeMismatch);
}

test "for-loop bounds must be int" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "for i in \"a\"..\"b\" {\n  print i\n}\n", SemanticError.TypeMismatch);
}

test "exit's code must be int" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "exit \"x\"\n", SemanticError.TypeMismatch);
}

test "throw's operand must be the built-in Error struct" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "throw 5\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "throw \"oops\"\n", SemanticError.TypeMismatch);
}

test "binary operators reject mismatched operand types" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "print 1 + true\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "print \"a\" - \"b\"\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "print \"a\" < 5\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "print 1 and true\n", SemanticError.TypeMismatch);
}

test "unary operators reject mismatched operand types" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "print -true\n", SemanticError.TypeMismatch);
    try expectCompileError(allocator, "print !5\n", SemanticError.TypeMismatch);
}

test "an operator type error is caught even nested inside another expression form's argument" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "list l := []\npush(l, 1 + \"x\")\n", SemanticError.TypeMismatch);
}

test "indexing a map/list leaves the destination's declared type unchecked (genuinely dynamic)" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "map m := {\"k\": 5}\nint x := m[\"k\"]\nprint x\n", &buf);
    try std.testing.expectEqualStrings("5\n", output);
}

test "open()'s stream result satisfies an int-declared local (the existing file-I/O convention)" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init("int f := open(\"x\", read)\nclose f\n");
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiler = Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileProgram(program);
    defer compiled.deinit(allocator);
}

// ---- try/catch (design note 3u, ISA.bnf section 14) ------------------

test "a runtime error in a try block continues in the catch block" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\print "before"
        \\try {
        \\    print 1 / 0
        \\    print "skipped"
        \\} catch e {
        \\    print "caught"
        \\}
        \\print "after"
    , &buf);
    try std.testing.expectEqualStrings("before\ncaught\nafter\n", output);
}

test "a try block that completes normally skips the catch block entirely" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\try {
        \\    print "ok"
        \\} catch e {
        \\    print "never"
        \\}
        \\print "after"
    , &buf);
    try std.testing.expectEqualStrings("ok\nafter\n", output);
}

test "a try block that completes normally leaves no armed handler behind" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\try {
        \\    print "ok"
        \\} catch e {
        \\    print "spent"
        \\}
        \\print 1 / 0
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    // Without the POP_HANDLER after the body, the division would resume in
    // the already-spent catch block instead of killing the program — and
    // the error alone can't tell the difference, so "spent" is the marker
    // that detects it.
    try std.testing.expectError(vm_mod.RuntimeError.DivisionByZero, vm.run(&compiled, .{ .out = &writer }));
    try std.testing.expectEqualStrings("ok\n", writer.buffered());
}

test "the caught error binds a struct with all four fields always present" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const output = try runProgram(allocator,
        \\map m := {"a": 1}
        \\try {
        \\    print m["nope"]
        \\} catch e {
        \\    print e.error
        \\    print e.message
        \\    print "[" + e.operation + "]"
        \\    print "[" + e.path + "]"
        \\}
    , &buf);
    // KeyNotFound carries no Diagnostic, so the last two are empty — but
    // still present, so reading them needs no guard.
    try std.testing.expectEqualStrings("KeyNotFound\nKeyNotFound\n[]\n[]\n", output);
}

test "a diagnostic-carrying error fills in operation" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const output = try runProgram(allocator,
        \\try {
        \\    print int("not a number")
        \\} catch e {
        \\    print e.error
        \\    print e.message
        \\    print e.operation
        \\}
    , &buf);
    // `path` stays empty here — PARSE_INT's Diagnostic names the operation
    // but has no file to name. The file errors that fill BOTH in need a
    // real `Host.fs`, which the `files` integration case covers end to end.
    try std.testing.expectEqualStrings("NumberParseFailed\nint: malformed integer literal\nint\n", output);
}

test "a failing write is catchable" {
    const allocator = std.testing.allocator;
    // A fixed writer far too small for what's written to it. Note this
    // uses `write(stdout, ...)`, not `print`: WRITE maps a writer failure
    // to StreamWriteFailed (vm.zig's `writeValue`), whereas PRINT lets the
    // raw `std.Io.Writer.Error` escape, which no handler sees.
    //
    // This and `FilesUnavailable` above are the two catchable variants
    // that depend on how the EMBEDDER wired up the host, so neither is
    // reachable from the integration case (`try_catch`), which always gets
    // a real filesystem and an unbounded output buffer.
    var lex = lexer_mod.Lexer.init(
        \\try {
        \\    print write(stdout, "far longer than the output buffer holds")
        \\} catch e {
        \\    exit 3
        \\}
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var buf: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    // The write fails partway, so what landed in `buf` is not worth
    // asserting on — that the handler ran at all is the point, and the
    // exit code is how it says so.
    try vm.run(&compiled, .{ .out = &writer });
    try std.testing.expectEqual(@as(?u8, 3), vm.exit_code);
}

test "the sandbox gate (no Host.fs) is itself catchable" {
    const allocator = std.testing.allocator;
    var buf: [256]u8 = undefined;
    // `runProgram` supplies no `Host.fs`, so `open` is refused outright —
    // an embedder that hasn't opted into file access can now be handled by
    // the program rather than killing it.
    const output = try runProgram(allocator,
        \\try {
        \\    int f := open("anything.txt", read)
        \\    print "opened"
        \\} catch e {
        \\    print e.error
        \\}
    , &buf);
    try std.testing.expectEqualStrings("FilesUnavailable\n", output);
}

test "an error raised several call frames deep unwinds to the handler" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\func deep(int n) -> int {
        \\    if n == 0 {
        \\        return 1 / 0
        \\    }
        \\    return deep(n - 1)
        \\}
        \\try {
        \\    print deep(5)
        \\} catch e {
        \\    print e.error
        \\}
        \\print "after"
    , &buf);
    try std.testing.expectEqualStrings("DivisionByZero\nafter\n", output);
}

test "try/catch inside a function: return works from either half" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\func safeDiv(int a, int b) -> int {
        \\    try {
        \\        return a / b
        \\    } catch _ {
        \\        return -1
        \\    }
        \\}
        \\print safeDiv(10, 2)
        \\print safeDiv(10, 0)
    , &buf);
    try std.testing.expectEqualStrings("5\n-1\n", output);
}

test "returning out of a try block does not strand its handler" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // `guarded` returns normally, leaving its handler behind unless RET
    // drops it. If one were stranded, the later division would resume in
    // `guarded`'s dead catch block and print "stranded" — so the marker,
    // not the error text, is what detects it (see DESIGN-error-recovery.md
    // step 3's first finding).
    const output = try runProgram(allocator,
        \\func guarded() -> int {
        \\    try {
        \\        return 1
        \\    } catch e {
        \\        print "stranded"
        \\        return 0
        \\    }
        \\}
        \\print guarded()
        \\try {
        \\    print 1 / 0
        \\} catch e {
        \\    print e.error
        \\}
    , &buf);
    try std.testing.expectEqualStrings("1\nDivisionByZero\n", output);
}

test "try/catch nests, and the innermost enclosing try wins" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\try {
        \\    try {
        \\        print [1, 2][9]
        \\    } catch inner {
        \\        print "inner " + inner.error
        \\    }
        \\    print "resumed"
        \\} catch outer {
        \\    print "never"
        \\}
    , &buf);
    try std.testing.expectEqualStrings("inner IndexOutOfBounds\nresumed\n", output);
}

test "an error inside a catch block escapes to the enclosing try, not its own" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\try {
        \\    try {
        \\        print [1, 2][9]
        \\    } catch inner {
        \\        print {"z": 1}["q"]
        \\    }
        \\} catch outer {
        \\    print "outer " + outer.error
        \\}
    , &buf);
    try std.testing.expectEqualStrings("outer KeyNotFound\n", output);
}

test "exit inside a try block is not catchable" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\try {
        \\    exit 7
        \\} catch e {
        \\    print "never"
        \\}
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try vm.run(&compiled, .{ .out = &writer });

    try std.testing.expectEqualStrings("", writer.buffered());
    try std.testing.expectEqual(@as(?u8, 7), vm.exit_code);
}

test "a non-catchable error still escapes a try block" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\func recurse(int n) -> int {
        \\    return recurse(n + 1)
        \\}
        \\try {
        \\    print recurse(0)
        \\} catch e {
        \\    print "never"
        \\}
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    // CallStackOverflow is a VM-integrity failure, not a program condition
    // (DESIGN-error-recovery.md section 3) — no handler sees it.
    try std.testing.expectError(vm_mod.RuntimeError.CallStackOverflow, vm.run(&compiled, .{ .out = &writer }));
}

test "a local declared in the try block is not in scope in the catch block" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\try {
        \\    int x := 1
        \\} catch e {
        \\    print x
        \\}
    , SemanticError.UndefinedVariable);
}

test "the error binding is not in scope after the catch block" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\try {
        \\    print 1
        \\} catch e {
        \\    print e.error
        \\}
        \\print e.error
    , SemanticError.UndefinedVariable);
}

test "the error binding is statically typed as the built-in Error struct" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\try {
        \\    print 1 / 0
        \\} catch e {
        \\    int n := e
        \\}
    , SemanticError.TypeMismatch);
}

// The whole point of switching the binding from a map to a struct (design
// note 3z): a typo'd field name is now caught HERE, at compile time,
// instead of surfacing as a `RuntimeError.KeyNotFound` the way a bad map
// key read always would.
test "a typo'd field name on the error binding is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\try {
        \\    print 1 / 0
        \\} catch e {
        \\    print e.mesage
        \\}
    , SemanticError.UnknownField);
}

// The flip side of no longer being a map: `has`/`keys`, which never
// static-type-check their argument, now fail at RUNTIME instead of
// compiling away to a lookup.
test "the error binding is no longer accepted where a map is expected" {
    const allocator = std.testing.allocator;
    var out_buf: [16]u8 = undefined;
    var err_buf: [16]u8 = undefined;
    try std.testing.expectError(vm_mod.RuntimeError.TypeMismatch, runProgramWithIo(allocator,
        \\try {
        \\    print 1 / 0
        \\} catch e {
        \\    print has(e, "error")
        \\}
    , "", &out_buf, &err_buf));
}

test "the error binding shadows an outer local of the same name, which survives intact" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\string e := "outer"
        \\try {
        \\    print 1 / 0
        \\} catch e {
        \\    print e.error
        \\}
        \\print e
    , &buf);
    try std.testing.expectEqualStrings("DivisionByZero\nouter\n", output);
}

test "repeatedly abandoning a try block neither drifts the stack nor leaks its locals" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // Each iteration strands a heap string and a map in the abandoned
    // scope, above the handler's recorded `sp`. Under
    // `std.testing.allocator` a missed decref fails the test; a botched
    // `sp` restore would overflow the value stack long before 2000.
    const output = try runProgram(allocator,
        \\int n := 0
        \\for i in 0..2000 {
        \\    try {
        \\        string s := "a string that is heap allocated"
        \\        map m := {"k": s}
        \\        print m["missing"]
        \\    } catch e {
        \\        n := n + 1
        \\    }
        \\}
        \\print n
    , &buf);
    try std.testing.expectEqualStrings("2000\n", output);
}

test "a try block's locals do not permanently consume slots" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // The catch binding lands in the slot the try block's first local
    // used, and both are reclaimed afterward — so `after` reads back
    // correctly rather than aliasing either.
    const output = try runProgram(allocator,
        \\try {
        \\    int a := 1
        \\    int b := 2
        \\    print a + b
        \\} catch e {
        \\    print "never"
        \\}
        \\int after := 99
        \\print after
    , &buf);
    try std.testing.expectEqualStrings("3\n99\n", output);
}

// ---- throw (GRAMMAR.bnf design note 3u, ISA.bnf section 14) ---------------

test "a thrown Error's four fields come through the catch binding unchanged" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    // Custom, program-chosen values in every field — proving THROW doesn't
    // rebuild the value through `Vm.errorValue` the way an internal error
    // does; what the handler binds is exactly what was thrown.
    const output = try runProgram(allocator,
        \\try {
        \\    throw Error{error: "Custom", message: "bad input", operation: "validate", path: "config.json"}
        \\} catch e {
        \\    print e.error
        \\    print e.message
        \\    print e.operation
        \\    print e.path
        \\}
    , &buf);
    try std.testing.expectEqualStrings("Custom\nbad input\nvalidate\nconfig.json\n", output);
}

test "an uncaught throw propagates out of Vm.run and reports its own message" {
    const allocator = std.testing.allocator;
    var lex = lexer_mod.Lexer.init(
        \\print "before"
        \\throw Error{error: "Custom", message: "boom", operation: "", path: ""}
    );
    const tokens = try lex.tokenizeAll(allocator);
    defer allocator.free(tokens);

    var parser = parser_mod.Parser.init(allocator, tokens);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var compiled = try compile(allocator, program);
    defer compiled.deinit(allocator);

    var vm = vm_mod.Vm.init(allocator);
    // Unlike the CLI (which exits the process immediately after printing,
    // needing no cleanup of its own), a test using the leak-checking
    // allocator has to release the value itself — nothing else holds a
    // reference to it once `run` has returned.
    defer if (vm.uncaught_throw) |thrown| thrown.decref(allocator);
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try std.testing.expectError(vm_mod.RuntimeError.UncaughtThrow, vm.run(&compiled, .{ .out = &writer }));

    try std.testing.expectEqualStrings("before\n", writer.buffered());
    try std.testing.expect(vm.uncaught_throw != null);
    const rec = vm.uncaught_throw.?.object.payload.record;
    try std.testing.expectEqualStrings("Custom", rec.fields[0].asStringBytes().?);
    try std.testing.expectEqualStrings("boom", rec.fields[1].asStringBytes().?);
    try std.testing.expectEqual(@as(?u32, 2), vm.line);
}

test "throw nests, and the innermost enclosing try wins" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\try {
        \\    try {
        \\        throw Error{error: "Inner", message: "", operation: "", path: ""}
        \\    } catch inner {
        \\        print "inner " + inner.error
        \\    }
        \\    print "resumed"
        \\} catch outer {
        \\    print "never"
        \\}
    , &buf);
    try std.testing.expectEqualStrings("inner Inner\nresumed\n", output);
}

test "a throw inside a catch block escapes to the enclosing try, not its own" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\try {
        \\    try {
        \\        print 1 / 0
        \\    } catch inner {
        \\        throw Error{error: "FromCatch", message: "", operation: "", path: ""}
        \\    }
        \\} catch outer {
        \\    print outer.error
        \\}
    , &buf);
    try std.testing.expectEqualStrings("FromCatch\n", output);
}

test "a throw several call frames deep unwinds to the handler" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\func deep(int n) -> int {
        \\    if n == 0 {
        \\        throw Error{error: "TooDeep", message: "", operation: "", path: ""}
        \\    }
        \\    return deep(n - 1)
        \\}
        \\try {
        \\    print deep(5)
        \\} catch e {
        \\    print e.error
        \\}
        \\print "after"
    , &buf);
    try std.testing.expectEqualStrings("TooDeep\nafter\n", output);
}

test "throw inside a function: caught by a try in the caller, several frames up" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\func validate(int x) -> int {
        \\    if x < 0 {
        \\        throw Error{error: "Negative", message: "x must be >= 0", operation: "", path: ""}
        \\    }
        \\    return x
        \\}
        \\try {
        \\    print validate(-1)
        \\} catch e {
        \\    print e.error + ": " + e.message
        \\}
    , &buf);
    try std.testing.expectEqualStrings("Negative: x must be >= 0\n", output);
}

// ---- Function values (GRAMMAR.bnf design note 3ad) ------------------------

test "a named function passed as a callback argument compiles, type-checks, and calls dynamically" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func isEven(int n) -> bool {
        \\    return n % 2 == 0
        \\}
        \\func apply(int n, func(int) bool pred) -> bool {
        \\    return pred(n)
        \\}
        \\print apply(4, isEven)
        \\print apply(5, isEven)
    , &buf);
    try std.testing.expectEqualStrings("true\nfalse\n", output);
}

test "a func-typed local can be initialized from a bare function name and called dynamically" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func square(int n) -> int {
        \\    return n * n
        \\}
        \\func(int) int f := square
        \\print f(5)
    , &buf);
    try std.testing.expectEqualStrings("25\n", output);
}

test "passing a function whose signature doesn't match the declared func type is a TypeMismatch" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\func addOne(int n) -> int {
        \\    return n + 1
        \\}
        \\func apply(int n, func(int) bool pred) -> bool {
        \\    return pred(n)
        \\}
        \\print apply(4, addOne)
    , SemanticError.TypeMismatch);
}

test "assigning a function with an array parameter to a declared func type is a TypeMismatch (structurally ineligible)" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\func sum(int[] xs) -> int {
        \\    return 0
        \\}
        \\func(int) int f := sum
    , SemanticError.TypeMismatch);
}

test "a bare reference to a function with an array parameter, with no expected func type to check against, is InvalidFunctionValue" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator,
        \\func sum(int[] xs) -> int {
        \\    return 0
        \\}
        \\print sum
    , SemanticError.InvalidFunctionValue);
}

test "a function-typed local without an initializer is a compile error" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "func(int) int f\n", SemanticError.MissingFunctionInitializer);
}

test "a function value prints as <func name> and compares equal only to itself" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\func square(int n) -> int {
        \\    return n * n
        \\}
        \\func(int) int f := square
        \\print f
        \\print f == square
    , &buf);
    try std.testing.expectEqualStrings("<func square>\ntrue\n", output);
}

// ---- String interpolation (GRAMMAR.bnf design note 3ae) -------------------

test "a string with no interpolation compiles and runs exactly as before" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator, "print \"hello, world\"\n", &buf);
    try std.testing.expectEqualStrings("hello, world\n", output);
}

test "interpolates a variable into a string" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\string name := "world"
        \\print "hello, ${name}!"
    , &buf);
    try std.testing.expectEqualStrings("hello, world!\n", output);
}

test "interpolates an arbitrary expression, not just a bare variable" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int age := 7
        \\print "next year: ${age + 1}"
    , &buf);
    try std.testing.expectEqualStrings("next year: 8\n", output);
}

test "every non-string value kind renders the same way print/write would" {
    const allocator = std.testing.allocator;
    var buf: [128]u8 = undefined;
    const output = try runProgram(allocator,
        \\int n := 42
        \\float f := 3.5
        \\bool b := true
        \\list xs := [1, 2]
        \\map m := {"a": 1}
        \\print "${n} ${f} ${b} ${xs} ${m}"
    , &buf);
    try std.testing.expectEqualStrings("42 3.5 true [1, 2] {\"a\": 1}\n", output);
}

test "an enum value interpolates as its bare variant name" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\enum Color { Red, Green }
        \\print "color: ${Color.Red}"
    , &buf);
    try std.testing.expectEqualStrings("color: Red\n", output);
}

test "multiple interpolations in one string, in order" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int a := 2
        \\int b := 3
        \\print "${a} + ${b} = ${a + b}"
    , &buf);
    try std.testing.expectEqualStrings("2 + 3 = 5\n", output);
}

test "a call, indexing, and struct field access all work inside an interpolation" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\struct Point { int x, int y }
        \\func double(int n) -> int { return n * 2 }
        \\list xs := [10, 20]
        \\Point p := Point{x: 1, y: 2}
        \\print "${double(4)} ${xs[1]} ${p.x}"
    , &buf);
    try std.testing.expectEqualStrings("8 20 1\n", output);
}

test "a map index using a string key works inside an interpolation despite the nested quotes" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\map m := {"a": 1}
        \\print "value: ${m["a"]}"
    , &buf);
    try std.testing.expectEqualStrings("value: 1\n", output);
}

test "'\\$' escapes a literal '$', suppressing interpolation" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\print "\${not_interpolated} and \$5"
    , &buf);
    try std.testing.expectEqualStrings("${not_interpolated} and $5\n", output);
}

test "interpolation nests — a string literal inside '${...}' may itself interpolate" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\string x := "deep"
        \\print "${ "inner: ${x}" }"
    , &buf);
    try std.testing.expectEqualStrings("inner: deep\n", output);
}

test "an interpolated string's static type is string, usable to initialize a string local" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int n := 5
        \\string s := "n is ${n}"
        \\print s
    , &buf);
    try std.testing.expectEqualStrings("n is 5\n", output);
}

test "an interpolated string's static type is checked against the declared type" {
    const allocator = std.testing.allocator;
    try expectCompileError(allocator, "int n := \"${1}\"\n", SemanticError.TypeMismatch);
}

test "an interpolated string composes with '+' like any other string" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    const output = try runProgram(allocator,
        \\int n := 1
        \\print "a: " + "${n}" + " b"
    , &buf);
    try std.testing.expectEqualStrings("a: 1 b\n", output);
}

test "a syntax error inside '${...}' is a compile error" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;
    try std.testing.expectError(parser_mod.SyntaxError.UnexpectedToken, runProgram(allocator,
        \\print "bad: ${1 +}"
    , &buf));
}
