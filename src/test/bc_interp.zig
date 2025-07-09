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
    defer encoder.deinit();

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

test "interpreter conditional branch" {
    const allocator = std.testing.allocator;

    // This test will execute one of two branches based on an input argument.
    // if (arg != 0) return 200 else return 100
    const builder = try ribbon.bytecode.Builder.init(allocator, .fromInt(10));
    defer builder.deinit();

    const entry_block = try builder.createBlock();
    const false_block = try builder.createBlock(); // Fallthrough block
    const true_block = try builder.createBlock(); // Branch target block

    // entry_block: br_if r0 -> true_block (fallthrough to false_block)
    // r0 will be the argument
    try entry_block.instrBr(.br_if, .{ .R = .r0, .I = 0 }); // I is placeholder
    @constCast(&entry_block.terminator.?).additional.branch_target = true_block.id;

    // false_block (fallthrough path)
    try false_block.instrWithImm64(.bit_copy64c, .{ .R = .r7 }, 100);
    try false_block.instr(.@"return", .{ .R = .r7 });

    // true_block (branch target path)
    try true_block.instrWithImm64(.bit_copy64c, .{ .R = .r7 }, 200);
    try true_block.instr(.@"return", .{ .R = .r7 });

    var encoder = try ribbon.bytecode.Encoder.init();
    defer encoder.deinit();

    try builder.encode(&encoder);
    const mem = try encoder.finalize();
    defer std.posix.munmap(mem);

    const instr: []const ribbon.core.InstructionBits = @ptrCast(mem);
    const function = ribbon.core.Function{
        .header = ribbon.core.EMPTY_HEADER,
        .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
        .stack_size = 0,
    };

    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // Test the false path (arg = 0)
    const result_false = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{0});
    try std.testing.expectEqual(@as(u64, 100), result_false);

    // Test the true path (arg = 1)
    const result_true = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{1});
    try std.testing.expectEqual(@as(u64, 200), result_true);
}

test "interpreter loop" {
    const allocator = std.testing.allocator;

    // This test calculates the sum of numbers from 1 to arg.
    // e.g. sum(5) = 1+2+3+4+5 = 15
    const builder = try ribbon.bytecode.Builder.init(allocator, .fromInt(11));
    defer builder.deinit();

    // The order of block creation matters for fallthrough branches.
    const entry_block = try builder.createBlock();
    const loop_header = try builder.createBlock();
    const exit_block = try builder.createBlock();
    const loop_body = try builder.createBlock();

    // entry: r1=0 (counter), r2=0 (acc), br -> loop_header
    // r0 holds the loop limit from arguments.
    try entry_block.instrWithImm64(.bit_copy64c, .{ .R = .r1 }, 0);
    try entry_block.instrWithImm64(.bit_copy64c, .{ .R = .r2 }, 0);
    try entry_block.instrBr(.br, .{ .I = 0 });
    @constCast(&entry_block.terminator.?).additional.branch_target = loop_header.id;

    // loop_header: r3 = r1 < r0. br_if r3 -> loop_body. Fallthrough to exit_block.
    try loop_header.instr(.u_lt64, .{ .Rx = .r3, .Ry = .r1, .Rz = .r0 });
    try loop_header.instrBr(.br_if, .{ .R = .r3, .I = 0 });
    @constCast(&loop_header.terminator.?).additional.branch_target = loop_body.id;

    // exit_block: return r2. This is the fallthrough target from loop_header.
    try exit_block.instr(.@"return", .{ .R = .r2 });

    // loop_body: r1++, r2+=r1, br -> loop_header
    try loop_body.instrWithImm64(.i_add64c, .{ .Rx = .r1, .Ry = .r1 }, 1);
    try loop_body.instr(.i_add64, .{ .Rx = .r2, .Ry = .r2, .Rz = .r1 });
    try loop_body.instrBr(.br, .{ .I = 0 });
    @constCast(&loop_body.terminator.?).additional.branch_target = loop_header.id;

    var encoder = try ribbon.bytecode.Encoder.init();
    defer encoder.deinit();
    try builder.encode(&encoder);
    const mem = try encoder.finalize();
    defer std.posix.munmap(mem);

    const instr: []const ribbon.core.InstructionBits = @ptrCast(mem);
    const function = ribbon.core.Function{
        .header = ribbon.core.EMPTY_HEADER,
        .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
        .stack_size = 0,
    };

    const fiber = try ribbon.core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{5});
    try std.testing.expectEqual(@as(u64, 15), result);
}

