//! Fuzz target for the lexer -> parser pipeline (TODO.md #19). Feeds
//! arbitrary bytes through `Lexer.tokenizeAll` and `Parser.parseProgram`
//! and asserts the pair never panics or crashes on any input — a lex or
//! parse error is an expected, ordinary outcome for garbage input, so only
//! a panic/crash (an assertion failure, an out-of-bounds read, a safety-
//! checked UB trap, ...) counts as a finding here.
//!
//! Under plain `zig build test`/`test-fuzz`, `std.testing.fuzz` just runs
//! `fuzzOne` once against an empty input as a smoke test; real mutation-
//! based fuzzing needs `zig build test-fuzz --fuzz`, which starts the
//! coverage-guided fuzzer and its web UI (see tests/README.md).

const std = @import("std");
const butter = @import("butter");

test "fuzz: lexer -> parser pipeline never panics" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Mostly printable ASCII (where legal Butter source lives) with a
    // healthy dose of arbitrary bytes and lexically-significant characters
    // (space/tab/CR/LF, NUL) layered on top, matching the weighting
    // std.zig.tokenizer's own fuzz target uses for the same reason: a
    // pile of random bytes rarely gets past the first token, so bias
    // toward inputs that actually exercise identifiers/keywords/numbers/
    // strings/operators before falling apart.
    var source_buf: [4096]u8 = undefined;
    const len = smith.sliceWeightedBytes(&source_buf, &.{
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .rangeAtMost(u8, 0x20, 0x7e, 4),
        .rangeAtMost(u8, 0x00, 0x1f, 1),
        .value(u8, 0, 4),
        .value(u8, ' ', 6),
        .rangeAtMost(u8, '\t', '\n', 6),
        .value(u8, '\r', 3),
        .value(u8, '"', 4),
        .value(u8, '\\', 4),
    });
    const source = source_buf[0..len];

    const allocator = std.testing.allocator;

    var lex = butter.lexer.Lexer.init(source);
    const tokens = lex.tokenizeAll(allocator) catch return;
    defer allocator.free(tokens);

    var parser = butter.parser.Parser.init(allocator, tokens);
    defer parser.deinit();
    _ = parser.parseProgram() catch return;
}
