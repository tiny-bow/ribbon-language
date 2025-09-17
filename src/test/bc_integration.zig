const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.bc_integration);

const ribbon = @import("ribbon_language");
const binary = ribbon.binary;
const core = ribbon.core;
const bc = ribbon.bytecode;

// test {
//     std.debug.print("bc_integration", .{});
// }

/// A helper struct to reduce boilerplate in tests.
fn TestBed(comptime test_name: []const u8) type {
    return struct {
        gpa: std.mem.Allocator,
        builder: bc.TableBuilder,

        fn init() !TestBed(test_name) {
            log.debug("Begin test \"{s}\"", .{test_name});
            var self: TestBed(test_name) = undefined;
            self.gpa = std.testing.allocator;
            self.builder = bc.TableBuilder.init(self.gpa, null);
            // testing.log_level = .debug;
            return self;
        }

        fn deinit(self: *TestBed(test_name)) void {
            self.builder.deinit();
            log.debug("End test \"{s}\"", .{test_name});
        }
    };
}

test "encode simple function with wide instruction" {
    var tb = try TestBed("encode simple function with wide instruction").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 0x1234);
    try entry_block.instr(.i_add64, .{ .Rx = .r0, .Ry = .r1, .Rz = .r1 });
    try entry_block.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

    const expected =
        \\    bit_copy64c r1 .. I:0000000000001234
        \\    i_add64 r0 r1 r1
        \\    return r0
        \\
    ;
    try testing.expectEqualStrings(expected, disas_w.written());
}

test "encode function with branch and dead code" {
    var tb = try TestBed("encode function with branch and dead code").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    var exit_block = try main_fn.createBlock();
    var dead_block = try main_fn.createBlock(); // Should not be encoded

    try entry_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 1);
    try entry_block.instrBr(exit_block.id);

    try dead_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 999);
    try dead_block.instrTerm(.halt, .{});

    try exit_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 2);
    try exit_block.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

    const expected =
        \\    bit_copy64c r0 .. I:0000000000000001
        \\    br I:0001
        \\    bit_copy64c r0 .. I:0000000000000002
        \\    return r0
        \\    bit_copy64c r0 .. I:00000000000003e7
        \\    halt
        \\
    ;
    try testing.expectEqualStrings(expected, disas_w.written());
}

test "encode function call" {
    var tb = try TestBed("encode function call").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const add_id = try tb.builder.createHeaderEntry(.function, "add");

    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var add_fn = try tb.builder.createFunctionBuilder(add_id);

    // main function
    var main_entry = try main_fn.createBlock();
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 10);
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r2 }, 20);
    try main_entry.instrCall(.call_c, .{ .R = .r0, .F = add_id, .I = 2 }, .fromSlice(&.{ .r1, .r2 }));
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // add function
    var add_entry = try add_fn.createBlock();
    try add_entry.instr(.i_add64, .{ .Rx = .r0, .Ry = .r0, .Rz = .r1 });
    try add_entry.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Disassemble and check main
    {
        var disas_w = std.io.Writer.Allocating.init(tb.gpa);
        defer disas_w.deinit();

        const main_func = table.bytecode.get(main_id);
        const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
        try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

        const expected_main =
            \\    bit_copy64c r1 .. I:000000000000000a
            \\    bit_copy64c r2 .. I:0000000000000014
            \\    call_c r0 F:00000001 I:02 .. (r1 r2)
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_main, disas_w.written());
    }

    // Disassemble and check add
    {
        var disas_w = std.io.Writer.Allocating.init(tb.gpa);
        defer disas_w.deinit();
        const add_func = table.bytecode.get(add_id);
        const code_slice = add_func.extents.base[0..@divExact(@intFromPtr(add_func.extents.upper) - @intFromPtr(add_func.extents.base), @sizeOf(core.InstructionBits))];
        try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

        const expected_add =
            \\    i_add64 r0 r0 r1
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_add, disas_w.written());
    }
}

