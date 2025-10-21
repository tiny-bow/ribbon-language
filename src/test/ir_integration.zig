const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.ir_integration);

const ribbon = @import("ribbon_language");
const common = ribbon.common;
const ir = ribbon.ir;

// test {
//     std.debug.print("ir_integration", .{});
// }

test "ir integration - basic context operations" {
    const gpa = testing.allocator;

    // Create root context
    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Test basic node creation
    const int_node = try ctx.addPrimitive(.constant, @as(u64, 42));
    const name_node = try ctx.internName("test_variable");

    // Verify nodes were created
    try testing.expect(int_node != ir.Ref.nil);
    try testing.expect(name_node != ir.Ref.nil);

    // Test data retrieval
    const int_data = ctx.getNodeData(int_node);
    try testing.expect(int_data != null);
    try testing.expectEqual(@as(u64, 42), int_data.?.primitive);

    const name_data = ctx.getNodeData(name_node);
    try testing.expect(name_data != null);
    try testing.expectEqualStrings("test_variable", name_data.?.name);
}

test "ir integration - struct type creation with packed layout" {
    const gpa = testing.allocator;

    // Create root context
    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Create basic types for struct fields
    const u32_type = try ctx.builder.integer_type(.unsigned, 32);
    const u16_type = try ctx.builder.integer_type(.unsigned, 16);
    const u8_type = try ctx.builder.integer_type(.unsigned, 8);

    // Create field names
    const field1_name = try ctx.builder.symbol("x");
    const field2_name = try ctx.builder.symbol("y");
    const field3_name = try ctx.builder.symbol("z");

    // Create packed layout symbol
    const packed_layout = try ctx.builder.symbol("packed");

    // Create the struct type with packed layout and three fields
    const field_names = [_]ir.Ref{ field1_name, field2_name, field3_name };
    const field_types = [_]ir.Ref{ u32_type, u16_type, u8_type };

    const struct_type = try ctx.builder.struct_type(packed_layout, &field_names, &field_types);

    // Verify the struct type was created
    try testing.expect(struct_type != ir.Ref.nil);
    try testing.expectEqual(ir.Tag.structure, struct_type.node_kind.getTag());
    try testing.expectEqual(ir.StructureKind.type, ir.discriminants.force(ir.StructureKind, struct_type.node_kind.getDiscriminator()));

    // Verify we can get the constructor and input types
    const constructor = try ctx.getField(struct_type, .constructor) orelse return error.InvalidGraphState;
    const input_types = try ctx.getField(struct_type, .input_types) orelse return error.InvalidGraphState;

    try testing.expect(constructor != ir.Ref.nil);
    try testing.expect(input_types != ir.Ref.nil);

    // Verify the input types list contains our field information
    const children = try ctx.getChildren(input_types);
    try testing.expect(children.len > 0);
}

test "ir integration - interning and node reuse" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Test primitive interning
    const int1 = try ctx.internPrimitive(@as(u64, 100));
    const int2 = try ctx.internPrimitive(@as(u64, 100));

    // Should be the same reference (interned)
    try testing.expectEqual(int1, int2);

    // Test buffer interning
    const buf1 = try ctx.internBuffer("hello world");
    const buf2 = try ctx.internBuffer("hello world");

    // Should be the same reference (interned)
    try testing.expectEqual(buf1, buf2);

    // Different content should give different references
    const buf3 = try ctx.internBuffer("different");
    try testing.expect(buf1.id.node != buf3.id.node);
}

test "ir integration - user data management" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Create a test node
    const test_ref = try ctx.addPrimitive(.constant, @as(u64, 42));

    // Get user data for the node
    const userdata = try ctx.getUserData(test_ref);
    try testing.expect(userdata.context == ctx);

    // Test adding custom data
    const test_value: u32 = 12345;
    try userdata.addData(.test_key, @constCast(&test_value));

    // Test retrieving custom data
    const retrieved = userdata.getData(u32, .test_key);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(u32, 12345), retrieved.?.*);

    // Test deleting custom data
    userdata.delData(.test_key);
    const after_delete = userdata.getData(*const u32, .test_key);
    try testing.expect(after_delete == null);
}

