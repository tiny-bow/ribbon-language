const std = @import("std");
const log = std.log.scoped(.ml_integration);
const ribbon = @import("ribbon_language");
const SyntaxTree = ribbon.analysis.SyntaxTree;
const common = ribbon.common;
const analysis = ribbon.analysis;
const ml = ribbon.meta_language;
const PP = common.PrettyPrinter;

// test {
//     std.debug.print("ml_integration", .{});
// }

test "rpkg_parse" {
    const file_text = @embedFile("min.rpkg");

    var result = try ml.RPkg.parseSource(
        std.testing.allocator,
        .{},
        "min.rpkg",
        file_text,
    ) orelse {
        log.err("Failed to parse RPkg", .{});
        return error.NullRPkg;
    };
    defer result.deinit(std.testing.allocator);

    var buffer: [1024]u8 = undefined;
    const fmt = std.fmt.bufPrint(&buffer, "{f}", .{result.rendered(std.testing.allocator, .{})}) catch |err| {
        log.err("Failed to format RPkg: {s}", .{@errorName(err)});
        return err;
    };
    try std.testing.expectEqualStrings(
        \\package mvp-test.
        \\    version = 1.0.0
        \\    dependencies =
        \\        std = pkg "base@0.1.0"
        \\        rg = git "https://github.com/tiny-bow/rg#8c22c3cb20d09fe380999c5d2b5026cb60c9ead2"
        \\    modules =
        \\        module text (0).
        \\            visibility = internal
        \\            inputs =
        \\                "./text.rib"
        \\                "./text/"
        \\            imports =
        \\                std.core as std
        \\                rg.case-fold
        \\            extensions = rg.syntax.utf32-literals
        \\        unresolved graphics.
        \\            visibility = exported
        \\            file_path = ./min.rmod
    , fmt);
}

test "rmod_parse" {
    const file_text = @embedFile("min.rmod");

    var result = try ml.RMod.parseSource(
        std.testing.allocator,
        .{},
        "min.rmod",
        file_text,
    ) orelse {
        log.err("Failed to parse RMod", .{});
        return error.NullRMod;
    };
    defer result.deinit(std.testing.allocator);

    var buffer: [1024]u8 = undefined;
    const fmt = std.fmt.bufPrint(&buffer, "{f}", .{result.rendered(std.testing.allocator, .{})}) catch |err| {
        log.err("Failed to format RMod: {s}", .{@errorName(err)});
        return err;
    };

    try std.testing.expectEqualStrings(
        \\module (0).
        \\    visibility = internal
        \\    inputs = "./graphics.rib"
        \\    imports =
        \\        std.core
        \\        std.gpu
        \\    extensions = std.syntax.spirv-annotations
    , fmt);
}

