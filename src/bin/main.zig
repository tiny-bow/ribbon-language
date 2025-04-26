const driver = @This();

const std = @import("std");

const ribbon = @import("ribbon_language");
const common = @import("common");

const log = std.log.scoped(.main);

pub const std_options = std.Options{
    .log_level = .info,
};


pub fn main() !void {
    // @breakpoint();

    log.info("Running tests ...", .{});

    try test_rir();
    try test_interpreter();
    try test_jit();
    try test_lexer();

    log.info("... All tests passed!", .{});
}

fn test_rir() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const ir = try ribbon.ir.Builder.init(allocator);
    defer ir.deinit();

    const foo = try ir.internName("foo");
    const bar = try ir.internName("bar");
    const foo2 = try ir.internName("foo");

    try std.testing.expectEqual(foo, foo2);
    try std.testing.expect(foo != bar);

    log.debug("foo: {} bar: {}", .{ foo, bar });

    const i64Name = try ir.internName("i64");

    log.debug("i64Name: {}", .{ i64Name });

    const i64Type = try ir.internType(i64Name, ribbon.ir.TypeInfo {
        .integer = .{ .bit_size = 64, .signedness = .signed },
    });

    log.debug("I64: {}", .{ i64Type });


    const aData = ribbon.ir.ConstantData {
        .type = i64Type,
        .bytes = std.mem.asBytes(&@as(i64, -23)),
    };

    const bData = ribbon.ir.ConstantData {
        .type = i64Type,
        .bytes = std.mem.asBytes(&@as(i64, 42)),
    };

    const a = try ir.internConstant(try ir.internName("a"), aData);
    const b = try ir.internConstant(try ir.internName("b"), bData);
    const a2 = try ir.internConstant(try ir.internName("a2"), aData);

    try std.testing.expectEqual(a, a2);
    try std.testing.expect(a != b);
}

fn test_interpreter() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const b = try ribbon.bytecode.Builder.init(allocator, common.Id.of(ribbon.core.Function).fromInt(0));
    defer b.deinit();

    const entry = try b.createBlock();

    try entry.instr(.i_add64, .{ .Rx = .r7, .Ry = .r0, .Rz = .r1 });
    try entry.instr(.@"return", .{ .R = .r7 });

    var encoder = ribbon.bytecode.Encoder { .writer = try ribbon.bytecode.Writer.init() };
    defer encoder.writer.deinit();

    try b.encode(&encoder);

    const mem = try encoder.finalize();
    defer std.posix.munmap(mem);

    const instr: []const ribbon.core.InstructionBits = @ptrCast(mem);

    const stdout = std.io.getStdOut();

    try ribbon.bytecode.disas(mem, stdout.writer());

    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const function = ribbon.core.Function {
        .header = undefined,
        .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
        .stack_size = 0,
    };

    const result = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{ 3, 2 });
    log.info("{} + {} = {}", .{ 3, 2, result });
    try std.testing.expectEqual(5, result);
}

fn test_jit() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    var jit = try ribbon.machine.Builder.init();
    defer jit.deinit();

    try jit.i_add64(.r(2), .r(0), .r(1));
    try jit.@"return"(.r(2));

    const exe = try jit.finalize();
    defer exe.deinit();

    try ribbon.machine.disas(exe.toSlice(), .{}, std.io.getStdOut().writer());

    const x: i64 = -8;
    const y: i64 = 2;

    const result: ribbon.interpreter.BuiltinResult = try ribbon.interpreter.invokeBuiltin(
        fiber, null,
        exe, &.{
            @as(ribbon.core.RegisterBits,
            @bitCast(x)),
            @as(ribbon.core.RegisterBits,
            @bitCast(y)),
        },
    );

    switch (result) {
        .@"return" => |bits| {
            const z: i64 = @bitCast(bits);

            log.info("{} + {} = {}", .{ x, y, z });

            try std.testing.expectEqual(x + y, z);
        },
        .cancel => |c| {
            log.err("Cancelled: {}", .{ c });
            return error.Cancelled;
        },
    }
}


fn test_lexer() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var lexer = try ribbon.meta_language.Lexer.init(allocator, .{},
        \\test
        \\  [
        \\      1,
        \\      2,
        \\      3
        \\  ]
        \\
    );

    defer lexer.deinit();

    const expect = [_]ribbon.meta_language.TokenData {
        .{ .sequence = "test" },
        .{ .linebreak = .{ .n = 1, .i = 1 } },
        .{ .special = .{ .escaped = false, .punctuation = ribbon.meta_language.Punctuation.fromChar('[') } },
        .{ .linebreak = .{ .n = 1, .i = 1 } },
        .{ .sequence = "1" },
        .{ .special = .{ .escaped = false, .punctuation = ribbon.meta_language.Punctuation.fromChar(',') } },
        .{ .linebreak = .{ .n = 1, .i = 0 } },
        .{ .sequence = "2" },
        .{ .special = .{ .escaped = false, .punctuation = ribbon.meta_language.Punctuation.fromChar(',') } },
        .{ .linebreak = .{ .n = 1, .i = 0 } },
        .{ .sequence = "3" },
        .{ .linebreak = .{ .n = 1, .i = -1 } },
        .{ .special = .{ .escaped = false, .punctuation = ribbon.meta_language.Punctuation.fromChar(']') } },
        .{ .linebreak = .{ .n = 1, .i = -1 } },
    };

    for (expect) |e| {
        const it = lexer.next() catch |err| {
            log.err("{}: {s}\n", .{ lexer.location, @errorName(err) });
            return err;
        };

        if (it) |tok| {
            log.debug("{} to {}: {} (expecting {})\n", .{ tok.location, lexer.location, tok.data, e });

            switch (e) {
                .sequence => |s| {
                    try std.testing.expectEqual(.sequence, @as(std.meta.Tag(ribbon.meta_language.TokenData), tok.data));
                    try std.testing.expectEqualSlices(u8, s, tok.data.sequence);
                },

                .special => |p| {
                    try std.testing.expectEqual(.special, @as(std.meta.Tag(ribbon.meta_language.TokenData), tok.data));
                    try std.testing.expectEqual(p, tok.data.special);
                },

                .linebreak => |l| {
                    try std.testing.expectEqual(.linebreak, @as(std.meta.Tag(ribbon.meta_language.TokenData), tok.data));
                    try std.testing.expectEqual(l.n, tok.data.linebreak.n);
                    try std.testing.expectEqual(l.i, tok.data.linebreak.i);
                },
            }
        } else {
            log.err("unexpected EOF {}; expected {}\n", .{ lexer.location, e });
            return error.UnexpectedEof;
        }
    }

    try std.testing.expectEqual(lexer.source.len, lexer.location.buffer);
}