test "ir integration - list and collection operations" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Create some test references
    const ref1 = try ctx.addPrimitive(.constant, @as(u64, 1));
    const ref2 = try ctx.addPrimitive(.constant, @as(u64, 2));
    const ref3 = try ctx.addPrimitive(.constant, @as(u64, 3));

    const refs = [_]ir.Ref{ ref1, ref2, ref3 };

    // Create a list
    const list_ref = try ctx.addList(.constant, .index, &refs);
    try testing.expect(list_ref != ir.Ref.nil);
    try testing.expectEqual(ir.Tag.collection, list_ref.node_kind.getTag());

    // Get children from the list
    const children = try ctx.getChildren(list_ref);
    try testing.expectEqual(@as(u64, 3), children.len);
    try testing.expectEqual(ref1, children[0]);
    try testing.expectEqual(ref2, children[1]);
    try testing.expectEqual(ref3, children[2]);

    // Test interned list
    const interned_list = try ctx.internList(.index, &refs);
    try testing.expect(interned_list != ir.Ref.nil);

    // Create the same list again - should be interned
    const interned_list2 = try ctx.internList(.index, &refs);
    try testing.expectEqual(interned_list, interned_list2);
}

test "ir integration - builtin types and operations" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // Test getting builtin kinds
    const data_kind = try ctx.getBuiltin(.data_kind);
    const primitive_kind = try ctx.getBuiltin(.primitive_kind);

    try testing.expect(data_kind != ir.Ref.nil);
    try testing.expect(primitive_kind != ir.Ref.nil);

    // Test integer type creation
    const i32_type = try ctx.builder.integer_type(.signed, 32);
    const u64_type = try ctx.builder.integer_type(.unsigned, 64);

    try testing.expect(i32_type != ir.Ref.nil);
    try testing.expect(u64_type != ir.Ref.nil);

    // Different types should have different references
    try testing.expect(i32_type.id.node != u64_type.id.node);

    // Test symbol type creation
    const symbol_type = try ctx.builder.symbol("my_symbol");
    try testing.expect(symbol_type != ir.Ref.nil);
}

test "ir integration - discriminant utilities" {
    const data_disc: ir.Discriminator = .name;
    const data_kind = ir.discriminants.cast(ir.DataKind, data_disc);
    try testing.expect(data_kind != null);
    try testing.expectEqual(ir.DataKind.name, data_kind.?);

    const prim_disc: ir.Discriminator = .operation;
    const prim_kind = ir.discriminants.cast(ir.PrimitiveKind, prim_disc);
    try testing.expect(prim_kind != null);
    try testing.expectEqual(ir.PrimitiveKind.operation, prim_kind.?);

    // Test invalid conversion
    const invalid = ir.discriminants.cast(ir.DataKind, prim_disc);
    try testing.expect(invalid == null);

    // Test force conversion
    const forced = ir.discriminants.force(ir.DataKind, data_disc);
    try testing.expectEqual(ir.DataKind.name, forced);
}

test "ir integration - node kind operations" {
    const data_kind = ir.NodeKind.data(.name);
    try testing.expectEqual(ir.Tag.data, data_kind.getTag());
    try testing.expectEqual(ir.DataKind.name, ir.discriminants.force(ir.DataKind, data_kind.getDiscriminator()));

    const prim_kind = ir.NodeKind.primitive(.operation);
    try testing.expectEqual(ir.Tag.primitive, prim_kind.getTag());
    try testing.expectEqual(ir.PrimitiveKind.operation, ir.discriminants.force(ir.PrimitiveKind, prim_kind.getDiscriminator()));

    const struct_kind = ir.NodeKind.structure(.type);
    try testing.expectEqual(ir.Tag.structure, struct_kind.getTag());
    try testing.expectEqual(ir.StructureKind.type, ir.discriminants.force(ir.StructureKind, struct_kind.getDiscriminator()));

    const coll_kind = ir.NodeKind.collection(.index);
    try testing.expectEqual(ir.Tag.collection, coll_kind.getTag());
    try testing.expectEqual(ir.Discriminator.index, coll_kind.getDiscriminator());
}

