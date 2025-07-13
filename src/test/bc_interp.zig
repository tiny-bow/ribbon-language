const pl = @import("platform");

const std = @import("std");
const testing = std.testing;

const ribbon = @import("ribbon_language");
const core = ribbon.core;
const bytecode = ribbon.bytecode;
const interpreter = ribbon.interpreter;

test "interpreter unconditional branch skips code" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    // Create blocks
    var entry_block = try main_fn.createBlock();
    var dead_block = try main_fn.createBlock(); // Should be skipped
    var exit_block = try main_fn.createBlock();

    // entry_block: r0 = 1; goto exit_block
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 1);
    try entry_block.instrBr(exit_block.id);

    // dead_block: r0 = 99; return r0
    try dead_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 99);
    try dead_block.instrTerm(.@"return", .{ .R = .r0 });

    // exit_block: return r0
    try exit_block.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 1), result);
}

test "interpreter conditional branch takes then path on true" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    var then_block = try main_fn.createBlock();
    var else_block = try main_fn.createBlock();
    var merge_block = try main_fn.createBlock();

    // entry_block: r0 is input. br_if r0, then_block, else_block
    // Interpreter logic: if (r0 != 0) goto then_block, else goto else_block.
    // We will pass a non-zero value, so it should go to then_block.
    try entry_block.instrBrIf(.r0, then_block.id, else_block.id);

    // then_block: r1 = 100
    try then_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 100);
    try then_block.instrBr(merge_block.id);

    // else_block: r1 = 200 (should not be executed)
    try else_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 200);
    try else_block.instrBr(merge_block.id);

    // merge_block: return r1
    try merge_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // Pass '1' (true) in r0.
    const result = try interpreter.invokeBytecode(fiber, function, &.{1});
    // With corrected interpreter logic, non-zero condition takes 'then' path.
    try testing.expectEqual(@as(u64, 100), result);
}

test "interpreter conditional branch takes else path on false" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    var then_block = try main_fn.createBlock();
    var else_block = try main_fn.createBlock();
    var merge_block = try main_fn.createBlock();

    // entry_block: r0 is input. br_if r0, then_block, else_block
    // Interpreter logic: if (r0 != 0) goto then_block, else goto else_block.
    // We will pass zero, so it should go to else_block.
    try entry_block.instrBrIf(.r0, then_block.id, else_block.id);

    // then_block: r1 = 100 (should not be executed)
    try then_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 100);
    try then_block.instrBr(merge_block.id);

    // else_block: r1 = 200
    try else_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 200);
    try else_block.instrBr(merge_block.id);

    // merge_block: return r1
    try merge_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // Pass '0' (false) in r0.
    const result = try interpreter.invokeBytecode(fiber, function, &.{0});
    // With corrected interpreter logic, zero condition takes 'else' path.
    try testing.expectEqual(@as(u64, 200), result);
}

test "interpreter simple loop" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    // Create blocks
    var entry_block = try main_fn.createBlock();
    var loop_head_block = try main_fn.createBlock();
    var loop_body_block = try main_fn.createBlock();
    var exit_block = try main_fn.createBlock();

    // entry: r1 = 0 (accumulator), br loop_head. Argument (counter) is in r0.
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 0);
    try entry_block.instrBr(loop_head_block.id);

    // loop_head: if r0 != 0, goto loop_body_block. else, goto exit_block
    try loop_head_block.instrBrIf(.r0, loop_body_block.id, exit_block.id);

    // loop_body: r1++, r0--, br loop_head
    try loop_body_block.instrWide(.bit_copy64c, .{ .R = .r2 }, 1); // Load constant 1
    try loop_body_block.instr(.i_add64, .{ .Rx = .r1, .Ry = .r1, .Rz = .r2 }); // r1 += 1
    try loop_body_block.instr(.i_sub64, .{ .Rx = .r0, .Ry = .r0, .Rz = .r2 }); // r0 -= 1
    try loop_body_block.instrBr(loop_head_block.id);

    // exit: return r1
    try exit_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // Loop 5 times
    const result = try interpreter.invokeBytecode(fiber, function, &.{5});
    try testing.expectEqual(@as(u64, 5), result);
}

