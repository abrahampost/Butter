//! Integration tests for the Butter language: each case is a complete
//! .butter program (tests/cases/<name>.butter) run end to end through the
//! same loader -> compiler -> VM pipeline the CLI uses, with everything it
//! prints compared byte for byte against tests/cases/<name>.expected.
//!
//! Unlike src/*.zig's unit tests, these never touch a Chunk, AST, or
//! opcode by hand — only Butter source text in and printed output out —
//! so they exercise the language as a user's program actually experiences
//! it, and catch regressions a single stage's own unit tests might miss.
//!
//! Cases are standard textbook programs/problems (FizzBuzz, factorial,
//! Fibonacci, sorting, a sieve, gcd/lcm, binary search, Collatz, array
//! stats, and the quadratic formula via the bundled math stdlib) chosen to
//! exercise recursion, loops, fixed/generic arrays, bool arrays, and
//! imports together, the way a real program would.

const std = @import("std");
const butter = @import("butter");

/// Runs `source` as a Butter program and returns everything it printed.
/// Caller owns the returned slice.
fn run(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return runWithArgs(allocator, source, &.{});
}

/// Same as `run`, but with `args` available to the program as `args`
/// (ISA.bnf's PUSH_ARGS) instead of the default empty list.
fn runWithArgs(allocator: std.mem.Allocator, source: []const u8, args: []const []const u8) ![]u8 {
    var loader = butter.module.Loader.init(allocator, std.testing.io, std.Io.Dir.cwd());
    defer loader.deinit();

    const entry = try loader.loadEntry(source, "<test>", ".");
    const modules = try butter.module.toCompilerUnits(loader.allocator(), loader.order.items, entry);

    var compiler = butter.compiler.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(modules.entry_index, modules.units);
    defer compiled.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var vm = butter.vm.Vm.init(allocator);
    try vm.run(&compiled, .{ .out = &out.writer, .args = args });

    return out.toOwnedSlice();
}