test "expr_parse" {
    try common.snapshotTest(.use_log("expr"), struct {
        pub fn testExpr(input: []const u8, expect: []const u8) !void {
            var parser = try ml.Cst.getRmlParser(std.testing.allocator, .{}, "test", input);
            defer parser.deinit();

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
        .{ .input = "foo.bar", .expect = "foo.bar" }, // 10
        .{ .input = "foo.bar.baz", .expect = "foo.bar.baz" }, // 11
        .{ .input = "(foo bar).baz", .expect = "(foo bar).baz" }, // 12
        .{ .input = "foo.bar baz", .expect = "foo.bar baz" }, // 13
        .{ .input = "foo + bar.baz", .expect = "foo + bar.baz" }, // 14
        .{ .input = "0.1 + 2.3", .expect = "0.1 + 2.3" }, // 15
        .{ .input = "foo 0.1 + 2.0e3", .expect = "foo 0.1 + 2000" }, // 16
        .{ .input = "2.0e-10", .expect = "0.0000000002" }, // 17
        .{ .input = "2.0e+10", .expect = "20000000000" }, // 18
        .{ .input = "2.foo", .expect = "2.foo" }, // 19
        .{ .input = "foo.3", .expect = "foo.3" }, // 20
    });
}

test "cst_parse" {
    try common.snapshotTest(.use_log("cst"), struct {
        pub fn testCst(input: []const u8, expect: []const u8) !void {
            var parser = try ml.Cst.getRmlParser(std.testing.allocator, .{}, "test", input);
            defer parser.deinit();

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
        .{ .input = "a b = x y", .expect = "⟨𝓪𝓼𝓼𝓲𝓰𝓷 ⟨𝓪𝓹𝓹 a b⟩ ⟨𝓪𝓹𝓹 x y⟩⟩" }, // 14
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
        .{ .input = "\n\n \nfoo(1) * 3 * 2 +\n  1 * 2;\nalert \"hello\nworld\" + 2;\ntest 2 3;\n", .expect = "⟨𝓼𝓮𝓺 ⟨+ ⟨* ⟨* ⟨𝓪𝓹𝓹 foo (1)⟩ 3⟩ 2⟩ ⌊⟨* 1 2⟩⌋⟩ ⟨𝓼𝓮𝓺 ⟨+ ⟨𝓪𝓹𝓹 alert \"hello\nworld\"⟩ 2⟩ ⟨𝓪𝓹𝓹 test 2 3⟩⟩⟩" }, // 25
        .{ .input = "incr := fun x.\n  y := x + 1\n  y = y * 2\n  3 / y\n", .expect = "⟨𝓭𝓮𝓬𝓵 incr ⟨λ x ⌊⟨𝓼𝓮𝓺 ⟨𝓭𝓮𝓬𝓵 y ⟨+ x 1⟩⟩ ⟨𝓪𝓼𝓼𝓲𝓰𝓷 y ⟨* y 2⟩⟩ ⟨/ 3 y⟩⟩⌋⟩⟩" }, // 26
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
        .{ .input = "foo.bar", .expect = "⟨𝓶𝓮𝓶𝓫𝓮𝓻 foo bar⟩" }, // 49
        .{ .input = "foo.bar.baz", .expect = "⟨𝓶𝓮𝓶𝓫𝓮𝓻 ⟨𝓶𝓮𝓶𝓫𝓮𝓻 foo bar⟩ baz⟩" }, // 50
        .{ .input = "(foo bar).baz", .expect = "⟨𝓶𝓮𝓶𝓫𝓮𝓻 (⟨𝓪𝓹𝓹 foo bar⟩) baz⟩" }, // 51
        .{ .input = "foo.bar baz", .expect = "⟨𝓪𝓹𝓹 ⟨𝓶𝓮𝓶𝓫𝓮𝓻 foo bar⟩ baz⟩" }, // 52
        .{ .input = "foo + bar.baz", .expect = "⟨+ foo ⟨𝓶𝓮𝓶𝓫𝓮𝓻 bar baz⟩⟩" }, // 53
        .{ .input = "0.1", .expect = "0.1" }, // 54
        .{ .input = "123.456", .expect = "123.456" }, // 55
        .{ .input = ".456", .expect = error.UnexpectedToken }, // 56
        .{ .input = "123.", .expect = error.UnexpectedToken }, // 57
        .{ .input = "1.2.3", .expect = "⟨𝓶𝓮𝓶𝓫𝓮𝓻 1.2 3⟩" }, // 58
        .{ .input = "123.0e456", .expect = "123.0e456" }, // 59
        .{ .input = "0.0e+1", .expect = "0.0e+1" }, // 60
        .{ .input = "0.0e-1", .expect = "0.0e-1" }, // 61
        .{ .input = "foo.1", .expect = "⟨𝓶𝓮𝓶𝓫𝓮𝓻 foo 1⟩" }, // 62
        .{ .input = "foo.1.2", .expect = "⟨𝓶𝓮𝓶𝓫𝓮𝓻 ⟨𝓶𝓮𝓶𝓫𝓮𝓻 foo 1⟩ 2⟩" }, // 62
        .{ .input = "test ;; i am a comment!", .expect = "test" }, // 63
        .{ .input = "foo; bar;\nbaz\nqux", .expect = "⟨𝓼𝓮𝓺 foo bar ⟨𝓼𝓮𝓺 baz qux⟩⟩" }, // 64
        .{ .input = "foo;\nbar;\nbaz\nqux", .expect = "⟨𝓼𝓮𝓺 foo bar ⟨𝓼𝓮𝓺 baz qux⟩⟩" }, // 65
    });
}

test "cst_attributes" {
    const check = struct {
        pub fn testCstAttributes(input: []const u8, expect: []const u8) !ml.Expr {
            var parser = try ml.Cst.getRmlParser(std.testing.allocator, .{}, "test", input);
            defer parser.deinit();

            var syn = try parser.parse() orelse {
                log.err("Failed to parse source", .{});
                return error.NullCst;
            };
            defer syn.deinit(std.testing.allocator);

            const expr = try ml.Expr.parseCst(std.testing.allocator, input, &syn);

            log.info("input: {s}\nresult: {f}", .{ input, expr });

            var buf = std.io.Writer.Allocating.init(std.testing.allocator);
            defer buf.deinit();

            try ml.Cst.dumpSExprs(input, &buf.writer, &syn);

            try std.testing.expectEqualStrings(expect, buf.written());

            return expr;
        }
    }.testCstAttributes;

    var a = try check(";; preceeding1\n;; preceding2\nfoo ;; comment", "foo");
    defer a.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(&.{
        analysis.Attribute{
            .kind = .{ .comment = .pre },
            .value = " preceeding1",
            .source = analysis.Source{
                .name = "test",
                .location = .{
                    .visual = .{ .line = 1, .column = 1 },
                    .buffer = 0,
                },
            },
        },
        analysis.Attribute{
            .kind = .{ .comment = .pre },
            .value = " preceding2",
            .source = analysis.Source{
                .name = "test",
                .location = .{
                    .visual = .{ .line = 2, .column = 1 },
                    .buffer = 15,
                },
            },
        },
        analysis.Attribute{
            .kind = .{ .comment = .post },
            .value = " comment",
            .source = analysis.Source{
                .name = "test",
                .location = .{
                    .visual = .{ .line = 3, .column = 5 },
                    .buffer = 33,
                },
            },
        },
    }, a.attributes);

    var b = try check(";; preceeding!\nfoo ;; comment.\nbar ;; another", "⟨𝓼𝓮𝓺 foo bar⟩");
    defer b.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(&.{
        analysis.Attribute{
            .kind = .{ .comment = .pre },
            .value = " preceeding!",
            .source = analysis.Source{
                .name = "test",
                .location = .{
                    .visual = .{ .line = 1, .column = 1 },
                    .buffer = 0,
                },
            },
        },
        analysis.Attribute{
            .kind = .{ .comment = .post },
            .value = " comment.",
            .source = analysis.Source{
                .name = "test",
                .location = .{
                    .visual = .{ .line = 2, .column = 5 },
                    .buffer = 19,
                },
            },
        },
    }, b.data.seq[0].attributes);

    try std.testing.expectEqualDeep(&.{
        analysis.Attribute{
            .kind = .{ .comment = .post },
            .value = " another",
            .source = analysis.Source{
                .name = "test",
                .location = .{
                    .visual = .{ .line = 3, .column = 5 },
                    .buffer = 35,
                },
            },
        },
    }, b.data.seq[1].attributes);
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