test "interpreter multiple arguments" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();

    // entry: r2 = r0 + r1; return r2. Arguments are passed in r0, r1.
    try entry_block.instr(.i_add64, .{ .Rx = .r2, .Ry = .r0, .Rz = .r1 });
    try entry_block.instrTerm(.@"return", .{ .R = .r2 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{ 10, 20 });
    try testing.expectEqual(@as(u64, 30), result);
}

test "interpreter subtraction" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();

    // entry: r2 = r0 - r1; return r2
    try entry_block.instr(.i_sub64, .{ .Rx = .r2, .Ry = .r0, .Rz = .r1 });
    try entry_block.instrTerm(.@"return", .{ .R = .r2 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{ 50, 15 });
    try testing.expectEqual(@as(u64, 35), result);
}

test "interpreter local variable store and load" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    // Create a local variable of size/alignment 8 (u64)
    const my_local = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });

    var entry_block = try main_fn.createBlock();

    // r0 = &my_local
    try entry_block.instrAddrOf(.addr_l, .r0, my_local);
    // r1 = 12345
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 12345);
    // *(r0) = r1
    try entry_block.instr(.store64, .{ .Rx = .r0, .Ry = .r1, .I = 0 });
    // r2 = *(r0)
    try entry_block.instr(.load64, .{ .Rx = .r2, .Ry = .r0, .I = 0 });
    // return r2
    try entry_block.instrTerm(.@"return", .{ .R = .r2 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 12345), result);
}

test "interpreter multiple local variables with varied alignment" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);

    // Create locals with different sizes and alignments.
    // The builder will re-order them to optimize layout based on alignment.
    const local_b = try main_fn.createLocal(.{ .size = 1, .alignment = 1 }); // u8
    const local_d = try main_fn.createLocal(.{ .size = 8, .alignment = 8 }); // u64
    const local_c = try main_fn.createLocal(.{ .size = 4, .alignment = 4 }); // u32
    const local_a = try main_fn.createLocal(.{ .size = 2, .alignment = 2 }); // u16

    var entry_block = try main_fn.createBlock();

    // Store values into each local variable
    try entry_block.instrAddrOf(.addr_l, .r0, local_d);
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 1000);
    try entry_block.instr(.store64, .{ .Rx = .r0, .Ry = .r1, .I = 0 });

    try entry_block.instrAddrOf(.addr_l, .r0, local_c);
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 200);
    try entry_block.instr(.store32, .{ .Rx = .r0, .Ry = .r1, .I = 0 });

    try entry_block.instrAddrOf(.addr_l, .r0, local_a);
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 30);
    try entry_block.instr(.store16, .{ .Rx = .r0, .Ry = .r1, .I = 0 });

    try entry_block.instrAddrOf(.addr_l, .r0, local_b);
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 4);
    try entry_block.instr(.store8, .{ .Rx = .r0, .Ry = .r1, .I = 0 });

    // Load values back and sum them up into r2
    try entry_block.instrAddrOf(.addr_l, .r0, local_d);
    try entry_block.instr(.load64, .{ .Rx = .r2, .Ry = .r0, .I = 0 }); // r2 = 1000

    try entry_block.instrAddrOf(.addr_l, .r0, local_c);
    try entry_block.instr(.load32, .{ .Rx = .r1, .Ry = .r0, .I = 0 }); // r1 = 200
    try entry_block.instr(.i_add64, .{ .Rx = .r2, .Ry = .r2, .Rz = .r1 }); // r2 += r1

    try entry_block.instrAddrOf(.addr_l, .r0, local_a);
    try entry_block.instr(.load16, .{ .Rx = .r1, .Ry = .r0, .I = 0 }); // r1 = 30
    try entry_block.instr(.i_add64, .{ .Rx = .r2, .Ry = .r2, .Rz = .r1 }); // r2 += r1

    try entry_block.instrAddrOf(.addr_l, .r0, local_b);
    try entry_block.instr(.load8, .{ .Rx = .r1, .Ry = .r0, .I = 0 }); // r1 = 4
    try entry_block.instr(.i_add64, .{ .Rx = .r2, .Ry = .r2, .Rz = .r1 }); // r2 += r1

    try entry_block.instrTerm(.@"return", .{ .R = .r2 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);

    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 1234), result);
}
