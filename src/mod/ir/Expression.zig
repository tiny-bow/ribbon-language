//! An ir expression, representing the body of a procedure, effect handler, or constant computation within a module.
const Expression = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.expression");

const common = @import("common");

const ir = @import("../ir.zig");

/// The module this expression belongs to.
module: *ir.Module,
/// The function this expression forms the body of, if it is not a constant expression.
function: ?*ir.Function = null,
/// The type of this expression, which must be a value type or a polymorphic type that instantiates to a value type.
/// * Note that if this expression is the body of a function, the type will be a function type.
type: ir.Term,

/// The entry block of this expression.
entry: *ir.Block,

/// The list of handler sets used by this expression.
handler_sets: common.ArrayList(*ir.HandlerSet) = .empty,

/// Create a new expression in the given module, pulling memory from the pool and assigning it a fresh identity.
pub fn init(module: *ir.Module, function: ?*ir.Function, ty: ir.Term) error{OutOfMemory}!*Expression {
    const entry_name = try module.root.internName("entry");

    const self = try module.expression_pool.create();
    errdefer module.expression_pool.destroy(self) catch |err| {
        log.err("Failed to destroy expression on init error: {s}", .{@errorName(err)});
    };

    self.* = Expression{
        .module = module,
        .function = function,
        .type = ty,

        .entry = undefined,
    };

    self.entry = try ir.Block.init(self, entry_name);

    return self;
}

/// Deinitialize this expression, freeing its resources.
/// * Frees the expression in the module expression pool for reuse.
pub fn deinit(self: *Expression) void {
    var it = self.iterate() catch |err| {
        log.err("Failed to destroy expression on deinit: {s}", .{@errorName(err)});
        return;
    };
    defer it.deinit();

    while (it.next() catch |err| {
        log.err("Failed to destroy expression on deinit: {s}", .{@errorName(err)});
        return;
    }) |block| {
        block.deinit();
    }

    for (self.handler_sets.items) |handler_set| {
        handler_set.deinit();
    }
    self.handler_sets.deinit(self.module.root.allocator);
    self.module.expression_pool.destroy(self) catch |err| {
        log.err("Failed to destroy expression on deinit: {s}", .{@errorName(err)});
    };
}

/// Create an iterator over the Blocks in this expression.
/// * Note that this requires allocation, as it uses a queue and a visited set.
pub fn iterate(self: *const Expression) !ir.Block.Iterator {
    return ir.Block.Iterator.init(self.module.root.allocator, self.entry);
}

/// Dehydrate this ir expression into an SMA expression.
pub fn dehydrate(self: *const Expression, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Expression {
    var out = ir.Sma.Expression{
        .module = self.module.guid,
        .type = try dehydrator.dehydrateTerm(self.type),
    };
    errdefer out.deinit(dehydrator.sma.allocator);

    var index_counter: u32 = 0;

    var successor_queue = common.ArrayList(*ir.Block).empty;
    defer successor_queue.deinit(dehydrator.sma.allocator);

    try successor_queue.append(dehydrator.sma.allocator, self.entry);

    while (successor_queue.pop()) |block| {
        if (dehydrator.block_to_index.contains(block)) continue;

        var instr_map = common.UniqueReprMap(*ir.Instruction, u32).empty;

        const start = index_counter;

        var it = block.iterate();
        while (it.next()) |instr| {
            const instr_index: u32 = index_counter;
            index_counter += 1;

            try instr_map.put(dehydrator.ctx.allocator, instr, instr_index);
        }

        const end = index_counter;
        const count = end - start;

        try dehydrator.block_to_index.put(dehydrator.ctx.allocator, block, .{ @intCast(out.blocks.items.len), instr_map });

        try out.blocks.append(dehydrator.ctx.allocator, ir.Sma.Block{
            .name = if (block.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
            .start = start,
            .count = count,
        });

        for (block.successors.items) |succ| {
            try successor_queue.append(dehydrator.sma.allocator, succ);
        }
    }

    // Dehydrate handler sets;
    // NOTE: this must be done after the traversal above, since handler sets refer to blocks as cancellation points
    for (self.handler_sets.items) |handler_set| {
        const hs_id = try dehydrator.dehydrateHandlerSet(handler_set);
        try out.handler_sets.append(dehydrator.sma.allocator, hs_id);
    }

    try self.entry.dehydrate(dehydrator, &out.instructions);

    return out;
}

/// Rehydrate an ir expression from the given SMA expression.
pub fn rehydrate(sma_expr: *const ir.Sma.Expression, rehydrator: *ir.Sma.Rehydrator, function: ?*ir.Function) error{ BadEncoding, OutOfMemory }!*Expression {
    const module = rehydrator.ctx.modules.get(sma_expr.module) orelse return error.BadEncoding;

    const expr = try ir.Expression.init(module, function, try rehydrator.rehydrateTerm(sma_expr.type));
    errdefer expr.deinit();

    var index_to_block = common.ArrayList(*ir.Block).empty;
    defer index_to_block.deinit(rehydrator.ctx.allocator);

    var index_to_instr = common.ArrayList(*ir.Instruction).empty;
    defer index_to_instr.deinit(rehydrator.ctx.allocator);

    // first we need to rehydrate the blocks in an empty state so that we have index -> block mappings

    for (sma_expr.blocks.items, 0..) |*sma_block, block_index| {
        const block_name = try rehydrator.rehydrateName(sma_block.name);
        const block =
            if (block_index == 0) use_entry: {
                expr.entry.name = block_name;
                break :use_entry expr.entry;
            } else try ir.Block.init(expr, block_name);
        errdefer if (block_index != 0) block.deinit();

        try index_to_block.append(rehydrator.ctx.allocator, block);

        for (sma_block.start..sma_block.start + sma_block.count) |instr_index| {
            const sma_instr = &sma_expr.instructions.items[instr_index];
            const ty = try rehydrator.rehydrateTerm(sma_instr.type);
            const name = try rehydrator.tryRehydrateName(sma_instr.name);
            const instr = try ir.Instruction.init(expr.entry, ty, sma_instr.command, name);
            try index_to_instr.append(rehydrator.ctx.allocator, instr);
        }
    }

    // then we can rehydrate handler sets since they may refer to blocks
    for (sma_expr.handler_sets.items) |hs_id| {
        const hs = try ir.HandlerSet.rehydrate(
            &rehydrator.sma.handler_sets.items[hs_id],
            rehydrator,
            index_to_block.items,
        );
        errdefer hs.deinit();

        try expr.handler_sets.append(rehydrator.ctx.allocator, hs);
    }

    // now we can rehydrate instructions and propagate the cfg entries, since we have both blocks and handler sets available
    try expr.entry.rehydrate(
        rehydrator,
        sma_expr.blocks.items,
        sma_expr.instructions.items,
        index_to_block.items,
        index_to_instr.items,
    );

    return expr;
}

/// Disassemble this expression to the given writer.
pub fn format(self: *const Expression, writer: *std.io.Writer) error{WriteFailed}!void {
    try writer.print("(type: {f}, handler_sets: [\n", .{self.type});

    for (self.handler_sets.items) |hs| {
        try hs.format(writer);
    }
    try writer.writeAll("], cfg: {{\n");

    var it = self.iterate() catch |err| {
        log.err("Failed to disassemble expression: {s}", .{@errorName(err)});
        return error.WriteFailed;
    };
    defer it.deinit();

    while (it.next() catch |err| {
        log.err("Failed to disassemble expression: {s}", .{@errorName(err)});
        return error.WriteFailed;
    }) |block| {
        try block.format(writer);
    }

    try writer.print("}})\n", .{});
}
