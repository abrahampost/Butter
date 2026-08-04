//! AST node definitions for Butter, matching section 2 (SYNTAX GRAMMAR) of
//! GRAMMAR.bnf. Nodes are produced by `parser.Parser` into memory owned by
//! its arena; they borrow string data (identifiers, string contents)
//! directly from the source text — except a string literal/import path/
//! map key that actually uses a `\n`/`\t`/`\\`/`\"` escape (design note 3s),
//! which is decoded into a fresh arena-owned buffer instead.

const std = @import("std");

/// Re-exported so the AST and the ISA name the same three streams by the
/// same type (see `value.Stream` for why it's declared over there). Only
/// `Standard` appears in the AST — the three keyword-named streams, which
/// are the only streams source code can spell out. A `file` stream has no
/// syntax at all; it only ever comes from evaluating an `open` at runtime,
/// which is exactly why the stream that `read`/`write` act on is a general
/// `*Expr` here rather than a fixed tag (design note 3l).
pub const Stream = @import("value.zig").Stream;

/// `'read' | 'write' | 'append'` in the mode position of an `open`
/// (re-exported from `value` alongside `Stream`, same reasoning). Kept
/// distinct from the `read`/`write` *operations* that share those keywords:
/// the parser only ever looks for a mode where a mode is legal, so there is
/// no ambiguity to resolve.
pub const OpenMode = @import("value.zig").OpenMode;

pub const ValueType = enum {
    int,
    float,
    bool,
    string,
    /// A refcounted heap map (GRAMMAR.bnf design note 3m) — unlike the
    /// other four, this is always exactly one runtime value (a heap
    /// reference), never a run of raw stack slots, so it never takes the
    /// `[N]`/`[]` array suffix `Param`/`VarDecl`/`FunctionDecl` otherwise
    /// allow.
    map,
    /// A refcounted heap list (GRAMMAR.bnf design note 3m) — same story as
    /// `map`, but ordered/indexed by INT instead of by STRING key.
    list,
    /// A user-declared `struct` or `enum` type (GRAMMAR.bnf design notes 3z
    /// and 3aa) — the actual name is never carried here, but in a sibling
    /// `named_type: ?[]const u8` field alongside whichever `ValueType` this
    /// is (`Param.named_type`, `Stmt.VarDecl.named_type`,
    /// `Stmt.FunctionDecl.return_named_type`, `Stmt.FieldDecl.named_type`).
    /// Keeping `ValueType` itself a plain, payload-less enum — rather than
    /// turning it into a `union(enum)` — means every existing
    /// `== .int`/`== .map`-style comparison across parser.zig/compiler.zig
    /// keeps working unchanged; only call sites that actually need the name
    /// (compiler.zig's type resolution, this file's debug printer) look at
    /// the sibling field. The parser never resolves this name against
    /// anything — that happens once, in compiler.zig, against the set of
    /// struct/enum types registered across the whole compiled program.
    named,
};

pub const UnaryOp = enum {
    negate, // '-'
    not, // '!'
};

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    logic_or,
    logic_and,
};

pub const Literal = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    /// JSON's `null` (ISA.bnf section 12) — named `null_value`, not `null`,
    /// since `null` is a reserved word and can't name a union field
    /// directly (matching `value.Value.null_value`'s own naming).
    null_value,
};

/// A parameter's or a function's return type's optional array-ness: either
/// a fixed compile-time size (passed/returned by VALUE, a copy — see
/// GRAMMAR.bnf design note 3e) or `generic` (no declared size — passed by
/// REFERENCE instead, a single runtime `Value.array_ref` pointing at
/// whatever array the caller actually supplies, of whatever length it
/// happens to have — see design note 3e's generic-array addendum). Local
/// var-declarations don't get this: `ast.Stmt.VarDecl.array_len` stays a
/// plain `?u32`, since a local's own storage is always something concrete
/// this compiler allocated slots for, never a reference to someone else's.
pub const ArraySpec = union(enum) {
    fixed: u32,
    generic,
};

pub const Param = struct {
    type: ValueType,
    /// Set only when `type == .named` — see `ValueType.named`'s doc comment.
    named_type: ?[]const u8 = null,
    name: []const u8,
    /// null for a plain scalar parameter; see `ArraySpec` otherwise.
    array_size: ?ArraySpec = null,
};

/// One `<type> IDENTIFIER` field of a `struct` declaration (GRAMMAR.bnf
/// design note 3z) — deliberately shaped like `Param` (same grammar, same
/// `<type> IDENTIFIER` order) but without an `array_size`: a field is always
/// exactly one `Value` slot in the record's `fields` array, the same
/// restriction `map`/`list` params already have, extended to every field
/// type (never a run of raw slots to lay out).
pub const FieldDecl = struct {
    type: ValueType,
    /// Set only when `type == .named` — see `ValueType.named`'s doc comment.
    named_type: ?[]const u8 = null,
    name: []const u8,
};

