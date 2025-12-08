//! An ir function, representing a procedure or effect handler within a module.
const Function = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.function");

const common = @import("common");

const ir = @import("../ir.zig");

/// The kind of function, either a procedure or an effect handler.
kind: Kind,
/// The expression body for this function.
body: *ir.Expression,
/// Optional abi name for this function.
name: ?ir.Name = null,

/// The kind of a function, either a procedure or an effect handler.
pub const Kind = enum(u1) {
    /// The function is a normal procedure.
    procedure,
    /// The function is an effect handler.
    handler,
};

pub fn init(
    module: *ir.Module,
    kind: Kind,
    name: ?ir.Name,
    ty: ir.Term,
) error{OutOfMemory}!*Function {
    const self = try module.function_pool.create();
    errdefer module.function_pool.destroy(self) catch |err| {
        log.err("Failed to destroy function on init error: {s}", .{@errorName(err)});
    };

    self.* = Function{
        .kind = kind,
        .body = undefined,
        .name = name,
    };

    self.body = try ir.Expression.init(module, self, ty);

    return self;
}

pub fn deinit(self: *Function) void {
    self.body.deinit();
    self.body.module.expression_pool.destroy(self.body) catch |err| {
        log.err("Failed to destroy function body on deinit: {s}", .{@errorName(err)});
    };
}

pub fn dehydrate(self: *const Function, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Function {
    return ir.Sma.Function{
        .kind = self.kind,
        .name = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
        .body = try self.body.dehydrate(dehydrator),
    };
}

pub fn rehydrate(
    sma_func: *const ir.Sma.Function,
    rehydrator: *ir.Sma.Rehydrator,
) error{ BadEncoding, OutOfMemory }!*Function {
    const module = rehydrator.ctx.modules.get(sma_func.body.module) orelse return error.BadEncoding;

    const func = try module.function_pool.create();
    errdefer module.function_pool.destroy(func) catch |err| {
        log.err("Failed to destroy function on rehydrate error: {s}", .{@errorName(err)});
    };

    func.* = Function{
        .kind = sma_func.kind,
        .name = try rehydrator.tryRehydrateName(sma_func.name),
        .body = try ir.Expression.rehydrate(&sma_func.body, rehydrator, func),
    };

    return func;
}
