const pl = @import("platform");

const std = @import("std");
const testing = std.testing;

const ribbon = @import("ribbon_language");
const core = ribbon.core;
const bytecode = ribbon.bytecode;
const interpreter = ribbon.interpreter;

test "interpreter unconditional branch skips code" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

    var tb = bytecode.TableBuilder.init(allocator, null);
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

test "interpreter basic effect handling" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // --- IDs ---
    const main_id = try tb.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.createHeaderEntry(.function, "handler_fn");
    const handler_set_id = try tb.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.createHeaderEntry(.effect, "my_effect");
    try tb.bindEffect(effect_id, @enumFromInt(0));

    // --- Handler Function ---
    // This function will be called when the effect is prompted.
    // It simply returns the value 42.
    var handler_fn = try tb.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();
    try handler_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 42);
    try handler_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Main Function ---
    var main_fn = try tb.createFunctionBuilder(main_id);

    // --- Handler Set ---
    // This set binds our effect_id to our handler_fn_id.
    var handler_set_builder = try tb.createHandlerSet(handler_set_id);
    _ = try handler_set_builder.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set_builder);

    // --- Main Function Body ---
    // 1. Push the handler set onto the stack, making it active.
    // 2. Prompt the effect. This transfers control to the handler function.
    // 3. The handler returns 42, which is placed in r0.
    // 4. Pop the handler set.
    // 5. Return the value in r0.
    var main_entry = try main_fn.createBlock();
    try main_entry.pushHandlerSet(handler_set_builder);
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try main_entry.popHandlerSet(handler_set_builder);
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Encode and Run ---
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 42), result);
}

test "interpreter effect cancellation" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // --- IDs ---
    const main_id = try tb.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.createHeaderEntry(.function, "cancelling_handler");
    const handler_set_id = try tb.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.createHeaderEntry(.effect, "my_effect");
    try tb.bindEffect(effect_id, @enumFromInt(0));

    // --- Handler Function ---
    // This handler will cancel the computation, passing 99 as the cancellation value.
    var handler_fn = try tb.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();
    try handler_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 99);
    try handler_entry.instrTerm(.cancel, .{ .R = .r0 });

    // --- Main Function ---
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();
    var cancel_landing_pad = try main_fn.createBlock();

    // --- Handler Set ---
    var handler_set_builder = try tb.createHandlerSet(handler_set_id);
    handler_set_builder.register = .r1; // Store cancellation value in r1
    _ = try handler_set_builder.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set_builder);

    // --- Main Function Body ---
    // entry_block: push set, prompt, then a branch to make the landing pad reachable.
    try entry_block.pushHandlerSet(handler_set_builder);
    try entry_block.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    // This branch ensures the landing pad is encoded, but won't be taken at runtime.
    try entry_block.instrBr(cancel_landing_pad.id);

    // cancel_landing_pad: This is where control resumes after cancellation.
    // The `cancel` instruction in the handler will jump here.
    try cancel_landing_pad.popHandlerSet(handler_set_builder);
    try cancel_landing_pad.bindHandlerSetCancellationLocation(handler_set_builder);
    try cancel_landing_pad.instrTerm(.@"return", .{ .R = .r1 }); // Return the cancellation value

    // --- Encode and Run ---
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 99), result);
}

test "interpreter upvalue access from handler" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // --- IDs ---
    const main_id = try tb.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.createHeaderEntry(.function, "upvalue_handler");
    const handler_set_id = try tb.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.createHeaderEntry(.effect, "my_effect");
    try tb.bindEffect(effect_id, @enumFromInt(0));

    // --- Main Function with a local variable ---
    var main_fn = try tb.createFunctionBuilder(main_id);
    const local_x = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });

    // --- Handler Function ---
    // This function will access an upvalue from its parent (main).
    var handler_fn = try tb.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();

    // --- Handler Set ---
    // Capture local_x from main as upvalue 0.
    var handler_set_builder = try tb.createHandlerSet(handler_set_id);
    const upvalue_x = try handler_set_builder.createUpvalue(local_x);
    _ = try handler_set_builder.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set_builder);

    // --- Handler Body ---
    // Access the upvalue, load its value, and return it.
    try handler_entry.instrAddrOf(.addr_u, .r0, upvalue_x);
    try handler_entry.instr(.load64, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    try handler_entry.instrTerm(.@"return", .{ .R = .r1 });

    // --- Main Function Body ---
    var main_entry = try main_fn.createBlock();
    // 1. Get address of local_x.
    try main_entry.instrAddrOf(.addr_l, .r0, local_x);
    // 2. Store the value 888 into it.
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 888);
    try main_entry.instr(.store64, .{ .Rx = .r0, .Ry = .r1, .I = 0 });
    // 3. Push handler set.
    try main_entry.pushHandlerSet(handler_set_builder);
    // 4. Prompt the effect. The handler will read the value of local_x (888) and return it.
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    // 5. Pop handler set.
    try main_entry.popHandlerSet(handler_set_builder);
    // 6. Return the result from the handler (which is in r0).
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Encode and Run ---
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 888), result);
}

