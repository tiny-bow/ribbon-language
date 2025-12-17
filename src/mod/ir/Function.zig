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

/// Create a new function in the given module, pulling memory from the pool and assigning it a fresh identity.
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

/// Free resources associated with this function.
/// * Frees the function in the module function pool for reuse.
pub fn deinit(self: *Function) void {
    self.body.deinit();
    self.body.module.function_pool.destroy(self) catch |err| {
        log.err("Failed to destroy function on deinit: {s}", .{@errorName(err)});
    };
}

/// Dehydrate this function into a serializable module artifact (SMA).
pub fn dehydrate(self: *const Function, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Function {
    return ir.Sma.Function{
        .kind = self.kind,
        .name = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
        .body = try self.body.dehydrate(dehydrator),
    };
}

/// Rehydrate an ir function from the given SMA function.
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

/// Disassemble this function to the given writer.
pub fn format(self: *const Function, writer: *std.io.Writer) error{WriteFailed}!void {
    if (self.name) |n| {
        try writer.print("(function @{s}:\n{f})", .{ n.value, self.body });
    } else {
        try writer.print("(function @<unnamed{x}>:\n{f})", .{ @intFromPtr(self), self.body });
    }
}