test "ir integration - child context creation" {
    const gpa = testing.allocator;

    const root_ctx = try ir.Context.init(gpa);
    defer root_ctx.deinit();

    // Create child context
    const child_ctx = try root_ctx.inner.root.createContext();

    // Verify child context properties
    try testing.expect(!child_ctx.isRoot());
    try testing.expectEqual(root_ctx, child_ctx.getRootContext());
    try testing.expect(child_ctx.id.toInt() != 0);

    // Test that we can create nodes in child context
    const test_node_in_child = try child_ctx.addPrimitive(.constant, @as(u64, 999));
    try testing.expect(test_node_in_child != ir.Ref.nil);
    try testing.expectEqual(child_ctx.id, test_node_in_child.id.context);

    // Destroy this child context before we test merging with a new one
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        root.destroyContext(child_ctx.id);
        root.mutex.unlock();
    }
}

test "ir integration - merging child context into root" {
    const gpa = testing.allocator;

    const root_ctx = try ir.Context.init(gpa);
    defer root_ctx.deinit();

    // Create child context
    const child_ctx = try root_ctx.asRoot().?.createContext();
    const child_id = child_ctx.id;

    // Populate root and child contexts with a mix of shared and unique nodes
    const root_shared_node = try root_ctx.internPrimitive(@as(u64, 42));

    const child_unique_node = try child_ctx.internPrimitive(@as(u64, 123));
    const child_shared_node = try child_ctx.internPrimitive(@as(u64, 42)); // Same content as root_shared_node

    // Create a list in the child that references other child nodes
    const child_list_refs = [_]ir.Ref{ child_unique_node, child_shared_node };
    const child_list = try child_ctx.internList(.index, &child_list_refs);

    // Add UserData to the list node in the child context
    const child_userdata_val: u32 = 54321;
    // An enum literal is needed for the key
    const child_userdata = try child_ctx.getUserData(child_list);
    try child_userdata.addData(.test_key, @constCast(&child_userdata_val));

    // Perform the merge
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        // Don't defer unlock here, merge might call functions that need the lock
        try root.merge(child_ctx);
        root.mutex.unlock();
    }

    // Verify child context was destroyed by checking if it's still in the root's map
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        defer root.mutex.unlock();
        try testing.expect(root.getContext(child_id) == null);
    }

    // Find the nodes in the root context and verify their new refs
    const merged_unique_node = try root_ctx.internPrimitive(@as(u64, 123));
    const merged_shared_node = try root_ctx.internPrimitive(@as(u64, 42));

    // The unique node should now be in the root context
    try testing.expectEqual(root_ctx.id, merged_unique_node.id.context);

    // The shared node should have been mapped to the pre-existing root node
    try testing.expectEqual(root_shared_node, merged_shared_node);

    // Find the merged list and verify its children and UserData
    const merged_list_refs = [_]ir.Ref{ merged_unique_node, merged_shared_node };
    const merged_list = try root_ctx.internList(.index, &merged_list_refs);

    // The list itself should now be in the root context
    try testing.expectEqual(root_ctx.id, merged_list.id.context);

    // Check its children to ensure refs were remapped
    const children = try root_ctx.getChildren(merged_list);
    try testing.expectEqual(2, children.len);
    try testing.expectEqual(merged_unique_node, children[0]);
    try testing.expectEqual(merged_shared_node, children[1]);

    // Check that its UserData was transferred
    const merged_userdata = try root_ctx.getUserData(merged_list);
    const retrieved_data = merged_userdata.getData(u32, .test_key);
    try testing.expect(retrieved_data != null);
    try testing.expectEqual(child_userdata_val, retrieved_data.?.*);
}