pub const Expr = union(enum) {
    literal: Literal,
    variable: []const u8,
    unary: Unary,
    binary: Binary,
    grouping: *Expr,
    assign: Assign,
    call: Call,
    array_literal: []*Expr,
    index: Index,
    index_assign: IndexAssign,
    /// `TypeName{field1: expr1, field2: expr2, ...}` (GRAMMAR.bnf design
    /// note 3z) — constructs a heap record of the declared struct
    /// `type_name`. Every field is required, keyed by name, any order in
    /// source; `type_name`/each field's name are unresolved here (bare
    /// source text) — compiler.zig resolves `type_name` against the
    /// program's registered struct types, validates the field set exactly,
    /// and reorders the field expressions into the struct's *declared*
    /// order before emitting `MAKE_STRUCT` (ISA.bnf section 19), so bytecode
    /// field order never depends on the order a literal happened to list
    /// them in.
    struct_literal: StructLiteral,
    /// `<base>.IDENTIFIER` (GRAMMAR.bnf design notes 3z/3aa) — a struct
    /// field read OR an enum variant reference (`Color.Red`); which one is
    /// never decided here. The parser only ever produces this one shape for
    /// every `.`-postfix, exactly the way `Index` doesn't care whether its
    /// `base` is a list or a map — compiler.zig disambiguates by resolving
    /// `base`: if it's a bare `.variable` that names no local in scope but
    /// does name a declared enum type, this is an enum-variant reference
    /// (compiles to a `PUSH_CONST` of a `Value.enum_value`); otherwise
    /// `base`'s static type must be a struct, and `field` must be one of
    /// its declared fields (`FIELD_GET`, ISA.bnf section 19) —
    /// `SemanticError.NotAStruct`/`UnknownField`/`UnknownEnumVariant`
    /// otherwise. Chains the same way `Index` does (`p.a.b`, `xs[0].x`) for
    /// free, since both live in the same postfix loop (parser.zig's
    /// `primary`).
    field_access: FieldAccess,
    /// `<base>.IDENTIFIER := <expression>` — the `.field_access`
    /// counterpart to `.index_assign`; only ever a struct field write
    /// (`assignment()` never turns an enum-variant reference into an
    /// lvalue, the same way it never does for any other non-lvalue shape).
    field_assign: FieldAssign,
    /// `<base>[start..end]` (GRAMMAR.bnf's Strings design notes) — a
    /// read-only substring, end exclusive, same convention as the
    /// for-loop's own range. Never produced as an assignment target: unlike
    /// `.index`, there is no `.slice_assign` counterpart — `assignment`
    /// only ever turns a `.variable` or `.index` shape into an lvalue, so
    /// `s[a..b] := v` falls through to its "invalid assignment target"
    /// error same as any other non-lvalue expression would.
    slice: Slice,
    /// `len(<expression>)`. Relaxed from a bare array name to an arbitrary
    /// expression (GRAMMAR.bnf design note 3m) now that a map/list is a
    /// genuine first-class runtime value — the compiler still special-cases
    /// a bare `.variable` naming a fixed/generic array to fold to a
    /// compile-time constant or `LOAD_REF_LEN` exactly as before (arrays
    /// still aren't first-class, design note 3e); anything else compiles as
    /// an ordinary expression followed by `LEN_VALUE`.
    len_of: *Expr,
    /// One of the three keyword-named streams, as a value.
    stream_literal: Stream.Standard,
    /// The bare `args` keyword (GRAMMAR.bnf design note 3p) — evaluates to a
    /// fresh `list` of the program's own command-line arguments, as
    /// strings. Unlike `stream_literal`, this isn't a compile-time constant:
    /// the argument count and text vary per run, so it compiles to a
    /// dedicated opcode (PUSH_ARGS, ISA.bnf) that builds the list from the
    /// VM's `Host.args` at run time.
    args_literal,
    read_bytes: ReadBytes,
    write_value: WriteValue,
    write_bytes: WriteBytes,
    open_file: OpenFile,
    /// `{ "k1": v1, "k2": v2, ... }` (GRAMMAR.bnf design note 3m). Keys are
    /// static STRING tokens, not arbitrary expressions — a dynamic key is
    /// still fully expressible via `m[expr] := v` once the map exists.
    map_literal: []MapEntry,
    /// `push(list, value)` — grows a list by one element, evaluating to its
    /// new length (mirroring `write`'s "evaluates to a count" convention).
    list_push: ListPush,
    /// `has(map, key)` — whether `key` is present, without the
    /// `RuntimeError.KeyNotFound` a bracket-read raises for a missing one.
    map_has: MapHas,
    /// `delete(map, key)` — removes `key` if present, evaluating to whether
    /// it was.
    map_delete: MapDelete,
    /// `keys(map)` — a fresh `list` of the map's own keys, in insertion
    /// order. How map/list iteration works (`for i in 0..len(ks) { ... }`)
    /// instead of a dedicated foreach form (GRAMMAR.bnf design note 3g).
    map_keys: *Expr,
    /// `json(buffer, count)` (GRAMMAR.bnf design note 3n) — parses the first
    /// `count` bytes of an `int` buffer as JSON, evaluating to whatever the
    /// document's root turns out to be. `buffer` is a bare array name, the
    /// same restriction `ReadBytes`'s destination has and for the same
    /// reason: arrays still aren't first-class (design note 3e).
    json_parse: JsonParse,
    /// `stringify(value)` (GRAMMAR.bnf design note 3o) — the reverse of
    /// `json_parse`: renders an arbitrary value as JSON text, evaluating to
    /// a fresh heap `string`. `value` is a general expression (unlike
    /// `json_parse`'s buffer, this has no array-identifier restriction to
    /// inherit — it reads a value, it doesn't name a buffer to fill).
    json_stringify: *Expr,
    /// `int(value)` (GRAMMAR.bnf design note 3r) — parses a `string` as a
    /// base-10 integer, evaluating to an `int`. Reuses the `int` TYPE
    /// keyword as call syntax, like `json`/`stringify` above; never
    /// ambiguous with a `<type>` use since that position is only ever
    /// consulted at the start of a var-declaration/param/return-type, never
    /// while parsing an expression.
    int_parse: *Expr,
    /// `float(value)` — the `float` counterpart to `int_parse`, parsing a
    /// `string` as a floating-point literal.
    float_parse: *Expr,
    /// `getenv(name)` (GRAMMAR.bnf design note 3v) — the value of the
    /// environment variable `name`, as a fresh heap `string`, or `""` when
    /// it isn't set. Like `args_literal` this reads live `Host` state at run
    /// time (GET_ENV, ISA.bnf section 15) rather than anything the compiler
    /// could fold; unlike it, it takes an operand, so it's shaped like the
    /// `json`/`stringify`/`int`/`float` special forms above instead of being
    /// a bare keyword.
    env_get: *Expr,
    /// `hasenv(name)` — whether that variable is SET, which `env_get` alone
    /// can't answer: a variable set to the empty string and one that doesn't
    /// exist both read as `""`. The same split `map_has` gives a map
    /// (GRAMMAR.bnf design note 3v).
    env_has: *Expr,
    /// `exists(path)` (GRAMMAR.bnf design note 3w) — whether `path` names
    /// anything on disk right now, as a `bool`. Never raises beyond the
    /// `FilesUnavailable` capability gate and a non-string `TypeMismatch`:
    /// any other reason the check can't be answered (permission denied, a
    /// bad path, ...) reads as `false`, the same "advisory, not a
    /// guarantee" contract `std.Io.Dir.access` itself documents.
    path_exists: *Expr,
    /// `listDir(path)` — the names of `path`'s own entries (files and
    /// subdirectories, not recursive, no `.`/`..`), as a fresh `list` of
    /// `string`s in whatever order the OS hands them back. Unlike
    /// `path_exists`, a `path` that can't actually be listed (missing, not a
    /// directory, no permission) is `RuntimeError.ListDirFailed` — there is
    /// no meaningful empty-list fallback for "list this" the way there is
    /// for "does this exist".
    list_dir: *Expr,
    /// `remove(path)` — deletes the file or empty directory at `path`,
    /// evaluating to whether there was anything there to remove (the same
    /// "present and removed" split `map_delete` gives a map key, extended to
    /// the filesystem: removing something already gone is a no-op success,
    /// not an error). Any other failure (no permission, a non-empty
    /// directory, ...) is `RuntimeError.RemoveFailed`.
    path_remove: *Expr,
    /// `rename(from, to)` — moves/renames `from` to `to`, evaluating to
    /// whether `from` existed to be renamed (same "absent is a no-op, not an
    /// error" split as `path_remove`). Any other failure is
    /// `RuntimeError.RenameFailed`.
    path_rename: PathRename,
    /// `exec(command, args)` (GRAMMAR.bnf design note 3x) — spawns `command`
    /// with `args` (a `list` of strings) as its own argv[1..], waits for it
    /// to exit, and evaluates to a fresh `map` with three keys, always all
    /// present: `"stdout"`/`"stderr"` (its captured output, as strings) and
    /// `"exit_code"` (an `int`). Like `rename`, both operands are arbitrary
    /// expressions, not literals, so a computed command/argument list works.
    exec: Exec,
    /// `now()` (GRAMMAR.bnf design note 3y) — the current wall-clock time as
    /// a fresh `float` of seconds since the Unix epoch, sub-second precision
    /// included. Like `args_literal` this reads live `Host` state (NOW,
    /// ISA.bnf section 18) rather than anything the compiler could fold; no
    /// operand, unlike `getenv`, since there's nothing to name.
    time_now,
    /// `random()` — a fresh `float` uniformly distributed in `[0, 1)`, the
    /// zero-argument form of `random(...)` (RANDOM_FLOAT, ISA.bnf section
    /// 18). Distinguished from `random_range` purely by argument count at
    /// parse time (parser.zig's `randomExpr`), the same way `write`'s two
    /// forms are.
    random_float,
    /// `random(start, end)` — a fresh `int` uniformly distributed over
    /// `[start, end)`, end EXCLUSIVE — the same convention the for-loop's
    /// own `start..end` uses, though this is an ordinary two-argument call,
    /// not `..` syntax (RANDOM_RANGE, ISA.bnf section 18). `start`/`end` are
    /// arbitrary expressions, checked to be `int` at compile time where
    /// possible (mirroring the for-loop's own bounds) and always at runtime.
    random_range: RandomRange,

    pub const Unary = struct {
        op: UnaryOp,
        right: *Expr,
    };

    pub const Binary = struct {
        left: *Expr,
        op: BinaryOp,
        right: *Expr,
    };

    pub const Assign = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const Call = struct {
        name: []const u8,
        args: []*Expr,
    };

    /// `<base>[index]`. `base` is a general expression, not just a bare
    /// name — this is what lets bracket-indexing CHAIN for map/list values
    /// (`doc["a"]["b"]`, GRAMMAR.bnf design note 3m), unlike an array
    /// (design note 3e), which still only ever resolves through a bare
    /// `.variable` base: the compiler rejects (or, for a non-identifier
    /// base, the VM rejects at run time) any other shape for a fixed/
    /// generic array target, since an array element is always scalar and
    /// therefore never itself indexable.
    pub const Index = struct {
        base: *Expr,
        index: *Expr,
    };

    pub const IndexAssign = struct {
        base: *Expr,
        index: *Expr,
        value: *Expr,
    };

    pub const FieldInit = struct {
        name: []const u8,
        value: *Expr,
    };

    pub const StructLiteral = struct {
        type_name: []const u8,
        fields: []FieldInit,
    };

    pub const FieldAccess = struct {
        base: *Expr,
        field: []const u8,
    };

    pub const FieldAssign = struct {
        base: *Expr,
        field: []const u8,
        value: *Expr,
    };

    pub const Slice = struct {
        base: *Expr,
        start: *Expr,
        end: *Expr,
    };

    pub const MapEntry = struct {
        key: []const u8,
        value: *Expr,
    };

    pub const ListPush = struct {
        list: *Expr,
        value: *Expr,
    };

    pub const MapHas = struct {
        map: *Expr,
        key: *Expr,
    };

    pub const MapDelete = struct {
        map: *Expr,
        key: *Expr,
    };

    pub const JsonParse = struct {
        buffer: []const u8,
        count: *Expr,
    };

    /// `read(stream, buffer)` — fills `buffer`'s elements with raw bytes
    /// (one byte per element, 0-255) and evaluates to how many were read,
    /// 0 at end of input (GRAMMAR.bnf design note 3k). `stream` is an
    /// arbitrary expression so an opened file works everywhere `stdin`
    /// does, but `buffer` is still a bare array name for the same reason
    /// `Index`'s and `len_of`'s targets are: arrays aren't first-class
    /// values there'd be an expression to compute one from.
    pub const ReadBytes = struct {
        stream: *Expr,
        buffer: []const u8,
    };

    /// `write(stream, expr)` — writes `expr`'s value in exactly the
    /// rendering `print` uses but WITHOUT a trailing newline, and evaluates
    /// to how many bytes that took.
    pub const WriteValue = struct {
        stream: *Expr,
        value: *Expr,
    };

    /// `write(stream, buffer, count)` — writes the first `count` elements
    /// of `buffer` as raw bytes, the inverse of `ReadBytes`. Distinguished
    /// from `WriteValue` purely by argument count (see parser.zig's
    /// `writeExpr`), so `write(f, x)` and `write(f, buf, n)` never need
    /// different keywords.
    pub const WriteBytes = struct {
        stream: *Expr,
        buffer: []const u8,
        count: *Expr,
    };

    /// `open(path, mode)` — evaluates to a new stream naming that file
    /// (design note 3l). `path` is an arbitrary expression that must be a
    /// string at runtime; `mode` is a bare keyword, so which direction the
    /// file is opened in is always known at compile time.
    pub const OpenFile = struct {
        path: *Expr,
        mode: OpenMode,
    };

    /// `rename(from, to)`'s two operands — both arbitrary expressions that
    /// must be string-shaped at runtime, same as `path_exists`/`path_remove`.
    pub const PathRename = struct {
        from: *Expr,
        to: *Expr,
    };

    /// `exec(command, args)`'s two operands — `command` a general expression
    /// that must be string-shaped at runtime, `args` one that must be
    /// list-shaped (of strings), same "checked at runtime, not here" stance
    /// `open`'s path and `getenv`'s name take.
    pub const Exec = struct {
        command: *Expr,
        args: *Expr,
    };

    /// `random(start, end)`'s two operands — both arbitrary expressions,
    /// checked to be `int` at compile time where possible, same as the
    /// for-loop's own bounds (ISA.bnf section 7).
    pub const RandomRange = struct {
        start: *Expr,
        end: *Expr,
    };
};

