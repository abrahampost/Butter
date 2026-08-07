//! AST node definitions for Butter, matching section 2 (SYNTAX GRAMMAR) of
//! GRAMMAR.bnf. Nodes are produced by `parser.Parser` into memory owned by
//! its arena; they borrow string data (identifiers, string contents)
//! directly from the source text — except a string literal/import path/
//! map key that actually uses a `\n`/`\t`/`\\`/`\"` escape (design note 3s),
//! which is decoded into a fresh arena-owned buffer instead.

const std = @import("std");

/// Re-exported so the AST and ISA share one type for the three streams
/// (see `value.Stream`). Only `Standard` appears in source — a `file`
/// stream only ever comes from an `open` at runtime, which is why
/// `read`/`write`'s stream operand is a general `*Expr` here, not a fixed
/// tag (design note 3l).
pub const Stream = @import("value.zig").Stream;

/// `'read' | 'write' | 'append'` in `open`'s mode position (re-exported
/// from `value` alongside `Stream`). Distinct from the `read`/`write`
/// operations sharing those keywords — the parser only looks for a mode
/// where one is legal, so there's no ambiguity.
pub const OpenMode = @import("value.zig").OpenMode;

pub const ValueType = enum {
    int,
    float,
    bool,
    string,
    /// A refcounted heap map (design note 3m) — always one runtime value
    /// (a heap reference), never raw stack slots, so it never takes the
    /// `[N]`/`[]` array suffix `Param`/`VarDecl`/`FunctionDecl` allow.
    map,
    /// A refcounted heap list (design note 3m) — same as `map`, but
    /// ordered/indexed by INT instead of by STRING key.
    list,
    /// A user-declared `struct` or `enum` type (design notes 3z/3aa). The
    /// name itself lives in a sibling `named_type: ?[]const u8` field
    /// (`Param.named_type`, `Stmt.VarDecl.named_type`, etc.), not here —
    /// keeping `ValueType` a plain payload-less enum so `== .int`/`== .map`
    /// comparisons keep working unchanged; only sites that need the name
    /// (compiler.zig's type resolution, the debug printer) look at the
    /// sibling field. The parser never resolves the name; compiler.zig
    /// does, once, against the program's registered struct/enum types.
    named,
    /// A reference to a top-level named function (design note 3ad) —
    /// `func(paramTypes) returnType` in source. Unlike `named`, the
    /// signature travels as a sibling `?*const FuncSig`
    /// (`Param.func_sig`/`Stmt.VarDecl.func_sig`), since a function type
    /// has no name to look up, only a shape. Only legal as a parameter or
    /// local variable's type — never a struct field's or a function's own
    /// return type (rejected by the parser).
    func,
};