test "ir integration - merging child context with cyclic nodes" {
    const gpa = testing.allocator;

    const root_ctx = try ir.Context.init(gpa);
    defer root_ctx.deinit();

    // Create a child context to build our cyclic graph in.
    const child_ctx = try root_ctx.asRoot().?.createContext();
    const child_id = child_ctx.id;

    // --- Create a cyclic graph in the child context ---
    // This graph represents a simple loop: loop_header -> loop_body -> loop_header

    const type_type = try child_ctx.internStructure(.type, .{
        .constructor = ir.Ref.nil,
        .input_types = ir.Ref.nil,
    });
    const op_branch = try child_ctx.internPrimitive(ir.Operation.unconditional_branch);

    // 1. Create two blocks: a loop header and a loop body.
    const loop_header = try child_ctx.addStructure(.mutable, .block, .{
        .parent = ir.Ref.nil,
        .locals = ir.Ref.nil,
        .handlers = ir.Ref.nil,
        .contents = ir.Ref.nil,
        .type = type_type,
    });
    const loop_body = try child_ctx.addStructure(.mutable, .block, .{
        .parent = ir.Ref.nil,
        .locals = ir.Ref.nil,
        .handlers = ir.Ref.nil,
        .contents = ir.Ref.nil,
        .type = type_type,
    });

    // 2. Create the instruction in the header that branches to the body.
    const branch_to_body_inst = try child_ctx.addStructure(.mutable, .instruction, .{
        .parent = loop_header,
        .operation = op_branch,
        .type = type_type,
        .operands = try child_ctx.addList(.mutable, .block, &.{loop_body}),
    });

    // 3. Create the instruction in the body that branches back to the header (the loop).
    const branch_to_header_inst = try child_ctx.addStructure(.mutable, .instruction, .{
        .parent = loop_body,
        .operation = op_branch,
        .type = type_type,
        .operands = try child_ctx.addList(.mutable, .block, &.{loop_header}),
    });
    // To make the graph fully connected, populate the blocks' contents.
    const header_contents = try child_ctx.addList(.mutable, .instruction, &.{branch_to_body_inst});
    try child_ctx.setField(loop_header, .contents, header_contents);

    const body_contents = try child_ctx.addList(.mutable, .instruction, &.{branch_to_header_inst});
    try child_ctx.setField(loop_body, .contents, body_contents);

    // At this point, `child_ctx` contains a clear cyclic graph:
    // loop_header -> branch_to_body_inst -> branch_to_body_edge -> loop_body
    // loop_body   -> branch_to_header_inst -> branch_to_header_edge -> loop_header

    // Perform the merge. The old implementation would stack overflow.
    {
        const root = root_ctx.asRoot().?;
        root.mutex.lock();
        try root.merge(child_ctx);
        root.mutex.unlock();
    }

    // --- Verification in the Root Context ---
    try testing.expect(root_ctx.asRoot().?.getContext(child_id) == null);

    // Find the merged blocks. We'll identify them by their structure.
    var merged_blocks = common.ArrayList(ir.Ref).empty;
    defer merged_blocks.deinit(gpa);

    var root_it = root_ctx.nodes.keyIterator();
    while (root_it.next()) |ref| {
        if (ref.node_kind.getTag() == .structure and
            ir.discriminants.force(ir.StructureKind, ref.node_kind.getDiscriminator()) == .block)
        {
            try merged_blocks.append(gpa, ref.*);
        }
    }
    try testing.expectEqual(@as(usize, 2), merged_blocks.items.len);

    // We don't know the order, so we find the header by looking for the one
    // that is the destination of the other's edge.
    const block_A = merged_blocks.items[0];
    const block_B = merged_blocks.items[1];

    const instr_A = try root_ctx.getElement(try root_ctx.getField(block_A, .contents) orelse return error.InvalidGraphState, 0) orelse return error.InvalidGraphState;
    const dest_A = try root_ctx.getElement(try root_ctx.getField(instr_A, .operands) orelse return error.InvalidGraphState, 0) orelse return error.InvalidGraphState;

    const instr_B = try root_ctx.getElement(try root_ctx.getField(block_B, .contents) orelse return error.InvalidGraphState, 0) orelse return error.InvalidGraphState;
    const dest_B = try root_ctx.getElement(try root_ctx.getField(instr_B, .operands) orelse return error.InvalidGraphState, 0) orelse return error.InvalidGraphState;

    try std.testing.expectEqual(block_B, dest_A);
    try std.testing.expectEqual(block_A, dest_B);
}

