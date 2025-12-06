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

pub fn cbr(self: *const HandlerSet) ir.Cbr {
    var hasher = ir.Cbr.Hasher.init();
    hasher.update("HandlerSet");

    hasher.update("handlers.count:");
    hasher.update(self.handlers.items.len);

    hasher.update("handlers:");
    for (self.handlers.items) |handler| {
        hasher.update("handler:");
        hasher.update(handler.getFullCbr());
    }

    hasher.update("handler_type:");
    hasher.update(self.handler_type.getCbr());

    hasher.update("result_type:");
    hasher.update(self.result_type.getCbr());

    hasher.update("cancellation_point:");
    hasher.update(self.cancellation_point.id);

    return hasher.final();
}

pub fn dehydrate(self: *const HandlerSet, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.HandlerSet {
    const type_id = try dehydrator.dehydrateTerm(self.handler_type);
    const result_id = try dehydrator.dehydrateTerm(self.result_type);

    // TODO: this won't work if done naively; blocks in the parent function need to be dehydrated first
    const cancel_id = common.todo(noreturn, .{self.cancellation_point});

    var out = ir.Sma.HandlerSet{
        .handler_type = type_id,
        .result_type = result_id,
        .cancellation_point = cancel_id,
    };
    errdefer out.deinit(dehydrator.sma.allocator);

    for (self.handlers) |handler| {
        const func_id = try dehydrator.dehydrateFunction(handler);
        try out.handlers.appendSlice(dehydrator.sma.allocator, func_id);
    }

    return out;
}

pub fn rehydrate(dehydrated: *const ir.Sma.Term, rehydrator: *ir.Sma.Rehydrator, out: *HandlerSet) error{ BadEncoding, OutOfMemory }!void {
    common.todo(noreturn, .{ dehydrated, rehydrator, out });
}
