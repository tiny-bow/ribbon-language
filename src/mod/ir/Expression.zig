//! An ir expression, representing the body of a procedure, effect handler, or constant computation within a module.
const Expression = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.expression");

const common = @import("common");

const ir = @import("../ir.zig");

/// The module this expression belongs to.
module: *ir.Module,
/// The type of this expression, which must be a value type or a polymorphic type that instantiates to a value type.
/// * Note that if this expression is the body of a function, the type will be a function type.
type: ir.Term,
/// The entry block of this expression.
entry: *ir.Block,
/// Storage for the expression's instructions.
/// While less memory efficient than a Pool, this allows us to include operands in the same allocation as the instruction.
arena: std.heap.ArenaAllocator,

/// The list of handler sets used by this expression.
handler_sets: common.ArrayList(*ir.HandlerSet) = .empty,

/// Create a new expression in the given module, pulling memory from the pool and assigning it a fresh identity.
pub fn init(module: *ir.Module, ty: ir.Term) error{OutOfMemory}!*Expression {
    const entry_name = try module.root.internName("entry");

    const self = try module.expression_pool.create();
    errdefer module.expression_pool.destroy(self) catch |err| {
        log.err("Failed to destroy expression on init error: {s}", .{@errorName(err)});
    };

    self.* = Expression{
        .module = module,
        .type = ty,

        .entry = try .init(self, entry_name),
        .arena = .init(module.root.allocator),
    };

    return self;
}

/// Deinitialize this expression, freeing its resources.
/// * Does not return the expression to its module's pool.
pub fn deinit(self: *Expression) void {
    for (self.handler_sets.items) |handler_set| {
        handler_set.deinit();
        self.module.handler_set_pool.destroy(handler_set) catch |err| {
            log.err("Failed to destroy handler set on deinit: {s}", .{@errorName(err)});
        };
    }
    self.handler_sets.deinit(self.module.root.allocator);
    self.arena.deinit();
}

pub fn dehydrate(self: *const Expression, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Expression {
    var out = ir.Sma.Expression{
        .module = self.module.guid,
        .type = try dehydrator.dehydrateTerm(self.type),
    };
    errdefer out.deinit(dehydrator.sma.allocator);

    var index_counter: u32 = 0;

    try self.entry.allocateDehydratedIndices(dehydrator, &index_counter, &out.blocks);

    // Dehydrate handler sets;
    // NOTE: this must be done after the traversal above, since handler sets refer to blocks as cancellation points
    for (self.handler_sets.items) |handler_set| {
        const hs_id = try dehydrator.dehydrateHandlerSet(handler_set);
        try out.handler_sets.append(dehydrator.sma.allocator, hs_id);
    }

    try self.entry.dehydrateInstructions(dehydrator, &out.instructions);

    return out;
}

pub fn rehydrate(sma_expr: *const ir.Sma.Expression, rehydrator: *ir.Sma.Rehydrator) error{ BadEncoding, OutOfMemory }!*Expression {
    const module = rehydrator.ctx.modules.get(sma_expr.module) orelse return error.BadEncoding;

    const expr = try ir.Expression.init(module, try rehydrator.rehydrateTerm(sma_expr.type));
    errdefer expr.deinit();

    // TODO: using the builder api might be cleaner here; doesn't exist yet though

    var index_to_block = common.ArrayList(*ir.Block).empty;
    defer index_to_block.deinit(rehydrator.ctx.allocator);

    var index_to_instr = common.ArrayList(*ir.Instruction).empty;
    defer index_to_instr.deinit(rehydrator.ctx.allocator);

    // first we need to rehydrate the blocks in an empty state so that we have index -> block mappings
    try index_to_block.append(rehydrator.ctx.allocator, expr.entry);

    for (sma_expr.blocks.items[1..]) |*sma_block| {
        const name = try rehydrator.rehydrateName(sma_block.name);
        const block = try ir.Block.init(expr, name);
        errdefer block.deinit();

        try index_to_block.append(rehydrator.ctx.allocator, block);

        for (sma_block.start..sma_block.start + sma_block.count) |instr_index| {
            const sma_instr = &sma_expr.instructions.items[instr_index];
            const instr = try ir.Instruction.preinit(block, sma_instr.operands.items.len);
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