pub const Stmt = struct {
    kind: StmtKind,
    line: usize,
};

pub const StmtKind = union(enum) {
    var_decl: VarDecl,
    block: []Stmt,
    if_stmt: If,
    while_stmt: While,
    print_stmt: *Expr,
    expr_stmt: *Expr,
    function_decl: FunctionDecl,
    return_stmt: *Expr,
    for_stmt: For,
    import_stmt: Import,
    /// `[export] struct IDENTIFIER '{' <field-list> '}'` (GRAMMAR.bnf design
    /// note 3z) — only ever produced at the top level (see parser.zig's
    /// `topLevelDeclaration`), matching `function_decl`/`import_stmt`.
    /// Compiles to nothing by itself (no codegen — purely a registration in
    /// compiler.zig, the same way `import_stmt` is); a struct name is
    /// resolved wherever `<type>` names it (`ValueType.named`) and a
    /// literal constructs it (`Expr.struct_literal`).
    struct_decl: StructDecl,
    /// `[export] enum IDENTIFIER '{' <variant-list> '}'` (GRAMMAR.bnf design
    /// note 3aa) — same top-level-only, registration-only shape as
    /// `struct_decl`. A variant's runtime value is a compile-time constant
    /// (`Value.enum_value`), never something this statement itself emits
    /// any code for.
    enum_decl: EnumDecl,
    /// `close <expression>` — a statement rather than an expression because,
    /// unlike `open`/`read`/`write`, it produces no value; `print` is the
    /// same shape for the same reason (design note 3l).
    close_stmt: *Expr,
    /// `exit <expression>` (design note 3q) — halts the whole program
    /// immediately, from anywhere (including deep inside nested calls, mid-
    /// loop, mid-expression-statement), propagating `expression`'s value as
    /// the process's own exit code. A statement, not an expression, for the
    /// same reason `close`/`print` are: it produces no value to a caller
    /// that, by definition, never gets to run.
    exit_stmt: *Expr,
    /// `try <block> catch IDENTIFIER <block>` (design note 3u) — runs
    /// `body`, and if a catchable runtime error is raised anywhere while it
    /// does (including several call frames deep), abandons the rest of it
    /// and runs `handler` instead, with `error_var` bound to a `map`
    /// describing the failure.
    try_stmt: Try,

    pub const VarDecl = struct {
        type: ValueType,
        /// Set only when `type == .named` — see `ValueType.named`'s doc comment.
        named_type: ?[]const u8 = null,
        name: []const u8,
        /// null for a plain scalar declaration; `Some(n)` means this
        /// declares a fixed-size array of `n` elements of `type` instead
        /// (see GRAMMAR.bnf design note 3e).
        array_len: ?u32 = null,
        initializer: ?*Expr,
    };

    pub const If = struct {
        condition: *Expr,
        then_branch: *Stmt,
        else_branch: ?*Stmt,
    };

    pub const While = struct {
        condition: *Expr,
        body: *Stmt,
    };

    /// Only ever produced at the top level (see parser.zig's
    /// `topLevelDeclaration`) — Butter has no nested functions or closures,
    /// so a `.function_decl` can never legally appear as the body of a
    /// block/if/while, even though the type itself doesn't forbid it.
    pub const FunctionDecl = struct {
        name: []const u8,
        params: []Param,
        return_type: ValueType,
        /// Set only when `return_type == .named` — see
        /// `ValueType.named`'s doc comment.
        return_named_type: ?[]const u8 = null,
        /// null for a plain scalar return type; see `ArraySpec` otherwise.
        return_array_size: ?ArraySpec = null,
        body: []Stmt,
        /// Whether this function is callable from a file that imports this
        /// one (see GRAMMAR.bnf design note h). Irrelevant for calls from
        /// within the same file, which are always allowed regardless.
        exported: bool = false,
    };

    /// `for var_name in start..end body` — always ascending, always step 1,
    /// end exclusive (see GRAMMAR.bnf design note 3f). `var_name` is a
    /// fresh int local scoped to the loop, per iteration re-usable but not
    /// visible outside it.
    pub const For = struct {
        var_name: []const u8,
        start: *Expr,
        end: *Expr,
        body: *Stmt,
    };

    /// The two halves of a `try`/`catch`. Both are `[]Stmt` — a block's
    /// contents — rather than the `*Stmt` `if`/`while`/`for` bodies are:
    /// braces are mandatory on both sides (design note 3u), so there is no
    /// braceless single-declaration form for either to represent.
    ///
    /// They are separate scopes, and `error_var` is a local of `handler`'s,
    /// not of `body`'s: a local declared in `body` may never have been
    /// initialized by the time `handler` runs, which is precisely the case
    /// `handler` exists to deal with.
    pub const Try = struct {
        body: []Stmt,
        error_var: []const u8,
        handler: []Stmt,
    };

    /// `import "path/to/file.butter"` — only ever produced at the top level
    /// (see parser.zig's `topLevelDeclaration`), matching `function_decl`.
    /// `path` is exactly the string literal's contents, unresolved — the
    /// module loader (module.zig) is what turns it into an actual file to
    /// read, relative to the importing file's own directory.
    pub const Import = struct {
        path: []const u8,
    };

    /// Only ever produced at the top level (see parser.zig's
    /// `topLevelDeclaration`) — same restriction `FunctionDecl` has, for the
    /// same reason (GRAMMAR.bnf design note 3z).
    pub const StructDecl = struct {
        name: []const u8,
        fields: []FieldDecl,
        /// Whether this struct is nameable from a file that imports this
        /// one (GRAMMAR.bnf design note h, extended to type declarations by
        /// design note 3z). Irrelevant for uses from within the same file.
        exported: bool = false,
    };

    /// Only ever produced at the top level, same as `StructDecl`
    /// (GRAMMAR.bnf design note 3aa).
    pub const EnumDecl = struct {
        name: []const u8,
        variants: [][]const u8,
        /// See `StructDecl.exported`.
        exported: bool = false,
    };
};

