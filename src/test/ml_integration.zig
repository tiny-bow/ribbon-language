const std = @import("std");
const log = std.log.scoped(.ml_integration);
const ribbon = @import("ribbon_language");
const SyntaxTree = ribbon.analysis.SyntaxTree;
const common = ribbon.common;
const ml = ribbon.meta_language;

// test {
//     std.debug.print("ml_integration", .{});
// }

test "module_cst" {
    const input =
        \\module graphics.
        \\    sources =
        \\        "renderer.rib",
        \\        "shaders/",
        \\        "mesh/",
        \\    
        \\    dependencies =
        \\        std = package "core@0.1.0"
        \\        gpu = github "tiny-bow/rgpu#W7SI6GbejPFWIbAPfm6uS623SVD"
        \\        linalg = path "../linear-algebra"
        \\   
        \\    extensions =
        \\        std/macros,
        \\        std/dsl/operator-precedence,
        \\        gpu/descriptors,
        \\        linalg/vector-ops,
        \\    
    ;

    const expect =
        \\⟨𝓶𝓸𝓭 graphics ⌊⟨𝓼𝓮𝓺 ⟨𝓼𝓮𝓽 sources ⌊⟨𝓵𝓲𝓼𝓽 "renderer.rib" "shaders/" "mesh/"⟩⌋⟩ ⟨𝓼𝓮𝓽 dependencies ⌊⟨𝓼𝓮𝓺 ⟨𝓼𝓮𝓽 std ⟨𝓪𝓹𝓹 package "core@0.1.0"⟩⟩ ⟨𝓼𝓮𝓽 gpu ⟨𝓪𝓹𝓹 github "tiny-bow/rgpu#W7SI6GbejPFWIbAPfm6uS623SVD"⟩⟩ ⟨𝓼𝓮𝓽 linalg ⟨𝓪𝓹𝓹 path "../linear-algebra"⟩⟩⟩⌋⟩ ⟨𝓼𝓮𝓽 extensions ⌊⟨𝓵𝓲𝓼𝓽 std/macros std/dsl/operator-precedence gpu/descriptors linalg/vector-ops⟩⌋⟩⟩⌋⟩
    ;

    var parser = try ml.Cst.getRModParser(std.testing.allocator, .{}, "test", input);
    var syn = try parser.parse() orelse {
        log.err("Failed to parse source", .{});
        return error.NullCst;
    };
    defer syn.deinit(std.testing.allocator);

    var writer_buf = [1]u8{0} ** (1024 * 16);
    var writer = std.io.Writer.fixed(&writer_buf);

    try ml.Cst.dumpSExprs(input, &writer, &syn);

    log.debug("CST: {f}\nSExprs:\n{s}\n", .{ syn, writer.buffered() });

    try std.testing.expectEqualStrings(expect, writer.buffered());
}

test "module_parse" {
    const input =
        \\module graphics.
        \\    sources =
        \\        "renderer.rib",
        \\        "shaders/",
        \\
        \\    dependencies =
        \\        std = package "core@0.1.0"
        \\        gpu = github "tiny-bow/rgpu#W7SI6GbejPFWIbAPfm6uS623SVD"
        \\        linalg = path "../linear-algebra"
        \\
        \\    extensions =
        \\        std/macros,
        \\        gpu/descriptors,
        \\
    ;

    var def = try ml.RMod.parseSource(std.testing.allocator, .{}, "test.rmod", input) orelse return error.NullCst;
    defer def.deinit(std.testing.allocator);

    // Verify name
    try std.testing.expectEqualStrings("graphics", def.name);

    // Verify sources
    try std.testing.expectEqual(@as(usize, 2), def.sources.items.len);
    try std.testing.expectEqualStrings("renderer.rib", def.sources.items[0]);
    try std.testing.expectEqualStrings("shaders/", def.sources.items[1]);

    // Verify dependencies
    try std.testing.expectEqual(@as(usize, 3), def.dependencies.count());

    const std_dep = def.dependencies.get("std").?;
    try std.testing.expect(std_dep == .package);
    try std.testing.expectEqualStrings("core@0.1.0", std_dep.package);

    const gpu_dep = def.dependencies.get("gpu").?;
    try std.testing.expect(gpu_dep == .github);
    try std.testing.expectEqualStrings("tiny-bow/rgpu#W7SI6GbejPFWIbAPfm6uS623SVD", gpu_dep.github);

    const linalg_dep = def.dependencies.get("linalg").?;
    try std.testing.expect(linalg_dep == .path);
    try std.testing.expectEqualStrings("../linear-algebra", linalg_dep.path);

    // Verify extensions
    try std.testing.expectEqual(@as(usize, 2), def.extensions.items.len);
    try std.testing.expectEqualStrings("std/macros", def.extensions.items[0]);
    try std.testing.expectEqualStrings("gpu/descriptors", def.extensions.items[1]);
}