// test "interpreter nested control flow" {
//     const allocator = std.testing.allocator;

//     // This test sums even numbers from 0 up to (but not including) arg.
//     // e.g. sum_evens(10) = 0 + 2 + 4 + 6 + 8 = 20.
//     const builder = try ribbon.bytecode.Builder.init(allocator, .fromInt(12));
//     defer builder.deinit();

//     // Block layout is important for fallthrough.
//     const entry_block = try builder.createBlock();
//     const loop_header = try builder.createBlock();
//     const exit_block = try builder.createBlock();
//     const loop_body = try builder.createBlock();
//     const increment_counter = try builder.createBlock();
//     const add_to_acc = try builder.createBlock();

//     // entry: r1=0 (counter), r2=0 (acc), r6=2 (const), br -> loop_header
//     try entry_block.instrWithImm64(.bit_copy64c, .{ .R = .r1 }, 0);
//     try entry_block.instrWithImm64(.bit_copy64c, .{ .R = .r2 }, 0);
//     try entry_block.instrWithImm64(.bit_copy64c, .{ .R = .r6 }, 2);
//     try entry_block.instrBr(.br, .{ .I = 0 });
//     @constCast(&entry_block.terminator.?).additional.branch_target = loop_header.id;

//     // loop_header: if r1 < r0, goto loop_body, else fallthrough to exit
//     try loop_header.instr(.u_lt64, .{ .Rx = .r3, .Ry = .r1, .Rz = .r0 });
//     try loop_header.instrBr(.br_if, .{ .R = .r3, .I = 0 });
//     @constCast(&loop_header.terminator.?).additional.branch_target = loop_body.id;

//     // exit_block: return r2
//     try exit_block.instr(.@"return", .{ .R = .r2 });

//     // loop_body: check if r1 is even. r4 = r1 % 2. r5 = (r4 == 0). br_if r5 -> add_to_acc.
//     // Fallthrough to increment_counter.
//     try loop_body.instr(.u_rem64, .{ .Rx = .r4, .Ry = .r1, .Rz = .r6 });
//     try loop_body.instrWithImm64(.i_eq64c, .{ .Rx = .r5, .Ry = .r4 }, 0);
//     try loop_body.instrBr(.br_if, .{ .R = .r5, .I = 0 });
//     @constCast(&loop_body.terminator.?).additional.branch_target = add_to_acc.id;

//     // increment_counter: r1++. br -> loop_header
//     try increment_counter.instrWithImm64(.i_add64c, .{ .Rx = .r1, .Ry = .r1 }, 1);
//     try increment_counter.instrBr(.br, .{ .I = 0 });
//     @constCast(&increment_counter.terminator.?).additional.branch_target = loop_header.id;

//     // add_to_acc: r2 += r1. br -> increment_counter
//     try add_to_acc.instr(.i_add64, .{ .Rx = .r2, .Ry = .r2, .Rz = .r1 });
//     try add_to_acc.instrBr(.br, .{ .I = 0 });
//     @constCast(&add_to_acc.terminator.?).additional.branch_target = increment_counter.id;

//     // --- Encode and run ---
//     var encoder = try ribbon.bytecode.Encoder.init();
//     defer encoder.deinit();
//     try builder.encode(&encoder);
//     const mem = try encoder.finalize();
//     defer std.posix.munmap(mem);

//     const instr: []const ribbon.core.InstructionBits = @ptrCast(mem);
//     const function = ribbon.core.Function{
//         .header = ribbon.core.EMPTY_HEADER,
//         .extents = .{ .base = instr.ptr, .upper = instr.ptr + instr.len },
//         .stack_size = 0,
//     };

//     const fiber = try ribbon.core.Fiber.init(allocator);
//     defer fiber.deinit(allocator);

//     const result = try ribbon.interpreter.invokeBytecode(fiber, &function, &.{10});
//     try std.testing.expectEqual(@as(u64, 20), result);
// }