test "encode static data reference" {
    var tb = try TestBed("encode static data reference").init();
    defer tb.deinit();

    // Create and build a constant data static
    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "my_const");
    const data_builder = try tb.builder.createDataBuilder(const_id);
    data_builder.alignment = @alignOf(u64);
    try data_builder.writeValue(@as(u64, 0xCAFEBABE_DECAF_BAD));

    // Create a function that references the constant
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    try entry_block.instrAddrOf(.addr_c, .r0, const_id);
    try entry_block.instr(.load64, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    try entry_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Check that the loaded constant is correct
    const data: *const core.Constant = table.bytecode.get(const_id);
    const data_ptr: *const u64 = @ptrCast(@alignCast(data.asPtr()));
    try testing.expectEqual(@as(u64, 0xCAFEBABE_DECAF_BAD), data_ptr.*);

    // Check disassembly

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const main_func = table.bytecode.get(main_id);
    const main_len = @divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits));
    try bc.disas(main_func.extents.base[0..main_len], .{ .buffer_address = false }, &disas_w.writer);

    const expected_disas =
        \\    addr_c r0 C:00000000
        \\    load64 r1 r0 I:00000000
        \\    return r1
        \\
    ;
    try testing.expectEqualStrings(expected_disas, disas_w.written());
}

test "encode external reference creates linker fixup" {
    var tb = try TestBed("encode external reference creates linker fixup").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const external_id = try tb.builder.createHeaderEntry(.function, "my.external.func");

    // Create builder for main, but not for the external function
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();
    try entry_block.instrCall(.call_c, .{ .R = .r0, .F = external_id, .I = 0 }, .{});
    try entry_block.instrTerm(.halt, .{});

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // We expect one unbound location: the external function
    try testing.expectEqual(@as(usize, 1), table.linker_map.unbound.count());

    const external_loc_id = tb.builder.locations.localLocationId(external_id);
    const linker_loc = table.linker_map.unbound.get(external_loc_id).?;

    // It should have one fixup associated with it (from the address table entry)
    try testing.expectEqual(@as(usize, 1), linker_loc.fixups.count());

    var fixup_it = linker_loc.fixups.iterator();
    const fixup = fixup_it.next().?.key_ptr;

    // The fixup should be to resolve the absolute address of the external function
    // and write it into the address table.
    try testing.expectEqual(binary.FixupKind.absolute, fixup.kind);
    try testing.expectEqual(binary.LinkerFixup.Basis.to, fixup.basis);
    try testing.expect(fixup.bit_offset == null);
}

test "block builder error on double-termination" {
    var tb = try TestBed("block builder error on double-termination").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var block = try main_fn.createBlock();
    try block.instrTerm(.halt, .{});
    try testing.expectError(error.BadEncoding, block.instrTerm(.@"return", .{ .R = .r0 }));
}

test "table builder error on wrong static kind" {
    var tb = try TestBed("table builder error on wrong static kind").init();
    defer tb.deinit();

    // Create a constant ID
    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "my_const");

    // Try to create a function builder with it, should fail.
    try testing.expectError(error.BadEncoding, tb.builder.createFunctionBuilder(const_id.cast(core.Function)));

    // Create a function ID
    const func_id: core.FunctionId = try tb.builder.createHeaderEntry(.function, "my_func");

    // Try to create a data builder with it, should fail.
    try testing.expectError(error.BadEncoding, tb.builder.createDataBuilder(func_id));
}

test "encode local variable reference" {
    var tb = try TestBed("encode local variable reference").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    const local_a = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_b = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_c = try main_fn.createLocal(.{ .size = 32, .alignment = 16 });

    var entry_block = try main_fn.createBlock();

    try entry_block.instrAddrOf(.addr_l, .r1, local_b);
    try entry_block.instrAddrOf(.addr_l, .r1, local_a);
    try entry_block.instrAddrOf(.addr_l, .r1, local_c);

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

    const expected =
        \\    addr_l r1 I:0028
        \\    addr_l r1 I:0020
        \\    addr_l r1 I:0000
        \\    unreachable
        \\
    ;
    try testing.expectEqualStrings(expected, disas_w.written());
}

