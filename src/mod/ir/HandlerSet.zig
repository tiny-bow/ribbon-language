//! Binds a set of handlers and cancellation information for a push_set instruction
const HandlerSet = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// The module this handler set belongs to
module: *ir.Module,
/// The set of handlers in this handler set
handlers: common.ArrayList(*ir.Function) = .empty,
/// A HandlerType that describes the unified type of the handlers in this set
handler_type: ir.Term,
/// The type of value the handler set resolves to, either directly or by cancellation
result_type: ir.Term,
/// The basic block where this handler set yields its value
cancellation_point: *ir.Block,

pub fn deinit(self: *HandlerSet) void {
    self.handlers.deinit(self.module.root.allocator);
}

pub fn dehydrate(self: *const HandlerSet, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.HandlerSet {
    const type_id = try dehydrator.dehydrateTerm(self.handler_type);
    const result_id = try dehydrator.dehydrateTerm(self.result_type);

    // NOTE: this won't work if done naively; blocks in the parent function need to be dehydrated first
    const cancel_id = dehydrator.block_to_index.get(self.cancellation_point).?[0];

    var out = ir.Sma.HandlerSet{
        .module = self.module.guid,
        .handler_type = type_id,
        .result_type = result_id,
        .cancellation_point = cancel_id,
    };
    errdefer out.deinit(dehydrator.sma.allocator);

    for (self.handlers.items) |handler| {
        const func_id = try dehydrator.dehydrateFunction(handler);
        try out.handlers.append(dehydrator.sma.allocator, func_id);
    }

    return out;
}

pub fn rehydrate(
    sma_hs: *const ir.Sma.HandlerSet,
    rehydrator: *ir.Sma.Rehydrator,
    index_to_block: []const *ir.Block,
) error{ BadEncoding, OutOfMemory }!*HandlerSet {
    const module = rehydrator.ctx.modules.get(sma_hs.module) orelse return error.BadEncoding;

    const hs = try module.handler_set_pool.create();
    hs.* = HandlerSet{
        .module = module,
        .handler_type = try rehydrator.rehydrateTerm(sma_hs.handler_type),
        .result_type = try rehydrator.rehydrateTerm(sma_hs.result_type),
        .cancellation_point = index_to_block[sma_hs.cancellation_point],
    };
    errdefer hs.deinit();

    for (sma_hs.handlers.items) |func_id| {
        const func = try rehydrator.rehydrateFunction(func_id);
        try hs.handlers.append(module.root.allocator, func);
    }

    return hs;
}