test "interpreter effect modulation via re-prompt" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // --- IDs ---
    const main_id = try tb.createHeaderEntry(.function, "main");
    const h_outer_id = try tb.createHeaderEntry(.function, "handler_outer");
    const h_mod_id = try tb.createHeaderEntry(.function, "handler_modulator");
    const hs_outer_id = try tb.createHeaderEntry(.handler_set, null);
    const hs_mod_id = try tb.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.createHeaderEntry(.effect, "my_effect");
    try tb.bindEffect(effect_id, @enumFromInt(0));

    // --- Outer Handler ---
    // This is the "real" implementation that the modulator will call.
    // It just returns 100.
    var h_outer_fn = try tb.createFunctionBuilder(h_outer_id);
    var h_outer_entry = try h_outer_fn.createBlock();
    try h_outer_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 100);
    try h_outer_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Modulating Handler ---
    // This handler intercepts the effect, re-prompts it to call the next
    // handler in the chain, modifies the result, and returns.
    var h_mod_fn = try tb.createFunctionBuilder(h_mod_id);
    var h_mod_entry = try h_mod_fn.createBlock();
    // Re-prompt the same effect. This should invoke the *next* handler (h_outer).
    try h_mod_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    // The result from h_outer (100) is now in r0. Add 1 to it.
    try h_mod_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 1);
    try h_mod_entry.instr(.i_add64, .{ .Rx = .r0, .Ry = .r0, .Rz = .r1 });
    // Return the modified result (101).
    try h_mod_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Main Function ---
    var main_fn = try tb.createFunctionBuilder(main_id);
    var main_entry = try main_fn.createBlock();

    // --- Handler Set Setup ---
    var hs_outer_builder = try tb.createHandlerSet(hs_outer_id);
    _ = try hs_outer_builder.bindHandler(effect_id, h_outer_fn);
    try main_fn.bindHandlerSet(hs_outer_builder);

    var hs_mod_builder = try tb.createHandlerSet(hs_mod_id);
    _ = try hs_mod_builder.bindHandler(effect_id, h_mod_fn);
    try main_fn.bindHandlerSet(hs_mod_builder);

    // --- Main Function Body ---
    // 1. Push the outer handler.
    try main_entry.pushHandlerSet(hs_outer_builder);
    // 2. Push the modulating handler. The evidence chain is now mod -> outer.
    try main_entry.pushHandlerSet(hs_mod_builder);
    // 3. Prompt the effect. This will invoke the modulator.
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    // 4. Pop both handlers.
    try main_entry.popHandlerSet(hs_mod_builder);
    try main_entry.popHandlerSet(hs_outer_builder);
    // 5. Return the result from the prompt, which should be 101.
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Encode and Run ---
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // The correct result should be 101.
    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 101), result);
}