/// A parsed program: the top-level list of declarations.
pub const Program = []Stmt;

/// Writes an S-expression rendering of `expr`, primarily for debugging and
/// for making test assertions readable at a glance.
pub fn printExpr(writer: *std.Io.Writer, expr: *const Expr) std.Io.Writer.Error!void {
    switch (expr.*) {
        .literal => |lit| switch (lit) {
            .int => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| try writer.print("\"{s}\"", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .null_value => try writer.writeAll("null"),
        },
        .variable => |name| try writer.writeAll(name),
        .unary => |u| {
            try writer.print("({s} ", .{switch (u.op) {
                .negate => "-",
                .not => "!",
            }});
            try printExpr(writer, u.right);
            try writer.writeAll(")");
        },
        .binary => |b| {
            try writer.print("({s} ", .{binaryOpLexeme(b.op)});
            try printExpr(writer, b.left);
            try writer.writeAll(" ");
            try printExpr(writer, b.right);
            try writer.writeAll(")");
        },
        .grouping => |inner| {
            try writer.writeAll("(group ");
            try printExpr(writer, inner);
            try writer.writeAll(")");
        },
        .assign => |a| {
            try writer.print("(:= {s} ", .{a.name});
            try printExpr(writer, a.value);
            try writer.writeAll(")");
        },
        .call => |c| {
            try writer.print("(call {s}", .{c.name});
            for (c.args) |arg| {
                try writer.writeAll(" ");
                try printExpr(writer, arg);
            }
            try writer.writeAll(")");
        },
        .array_literal => |elems| {
            try writer.writeAll("(array");
            for (elems) |elem| {
                try writer.writeAll(" ");
                try printExpr(writer, elem);
            }
            try writer.writeAll(")");
        },
        .index => |i| {
            try writer.writeAll("(index ");
            try printExpr(writer, i.base);
            try writer.writeAll(" ");
            try printExpr(writer, i.index);
            try writer.writeAll(")");
        },
        .index_assign => |ia| {
            try writer.writeAll("(:= (index ");
            try printExpr(writer, ia.base);
            try writer.writeAll(" ");
            try printExpr(writer, ia.index);
            try writer.writeAll(") ");
            try printExpr(writer, ia.value);
            try writer.writeAll(")");
        },
        .struct_literal => |sl| {
            try writer.print("(struct {s}", .{sl.type_name});
            for (sl.fields) |f| {
                try writer.print(" ({s} ", .{f.name});
                try printExpr(writer, f.value);
                try writer.writeAll(")");
            }
            try writer.writeAll(")");
        },
        .field_access => |fa| {
            try writer.writeAll("(. ");
            try printExpr(writer, fa.base);
            try writer.print(" {s})", .{fa.field});
        },
        .field_assign => |fa| {
            try writer.writeAll("(:= (. ");
            try printExpr(writer, fa.base);
            try writer.print(" {s}) ", .{fa.field});
            try printExpr(writer, fa.value);
            try writer.writeAll(")");
        },
        .slice => |s| {
            try writer.writeAll("(slice ");
            try printExpr(writer, s.base);
            try writer.writeAll(" ");
            try printExpr(writer, s.start);
            try writer.writeAll(" ");
            try printExpr(writer, s.end);
            try writer.writeAll(")");
        },
        .len_of => |e| {
            try writer.writeAll("(len ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .stream_literal => |s| try writer.writeAll(s.name()),
        .args_literal => try writer.writeAll("args"),
        .read_bytes => |r| {
            try writer.writeAll("(read ");
            try printExpr(writer, r.stream);
            try writer.print(" {s})", .{r.buffer});
        },
        .write_value => |w| {
            try writer.writeAll("(write ");
            try printExpr(writer, w.stream);
            try writer.writeAll(" ");
            try printExpr(writer, w.value);
            try writer.writeAll(")");
        },
        .write_bytes => |w| {
            try writer.writeAll("(write ");
            try printExpr(writer, w.stream);
            try writer.print(" {s} ", .{w.buffer});
            try printExpr(writer, w.count);
            try writer.writeAll(")");
        },
        .open_file => |o| {
            try writer.writeAll("(open ");
            try printExpr(writer, o.path);
            try writer.print(" {s})", .{o.mode.name()});
        },
        .map_literal => |entries| {
            try writer.writeAll("(map");
            for (entries) |entry| {
                try writer.print(" (\"{s}\" ", .{entry.key});
                try printExpr(writer, entry.value);
                try writer.writeAll(")");
            }
            try writer.writeAll(")");
        },
        .list_push => |p| {
            try writer.writeAll("(push ");
            try printExpr(writer, p.list);
            try writer.writeAll(" ");
            try printExpr(writer, p.value);
            try writer.writeAll(")");
        },
        .map_has => |h| {
            try writer.writeAll("(has ");
            try printExpr(writer, h.map);
            try writer.writeAll(" ");
            try printExpr(writer, h.key);
            try writer.writeAll(")");
        },
        .map_delete => |d| {
            try writer.writeAll("(delete ");
            try printExpr(writer, d.map);
            try writer.writeAll(" ");
            try printExpr(writer, d.key);
            try writer.writeAll(")");
        },
        .map_keys => |m| {
            try writer.writeAll("(keys ");
            try printExpr(writer, m);
            try writer.writeAll(")");
        },
        .json_parse => |j| {
            try writer.print("(json {s} ", .{j.buffer});
            try printExpr(writer, j.count);
            try writer.writeAll(")");
        },
        .json_stringify => |e| {
            try writer.writeAll("(stringify ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .int_parse => |e| {
            try writer.writeAll("(int ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .float_parse => |e| {
            try writer.writeAll("(float ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .env_get => |e| {
            try writer.writeAll("(getenv ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .env_has => |e| {
            try writer.writeAll("(hasenv ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .path_exists => |e| {
            try writer.writeAll("(exists ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .list_dir => |e| {
            try writer.writeAll("(listDir ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .path_remove => |e| {
            try writer.writeAll("(remove ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .path_rename => |r| {
            try writer.writeAll("(rename ");
            try printExpr(writer, r.from);
            try writer.writeAll(" ");
            try printExpr(writer, r.to);
            try writer.writeAll(")");
        },
        .exec => |x| {
            try writer.writeAll("(exec ");
            try printExpr(writer, x.command);
            try writer.writeAll(" ");
            try printExpr(writer, x.args);
            try writer.writeAll(")");
        },
        .time_now => try writer.writeAll("(now)"),
        .random_float => try writer.writeAll("(random)"),
        .random_range => |r| {
            try writer.writeAll("(random ");
            try printExpr(writer, r.start);
            try writer.writeAll(" ");
            try printExpr(writer, r.end);
            try writer.writeAll(")");
        },
    }
}

/// Also used by compiler.zig's static type checker to name an operator in a
/// `SemanticError.TypeMismatch` diagnostic.
pub fn binaryOpLexeme(op: BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .pow => "**",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .lte => "<=",
        .gt => ">",
        .gte => ">=",
        .logic_or => "or",
        .logic_and => "and",
    };
}

fn printArraySpecSuffix(writer: *std.Io.Writer, spec: ArraySpec) std.Io.Writer.Error!void {
    switch (spec) {
        .fixed => |n| try writer.print("[{d}]", .{n}),
        .generic => try writer.writeAll("[]"),
    }
}

/// `named_type` is only consulted when `t == .named` (see
/// `ValueType.named`'s doc comment); every other case ignores it.
fn valueTypeName(t: ValueType, named_type: ?[]const u8) []const u8 {
    return switch (t) {
        .int => "int",
        .float => "float",
        .bool => "bool",
        .string => "string",
        .map => "map",
        .list => "list",
        .named => named_type.?,
    };
}

/// Writes an S-expression rendering of `stmt`, indented by `depth` levels.
pub fn printStmt(writer: *std.Io.Writer, stmt: *const Stmt, depth: usize) std.Io.Writer.Error!void {
    try writer.splatByteAll(' ', depth * 2);
    switch (stmt.kind) {
        .var_decl => |d| {
            if (d.array_len) |n| {
                try writer.print("({s}[{d}] {s}", .{ valueTypeName(d.type, d.named_type), n, d.name });
            } else {
                try writer.print("({s} {s}", .{ valueTypeName(d.type, d.named_type), d.name });
            }
            if (d.initializer) |init_expr| {
                try writer.writeAll(" ");
                try printExpr(writer, init_expr);
            }
            try writer.writeAll(")");
        },
        .block => |stmts| {
            try writer.writeAll("(block\n");
            for (stmts) |*s| {
                try printStmt(writer, s, depth + 1);
                try writer.writeAll("\n");
            }
            try writer.splatByteAll(' ', depth * 2);
            try writer.writeAll(")");
        },
        .if_stmt => |i| {
            try writer.writeAll("(if ");
            try printExpr(writer, i.condition);
            try writer.writeAll("\n");
            try printStmt(writer, i.then_branch, depth + 1);
            if (i.else_branch) |eb| {
                try writer.writeAll("\n");
                try printStmt(writer, eb, depth + 1);
            }
            try writer.writeAll(")");
        },
        .while_stmt => |w| {
            try writer.writeAll("(while ");
            try printExpr(writer, w.condition);
            try writer.writeAll("\n");
            try printStmt(writer, w.body, depth + 1);
            try writer.writeAll(")");
        },
        .print_stmt => |e| {
            try writer.writeAll("(print ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .expr_stmt => |e| try printExpr(writer, e),
        .function_decl => |f| {
            const prefix = if (f.exported) "export " else "";
            try writer.print("({s}func {s} (", .{ prefix, f.name });
            for (f.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.writeAll(valueTypeName(p.type, p.named_type));
                if (p.array_size) |spec| try printArraySpecSuffix(writer, spec);
            }
            try writer.print(") {s}", .{valueTypeName(f.return_type, f.return_named_type)});
            if (f.return_array_size) |spec| try printArraySpecSuffix(writer, spec);
            try writer.writeAll(")\n");
            for (f.body) |*s| {
                try printStmt(writer, s, depth + 1);
                try writer.writeAll("\n");
            }
            try writer.splatByteAll(' ', depth * 2);
            try writer.writeAll(")");
        },
        .return_stmt => |e| {
            try writer.writeAll("(return ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .for_stmt => |f| {
            try writer.print("(for {s} ", .{f.var_name});
            try printExpr(writer, f.start);
            try writer.writeAll(" ");
            try printExpr(writer, f.end);
            try writer.writeAll("\n");
            try printStmt(writer, f.body, depth + 1);
            try writer.writeAll(")");
        },
        .import_stmt => |i| try writer.print("(import \"{s}\")", .{i.path}),
        .struct_decl => |s| {
            const prefix = if (s.exported) "export " else "";
            try writer.print("({s}struct {s}", .{ prefix, s.name });
            for (s.fields) |f| {
                try writer.print(" ({s} {s})", .{ valueTypeName(f.type, f.named_type), f.name });
            }
            try writer.writeAll(")");
        },
        .enum_decl => |e| {
            const prefix = if (e.exported) "export " else "";
            try writer.print("({s}enum {s}", .{ prefix, e.name });
            for (e.variants) |v| try writer.print(" {s}", .{v});
            try writer.writeAll(")");
        },
        .close_stmt => |e| {
            try writer.writeAll("(close ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .exit_stmt => |e| {
            try writer.writeAll("(exit ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .try_stmt => |t| {
            try writer.writeAll("(try");
            for (t.body) |*s| {
                try writer.writeAll("\n");
                try printStmt(writer, s, depth + 1);
            }
            try writer.writeAll("\n");
            try writer.splatByteAll(' ', (depth + 1) * 2);
            try writer.print("(catch {s}", .{t.error_var});
            for (t.handler) |*s| {
                try writer.writeAll("\n");
                try printStmt(writer, s, depth + 2);
            }
            try writer.writeAll("))");
        },
    }
}

/// Writes an S-expression rendering of an entire parsed program, one
/// top-level declaration per line.
pub fn printProgram(writer: *std.Io.Writer, program: Program) std.Io.Writer.Error!void {
    for (program) |*stmt| {
        try printStmt(writer, stmt, 0);
        try writer.writeAll("\n");
    }
}

test "printExpr renders a nested expression as an s-expression" {
    var one = Expr{ .literal = .{ .int = 1 } };
    var two = Expr{ .literal = .{ .int = 2 } };
    var sum = Expr{ .binary = .{ .left = &one, .op = .add, .right = &two } };
    var grouped = Expr{ .grouping = &sum };
    var neg = Expr{ .unary = .{ .op = .negate, .right = &grouped } };

    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printExpr(&writer, &neg);
    try std.testing.expectEqualStrings("(- (group (+ 1 2)))", writer.buffered());
}

test "printStmt renders an if/else with indented branches" {
    var cond = Expr{ .variable = "x" };
    var one = Expr{ .literal = .{ .int = 1 } };
    var two = Expr{ .literal = .{ .int = 2 } };
    var then_branch = Stmt{ .kind = .{ .print_stmt = &one }, .line = 1 };
    var else_branch = Stmt{ .kind = .{ .print_stmt = &two }, .line = 1 };
    var if_stmt = Stmt{ .kind = .{ .if_stmt = .{ .condition = &cond, .then_branch = &then_branch, .else_branch = &else_branch } }, .line = 1 };

    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try printStmt(&writer, &if_stmt, 0);
    try std.testing.expectEqualStrings("(if x\n  (print 1)\n  (print 2))", writer.buffered());
}