/// Runs tests/cases/<name>.butter and asserts its output matches
/// tests/cases/<name>.expected exactly.
fn expectCaseOutput(comptime name: []const u8) !void {
    const allocator = std.testing.allocator;
    const source = @embedFile("cases/" ++ name ++ ".butter");
    const expected = @embedFile("cases/" ++ name ++ ".expected");

    const actual = try run(allocator, source);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

/// Same as `expectCaseOutput`, but running with `args` available to the
/// program as `args`.
fn expectCaseOutputWithArgs(comptime name: []const u8, args: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const source = @embedFile("cases/" ++ name ++ ".butter");
    const expected = @embedFile("cases/" ++ name ++ ".expected");

    const actual = try runWithArgs(allocator, source, args);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

/// Runs `source` with `args` and returns both everything it printed and
/// the process exit code it requested via `exit` (ISA.bnf's EXIT) — `null`
/// for a program that falls off the end (an ordinary HALT) without ever
/// calling `exit` itself. Caller owns `output`.
fn runCapture(allocator: std.mem.Allocator, source: []const u8, args: []const []const u8) !struct { output: []u8, exit_code: ?u8 } {
    var loader = butter.module.Loader.init(allocator, std.testing.io, std.Io.Dir.cwd());
    defer loader.deinit();

    const entry = try loader.loadEntry(source, "<test>", ".");
    const modules = try butter.module.toCompilerUnits(loader.allocator(), loader.order.items, entry);

    var compiler = butter.compiler.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = try compiler.compileModules(modules.entry_index, modules.units);
    defer compiled.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var vm = butter.vm.Vm.init(allocator);
    try vm.run(&compiled, .{ .out = &out.writer, .args = args });

    return .{ .output = try out.toOwnedSlice(), .exit_code = vm.exit_code };
}

test "fizzbuzz: Fizz/Buzz/FizzBuzz/number for 1..20" {
    try expectCaseOutput("fizzbuzz");
}

test "factorial: 0! through 10!, computed iteratively" {
    try expectCaseOutput("factorial");
}

test "fibonacci: fib(0) through fib(9), computed recursively" {
    try expectCaseOutput("fibonacci");
}

test "bubble_sort: sorts a fixed-size array ascending in place" {
    try expectCaseOutput("bubble_sort");
}

test "sieve_of_eratosthenes: primes up to 30 via a bool array" {
    try expectCaseOutput("sieve_of_eratosthenes");
}

test "gcd_lcm: greatest common divisor and least common multiple" {
    try expectCaseOutput("gcd_lcm");
}

test "binary_search: found and not-found cases over a sorted array" {
    try expectCaseOutput("binary_search");
}

test "collatz: step counts for the first 20 positive integers" {
    try expectCaseOutput("collatz");
}

test "array_stats: sum, float average, min, and max of an array" {
    try expectCaseOutput("array_stats");
}

test "quadratic_formula: roots via the bundled math stdlib's sqrt/pow" {
    try expectCaseOutput("quadratic_formula");
}

test "string_indexing: hand-rolled key=value;... parsing via s[i]/s[a..b]" {
    try expectCaseOutput("string_indexing");
}

test "strings: concatenation and lexicographic ordering, incl. a bubble sort" {
    try expectCaseOutput("strings");
}

test "parse_numbers: int(...)/float(...) parse strings into numbers" {
    try expectCaseOutput("parse_numbers");
}

test "escapes: \\n/\\t/\\\\/\\\" decode inside string literals" {
    try expectCaseOutput("escapes");
}

test "args: the bare 'args' keyword sees the host's argv, in order" {
    try expectCaseOutputWithArgs("args", &.{ "alpha", "beta", "gamma" });
}

test "args: with no host args, 'args' is an empty list" {
    const allocator = std.testing.allocator;
    const actual = try run(allocator, "print len(args)\n");
    defer allocator.free(actual);
    try std.testing.expectEqualStrings("0\n", actual);
}

// ---- exit_code: a grep-style tool built on `args` + `exit` ------------
//
// Same case source (tests/cases/exit_code.butter) run three ways — found,
// not found, no argument at all — each asserting both what it printed and
// the process exit code it requested, the way a shell script driving a
// real `grep`/`diff`-style CLI tool would actually observe it.

test "exit_code: the needle is found, prints a match and exits 0" {
    const allocator = std.testing.allocator;
    const source = @embedFile("cases/exit_code.butter");

    const result = try runCapture(allocator, source, &.{"cat"});
    defer allocator.free(result.output);

    try std.testing.expectEqualStrings("found: cat\n", result.output);
    try std.testing.expectEqual(@as(?u8, 0), result.exit_code);
}

test "exit_code: the needle is absent, prints nothing found and exits 1" {
    const allocator = std.testing.allocator;
    const source = @embedFile("cases/exit_code.butter");

    const result = try runCapture(allocator, source, &.{"shark"});
    defer allocator.free(result.output);

    try std.testing.expectEqualStrings("not found: shark\n", result.output);
    try std.testing.expectEqual(@as(?u8, 1), result.exit_code);
}

test "exit_code: no needle given, prints usage and exits 2" {
    const allocator = std.testing.allocator;
    const source = @embedFile("cases/exit_code.butter");

    const result = try runCapture(allocator, source, &.{});
    defer allocator.free(result.output);

    try std.testing.expectEqualStrings("usage: exit_code <needle>\n", result.output);
    try std.testing.expectEqual(@as(?u8, 2), result.exit_code);
}

// ---- Error-path cases ------------------------------------------------
//
// Programs that are expected to fail: no .expected file (there is nothing
// printed to check), just the RuntimeError the VM must report.

test "division by zero is a runtime error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.DivisionByZero, run(allocator, "print 1 / 0\n"));
}

test "indexing past an array's length is a runtime error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.IndexOutOfBounds, run(allocator, "int[3] a\nprint a[5]\n"));
}

test "indexing past a string's length is a runtime error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.IndexOutOfBounds, run(allocator, "string s := \"hi\"\nprint s[5]\n"));
}

test "slicing a string with start > end is a runtime error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.IndexOutOfBounds, run(allocator, "string s := \"hi\"\nprint s[2..0]\n"));
}

test "assigning through a string index is a runtime error (strings are read-only)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TypeMismatch, run(allocator, "string s := \"hi\"\ns[0] := \"X\"\n"));
}