test "ir integration - immutable nodes cannot reference mutable nodes" {
    const gpa = testing.allocator;
    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // 1. Create a mutable node.
    // This will be the reference that our immutable nodes will illegally point to.
    const mutable_list = try ctx.addList(.mutable, .nil, &.{});

    // 2. Define the structure for our test nodes.
    const illegal_struct_value = .{
        .data = mutable_list, // <-- The illegal reference
    };

    // 3. Test failure case 1: Trying to create a non-interned, but immutable, node.
    // We expect this to fail because illegal_struct_value.contents points to a mutable ref.
    // The internal call to _addNode should trigger _ensureConstantRefs, which should fail.
    const immutable_add_result = ctx.addStructure(.constant, .intrinsic, illegal_struct_value);
    try testing.expectError(error.ImmutableNodeReferencesMutable, immutable_add_result);

    // 4. Test failure case 2: Trying to intern a node.
    // We expect this to also fail for the same reason.
    // The internal call to _internNode should trigger _ensureConstantRefs, which should fail.
    const intern_result = ctx.internStructure(.intrinsic, illegal_struct_value);
    try testing.expectError(error.ImmutableNodeReferencesMutable, intern_result);

    // 5. Sanity Check: Confirm that creating a mutable version of the same node SUCCEEDS.
    // This ensures our test isn't failing for some other reason.
    const mutable_add_result = ctx.addStructure(.mutable, .intrinsic, illegal_struct_value);
    try testing.expect(mutable_add_result != error.ImmutableNodeReferencesMutable);
    const success_ref = try mutable_add_result;
    try testing.expect(success_ref != ir.Ref.nil);
}

test "ir integration - global symbol binding" {
    const gpa = testing.allocator;

    const ctx = try ir.Context.init(gpa);
    defer ctx.deinit();

    // --- Test 1: internName functionality ---
    const name_ref_a = try ctx.internName("my_symbol");
    const name_ref_b = try ctx.internName("my_symbol");
    const different_name_ref = try ctx.internName("another_symbol");

    // Interning the same string should yield the exact same reference.
    try testing.expectEqual(name_ref_a, name_ref_b);
    // Different strings should yield different references.
    try testing.expect(name_ref_a != different_name_ref);

    // --- Test 2: Initial binding of a global symbol ---
    const value1_ref = try ctx.internPrimitive(@as(u64, 123));
    const global_symbol_ref = try ctx.bindGlobal("my_global", value1_ref);

    // Verify that a valid, non-nil ref was returned.
    try testing.expect(global_symbol_ref != ir.Ref.nil);

    // Verify the created node is of the correct kind.
    try testing.expectEqual(ir.Tag.structure, global_symbol_ref.node_kind.getTag());
    try testing.expectEqual(
        ir.StructureKind.global_symbol,
        ir.discriminants.force(ir.StructureKind, global_symbol_ref.node_kind.getDiscriminator()),
    );

    // Inspect the created global_symbol node to ensure it's correct.
    const bound_name_ref = try ctx.getField(global_symbol_ref, .name) orelse return error.TestFailed;
    const bound_node_ref = try ctx.getField(global_symbol_ref, .node) orelse return error.TestFailed;

    // Check that the .node field points to our original value.
    try testing.expectEqual(value1_ref, bound_node_ref);

    // Check that the .name field points to an interned name node with the correct string.
    const name_node_data = ctx.getNodeData(bound_name_ref) orelse return error.TestFailed;
    try testing.expectEqualStrings("my_global", name_node_data.name);

    // Check that the reverse mapping from node to export name is correct.
    const export_name = ctx.exported_nodes.get(value1_ref) orelse return error.TestFailed;
    try testing.expectEqualStrings("my_global", export_name);

    // --- Test 3: Rebinding an existing global symbol ---
    const value2_ref = try ctx.internPrimitive(@as(u64, 456));
    const rebound_global_symbol_ref = try ctx.bindGlobal("my_global", value2_ref);

    // Test that rebinding UPDATES the existing global_symbol node, not creates a new one.
    // The reference to the global_symbol node itself should be stable.
    try testing.expectEqual(global_symbol_ref, rebound_global_symbol_ref);

    // Now, inspect the SAME global_symbol node again and check that its .node field points to the NEW value.
    const rebound_node_ref = try ctx.getField(global_symbol_ref, .node) orelse return error.TestFailed;
    try testing.expectEqual(value2_ref, rebound_node_ref);
    try testing.expect(rebound_node_ref != value1_ref); // Sanity check it's not the old value.

    // --- Test 4: Check self-reference protection ---
    // Attempting to bind a symbol to its own global_symbol node should fail.
    try testing.expectError(error.InvalidReference, ctx.bindGlobal("my_global", global_symbol_ref));
}