test "encode function with conditional branch" {
    var tb = try TestBed("encode function with conditional branch").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    var then_block = try main_fn.createBlock();
    var else_block = try main_fn.createBlock();
    var merge_block = try main_fn.createBlock();

    // entry: if (r0 != 0) goto then_block else goto else_block
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 1); // condition will be true
    try entry_block.instrBrIf(.r0, then_block.id, else_block.id);

    // then: r1 = 1; goto merge_block
    try then_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 1);
    try then_block.instrBr(merge_block.id);

    // else: r1 = 2; goto merge_block
    try else_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 2);
    try else_block.instrBr(merge_block.id);

    // merge: return r1
    try merge_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

    // Expected offsets are calculated based on sequential layout of visited blocks: entry, then, else, merge.
    // br_if (word 2) -> then (word 3, offset +1), else (word 6, offset +4)
    // br in then (word 5) -> merge (word 9, offset +4)
    // br in else (word 8) -> merge (word 9, offset +1)
    const expected =
        \\    bit_copy64c r0 .. I:0000000000000001
        \\    br_if r0 Ix:0001 Iy:0004
        \\    bit_copy64c r1 .. I:0000000000000001
        \\    br I:0004
        \\    bit_copy64c r1 .. I:0000000000000002
        \\    br I:0001
        \\    return r1
        \\
    ;
    try testing.expectEqualStrings(expected, disas_w.written());
}

test "data builder with internal pointer fixup" {
    var tb = try TestBed("data builder with internal pointer fixup").init();
    defer tb.deinit();

    const Node = struct {
        value: u64,
        next: ?*const @This(),
    };

    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "linked_list");
    const data_builder = try tb.builder.createDataBuilder(const_id);
    data_builder.alignment = @alignOf(Node);

    // Node 1
    const node1_rel = data_builder.getRelativeAddress();
    _ = node1_rel;
    try data_builder.writeValue(@as(u64, 111));
    const node1_next_rel = data_builder.getRelativeAddress();
    try data_builder.writeValue(@as(?*const Node, null)); // placeholder for next pointer

    // Node 2
    const node2_rel = data_builder.getRelativeAddress();
    try data_builder.writeValue(@as(u64, 222));
    try data_builder.writeValue(@as(?*const Node, null)); // next is null for the last node

    // Fixup Node 1's next pointer to point to Node 2
    try data_builder.bindFixup(.absolute, node1_next_rel, .{ .internal = .{ .relative = node2_rel } }, null);

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify the structure after encoding and linking
    const data: *const core.Constant = table.bytecode.get(const_id);
    const node1_ptr: *const Node = @ptrCast(@alignCast(data.asPtr()));

    try testing.expectEqual(@as(u64, 111), node1_ptr.value);
    try testing.expect(node1_ptr.next != null);

    const node2_ptr = node1_ptr.next orelse unreachable;
    try testing.expectEqual(@as(u64, 222), node2_ptr.value);
    try testing.expect(node2_ptr.next == null);

    // Check that node2_ptr is at the correct offset from node1_ptr
    const offset = @as(isize, @intCast(@intFromPtr(node2_ptr))) - @as(isize, @intCast(@intFromPtr(node1_ptr)));
    try testing.expectEqual(@as(isize, @sizeOf(Node)), offset);
}

test "data builder with external function pointer fixup" {
    var tb = try TestBed("data builder with external function pointer fixup").init();
    defer tb.deinit();

    const StructWithFnPtr = struct {
        id: u64,
        handler: ?*const fn () void,
    };

    const func_id = try tb.builder.createHeaderEntry(.function, "my_func");
    var fn_builder = try tb.builder.createFunctionBuilder(func_id);
    var entry = try fn_builder.createBlock();
    try entry.instrTerm(.halt, .{});

    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "my_struct");
    var data_builder = try tb.builder.createDataBuilder(const_id);
    data_builder.alignment = @alignOf(StructWithFnPtr);

    const func_loc = tb.builder.getStaticLocation(func_id.cast(anyopaque)).?;

    // Write placeholder struct
    try data_builder.writeValue(@as(u64, 42)); // id
    const handler_ptr_rel = data_builder.getRelativeAddress();
    try data_builder.writeValue(@as(?*const fn () void, null)); // handler placeholder

    // Bind a fixup to patch the handler address later
    try data_builder.bindFixup(.absolute, handler_ptr_rel, .{ .standard = .{ .location = func_loc } }, null);

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify
    const data: *const core.Constant = table.bytecode.get(const_id);
    const my_struct_ptr: *const StructWithFnPtr = @ptrCast(@alignCast(data.asPtr()));

    const func_ptr = table.bytecode.get(func_id);

    try testing.expectEqual(@as(u64, 42), my_struct_ptr.id);
    try testing.expect(my_struct_ptr.handler == @as(?*const fn () void, @ptrCast(func_ptr)));
}

