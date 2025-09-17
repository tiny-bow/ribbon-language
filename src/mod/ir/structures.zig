/// Comptime data structure describing the kinds of structural nodes in the ir. Type is `ir.Structures`.
pub const structures = .{
    .kind = .{
        .output_tag = .{ .primitive, .kind_tag },
        .input_kinds = .{ .collection, .kind },
    },
    .constructor = .{
        .kind = .{ .structure, .kind },
    },
    .type = .{
        .constructor = .{ .structure, .constructor },
        .input_types = .{ .collection, .type },
    },
    .effect = .{
        .handler_types = .{ .collection, .type },
    },
    .constant = .{
        .type = .{ .structure, .type },
        .value = .any,
    },
    .global = .{
        .type = .{ .structure, .type },
        .initializer = .{ .structure, .constant },
    },
    .local = .{ .type = .{ .structure, .type } },
    .handler = .{
        .parent_block = .{ .structure, .block }, // the block that this handler is alive within
        .function = .{ .structure, .function }, // the function that implements the handler
        .handled_effect = .{ .structure, .effect }, // the effect that this handler can handle
        .cancellation_type = .{ .structure, .type }, // the type that this handler can cancel the effect with
    },
    .function = .{
        .parent_handler = .{ .structure, .handler }, // the handler that this function is a part of, if any
        .body_block = .{ .structure, .block },
        .type = .{ .structure, .type },
    },
    .block = .{
        .parent = .{ .structure, .nil }, // either a block, function, or constant
        .locals = .{ .collection, .local },
        .handlers = .{ .collection, .handler },
        .contents = .{ .collection, .nil }, // a collection of either blocks or instructions
        .type = .{ .structure, .type }, // the type of data yielded by the block
    },
    .instruction = .{
        .parent = .{ .structure, .block }, // the block that contains this instruction
        .operation = .{ .primitive, .operation }, // the operation performed by this instruction
        .type = .{ .structure, .type }, // the type of data yielded by the instruction
    },
    .ctrl_edge = .{
        .source = .{ .structure, .nil }, // either a block or an instruction
        .destination = .{ .structure, .nil }, // either a block or an instruction
        .source_index = .{ .primitive, .index }, // the index of the edge in the source
        .destination_index = .{ .primitive, .index }, // the index of the edge in the destination
    },
    .data_edge = .{
        .source = .{ .structure, .nil }, // either a block or an instruction
        .destination = .{ .structure, .nil }, // either a block or an instruction
        .source_index = .{ .primitive, .index }, // the index of the edge in the source
        .destination_index = .{ .primitive, .index }, // the index of the edge in the destination
    },
    .global_symbol = .{
        .name = .{ .data, .name },
        .node = .any,
    },
    .debug_symbols = .{
        .name = .{ .collection, .name },
        .node = .any,
    },
    .debug_sources = .{
        .source = .{ .collection, .source },
        .node = .any,
    },
    .foreign = .{
        .address = .{ .primitive, .index }, // the address of the foreign function
    },
    .builtin = .{
        .address = .{ .primitive, .index }, // the address of the builtin function
    },
    .intrinsic = .{
        .data = .any, // the data of the intrinsic function; usually, a bytecode opcode
    },
};
