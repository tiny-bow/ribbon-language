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
handler_sets: common.UniqueReprSet(*ir.HandlerSet) = .empty,

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
    var handler_set_it = self.handler_sets.keyIterator();
    while (handler_set_it.next()) |handler_set_p2p| {
        handler_set_p2p.*.deinit();
        self.module.handler_set_pool.destroy(handler_set_p2p.*) catch |err| {
            log.err("Failed to destroy handler set on deinit: {s}", .{@errorName(err)});
        };
    }
    self.handler_sets.deinit(self.module.root.allocator);
    self.arena.deinit();
}

pub fn dehydrate(self: *const Expression, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Expression {
    var out = ir.Sma.Expression{
        .type = try dehydrator.dehydrateTerm(self.type),
    };
    errdefer out.deinit(dehydrator.sma.allocator);

    var handler_sets_ordered = common.ArrayList(*ir.HandlerSet).empty;
    defer handler_sets_ordered.deinit(dehydrator.ctx.allocator);

    try self.entry.allocateDehydratedIndices(dehydrator, &handler_sets_ordered, &out.blocks);

    // Dehydrate handler sets;
    // NOTE: this must be an ordered operation to ensure consistent cbr
    // NOTE: this must be done after the traversal above, since handler sets refer to blocks as cancellation points
    for (handler_sets_ordered.items) |handler_set| {
        const hs_id = try dehydrator.dehydrateHandlerSet(handler_set);
        try out.handler_sets.append(dehydrator.sma.allocator, hs_id);
    }

    try self.entry.dehydrateInstructions(dehydrator, &out.blocks);

    return out;
}
