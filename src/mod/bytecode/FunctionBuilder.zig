//! A simple builder API for bytecode functions.
const FunctionBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_function_builder);

const core = @import("core");
const common = @import("common");
const binary = @import("binary");

const bytecode = @import("../bytecode.zig");

test {
    // std.debug.print("semantic analysis for bytecode FunctionBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

/// The general allocator used by this function for collections.
gpa: std.mem.Allocator,
/// The arena allocator used by this function for non-volatile data.
arena: std.mem.Allocator,
/// The function's unique identifier.
id: core.FunctionId = .fromInt(0),
/// The function's parent, if it is an effect handler.
parent: ?core.FunctionId = null,
/// The function's basic blocks, unordered.
blocks: bytecode.BlockMap = .empty,
/// The function's local variables, unordered.
locals: bytecode.LocalMap = .empty,
/// The function's local handler set definitions.
handler_sets: bytecode.HandlerSetMap = .empty,

/// Initialize a new builder for a bytecode function.
pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) FunctionBuilder {
    return FunctionBuilder{
        .gpa = gpa,
        .arena = arena,
    };
}

/// Clear the function builder, retaining the current memory capacity.
pub fn clear(self: *FunctionBuilder) void {
    var block_it = self.blocks.valueIterator();
    while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();
    self.blocks.clearRetainingCapacity();

    self.locals.clearRetainingCapacity();

    self.handler_sets.clearRetainingCapacity();

    self.id = .fromInt(0);
    self.parent = null;
}

/// Deinitialize the builder, freeing all memory associated with it.
pub fn deinit(self: *FunctionBuilder) void {
    var block_it = self.blocks.valueIterator();
    while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

    self.blocks.deinit(self.gpa);
    self.locals.deinit(self.gpa);
    self.handler_sets.deinit(self.gpa);

    self.* = undefined;
}

/// Create a new local variable within this function, returning an id for it.
pub fn createLocal(self: *FunctionBuilder, layout: core.Layout) error{OutOfMemory}!core.LocalId {
    const index = self.locals.count();

    if (index > core.LocalId.MAX_INT) {
        log.debug("FunctionBuilder.createLocal: Cannot create more than {d} locals", .{core.LocalId.MAX_INT});
        return error.OutOfMemory;
    }

    const local_id = core.LocalId.fromInt(index);
    const gop = try self.locals.getOrPut(self.gpa, local_id);

    // sanity check: local_id should be fresh if the map has been mutated in append-only fashion
    std.debug.assert(!gop.found_existing);

    gop.value_ptr.* = layout;

    return local_id;
}

/// Get the layout of a local variable by its id.
pub fn getLocal(self: *const FunctionBuilder, id: core.LocalId) ?core.Layout {
    return self.locals.get(id);
}

/// Bind a handler set builder to this function builder.
/// * The handler set builder address may be retrieved later with `getHandlerSet` and the id of the handler set,
///   which is accessible as a field of the builder.
/// * The function builder does not own the handler set builder, so it must be deinitialized separately.
///   Recommended usage pattern is to use `TableBuilder` to manage statics.
pub fn bindHandlerSet(self: *FunctionBuilder, builder: *bytecode.HandlerSetBuilder) error{OutOfMemory}!void {
    if (builder.function) |old_function| {
        log.debug("FunctionBuilder.bindHandlerSet: Handler set builder already bound to function {f}", .{old_function});
        return error.OutOfMemory;
    }

    builder.function = self.id;

    try self.handler_sets.put(self.gpa, builder.id, builder);
}

/// Get a pointer to a handler set builder by its handler set id.
pub fn getHandlerSet(self: *const FunctionBuilder, id: core.HandlerSetId) ?*bytecode.HandlerSetBuilder {
    return self.handler_sets.get(id);
}

/// Create a new basic block within this function, returning a pointer to it.
/// * Note that the returned pointer is owned by the function builder and should not be deinitialized manually.
/// * Use `getBlock` to retrieve the pointer to the block builder by its id (available as a field of the builder).
pub fn createBlock(self: *FunctionBuilder) error{OutOfMemory}!*bytecode.BlockBuilder {
    const index = self.blocks.count();

    if (index > core.StaticId.MAX_INT) {
        log.debug("FunctionBuilder.createBlock: Cannot create more than {d} blocks", .{core.StaticId.MAX_INT});
        return error.OutOfMemory;
    }

    const block_id = core.BlockId.fromInt(index);
    const addr = try self.arena.create(bytecode.BlockBuilder);

    const gop = try self.blocks.getOrPut(self.gpa, block_id);

    // sanity check: block_id should be fresh if the map has been mutated in append-only fashion
    std.debug.assert(!gop.found_existing);

    addr.* = bytecode.BlockBuilder.init(self.gpa, self.arena);
    addr.id = block_id;
    addr.body.function = self.id;

    gop.value_ptr.* = addr;

    return addr;
}

/// Get a pointer to a block builder by its block id.
pub fn getBlock(self: *const FunctionBuilder, id: core.BlockId) ?*bytecode.BlockBuilder {
    return self.blocks.get(id);
}