test "decoder with incomplete wide instruction" {
    const gpa = testing.allocator;

    var instructions = try gpa.alloc(core.InstructionBits, 1);
    defer gpa.free(instructions);

    // bit_copy64c is a wide instruction, so it requires a second word for its immediate value.
    const instr = bc.Instruction{ .code = .bit_copy64c, .data = .{ .bit_copy64c = .{ .R = .r1 } } };
    instructions[0] = instr.toBits();

    var decoder = bc.Decoder.init(instructions);
    // The decoder should find the first word, but fail to read the second.
    try testing.expectError(error.BadEncoding, decoder.next());
}

test "decoder with incomplete call instruction" {
    const gpa = testing.allocator;
    var instructions = try gpa.alloc(core.InstructionBits, 1);
    defer gpa.free(instructions);

    // call_c with I=2 expects 16 bytes (2 words) of arguments after it.
    const instr = bc.Instruction{ .code = .call_c, .data = .{ .call_c = .{ .R = .r0, .F = .fromInt(1), .I = 2 } } };
    instructions[0] = instr.toBits();

    var decoder = bc.Decoder.init(instructions);
    // The decoder should see the call, but fail to read the arguments.
    try testing.expectError(error.BadEncoding, decoder.next());
}

test "encode handler set" {
    var tb = try TestBed("encode handler set").init();
    defer tb.deinit();

    // IDs for our functions and effects
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.builder.createHeaderEntry(.function, "my_handler");
    const handler_set_id = try tb.builder.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.builder.createHeaderEntry(.effect, "my_effect");
    try tb.builder.bindEffect(effect_id, @enumFromInt(0));

    // Main function builder
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    // Handler function builder
    var handler_fn = try tb.builder.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();
    try handler_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 42); // return 42
    try handler_entry.instrTerm(.@"return", .{ .R = .r0 });

    // Handler set builder
    var handler_set = try tb.builder.createHandlerSet(handler_set_id);
    _ = try handler_set.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set);

    // Main function body
    var main_entry = try main_fn.createBlock();
    try main_entry.pushHandlerSet(handler_set);
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try main_entry.popHandlerSet(handler_set);
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // Encode
    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify main function disassembly
    {
        var disas_w = std.io.Writer.Allocating.init(tb.gpa);
        defer disas_w.deinit();
        const main_func = table.bytecode.get(main_id);
        const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
        try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

        const expected_main =
            \\    push_set H:00000002
            \\    prompt r0 E:00000003 I:00 .. ()
            \\    pop_set
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_main, disas_w.written());
    }

    // Verify handler function disassembly
    {
        var disas_w = std.io.Writer.Allocating.init(tb.gpa);
        defer disas_w.deinit();
        const handler_func: *const core.Function = table.bytecode.get(handler_fn_id);
        const code_slice = handler_func.extents.base[0..@divExact(@intFromPtr(handler_func.extents.upper) - @intFromPtr(handler_func.extents.base), @sizeOf(core.InstructionBits))];
        try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

        const expected_handler =
            \\    bit_copy64c r0 .. I:000000000000002a
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_handler, disas_w.written());
    }
}

test "encode handler set with cancellation" {
    var tb = try TestBed("encode handler set with cancellation").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.builder.createHeaderEntry(.function, "cancelling_handler");
    const handler_set_id = try tb.builder.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.builder.createHeaderEntry(.effect, "my_effect");
    try tb.builder.bindEffect(effect_id, @enumFromInt(0));

    var handler_fn = try tb.builder.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();
    try handler_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 99);
    try handler_entry.instrTerm(.cancel, .{ .R = .r0 });

    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();
    var cancel_block = try main_fn.createBlock();

    var handler_set = try tb.builder.createHandlerSet(handler_set_id);
    try main_fn.bindHandlerSet(handler_set);
    handler_set.register = .r1;

    _ = try handler_set.bindHandler(effect_id, handler_fn);

    // Entry block: push, prompt, then branch to the cancellation block to ensure it's assembled
    try entry_block.pushHandlerSet(handler_set);
    try entry_block.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try entry_block.instrTerm(.halt, .{});

    // Cancellation block: pop and return value
    try cancel_block.popHandlerSet(handler_set);
    try cancel_block.bindHandlerSetCancellationLocation(handler_set);
    try cancel_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    const main_func = table.bytecode.get(main_id);
    const set: *const core.HandlerSet = table.bytecode.get(handler_set_id);
    const cancel_addr = set.cancellation.address;

    // The entry block has 3 instructions (push, prompt, br), taking 3 words.
    // The cancellation block should therefore start at an offset of 3 words from the function base.
    // The cancellation address should be after the pop instruction, which is the first instruction in the cancel block, meaning a total of 4 word offset.
    const cancel_block_start_addr = @intFromPtr(main_func.extents.base) + 4 * @sizeOf(core.InstructionBits);
    try testing.expectEqual(cancel_block_start_addr, @intFromPtr(cancel_addr));
    try testing.expectEqual(core.Register.r1, set.cancellation.register);
}

