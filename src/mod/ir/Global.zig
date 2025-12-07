//! Binds information about a global variable inside an ir context.
const Global = @This();

const std = @import("std");

const ir = @import("../ir.zig");

/// The module this global variable belongs to.
module: *ir.Module,
/// The type of this global variable.
type: ir.Term,
/// The initializer term for this global variable.
initializer: ir.Term,

/// Optional abi name for this global variable.
name: ?ir.Name = null,

/// Create a new global in the given module, pulling memory from the pool and assigning it a fresh identity.
pub fn init(module: *ir.Module, name: ?ir.Name, ty: ir.Term, initial: ir.Term) error{OutOfMemory}!*Global {
    const self = try module.global_pool.create();
    self.* = Global{
        .module = module,
        .type = ty,
        .initializer = initial,

        .name = name,
    };
    return self;
}

pub fn dehydrate(self: *const Global, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Global {
    return ir.Sma.Global{
        .module = self.module.guid,
        .name = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
        .type = try dehydrator.dehydrateTerm(self.type),
        .initializer = try dehydrator.dehydrateTerm(self.initializer),
    };
}

pub fn rehydrate(sma_global: *const ir.Sma.Global, rehydrator: *ir.Sma.Rehydrator) error{ BadEncoding, OutOfMemory }!*ir.Global {
    const module = rehydrator.ctx.modules.get(sma_global.module) orelse return error.BadEncoding;

    const global = try module.global_pool.create();
    global.* = Global{
        .module = module,
        .type = try rehydrator.rehydrateTerm(sma_global.type),
        .initializer = try rehydrator.rehydrateTerm(sma_global.initializer),
        .name = try rehydrator.rehydrateName(sma_global.name),
    };
    return global;
}
