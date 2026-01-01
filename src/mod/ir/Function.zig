//! An ir function, representing a procedure or effect handler within a module.
const Function = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.function");

const common = @import("common");
const analysis = @import("analysis");

const ir = @import("../ir.zig");

/// The kind of function, either a procedure or an effect handler.
kind: Kind,
/// The module this function belongs to.
module: *ir.Module,
/// The type of this function.
type: ir.Term,
/// The expression body for this function.
body: ?*ir.Expression = null,
/// Optional abi name for this function.
name: ?ir.Name = null,
/// Optional source attribution for this function.
source: ?analysis.Source = null,

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
    src: ?analysis.Source,
) error{OutOfMemory}!*Function {
    const self = try module.function_pool.create();
    errdefer module.function_pool.destroy(self) catch |err| {
        log.err("Failed to destroy function on init error: {s}", .{@errorName(err)});
    };

    self.* = Function{
        .module = module,
        .type = ty,
        .kind = kind,
        .body = null,
        .name = name,
        .source = src,
    };

    return self;
}

/// Free resources associated with this function.
/// * Frees the function in the module function pool for reuse.
pub fn deinit(self: *Function) void {
    if (self.body) |b| {
        b.deinit();
        b.module.function_pool.destroy(self) catch |err| {
            log.err("Failed to destroy function on deinit: {s}", .{@errorName(err)});
        };
    }
}

/// Dehydrate this function into a serializable module artifact (SMA).
pub fn dehydrate(self: *const Function, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Function {
    return ir.Sma.Function{
        .module = self.module.guid,
        .kind = self.kind,
        .type = try dehydrator.dehydrateTerm(self.type),
        .name = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
        .body = if (self.module.is_primary and self.body != null) try dehydrator.dehydrateExpression(self.body.?) else ir.Sma.sentinel_index,
        .source = if (self.source) |s| try dehydrator.dehydrateSource(s) else ir.Sma.sentinel_index,
    };
}

/// Rehydrate an ir function from the given SMA function.
pub fn rehydrate(
    sma_func: *const ir.Sma.Function,
    rehydrator: *ir.Sma.Rehydrator,
) error{ BadEncoding, OutOfMemory }!*Function {
    const module = rehydrator.ctx.modules.get(sma_func.module) orelse return error.BadEncoding;

    const func = try module.function_pool.create();
    errdefer module.function_pool.destroy(func) catch |err| {
        log.err("Failed to destroy function on rehydrate error: {s}", .{@errorName(err)});
    };

    func.* = Function{
        .module = module,
        .kind = sma_func.kind,
        .type = try rehydrator.rehydrateTerm(sma_func.type),
        .name = try rehydrator.tryRehydrateName(sma_func.name),
        .body = if (module.is_primary) try rehydrator.tryRehydrateExpression(sma_func.body) else null,
        .source = try rehydrator.tryRehydrateSource(sma_func.source),
    };

    return func;
}

/// Disassemble this function to the given writer.
pub fn format(self: *const Function, writer: *std.io.Writer) error{WriteFailed}!void {
    if (self.body) |b| {
        if (self.name) |n| {
            try writer.print("(function @{s}:\n{f})", .{ n.value, b });
        } else {
            try writer.print("(function @<unnamed{x}>:\n{f})", .{ @intFromPtr(self), b });
        }
    } else {
        if (self.name) |n| {
            try writer.print("(decl function @{s})", .{n.value});
        } else {
            try writer.print("(decl function @<unnamed{x}>)", .{@intFromPtr(self)});
        }
    }
}
