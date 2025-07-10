const pl = @import("platform");

const std = @import("std");
const testing = std.testing;

const ribbon = @import("ribbon_language");
const core = ribbon.core;
const bytecode = ribbon.bytecode;
const interpreter = ribbon.interpreter;

// test "basic integration" {
//     const temp_allocator = testing.allocator;
//     const writer_allocator = testing.allocator;

//     const b = try bytecode.FunctionBuilder.init(temp_allocator, .fromInt(0));
//     defer b.deinit();

//     const entry = try b.createBlock();

//     try entry.instr(.i_add64, .{ .Rx = .r7, .Ry = .r0, .Rz = .r1 });
//     try entry.instr(.@"return", .{ .R = .r7 });

//     var encoder = try bytecode.Encoder.init(temp_allocator, writer_allocator);
//     defer encoder.deinit();

//     try b.finalize(&encoder);

//     const mem = try encoder.finalize();
//     defer std.posix.munmap(mem);

//     const instr: []const core.InstructionBits = @ptrCast(mem);

//     const fiber = try core.Fiber.init(testing.allocator);
//     defer fiber.deinit(testing.allocator);

//     const function = core.Function{
//         .header = core.EMPTY_HEADER,
//         .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
//         .stack_size = 0,
//     };

//     const result = try interpreter.invokeBytecode(fiber, &function, &.{ 3, 2 });
//     try testing.expectEqual(5, result);
// }
