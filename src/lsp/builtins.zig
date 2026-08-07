//! Signature/doc data for Butter's built-in keyword-form operations
//! (`ord`, `chr`, `len`, `getenv`, ...) — GRAMMAR.bnf section 3's
//! `<len-expr>`/`<read-expr>`/.../`<ord-expr>`/`<chr-expr>`/`<join-expr>`
//! productions. Each of these is a dedicated lexer keyword (lexer.zig's
//! `TokenType`) with its own AST node and hardcoded typing in
//! parser.zig/compiler.zig, not an `ast.Stmt.function_decl` symbol — so
//! resolve.zig has nothing in the AST to read a signature from the way it
//! does for a user-declared `func`. This table is hand-maintained in
//! parallel with parser.zig's own `<...-expr>` productions for exactly
//! that reason; a new builtin needs an entry here too.
//!
//! `int`/`float` are the only two also usable as a `<type>` keyword
//! (`int x := 5`) sharing the same token type as their call form
//! (`int(x)`, design note 3r) — resolve.zig only resolves a `Builtin` for
//! those two when the keyword is immediately followed by '(', the same
//! followed-by-call heuristic `tokens.zig`'s `roleOf` already uses to tell
//! an identifier `call` from a `variable`. Every other entry here has no
//! competing meaning, so no such gate is needed.

const std = @import("std");
const butter = @import("butter");
const lexer = butter.lexer;

pub const Builtin = struct {
    /// Rendered verbatim inside a ```butter fenced code block, matching
    /// how hover.zig renders a user-declared function/struct/enum's
    /// signature. May contain embedded newlines for a builtin with more
    /// than one call form (e.g. `random()` / `random(start, end)`).
    signature: []const u8,
    /// A one-line description, rendered below the signature the same way
    /// a function's `##` doc comment is (hover.zig's `writeDoc`).
    doc: []const u8,
};

const Entry = struct { kw: lexer.TokenType, name: []const u8, b: Builtin };

const table = [_]Entry{
    .{ .kw = .kw_print, .name = "print", .b = .{ .signature = "print <expr>", .doc = "Writes expr's human-readable rendering to stdout, followed by a newline." } },
    .{ .kw = .kw_close, .name = "close", .b = .{ .signature = "close <stream>", .doc = "Closes an open file stream. Closing stdin/stdout/stderr is rejected." } },
    .{ .kw = .kw_exit, .name = "exit", .b = .{ .signature = "exit <int>", .doc = "Halts the program immediately with the given exit code." } },
    .{ .kw = .kw_throw, .name = "throw", .b = .{ .signature = "throw <expr>", .doc = "Raises expr as an error, unwinding to the nearest enclosing try/catch." } },
    .{ .kw = .kw_len, .name = "len", .b = .{ .signature = "func len(list|map|string|array) -> int", .doc = "The number of elements (list/array), keys (map), or bytes (string)." } },
    .{ .kw = .kw_read, .name = "read", .b = .{ .signature = "func read(stream, buf: int[]) -> int", .doc = "A short read into buf (bytes 0..255): at least 1, at most len(buf); 0 only at end of input." } },
    .{ .kw = .kw_write, .name = "write", .b = .{ .signature = "func write(stream, value) -> int\nfunc write(stream, buf: int[], n: int) -> int", .doc = "Renders value like print (no trailing newline), or writes the first n bytes of buf. Evaluates to the byte count written." } },
    .{ .kw = .kw_open, .name = "open", .b = .{ .signature = "func open(path: string, mode: read|write|append) -> stream", .doc = "Opens path for the given mode, usable anywhere stdin/stdout/stderr are." } },
    .{ .kw = .kw_push, .name = "push", .b = .{ .signature = "func push(list, value) -> int", .doc = "Appends value to list, evaluating to the list's new length." } },
    .{ .kw = .kw_keys, .name = "keys", .b = .{ .signature = "func keys(map) -> list", .doc = "A fresh list of map's own keys, in insertion order." } },
    .{ .kw = .kw_has, .name = "has", .b = .{ .signature = "func has(map, key: string) -> bool", .doc = "Whether key is present in map." } },
    .{ .kw = .kw_delete, .name = "delete", .b = .{ .signature = "func delete(map, key: string) -> bool", .doc = "Removes key from map if present; a no-op (not an error) if it wasn't." } },
    .{ .kw = .kw_json, .name = "json", .b = .{ .signature = "func json(buf: int[], count: int) -> number|bool|null|string|list|map", .doc = "Parses count bytes of buf as JSON text." } },
    .{ .kw = .kw_stringify, .name = "stringify", .b = .{ .signature = "func stringify(value) -> string", .doc = "Renders any value as JSON text (a stream or array reference has no JSON form)." } },
    .{ .kw = .kw_int, .name = "int", .b = .{ .signature = "func int(string) -> int\nfunc int(float) -> int", .doc = "Parses a numeric string, or truncates a float toward zero." } },
    .{ .kw = .kw_float, .name = "float", .b = .{ .signature = "func float(string) -> float", .doc = "Parses a numeric string (also accepts \"nan\"/\"inf\"/\"-inf\")." } },
    .{ .kw = .kw_getenv, .name = "getenv", .b = .{ .signature = "func getenv(name: string) -> string", .doc = "The environment variable name's value, or \"\" if unset." } },
    .{ .kw = .kw_hasenv, .name = "hasenv", .b = .{ .signature = "func hasenv(name: string) -> bool", .doc = "Whether environment variable name is set." } },
    .{ .kw = .kw_exists, .name = "exists", .b = .{ .signature = "func exists(path: string) -> bool", .doc = "Whether path names anything on disk right now." } },
    .{ .kw = .kw_listdir, .name = "listDir", .b = .{ .signature = "func listDir(path: string) -> list", .doc = "The names of path's own entries, in OS iteration order (not sorted)." } },
    .{ .kw = .kw_remove, .name = "remove", .b = .{ .signature = "func remove(path: string) -> bool", .doc = "Deletes the file or empty directory at path; true if something was removed." } },
    .{ .kw = .kw_rename, .name = "rename", .b = .{ .signature = "func rename(from: string, to: string) -> bool", .doc = "Moves/renames from to to; true if from existed." } },
    .{ .kw = .kw_mkdir, .name = "mkdir", .b = .{ .signature = "func mkdir(path: string) -> bool", .doc = "Creates path as a directory; true if a new directory was made." } },
    .{ .kw = .kw_exec, .name = "exec", .b = .{ .signature = "func exec(command: string, args: list) -> map", .doc = "Runs command, waits for exit, and returns {stdout, stderr, exit_code}." } },
    .{ .kw = .kw_now, .name = "now", .b = .{ .signature = "func now() -> float", .doc = "The current wall-clock time, as seconds since the Unix epoch." } },
    .{ .kw = .kw_random, .name = "random", .b = .{ .signature = "func random() -> float\nfunc random(start: int, end: int) -> int", .doc = "A uniform float in [0, 1), or a uniform int in [start, end)." } },
    .{ .kw = .kw_ord, .name = "ord", .b = .{ .signature = "func ord(string) -> int", .doc = "The byte value (0..255) of a single-byte string." } },
    .{ .kw = .kw_chr, .name = "chr", .b = .{ .signature = "func chr(int) -> string", .doc = "The inverse of ord: the length-1 string whose single byte is the given int (0..255)." } },
    .{ .kw = .kw_join, .name = "join", .b = .{ .signature = "func join(list, sep: string) -> string", .doc = "Every element of list (each a string) concatenated, with sep between each pair." } },
    .{ .kw = .kw_args, .name = "args", .b = .{ .signature = "args : list", .doc = "The program's own command-line arguments, as a fresh list of strings." } },
    .{ .kw = .kw_stdin, .name = "stdin", .b = .{ .signature = "stdin : stream", .doc = "The standard input stream." } },
    .{ .kw = .kw_stdout, .name = "stdout", .b = .{ .signature = "stdout : stream", .doc = "The standard output stream." } },
    .{ .kw = .kw_stderr, .name = "stderr", .b = .{ .signature = "stderr : stream", .doc = "The standard error stream." } },
};