test "expr_parse" {
    try common.snapshotTest(.use_log("expr"), struct {
        pub fn testExpr(input: []const u8, expect: []const u8) !void {
            _ = .{ input, expect };
            var parser = try ml.Cst.getRmlParser(std.testing.allocator, .{}, "test", input);
            var syn = try parser.parse() orelse {
                log.err("Failed to parse source", .{});
                return error.NullCst;
            };
            defer syn.deinit(std.testing.allocator);

            var expr = try ml.Expr.parseCst(std.testing.allocator, input, &syn);
            defer expr.deinit(std.testing.allocator);

            log.info("input: {s}\nresult: {f}", .{ input, expr });

            var buf = std.io.Writer.Allocating.init(std.testing.allocator);
            defer buf.deinit();

            try buf.writer.print("{f}", .{expr});

            try std.testing.expectEqualStrings(expect, buf.written());
        }
    }.testExpr, &.{
        .{ .input = "1 + 2", .expect = "1 + 2" }, // 0
        .{ .input = "1 * 2", .expect = "1 * 2" }, // 1
        .{ .input = "1 + 2 + 3", .expect = "1 + 2 + 3" }, // 2
        .{ .input = "1 - 2 * 3", .expect = "1 - 2 * 3" }, // 3
        .{ .input = "1 * 2 + 3", .expect = "1 * 2 + 3" }, // 4
        .{ .input = "(1 + 2) * 3", .expect = "(1 + 2) * 3" }, // 5
        .{ .input = "1, 2, 3", .expect = "⟨ 1, 2, 3, ⟩" }, // 6
        .{ .input = "[1, 2, 3]", .expect = "[ 1, 2, 3, ]" }, // 7
        .{ .input = "(1, 2, 3,)", .expect = "(1, 2, 3)" }, // 8
        .{ .input = "(1, )", .expect = "(1,)" }, // 9
    });
}

