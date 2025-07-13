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