test "int(...) on a malformed string is a runtime error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NumberParseFailed, run(allocator, "print int(\"not a number\")\n"));
}

test "float(...) on a non-string value is a runtime error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.TypeMismatch, run(allocator, "print float(true)\n"));
}

test "int(x) on a float outside i64's range is a runtime Overflow" {
    // Butter float literals have no exponent syntax (GRAMMAR.bnf section 1),
    // so this spells the out-of-range magnitude out in plain decimal.
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.Overflow, run(allocator, "print int(99999999999999999999999999999999.0)\n"));
}

// ---- Compile errors: reported line number ------------------------------
//
// The compiler stamps every diagnostic with the source line of the
// statement it failed on (compiler.zig's `current_line`/`fail`). These
// drive that line-tracking through the same loader -> compiler pipeline
// `run` uses, but stop short of the VM, and check *which* line lands in
// the diagnostic — not just that compilation failed — since a wrong-line
// diagnostic is a distinct, less obvious bug from a wrong-error diagnostic.

/// Compiles `source` expecting it to fail with `expected`, then asserts
/// the diagnostic's line number is `expected_line`.
fn expectCompileErrorAtLine(
    allocator: std.mem.Allocator,
    source: []const u8,
    expected: butter.compiler.SemanticError,
    expected_line: usize,
) !void {
    var loader = butter.module.Loader.init(allocator, std.testing.io, std.Io.Dir.cwd());
    defer loader.deinit();

    const entry = try loader.loadEntry(source, "<test>", ".");
    const modules = try butter.module.toCompilerUnits(loader.allocator(), loader.order.items, entry);

    var compiler = butter.compiler.Compiler.init(allocator);
    defer compiler.deinit();

    try std.testing.expectError(expected, compiler.compileModules(modules.entry_index, modules.units));

    const diag = compiler.diagnostic orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqual(expected_line, diag.line);
}

test "compile error line: undefined variable reports the line it's used on, not line 1" {
    const allocator = std.testing.allocator;
    try expectCompileErrorAtLine(
        allocator,
        "int a := 1\nint b := 2\nprint a + nope\n",
        error.UndefinedVariable,
        3,
    );
}

test "compile error line: error nested inside an if/while/for reports the inner statement's own line, not the block's" {
    const allocator = std.testing.allocator;
    try expectCompileErrorAtLine(
        allocator,
        "int i\n" ++
            "while true {\n" ++
            "    print 1\n" ++
            "    print nope\n" ++
            "}\n",
        error.UndefinedVariable,
        4,
    );
}

test "compile error line: error in a function body reports the line within that function, not the call site" {
    const allocator = std.testing.allocator;
    try expectCompileErrorAtLine(
        allocator,
        "func greet() -> int {\n" ++
            "    print \"hi\"\n" ++
            "    print missing\n" ++
            "}\n" ++
            "greet()\n",
        error.UndefinedVariable,
        3,
    );
}

test "compile error line: error in the second of two functions doesn't inherit the line from the first" {
    const allocator = std.testing.allocator;
    try expectCompileErrorAtLine(
        allocator,
        "func first() -> int {\n" ++
            "    print 1\n" ++
            "    print 2\n" ++
            "    return 3\n" ++
            "}\n" ++
            "func second() -> int {\n" ++
            "    print oops\n" ++
            "    return 0\n" ++
            "}\n" ++
            "first()\n",
        error.UndefinedVariable,
        7,
    );
}

test "compile error line: array length mismatch reports the declaration's own line" {
    const allocator = std.testing.allocator;
    try expectCompileErrorAtLine(
        allocator,
        "int x := 1\nint y := 2\nint[3] a := [1, 2]\n",
        error.ArrayLengthMismatch,
        3,
    );
}

test "compile error line: duplicate function declaration reports the second declaration's line, not line 0" {
    const allocator = std.testing.allocator;
    try expectCompileErrorAtLine(
        allocator,
        "func f() -> int {\n" ++
            "    print 1\n" ++
            "    return 1\n" ++
            "}\n" ++
            "func f() -> int {\n" ++
            "    print 2\n" ++
            "    return 2\n" ++
            "}\n",
        error.DuplicateFunction,
        5,
    );
}