test "cst_parse" {
    try common.snapshotTest(.use_log("cst"), struct {
        pub fn testCst(input: []const u8, expect: []const u8) !void {
            _ = .{ input, expect };
            var parser = try ml.Cst.getRmlParser(std.testing.allocator, .{}, "test", input);
            var syn = try parser.parse() orelse {
                log.err("Failed to parse source", .{});
                return error.BadEncoding;
            };
            defer syn.deinit(std.testing.allocator);

            const Data = struct { input: []const u8, syn: SyntaxTree };
            log.info("input: {s}\nresult: {f}", .{ input, std.fmt.Formatter(Data, struct {
                pub fn formatter(
                    data: Data,
                    writer: *std.io.Writer,
                ) error{WriteFailed}!void {
                    ml.Cst.dumpSExprs(data.input, writer, &data.syn) catch |err| {
                        log.err("Failed to dump CST S-expr: {s}", .{@errorName(err)});
                        return error.WriteFailed;
                    };
                }
            }.formatter){ .data = .{ .input = input, .syn = syn } } });

            var buf = std.io.Writer.Allocating.init(std.testing.allocator);
            defer buf.deinit();

            try ml.Cst.dumpSExprs(input, &buf.writer, &syn);

            try std.testing.expectEqualStrings(expect, buf.written());
        }
    }.testCst, &.{
        .{ .input = "\n1", .expect = "1" }, // 0
        .{ .input = "()", .expect = "()" }, // 1
        .{ .input = "a b", .expect = "⟨𝓪𝓹𝓹 a b⟩" }, // 2
        .{ .input = "a b c", .expect = "⟨𝓪𝓹𝓹 a b c⟩" }, // 3
        .{ .input = "1 * a b", .expect = "⟨* 1 ⟨𝓪𝓹𝓹 a b⟩⟩" }, // 4
        .{ .input = "1 * (a b)", .expect = "⟨* 1 (⟨𝓪𝓹𝓹 a b⟩)⟩" }, // 5
        .{ .input = "1 + 2", .expect = "⟨+ 1 2⟩" }, // 6
        .{ .input = "1 * 2", .expect = "⟨* 1 2⟩" }, // 7
        .{ .input = "1 + 2 + 3", .expect = "⟨+ ⟨+ 1 2⟩ 3⟩" }, // 8
        .{ .input = "1 - 2 - 3", .expect = "⟨- ⟨- 1 2⟩ 3⟩" }, // 9
        .{ .input = "1 * 2 * 3", .expect = "⟨* ⟨* 1 2⟩ 3⟩" }, // 10
        .{ .input = "1 / 2 / 3", .expect = "⟨/ ⟨/ 1 2⟩ 3⟩" }, // 11
        .{ .input = "1 + 2 * 3", .expect = "⟨+ 1 ⟨* 2 3⟩⟩" }, // 12
        .{ .input = "a b := x y", .expect = "⟨𝓭𝓮𝓬𝓵 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 x y⟩⟩" }, // 13
        .{ .input = "a b = x y", .expect = "⟨𝓼𝓮𝓽 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 x y⟩⟩" }, // 14
        .{ .input = "x y\nz w", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 x y⟩ ⟨𝓪𝓹𝓹 z w⟩⟩" }, // 15
        .{ .input = "x y\nz w\n", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 x y⟩ ⟨𝓪𝓹𝓹 z w⟩⟩" }, // 16
        .{ .input = "a b\nc d\ne f\n", .expect = "⟨𝓼𝓮𝓺 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 c d⟩ ⟨𝓪𝓹𝓹 e f⟩⟩" }, // 17
        .{ .input = "1\n2\n3\n4\n", .expect = "⟨𝓼𝓮𝓺 1 2 3 4⟩" }, // 18
        .{ .input = "1;2;3;4;", .expect = "⟨𝓼𝓮𝓺 1 2 3 4⟩" }, // 19
        .{ .input = "1 *\n  2 + 3\n", .expect = "⟨* 1 ⌊⟨+ 2 3⟩⌋⟩" }, // 20
        .{ .input = "1 *\n  2 + 3\n4", .expect = "⟨𝓼𝓮𝓺 ⟨* 1 ⌊⟨+ 2 3⟩⌋⟩ 4⟩" }, // 21
        .{ .input = "foo(1) * 3 * 2 +\n  1 * 2\nalert \"hello world\" + 2\ntest 2 3\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ ⌊⟨* 1 2⟩⌋⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello world\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 22
        .{ .input = "foo(1) * 3 * 2 + (1 * 2); alert \"hello world\" + 2; test 2 3;", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ (⟨* 1 2⟩)⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello world\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 23
        .{ .input = "foo(1) * 3 * 2 + (1 * 2);\nalert \"hello world\" + 2;\ntest 2 3;\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ (⟨* 1 2⟩)⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello world\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 24
        .{ .input = "\n\n \nfoo(1) * 3 * 2 +\n  1 * 2;\nalert \"hello\nworld\" + 2;\ntest 2 3;\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ ⌊⟨* 1 2⟩⌋⟩ ⟨+ ⟨𝓪𝓹𝓹 alert \"hello\nworld\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩" }, // 25
        .{ .input = "incr := fun x.\n  y := x + 1\n  y = y * 2\n  3 / y\n", .expect = "⟨𝓭𝓮𝓬𝓵 incr ⟨λ x ⌊⟨𝓼𝓮𝓺 ⟨𝓭𝓮𝓬𝓵 y ⟨+ x 1⟩⟩ ⟨𝓼𝓮𝓽 y ⟨* y 2⟩⟩ ⟨/ 3 y⟩⟩⌋⟩⟩" }, // 26
        .{ .input = "fun x y z. x * y * z", .expect = "⟨λ ⟨𝓪𝓹𝓹 x y z⟩ ⟨* ⟨* x y⟩ z⟩⟩" }, // 27
        .{ .input = "x, y, z", .expect = "⟨𝓵𝓲𝓼𝓽 x y z⟩" }, // 28
        .{ .input = "fun x, y, z. x, y, z", .expect = "⟨λ ⟨𝓵𝓲𝓼𝓽 x y z⟩ ⟨𝓵𝓲𝓼𝓽 x y z⟩⟩" }, // 29
        .{ .input = "fun x (y, z). Set [\n  x,\n  y,\n  z\n]", .expect = "⟨λ ⟨𝓪𝓹𝓹 x (⟨𝓵𝓲𝓼𝓽 y z⟩)⟩ ⟨𝓪𝓹𝓹 Set [⌊⟨𝓵𝓲𝓼𝓽 x y z⟩⌋]⟩⟩" }, // 30
        .{ .input = "fun x (y, z). Set\n  [ x\n  , y\n  , z\n  ]", .expect = "⟨λ ⟨𝓪𝓹𝓹 x (⟨𝓵𝓲𝓼𝓽 y z⟩)⟩ ⟨𝓪𝓹𝓹 Set ⌊[⟨𝓵𝓲𝓼𝓽 x y z⟩]⌋⟩⟩" }, // 31
        .{ .input = "x := y := z", .expect = error.UnexpectedInput }, // 32
        .{ .input = "x = y = z", .expect = error.UnexpectedInput }, // 33
        .{ .input = "x = y := z", .expect = error.UnexpectedInput }, // 34
        .{ .input = "x := y = z", .expect = error.UnexpectedInput }, // 35
        .{ .input = "x == y != z", .expect = error.UnexpectedInput }, // 36
        .{ .input = "not x and y", .expect = "⟨and ⟨not x⟩ y⟩" }, // 37
        .{ .input = "f x and - y == not w or z + 1", .expect = "⟨== ⟨and ⟨𝓪𝓹𝓹 f x⟩ ⟨- y⟩⟩ ⟨or ⟨not w⟩ ⟨+ z 1⟩⟩⟩" }, // 38
        .{ .input = "x-x", .expect = "x-x" }, // 39
        .{ .input = "- x", .expect = "⟨- x⟩" }, // 40
        .{ .input = "+ x - y", .expect = "⟨- ⟨+ x⟩ y⟩" }, // 41
        .{ .input = "'h'", .expect = "'h'" }, // 42
        .{ .input = "'\\r'", .expect = "'\r'" }, // 43
        .{ .input = "'\\n'", .expect = "'\n'" }, // 44
        .{ .input = "'\\0'", .expect = "'\x00'" }, // 45
        .{ .input = "'x", .expect = "'x" }, // 46
        .{ .input = "'\\0", .expect = error.UnexpectedEof }, // 47
        .{ .input = "'x + 'y", .expect = "⟨+ 'x 'y⟩" }, // 48
    });
}

test "value_basics" {
    {
        var x: f64 = -10.0;

        while (x < 10.0) : (x += 0.1) {
            const y = ml.Value.from(x);
            try std.testing.expect(y.isNumber());
            try std.testing.expect(!y.isData());
            try std.testing.expect(y.isF64());
            try std.testing.expect(!y.isNaN());
            try std.testing.expectEqual(x, y.as(f64));
        }
    }

    {
        var x: i48 = -1000;

        while (x < 1000) : (x += 1) {
            const y = ml.Value.from(x);
            try std.testing.expect(y.isNumber());
            try std.testing.expect(!y.isData());
            try std.testing.expect(y.is(i48));
            try std.testing.expect(y.isNaN());
            try std.testing.expectEqual(x, y.as(i48));
        }
    }

    {
        const a: [:0]const u8 = "test_string";

        const b: [:0]align(8) u8 = try std.testing.allocator.allocWithOptions(u8, a.len, .fromByteUnits(8), 0);
        defer std.testing.allocator.free(b);

        @memcpy(b, a);

        const x = ml.Value.from(b.ptr);
        try std.testing.expect(x.isData());
        try std.testing.expect(!x.isObject());
        try std.testing.expect(x.isSymbol());
        try std.testing.expect(x.isNaN());
        try std.testing.expectEqualStrings(b, std.mem.span(x.asSymbol() orelse return error.NullSymbol));
    }

    {
        var a: usize = 1;

        const x = ml.Value.from(@as(*align(8) anyopaque, &a));
        try std.testing.expect(x.isData());
        try std.testing.expect(x.isObject());
        try std.testing.expect(x.isForeign());
        try std.testing.expect(x.isNaN());
        try std.testing.expectEqual(@intFromPtr(&a), @intFromPtr(x.asObject() orelse return error.NullObject));
    }
}