/// `kw`'s builtin doc entry, or `null` if `kw` isn't a documented builtin
/// (an ordinary syntax keyword like `if`/`while`/`func`, or a scalar
/// `<type>` keyword — `bool`/`string`/`map`/`list` — with no call form of
/// its own).
pub fn lookup(kw: lexer.TokenType) ?Builtin {
    for (table) |entry| {
        if (entry.kw == kw) return entry.b;
    }
    return null;
}

/// Same as `lookup`, keyed by the keyword's source spelling — completion.zig
/// only has the name (its own `keywords` list mixes builtins in with plain
/// syntax keywords), not a `TokenType`.
pub fn lookupByName(name: []const u8) ?Builtin {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.b;
    }
    return null;
}

/// Whether `kw` is ambiguous with a `<type>` keyword use — true only for
/// `int`/`float` (design note 3r). resolve.zig only resolves these to a
/// `Builtin` when the token is immediately followed by '(', so a
/// var-declaration's `int x` doesn't get a misleading call-form hover.
pub fn requiresCallParen(kw: lexer.TokenType) bool {
    return kw == .kw_int or kw == .kw_float;
}

// ---- Tests -------------------------------------------------------------

const testing = std.testing;

test "lookup finds ord and chr's signatures" {
    try testing.expect(lookup(.kw_ord) != null);
    try testing.expectEqualStrings("func ord(string) -> int", lookup(.kw_ord).?.signature);
    try testing.expect(lookup(.kw_chr) != null);
    try testing.expectEqualStrings("func chr(int) -> string", lookup(.kw_chr).?.signature);
}

test "lookup returns null for a plain syntax keyword" {
    try testing.expect(lookup(.kw_if) == null);
    try testing.expect(lookup(.kw_func) == null);
}

test "lookup returns null for a scalar type keyword with no call form" {
    try testing.expect(lookup(.kw_bool) == null);
    try testing.expect(lookup(.kw_string) == null);
    try testing.expect(lookup(.kw_map) == null);
    try testing.expect(lookup(.kw_list) == null);
}

test "lookupByName mirrors lookup by the keyword's spelling" {
    try testing.expect(lookupByName("listDir") != null);
    try testing.expect(lookupByName("nonexistent") == null);
}

test "requiresCallParen is true only for int/float" {
    try testing.expect(requiresCallParen(.kw_int));
    try testing.expect(requiresCallParen(.kw_float));
    try testing.expect(!requiresCallParen(.kw_ord));
    try testing.expect(!requiresCallParen(.kw_len));
}