test "encode handler set with upvalues" {
    var tb = try TestBed("encode handler set with upvalues").init();
    defer tb.deinit();

    // IDs
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.builder.createHeaderEntry(.function, "upvalue_handler");
    const handler_set_id = try tb.builder.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.builder.createHeaderEntry(.effect, "my_effect");
    try tb.builder.bindEffect(effect_id, @enumFromInt(0));

    // Main function with locals
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    const local_x = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_y = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });

    // Handler function that uses upvalues
    var handler_fn = try tb.builder.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();

    // Handler set that captures locals as upvalues
    var handler_set = try tb.builder.createHandlerSet(handler_set_id);
    const upvalue_y = try handler_set.createUpvalue(local_y);
    _ = try handler_set.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set);

    // Now define the handler body using the upvalue id
    try handler_entry.instrAddrOf(.addr_u, .r0, upvalue_y);
    try handler_entry.instr(.load64, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    try handler_entry.instrTerm(.@"return", .{ .R = .r1 });

    // Main function body
    var main_entry = try main_fn.createBlock();
    // Initialize local y to 123
    try main_entry.instrAddrOf(.addr_l, .r0, local_y);
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 123);
    try main_entry.instr(.store64, .{ .Rx = .r0, .Ry = .r1, .I = 0 });
    _ = local_x; // to ensure it gets a stack slot and affects layout

    // Prompt the effect
    try main_entry.pushHandlerSet(handler_set);
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try main_entry.popHandlerSet(handler_set);
    try main_entry.instrTerm(.halt, .{});

    // Encode
    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify handler function disassembly

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const h_func: *const core.Function = table.bytecode.get(handler_fn_id);
    const code_slice = h_func.extents.base[0..@divExact(@intFromPtr(h_func.extents.upper) - @intFromPtr(h_func.extents.base), @sizeOf(core.InstructionBits))];
    try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

    const expected_handler =
        \\    addr_u r0 I:0008
        \\    load64 r1 r0 I:00000000
        \\    return r1
        \\
    ;
    try testing.expectEqualStrings(expected_handler, disas_w.written());
}

// This is just a placeholder for the test. It won't be called.
fn dummyBuiltinProc(fiber: *core.Fiber) callconv(.c) core.Builtin.Signal {
    _ = fiber;
    return core.Builtin.Signal.@"return";
}

test "bind builtin function" {
    var tb = try TestBed("bind builtin function").init();
    defer tb.deinit();

    // Create an entry for the builtin function
    const builtin_id: core.BuiltinId = try tb.builder.createHeaderEntry(.builtin, "my_builtin_func");

    // Bind the native Zig function to the ID
    try tb.builder.bindBuiltinProcedure(builtin_id, dummyBuiltinProc);

    // Create a main function to test calling this builtin
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    // Call the builtin function
    try entry_block.instrCall(.call_c, .{ .R = .r0, .F = builtin_id.cast(core.Function), .I = 0 }, .{});
    try entry_block.instrTerm(.halt, .{});

    // Encode the table
    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verification
    // 1. Check the address in the header
    const builtin_addr: *const core.Builtin = table.bytecode.get(builtin_id);
    try testing.expectEqual(builtin_addr.kind, .builtin);
    try testing.expectEqual(@intFromPtr(&dummyBuiltinProc), builtin_addr.addr);

    // 2. Check the disassembly

    var disas_w = std.io.Writer.Allocating.init(tb.gpa);
    defer disas_w.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try bc.disas(code_slice, .{ .buffer_address = false }, &disas_w.writer);

    const expected_disas =
        \\    call_c r0 F:00000000 I:00 .. ()
        \\    halt
        \\
    ;
    try testing.expectEqualStrings(expected_disas, disas_w.written());
}