test "interpreter nested effect cancellation" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // --- IDs ---
    const main_id = try tb.createHeaderEntry(.function, "main");
    const h_outer_id = try tb.createHeaderEntry(.function, "handler_outer_cancel");
    const h_inner_id = try tb.createHeaderEntry(.function, "handler_inner_reprompt");
    const hs_outer_id = try tb.createHeaderEntry(.handler_set, "outer_set");
    const hs_inner_id = try tb.createHeaderEntry(.handler_set, "inner_set");
    const effect_id = try tb.createHeaderEntry(.effect, "cancellable_effect");
    try tb.bindEffect(effect_id, @enumFromInt(0));

    // --- Outer Handler (Cancels) ---
    var h_outer_fn = try tb.createFunctionBuilder(h_outer_id);
    var h_outer_entry = try h_outer_fn.createBlock();
    try h_outer_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 250); // The cancellation value
    try h_outer_entry.instrTerm(.cancel, .{ .R = .r0 });

    // --- Inner Handler (Re-prompts) ---
    var h_inner_fn = try tb.createFunctionBuilder(h_inner_id);
    var h_inner_entry = try h_inner_fn.createBlock();
    // This prompt will be handled by the outer handler, which will then cancel.
    try h_inner_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    // This part should never be reached.
    try h_inner_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 999);
    try h_inner_entry.instrTerm(.@"return", .{ .R = .r0 });

    // --- Main Function ---
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();
    var outer_cancel_pad = try main_fn.createBlock();
    var inner_cancel_pad = try main_fn.createBlock(); // Should not be reached.

    // --- Handler Set Setup ---
    var hs_outer_builder = try tb.createHandlerSet(hs_outer_id);
    _ = try hs_outer_builder.bindHandler(effect_id, h_outer_fn);
    hs_outer_builder.register = .r1; // Cancellation value for outer set goes to r1
    try main_fn.bindHandlerSet(hs_outer_builder);

    var hs_inner_builder = try tb.createHandlerSet(hs_inner_id);
    _ = try hs_inner_builder.bindHandler(effect_id, h_inner_fn);
    hs_inner_builder.register = .r2; // Cancellation value for inner set goes to r2
    try main_fn.bindHandlerSet(hs_inner_builder);

    // --- Main Function Body ---
    try entry_block.pushHandlerSet(hs_outer_builder);
    try entry_block.pushHandlerSet(hs_inner_builder);
    // This prompt is handled by the inner handler, which re-prompts to the outer, which cancels.
    try entry_block.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    // This code should not be reached.
    try entry_block.popHandlerSet(hs_inner_builder);
    try entry_block.popHandlerSet(hs_outer_builder);
    try entry_block.instrTerm(.halt, .{});

    // Landing pad for the inner set's cancellation (should be skipped).
    try inner_cancel_pad.popHandlerSet(hs_inner_builder);
    try inner_cancel_pad.bindHandlerSetCancellationLocation(hs_inner_builder);
    try inner_cancel_pad.instrTerm(.@"return", .{ .R = .r2 }); // would return from r2

    // Landing pad for the outer set's cancellation (should be hit).
    try outer_cancel_pad.popHandlerSet(hs_outer_builder);
    try outer_cancel_pad.bindHandlerSetCancellationLocation(hs_outer_builder);
    try outer_cancel_pad.instrTerm(.@"return", .{ .R = .r1 }); // returns from r1

    // --- Encode and Run ---
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 250), result);
}

test "invokeBytecode call stack overflow" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry = try main_fn.createBlock();
    try entry.instrTerm(.halt, .{});

    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    var fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // Manually fill the call stack to leave less than 2 free frames.
    // invokeBytecode requires 2 frames (one for the wrapper, one for the function).
    const frames_to_push = core.CALL_STACK_SIZE - 1;
    for (0..frames_to_push) |_| {
        _ = fiber.header.calls.allocPtr();
    }

    // This invocation should fail with an overflow error.
    const result = interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectError(error.Overflow, result);
}

test "invokeBytecode data stack overflow" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry = try main_fn.createBlock();
    try entry.instrTerm(.halt, .{});

    // Create a function with a layout so large it cannot possibly fit on the data stack.
    const huge_size = (core.DATA_STACK_SIZE * @sizeOf(u64)) + 1;
    var table = try tb.encode(allocator);
    defer table.deinit();

    // Manually patch the function's layout after encoding.
    var function: *core.Function = @ptrCast(@constCast(table.bytecode.header.get(main_id)));
    function.layout.size = huge_size;

    var fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    // This invocation should now correctly fail with an overflow error.
    const result = interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectError(error.Overflow, result);
}