/// Encode the function and all blocks into the provided encoder, inserting a binary.Fixup location for the function itself into the current region.
pub fn encode(self: *const FunctionBuilder, maybe_upvalue_fixups: ?*const bytecode.UpvalueFixupMap, encoder: *binary.Encoder) binary.Encoder.Error!void {
    const location = encoder.localLocationId(self.id);

    if (maybe_upvalue_fixups == null and self.parent != null) {
        log.debug("FunctionBuilder.encode: {f} has a parent but no parent locals map was provided; assuming this is the top-level TableBuilder hitting a pre-declared handler function, skipping", .{self.id});
        return encoder.skipLocation(location);
    }

    if (!try encoder.visitLocation(location)) {
        log.debug("FunctionBuilder.encode: {f} has already been encoded, skipping", .{self.id});
        return;
    }

    // compute stack layout and set up the local binary.Fixup map for the function
    const layouts = self.locals.values();

    const indices = try encoder.temp_allocator.alloc(u64, layouts.len);
    defer encoder.temp_allocator.free(indices);

    const offsets = try encoder.temp_allocator.alloc(u64, layouts.len);
    defer encoder.temp_allocator.free(offsets);

    const stack_layout = core.Layout.computeOptimalCommonLayout(layouts, indices, offsets);

    var local_fixups = try bytecode.LocalFixupMap.init(encoder.temp_allocator, self.locals.keys(), offsets);
    defer local_fixups.deinit(encoder.temp_allocator);

    // create our header entry
    const entry_addr_rel = try encoder.createRel(core.Function);

    // bind its location to the function id
    try encoder.bindLocation(location, entry_addr_rel);

    { // function block region
        const region_token = encoder.enterRegion(self.id);
        defer encoder.leaveRegion(region_token);

        var queue: bytecode.BlockVisitorQueue = .init(encoder.temp_allocator);
        defer queue.deinit();

        // write the function body

        // ensure the function's instructions are aligned
        try encoder.alignTo(core.BYTECODE_ALIGNMENT);

        const base_rel = encoder.getRelativeAddress();

        try queue.add(bytecode.BlockBuilder.entry_point_id);

        while (queue.visit()) |block_id| {
            const block = self.blocks.get(block_id).?;

            try block.encode(&queue, maybe_upvalue_fixups, &local_fixups, encoder);
        }

        // certain situations, such as a block that is only reached via effect cancellation,
        // may result in a block not being encoded at all.
        // while one might argue for a "dead code elimination" principled motivation here,
        // dead code removal is not an intended feature of this api; it is an expectation
        // placed upon the caller, as with any assembler.

        // thus, we simply ensure any blocks we didn't touch via traversal get encoded at the end
        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |ptr2ptr| {
            const block = ptr2ptr.*;
            try block.encode(&queue, maybe_upvalue_fixups, &local_fixups, encoder);
        }

        const upper_rel = encoder.getRelativeAddress();

        // write the function header
        const func = encoder.relativeToPointer(*core.Function, entry_addr_rel);

        func.kind = .bytecode;
        func.layout = stack_layout;

        // Add a binary.Fixup for the function's header reference
        try encoder.bindFixup(
            .absolute,
            .{ .relative = entry_addr_rel.applyOffset(@intCast(@offsetOf(core.Function, "unit"))) },
            .{ .relative = .base },
            null,
        );

        // Add fixups for the function's extents references
        const extents_rel = entry_addr_rel.applyOffset(@intCast(@offsetOf(core.Function, "extents")));
        try encoder.bindFixup(
            .absolute,
            .{ .relative = extents_rel.applyOffset(@intCast(@offsetOf(core.Extents, "base"))) },
            .{ .relative = base_rel },
            null,
        );

        try encoder.bindFixup(
            .absolute,
            .{ .relative = extents_rel.applyOffset(@intCast(@offsetOf(core.Extents, "upper"))) },
            .{ .relative = upper_rel },
            null,
        );
    }

    // encode descendents
    var set_it = self.handler_sets.valueIterator();
    while (set_it.next()) |ptr2ptr| {
        const handler_set = ptr2ptr.*;

        // we need to create a map from UpvalueId to our local fixups;
        // we can do this by using the handler set builder's upvalues map to create a buffer of UpvalueIds matched with our existing local fixups.
        var new_upvalue_fixups: bytecode.UpvalueFixupMap = .{};
        defer new_upvalue_fixups.deinit(encoder.temp_allocator);

        var handler_it = handler_set.upvalues.iterator();
        while (handler_it.next()) |pair| {
            const upvalue_id = pair.key_ptr.*;
            const local_id = pair.value_ptr.*;

            try new_upvalue_fixups.put(
                encoder.temp_allocator,
                upvalue_id,
                local_fixups.get(local_id) orelse {
                    log.err("FunctionBuilder.encode: Local variable {f} referenced by upvalue {f} in handler set {f} does not exist", .{ local_id, upvalue_id, handler_set.id });
                    return error.BadEncoding;
                },
            );
        }

        try handler_set.encode(&new_upvalue_fixups, encoder);
    }
}
