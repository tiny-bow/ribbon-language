const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.ir_integration);

const ribbon = @import("ribbon_language");
const common = ribbon.common;
const ir = ribbon.ir;
const core = ribbon.core;

test "ir_full_cycle_pipeline" {
    // We use the testing allocator for all steps to ensure we catch leaks
    const allocator = testing.allocator;

    // =========================================================================
    // PHASE 1: DRAFTING
    // Construct a valid IR graph in a source Context.
    // =========================================================================
    var src_ctx = try ir.Context.init(allocator);
    defer src_ctx.deinit();

    // 1. Create a Module
    const mod_name = try src_ctx.internName("test_module");
    const mod_guid: ir.Module.GUID = @enumFromInt(0xDEAD_BEEF);
    const src_mod = try src_ctx.createModule(mod_name, mod_guid);

    // 2. Create Types (Void and Bool)
    const void_ty = try src_ctx.getOrCreateSharedTerm(ir.terms.VoidType{});
    const bool_ty = try src_ctx.getOrCreateSharedTerm(ir.terms.BoolType{});

    // 3. Create a Function
    const fn_name = try src_ctx.internName("branching_logic");
    const src_func = try ir.Function.init(src_mod, .procedure, fn_name, void_ty);

    // Export the function so we can find it easily later
    try src_mod.exportFunction(fn_name, src_func);

    // 4. Create Basic Blocks
    const entry_block = src_func.body.entry;
    const then_block = try ir.Block.init(src_func.body, try src_ctx.internName("then_case"));
    const else_block = try ir.Block.init(src_func.body, try src_ctx.internName("else_case"));

    // 5. Build Instructions
    var builder = ir.Builder.init(src_ctx);

    // Block: Entry
    // Logic: val = stack_alloc(bool); br_if val then else;
    builder.positionAtEnd(entry_block);

    // We create a stack allocation to act as a variable/condition handle
    const condition_var = try builder.instr.stack_alloc(void_ty, bool_ty, try src_ctx.internName("condition"));

    _ = try builder.instr.br_if(condition_var, then_block, else_block);

    // Block: Then
    // Logic: return
    builder.positionAtEnd(then_block);
    _ = try builder.instr.@"return"(null);

    // Block: Else
    // Logic: return
    builder.positionAtEnd(else_block);
    _ = try builder.instr.@"return"(null);

    // =========================================================================
    // PHASE 2: DEHYDRATION
    // Convert the Context into a Serializable Module Artifact (SMA).
    // =========================================================================
    const src_sma = try src_ctx.dehydrate(allocator);
    defer src_sma.deinit();

    // Verify SMA basic properties
    try testing.expectEqual(@as(usize, 1), src_sma.modules.items.len);
    try testing.expectEqual(mod_guid, src_sma.modules.items[0].guid);
    try testing.expectEqual(@as(usize, 1), src_sma.functions.items.len);

    // =========================================================================
    // PHASE 3: SERIALIZATION
    // Write the SMA to a binary buffer.
    // =========================================================================
    var ab = std.io.Writer.Allocating.init(allocator);
    defer ab.deinit();

    try src_sma.serialize(&ab.writer);

    try ab.writer.flush();

    const serialized_bytes = ab.written();
    try testing.expect(serialized_bytes.len > 0);

    // =========================================================================
    // PHASE 4: DESERIALIZATION
    // Read the binary buffer back into a new SMA.
    // =========================================================================
    var stream = std.io.Reader.fixed(serialized_bytes);
    const dest_sma = try ir.Sma.deserialize(&stream, allocator);
    defer dest_sma.deinit();

    // Check version match
    try testing.expect(dest_sma.version.eql(&core.VERSION));

    // =========================================================================
    // PHASE 5: REHYDRATION
    // Create a new Context and populate it from the deserialized SMA.
    // =========================================================================
    var dest_ctx = try ir.Context.init(allocator);
    defer dest_ctx.deinit();

    try dest_ctx.rehydrate(dest_sma);

    // =========================================================================
    // PHASE 6: VERIFICATION
    // Assert that the rehydrated graph matches the original intent.
    // =========================================================================

    // 1. Verify Module
    // Note: We access internal maps for testing verification
    const dest_mod = dest_ctx.modules.get(mod_guid) orelse return error.TestFailed;
    try testing.expectEqualStrings("test_module", dest_mod.name.value);

    // 2. Verify Function Export
    const exported = dest_mod.exported_symbols.get("branching_logic") orelse return error.TestFailed;
    const dest_func = switch (exported) {
        .function => |f| f,
        else => return error.TestFailed,
    };
    try testing.expectEqual(ir.Function.Kind.procedure, dest_func.kind);

    // 3. Verify Blocks (Entry, Then, Else)
    // The expression body should have 3 reachable blocks.
    // Since rehydration creates blocks in order, we expect 3 distinct blocks in the pool.
    // However, exact iteration order of the pool depends on implementation details,
    // so we traverse via the CFG starting at entry.

    const d_entry = dest_func.body.entry;

    // Entry should have 2 instructions: stack_alloc, br_if
    var entry_it = d_entry.iterate();

    const d_inst_1 = entry_it.next().?; // stack_alloc
    try testing.expect(d_inst_1.isOperation());
    try testing.expectEqual(ir.Instruction.Operation.stack_alloc, d_inst_1.asOperation().?);

    const d_inst_2 = entry_it.next().?; // br_if
    try testing.expect(d_inst_2.isTermination());
    try testing.expectEqual(ir.Instruction.Termination.br_if, d_inst_2.asTermination().?);

    // Verify br_if operands
    const br_operands = d_inst_2.operands();
    try testing.expectEqual(@as(usize, 3), br_operands.len);

    // Op 0: Condition (Reference to d_inst_1)
    try testing.expect(br_operands[0].operand == .variable);
    try testing.expectEqual(d_inst_1, br_operands[0].operand.variable);

    // Op 1: Then Block
    try testing.expect(br_operands[1].operand == .block);
    const d_then = br_operands[1].operand.block;
    try testing.expectEqualStrings("then_case", d_then.name.?.value);

    // Op 2: Else Block
    try testing.expect(br_operands[2].operand == .block);
    const d_else = br_operands[2].operand.block;
    try testing.expectEqualStrings("else_case", d_else.name.?.value);

    // Verify contents of Then block
    var then_it = d_then.iterate();
    const d_then_ret = then_it.next().?;
    try testing.expectEqual(ir.Instruction.Termination.@"return", d_then_ret.asTermination().?);

    // Verify contents of Else block
    var else_it = d_else.iterate();
    const d_else_ret = else_it.next().?;
    try testing.expectEqual(ir.Instruction.Termination.@"return", d_else_ret.asTermination().?);
}