test "mem_set with zero size is a no-op" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    const local = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    var entry = try main_fn.createBlock();

    // r0 = &local
    try entry.instrAddrOf(.addr_l, .r0, local);
    // Store a known initial value into the local
    try entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 0x12345678_87654321);
    try entry.instr(.store64, .{ .Rx = .r0, .Ry = .r1, .I = 0 });

    // Now, attempt the mem_set with zero size
    // r1 = byte to write (0xFF)
    try entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 0xFF);
    // r2 = size (0)
    try entry.instrWide(.bit_copy64c, .{ .R = .r2 }, 0);
    // mem_set(dest=r0, byte=r1, size=r2) -> should do nothing
    try entry.instr(.mem_set, .{ .Rx = .r0, .Ry = .r1, .Rz = .r2 });

    // Load the value from the local and return it.
    try entry.instr(.load64, .{ .Rx = .r3, .Ry = .r0, .I = 0 });
    try entry.instrTerm(.@"return", .{ .R = .r3 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    var fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, table.bytecode.header.get(main_id), &.{});
    // The result should be the original, unmodified value.
    try testing.expectEqual(@as(u64, 0x12345678_87654321), result);
}

test "mem_copy with zero size is a no-op" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    const local_dest = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_src = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    var entry = try main_fn.createBlock();

    // Get addresses for dest and src
    try entry.instrAddrOf(.addr_l, .r0, local_dest);
    try entry.instrAddrOf(.addr_l, .r1, local_src);

    // Initialize dest to a known value
    try entry.instrWide(.bit_copy64c, .{ .R = .r3 }, 0x11111111_11111111);
    try entry.instr(.store64, .{ .Rx = .r0, .Ry = .r3, .I = 0 });

    // Initialize src to a different known value
    try entry.instrWide(.bit_copy64c, .{ .R = .r3 }, 0x99999999_99999999);
    try entry.instr(.store64, .{ .Rx = .r1, .Ry = .r3, .I = 0 });

    // Attempt the mem_copy with zero size
    try entry.instrWide(.bit_copy64c, .{ .R = .r2 }, 0); // Zero size
    // mem_copy(dest=r0, src=r1, size=r2) -> should do nothing
    try entry.instr(.mem_copy, .{ .Rx = .r0, .Ry = .r1, .Rz = .r2 });

    // Load the value from dest and return it.
    try entry.instr(.load64, .{ .Rx = .r3, .Ry = .r0, .I = 0 });
    try entry.instrTerm(.@"return", .{ .R = .r3 });

    var table = try tb.encode(allocator);
    defer table.deinit();

    var fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, table.bytecode.header.get(main_id), &.{});
    // The result should be the original destination value, not the source value.
    try testing.expectEqual(@as(u64, 0x11111111_11111111), result);
}

// --- Helpers for builtin tests ---

fn simpleBuiltin(fiber: *core.mem.FiberHeader) callconv(.C) core.BuiltinSignal {
    // Return 555 in the designated return register.
    const regs = fiber.registers.top();
    regs[core.Register.native_ret.getIndex()] = 555;
    return .@"return";
}

fn trapBuiltin(fiber: *core.mem.FiberHeader) callconv(.C) core.BuiltinSignal {
    _ = fiber;
    return .request_trap;
}

// This function gets called by bytecode, and it in turn calls other bytecode.
fn interlacedBuiltin(fiber_header: *core.mem.FiberHeader) callconv(.C) core.BuiltinSignal {
    const fiber = core.Fiber{ .header = fiber_header };

    // Get the arguments passed to this builtin from its registers.
    const builtin_regs = fiber.header.registers.top();
    const arg_for_target = builtin_regs[core.Register.r0.getIndex()];
    const target_fn_id_int = builtin_regs[core.Register.r1.getIndex()];
    const target_fn_id = core.FunctionId.fromInt(target_fn_id_int);

    // The current function is the builtin itself. To find the bytecode world,
    // we need to go one level down the call stack to the bytecode function that called us.
    const caller_call_frame: *core.CallFrame = @ptrCast(fiber.header.calls.top_ptr - 1);
    const bc_function = @as(*const core.Function, @ptrCast(@alignCast(caller_call_frame.function)));

    // Look up the target function in the header of the calling bytecode function.
    const target_function = bc_function.header.get(target_fn_id);

    // Invoke the target bytecode function.
    const result = interpreter.invokeBytecode(fiber, target_function, &.{arg_for_target}) catch {
        // On error, return a sentinel value.
        builtin_regs[core.Register.native_ret.getIndex()] = 0xDEADBEEF;
        return .@"return";
    };

    // Put the result into our return register.
    builtin_regs[core.Register.native_ret.getIndex()] = result;

    return .@"return";
}

