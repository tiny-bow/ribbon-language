const pl = @import("platform");
const std = @import("std");
const ribbon = @import("ribbon_language");

test "basic integration" {
    const allocator = std.testing.allocator;

    const b = try ribbon.bytecode.Builder.init(allocator, .fromInt(0));
    defer b.deinit();

    const entry = try b.createBlock();

    try entry.instr(.i_add64, .{ .Rx = .r7, .Ry = .r0, .Rz = .r1 });
    try entry.instr(.@"return", .{ .R = .r7 });

    var encoder = try ribbon.bytecode.Encoder.init();
    defer encoder.writer.deinit();

    try b.encode(&encoder);

    const mem = try encoder.finalize();
    defer std.posix.munmap(mem);

    const instr: []const ribbon.core.InstructionBits = @ptrCast(mem);

    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const function = ribbon.core.Function{
        .header = ribbon.core.EMPTY_HEADER,
        .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
        .stack_size = 0,
    };

    const result = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{ 3, 2 });
    try std.testing.expectEqual(5, result);
}