/// The structural signature a `func(paramTypes) returnType` type names
/// (design note 3ad). Restricted to plain scalars in `param_types`/
/// `return_type` — never `.named` or nested `.func` — so two signatures
/// can be compared structurally with plain `==`, no name resolution
/// needed.
pub const FuncSig = struct {
    param_types: []const ValueType,
    return_type: ValueType,
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

/// A parameter's or return type's optional array-ness: `fixed`
/// (compile-time size, passed/returned BY VALUE — design note 3e) or
/// `generic` (no declared size, passed BY REFERENCE as a `Value.array_ref`
/// to whatever array the caller supplies — design note 3e's generic-array
/// addendum). Local var-declarations don't use this: `VarDecl.array_len`
/// stays a plain `?u32`, since a local's storage is always concrete slots
/// this compiler allocated, never someone else's reference.
pub const ArraySpec = union(enum) {
    fixed: u32,
    generic,
};

pub const Param = struct {
    type: ValueType,
    /// Set only when `type == .named` — see `ValueType.named`'s doc comment.
    named_type: ?[]const u8 = null,
    /// Set only when `type == .func` — see `ValueType.func`'s doc comment.
    func_sig: ?*const FuncSig = null,
    name: []const u8,
    /// null for a plain scalar parameter; see `ArraySpec` otherwise.
    array_size: ?ArraySpec = null,
};

/// One `<type> IDENTIFIER` field of a `struct` declaration (design note
/// 3z) — shaped like `Param` but without `array_size`: a field is always
/// exactly one `Value` slot in the record, the same restriction `map`/
/// `list` params have, extended to every field type.
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
    /// `<base>.IDENTIFIER '(' args ')'` (design note 3af) — a struct
    /// method call, distinguished from `.field_access` by the trailing '('
    /// (parser.zig's `primary` postfix loop). `base` must statically be a
    /// struct and `method` one of its declared methods; compiler.zig
    /// resolves both.
    method_call: MethodCall,
    array_literal: []*Expr,
    index: Index,
    index_assign: IndexAssign,
    /// `TypeName{field1: expr1, ...}` (design note 3z) — constructs a heap
    /// record of struct `type_name`. Every field is required, keyed by
    /// name, any order in source; compiler.zig resolves `type_name`,
    /// validates the field set, and reorders fields into the struct's
    /// declared order before emitting `MAKE_STRUCT` (ISA.bnf section 19) —
    /// bytecode field order never depends on literal order.
    struct_literal: StructLiteral,
    /// `<base>.IDENTIFIER` (design notes 3z/3aa) — a struct field read OR
    /// an enum variant reference (`Color.Red`); undecided here.
    /// compiler.zig disambiguates by resolving `base`: a bare `.variable`
    /// naming no local but a declared enum type is an enum-variant
    /// reference (`PUSH_CONST` of a `Value.enum_value`); otherwise `base`
    /// must be a struct and `field` one of its declared fields
    /// (`FIELD_GET`, ISA.bnf section 19), else `SemanticError.NotAStruct`/
    /// `UnknownField`/`UnknownEnumVariant`. Chains for free (`p.a.b`,
    /// `xs[0].x`) since it shares `Index`'s postfix loop.
    field_access: FieldAccess,
    /// `<base>.IDENTIFIER := <expression>` — the `.field_access`
    /// counterpart to `.index_assign`; only ever a struct field write
    /// (`assignment()` never turns an enum-variant reference into an
    /// lvalue).
    field_assign: FieldAssign,
    /// `<base>[start..end]` (Strings design notes) — a read-only
    /// substring, end exclusive, same convention as a for-loop range. No
    /// `.slice_assign` counterpart: `assignment` only turns
    /// `.variable`/`.index` into lvalues, so `s[a..b] := v` falls through
    /// to the "invalid assignment target" error.
    slice: Slice,
    /// `len(<expression>)`. Relaxed from a bare array name to an arbitrary
    /// expression (design note 3m) now that map/list are first-class. The
    /// compiler still special-cases a bare `.variable` naming a
    /// fixed/generic array (folds to a constant or `LOAD_REF_LEN` — arrays
    /// still aren't first-class, design note 3e); anything else compiles
    /// as `LEN_VALUE`.
    len_of: *Expr,
    /// One of the three keyword-named streams, as a value.
    stream_literal: Stream.Standard,
    /// The bare `args` keyword (design note 3p) — a fresh `list` of the
    /// program's command-line arguments as strings. Not a compile-time
    /// constant (varies per run), so it compiles to PUSH_ARGS, building
    /// the list from `Host.args` at run time.
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
    /// order. How map/list iteration works (`for i in 0..len(ks) { ... }`
    /// instead of a dedicated foreach form (design note 3g).
    map_keys: *Expr,
    /// `json(buffer, count)` (design note 3n) — parses the first `count`
    /// bytes of an `int` buffer as JSON. `buffer` is a bare array name,
    /// same restriction as `ReadBytes`'s destination and for the same
    /// reason: arrays aren't first-class (design note 3e).
    json_parse: JsonParse,
    /// `stringify(value)` (design note 3o) — the reverse of `json_parse`:
    /// renders `value` as JSON text into a fresh `string`. `value` is a
    /// general expression, unlike `json_parse`'s buffer — it reads a
    /// value rather than naming a buffer to fill.
    json_stringify: *Expr,
    /// `int(value)` (design note 3r) — parses a `string` as base-10,
    /// evaluating to an `int`. Reuses the `int` TYPE keyword as call
    /// syntax; never ambiguous with a `<type>` use since that position
    /// only appears at the start of a var-declaration/param/return-type.
    int_parse: *Expr,
    /// `float(value)` — the `float` counterpart to `int_parse`, parsing a
    /// `string` as a floating-point literal.
    float_parse: *Expr,
    /// `getenv(name)` (design note 3v) — the environment variable `name`'s
    /// value as a `string`, or `""` if unset. Reads live `Host` state at
    /// run time (GET_ENV, ISA.bnf section 15) like `args_literal`, but
    /// takes an operand, so it's shaped like `json`/`stringify`/`int`/
    /// `float` instead of a bare keyword.
    env_get: *Expr,
    /// `hasenv(name)` — whether the variable is SET; `env_get` alone can't
    /// answer this since an empty-string value and an unset variable both
    /// read as `""`. The same split `map_has` gives a map (design note 3v).
    env_has: *Expr,
    /// `exists(path)` (design note 3w) — whether `path` names anything on
    /// disk, as a `bool`. Never raises beyond the `FilesUnavailable` gate
    /// and a non-string `TypeMismatch`: any other failure (permission
    /// denied, bad path) reads as `false` — "advisory, not a guarantee",
    /// matching `std.Io.Dir.access`.
    path_exists: *Expr,
    /// `listDir(path)` — `path`'s own entries (not recursive, no `.`/
    /// `..`) as a `list` of `string`s, OS order. Unlike `path_exists`, an
    /// unlistable `path` (missing, not a directory, no permission) raises
    /// `RuntimeError.ListDirFailed` — no empty-list fallback.
    list_dir: *Expr,
    /// `remove(path)` — deletes the file or empty directory at `path`,
    /// evaluating to whether anything was removed (same "present and
    /// removed" split as `map_delete`: removing something already gone is
    /// a no-op success). Any other failure is `RuntimeError.RemoveFailed`.
    path_remove: *Expr,
    /// `rename(from, to)` — moves/renames `from` to `to`, evaluating to
    /// whether `from` existed to be renamed (same "absent is a no-op, not an
    /// error" split as `path_remove`). Any other failure is
    /// `RuntimeError.RenameFailed`.
    path_rename: PathRename,
    /// `mkdir(path)` — creates the directory at `path`, evaluating to
    /// whether a NEW one was made (`true` if it didn't exist, `false` if
    /// already a directory — the mirror of `path_remove`'s no-op split).
    /// NOT recursive: a missing parent, or `path` existing as a
    /// non-directory, is `RuntimeError.MkdirFailed`, not silently handled.
    path_mkdir: *Expr,
    /// `exec(command, args)` (design note 3x) — spawns `command` with
    /// `args` (a `list` of strings) as argv[1..], waits for exit,
    /// evaluates to a `map` with `"stdout"`/`"stderr"`/`"exit_code"`. Both
    /// operands are arbitrary expressions, so a computed command/argument
    /// list works.
    exec: Exec,
    /// `now()` (design note 3y) — wall-clock time as a `float` of seconds
    /// since the Unix epoch, sub-second precision. Reads live `Host` state
    /// (NOW, ISA.bnf section 18); no operand, unlike `getenv`, since
    /// there's nothing to name.
    time_now,
    /// `random()` — a `float` uniform in `[0, 1)`, the zero-arg form of
    /// `random(...)` (RANDOM_FLOAT, ISA.bnf section 18). Distinguished
    /// from `random_range` by argument count at parse time
    /// (`randomExpr`), like `write`'s two forms.
    random_float,
    /// `random(start, end)` — an `int` uniform over `[start, end)`, end
    /// EXCLUSIVE (same convention as a for-loop's `start..end`, though
    /// this is an ordinary call, not `..` syntax; RANDOM_RANGE, ISA.bnf
    /// section 18). `start`/`end` are checked `int` at compile time where
    /// possible, always at runtime.
    random_range: RandomRange,
    /// `ord(s)` (design note 3ab) — the byte value (0..255) of
    /// single-byte string `s`, using the "characters are length-1
    /// strings" convention `s[i]` already has, without a separate `char`
    /// type. `RuntimeError.InvalidCharLength` (ISA.bnf section 21) if
    /// `s`'s length isn't exactly 1 — checked, not truncated.
    char_ord: *Expr,
    /// `chr(n)` (design note 3ab) — the inverse of `ord`: the length-1
    /// `string` whose single byte is `n`. `RuntimeError.ByteOutOfRange`
    /// (ISA.bnf section 21) if `n` isn't in `0..255` — the same range
    /// check `write`'s buffer argument gets, checked rather than masked.
    char_chr: *Expr,
    /// `join(list, sep)` (design note 3ac) — every `string` element of
    /// `list`, concatenated with `sep` between them, as one fresh string.
    /// The single-pass counterpart to building a string via repeated `+`
    /// in a loop, solved by pairing with existing `list`/`push` rather
    /// than adding a mutable value kind (ISA.bnf section 22).
    list_join: Join,
    /// `"literal ${expr} literal"` (design note 3ae) — a STRING literal
    /// with one or more `${...}` interpolations, split at parse time into
    /// alternating literal-text/sub-expression parts (`parser.zig`'s
    /// `parseStringOrInterp`). A STRING with no `${` stays a plain
    /// `.literal.string` — purely additive. Always evaluates to `string`:
    /// `compiler.zig` desugars to PUSH_CONST/TO_STRING per part plus one
    /// INTERP_CONCAT (ISA.bnf section 23), avoiding both a new heap value
    /// kind and the O(n^2) growth a chain of ADD would cause.
    string_interp: []InterpPart,

    /// One piece of an interpolated string: literal text (escape-decoded
    /// like `Literal.string`) or a `${...}` sub-expression, in source
    /// order. A literal part may be empty; `parser.zig` emits one for
    /// every gap, including empty ones at the start/end, so `compiler.zig`
    /// only ever sees ordinary literal/expr alternation — no "was there
    /// text before the first `${`?" special case.
    pub const InterpPart = union(enum) {
        literal: []const u8,
        expr: *Expr,
    };

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

    /// `base.method(args)` (design note 3af). `args` never includes `base`
    /// (the receiver) — compiler.zig prepends it as the underlying
    /// function's first argument at codegen time, matching how
    /// `MethodDecl.receiver_name`/`receiver_type` desugar to that
    /// function's first parameter at registration.
    pub const MethodCall = struct {
        base: *Expr,
        method: []const u8,
        args: []*Expr,
    };

    /// `<base>[index]`. `base` is a general expression, not just a bare
    /// name — this lets bracket-indexing CHAIN for map/list values
    /// (`doc["a"]["b"]`, design note 3m). An array (design note 3e) still
    /// only resolves through a bare `.variable` base, since an array
    /// element is always scalar and never itself indexable.
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

    pub const Join = struct {
        list: *Expr,
        sep: *Expr,
    };

    pub const JsonParse = struct {
        buffer: []const u8,
        count: *Expr,
    };

    /// `read(stream, buffer)` — fills `buffer`'s elements with raw bytes
    /// (0-255), evaluating to the count read, 0 at EOF (design note 3k).
    /// `stream` is a general expression so an opened file works anywhere
    /// `stdin` does; `buffer` stays a bare array name — arrays aren't
    /// first-class (same as `Index`/`len_of`'s targets).
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
    /// from `WriteValue` by argument count (parser.zig's `writeExpr`), so
    /// `write(f, x)` and `write(f, buf, n)` share one keyword.
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
    /// `[export] func '(' IDENTIFIER IDENTIFIER ')' IDENTIFIER '(' params ')'
    /// '->' <type> <block>` (design note 3af) — a struct method, top-level
    /// only like `function_decl`. Never compiled directly: compiler.zig
    /// desugars it into an ordinary function whose first parameter is the
    /// receiver, then compiles that like any `function_decl`. A method
    /// call resolves statically at its call site, never via runtime
    /// dispatch.
    method_decl: MethodDecl,
    return_stmt: *Expr,
    for_stmt: For,
    import_stmt: Import,
    /// `[export] struct IDENTIFIER '{' <field-list> '}'` (design note 3z)
    /// — top-level only, matching `function_decl`/`import_stmt`. Compiles
    /// to nothing itself — purely a registration in compiler.zig; a
    /// struct name is resolved wherever `<type>` names it
    /// (`ValueType.named`) and a literal constructs it
    /// (`Expr.struct_literal`).
    struct_decl: StructDecl,
    /// `[export] enum IDENTIFIER '{' <variant-list> '}'` (design note 3aa)
    /// — same top-level-only, registration-only shape as `struct_decl`. A
    /// variant's runtime value is a compile-time constant
    /// (`Value.enum_value`); this statement itself emits no code.
    enum_decl: EnumDecl,
    /// `close <expression>` — a statement rather than an expression because,
    /// unlike `open`/`read`/`write`, it produces no value; `print` is the
    /// same shape for the same reason (design note 3l).
    close_stmt: *Expr,
    /// `exit <expression>` (design note 3q) — halts the whole program
    /// immediately from anywhere (nested calls, mid-loop,
    /// mid-expression), using `expression`'s value as the exit code. A
    /// statement, not an expression, since there's no caller left to
    /// receive a value.
    exit_stmt: *Expr,
    /// `throw <expression>` (design note 3u) — raises `expression` (must
    /// statically be the built-in `Error` struct) as a catchable error,
    /// caught by the nearest enclosing `try` or, uncaught, terminating the
    /// program like an internal error would. A statement, not an
    /// expression, same as `exit`/`close`/`print`.
    throw_stmt: *Expr,
    /// `try <block> catch IDENTIFIER <block>` (design note 3u) — runs
    /// `body`; if a catchable runtime error is raised anywhere while it
    /// does (even frames deep), abandons the rest and runs `handler`
    /// instead, with `error_var` bound to a `map` describing the failure.
    try_stmt: Try,

    pub const VarDecl = struct {
        type: ValueType,
        /// Set only when `type == .named` — see `ValueType.named`'s doc comment.
        named_type: ?[]const u8 = null,
        /// Set only when `type == .func` — see `ValueType.func`'s doc comment.
        func_sig: ?*const FuncSig = null,
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

    /// Only ever produced at the top level (`topLevelDeclaration`) —
    /// Butter has no nested functions or closures, so `.function_decl`
    /// never legally appears as a block/if/while body, though the type
    /// itself doesn't forbid it.
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

    /// See `StmtKind.method_decl`'s doc comment. `receiver_type` must name a
    /// declared struct (never an enum — GRAMMAR.bnf design note 3af); which
    /// one is resolved by compiler.zig, same as `Param.named_type` elsewhere.
    pub const MethodDecl = struct {
        receiver_name: []const u8,
        receiver_type: []const u8,
        name: []const u8,
        params: []Param,
        return_type: ValueType,
        /// Set only when `return_type == .named` — see `FunctionDecl`'s
        /// sibling field of the same name.
        return_named_type: ?[]const u8 = null,
        /// null for a plain scalar return type; see `ArraySpec` otherwise.
        return_array_size: ?ArraySpec = null,
        body: []Stmt,
        /// See `FunctionDecl.exported`'s doc comment — a method opts into
        /// cross-module visibility independently of its receiver struct's
        /// own `StructDecl.exported`, exactly like a plain function does.
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

    /// The two halves of a `try`/`catch`. Both are `[]Stmt` rather than
    /// the `*Stmt` `if`/`while`/`for` bodies use — braces are mandatory on
    /// both sides (design note 3u), so there's no braceless single-
    /// statement form. They are separate scopes: `error_var` is a local
    /// of `handler`'s, not `body`'s, since a local declared in `body` may
    /// never have been initialized by the time `handler` runs — exactly
    /// the case `handler` exists to handle.
    pub const Try = struct {
        body: []Stmt,
        error_var: []const u8,
        handler: []Stmt,
    };

    /// `import "path/to/file.butter"` — top-level only, matching
    /// `function_decl`. `path` is the string literal's raw contents,
    /// unresolved — module.zig turns it into an actual file, relative to
    /// the importing file's directory.
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
        .method_call => |mc| {
            try writer.writeAll("(methodcall ");
            try printExpr(writer, mc.base);
            try writer.print(" {s}", .{mc.method});
            for (mc.args) |arg| {
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
        .char_ord => |e| {
            try writer.writeAll("(ord ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .char_chr => |e| {
            try writer.writeAll("(chr ");
            try printExpr(writer, e);
            try writer.writeAll(")");
        },
        .list_join => |j| {
            try writer.writeAll("(join ");
            try printExpr(writer, j.list);
            try writer.writeAll(" ");
            try printExpr(writer, j.sep);
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
        .path_mkdir => |e| {
            try writer.writeAll("(mkdir ");
            try printExpr(writer, e);
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
        .string_interp => |parts| {
            try writer.writeAll("(interp");
            for (parts) |part| {
                try writer.writeAll(" ");
                switch (part) {
                    .literal => |s| try writer.print("\"{s}\"", .{s}),
                    .expr => |e| try printExpr(writer, e),
                }
            }
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
        // A placeholder, not the full signature — rendering
        // `func(int,int)bool` in full would need `func_sig` threaded
        // through every one of this function's call sites for a debug-only
        // printer; not worth it (GRAMMAR.bnf design note 3ad).
        .func => "func",
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
        .method_decl => |md| {
            const prefix = if (md.exported) "export " else "";
            try writer.print("({s}func ({s} {s}) {s} (", .{ prefix, md.receiver_name, md.receiver_type, md.name });
            for (md.params, 0..) |p, i| {
                if (i > 0) try writer.writeAll(" ");
                try writer.writeAll(valueTypeName(p.type, p.named_type));
                if (p.array_size) |spec| try printArraySpecSuffix(writer, spec);
            }
            try writer.print(") {s}", .{valueTypeName(md.return_type, md.return_named_type)});
            if (md.return_array_size) |spec| try printArraySpecSuffix(writer, spec);
            try writer.writeAll(")\n");
            for (md.body) |*s| {
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
        .throw_stmt => |e| {
            try writer.writeAll("(throw ");
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