test "interpreter builtin data access" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // 1. Create a builtin data entry
    const builtin_data_id = try tb.createHeaderEntry(.builtin, "my_builtin_data");
    const test_data = "hello";
    try tb.bindBuiltinData(builtin_data_id, .fromSlice(test_data));

    // 2. Create the main function that accesses it
    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    // r0 = &my_builtin_data
    try entry_block.instrAddrOf(.addr_b, .r0, builtin_data_id);
    // r1 = *r0 (load first byte)
    try entry_block.instr(.load8, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    // return r1
    try entry_block.instrTerm(.@"return", .{ .R = .r1 });

    // 3. Encode and run
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 'h'), result);
}

test "interpreter builtin function usage" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // 1. Bind the native Zig function
    const builtin_fn_id = try tb.createHeaderEntry(.builtin, "simpleBuiltin");
    try tb.bindBuiltinFunction(builtin_fn_id, simpleBuiltin);

    // 2. Create main function to call it
    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    // Call the builtin, result in r0
    try entry_block.instrCall(.call_c, .{ .R = .r0, .F = builtin_fn_id.cast(core.Function), .I = 0 }, .fromSlice(&.{}));
    // Return r0
    try entry_block.instrTerm(.@"return", .{ .R = .r0 });

    // 3. Encode and run
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectEqual(@as(u64, 555), result);
}

test "interpreter interlaced bytecode->builtin->bytecode noneffectful" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // The function that will be called *by* the builtin
    const callee_id = try tb.createHeaderEntry(.function, "callee");
    var callee_fn = try tb.createFunctionBuilder(callee_id);
    var callee_entry = try callee_fn.createBlock();
    // Takes one arg in r0, adds 100 to it, and returns.
    try callee_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 100);
    try callee_entry.instr(.i_add64, .{ .Rx = .r0, .Ry = .r0, .Rz = .r1 });
    try callee_entry.instrTerm(.@"return", .{ .R = .r0 });

    // The builtin function
    const builtin_id = try tb.createHeaderEntry(.builtin, "interlacedBuiltin");
    try tb.bindBuiltinFunction(builtin_id, interlacedBuiltin);

    // Main function to start the chain
    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    var main_entry = try main_fn.createBlock();
    // Arg for the builtin -> callee
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 42);
    // ID of the callee function for the builtin
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, callee_id.toInt());
    // Call the builtin, result in r0
    try main_entry.instrCall(.call_c, .{ .R = .r0, .F = builtin_id.cast(core.Function), .I = 2 }, .fromSlice(&.{ .r0, .r1 }));
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // Encode and run
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = try interpreter.invokeBytecode(fiber, function, &.{});
    // Expected: interlacedBuiltin(42, callee_id) -> callee(42) -> 42 + 100 -> 142
    try testing.expectEqual(@as(u64, 142), result);
}

test "builtin function requests trap" {
    const allocator = testing.allocator;

    var tb = bytecode.TableBuilder.init(allocator, null);
    defer tb.deinit();

    // 1. Bind the trapping native Zig function
    const builtin_fn_id = try tb.createHeaderEntry(.builtin, "trapBuiltin");
    try tb.bindBuiltinFunction(builtin_fn_id, trapBuiltin);

    // 2. Create main function to call it
    const main_id = try tb.createHeaderEntry(.function, "main");
    var main_fn = try tb.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    try entry_block.instrCall(.call_c, .{ .R = .r0, .F = builtin_fn_id.cast(core.Function), .I = 0 }, .fromSlice(&.{}));
    try entry_block.instrTerm(.halt, .{}); // Should not be reached

    // 3. Encode and run
    var table = try tb.encode(allocator);
    defer table.deinit();

    const function = table.bytecode.header.get(main_id);
    const fiber = try core.Fiber.init(allocator);
    defer fiber.deinit(allocator);

    const result = interpreter.invokeBytecode(fiber, function, &.{});
    try testing.expectError(error.FunctionTrapped, result);
}
