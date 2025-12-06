//! Binds information about a global variable inside an ir context.
const Global = @This();

const std = @import("std");

const ir = @import("../ir.zig");

/// The module this global variable belongs to.
module: *ir.Module,
/// A module-unique identifier for this global variable.
id: Global.Id,
/// The type of this global variable.
type: ir.Term,
/// The initializer term for this global variable.
initializer: ir.Term,

/// Optional abi name for this global variable.
name: ?ir.Name = null,

/// Cached CBR for this global variable.
cached_cbr: ?ir.Cbr = null,

/// Identifier for a global variable within a module.
pub const Id = enum(u32) { _ };

/// Create a new global in the given module, pulling memory from the pool and assigning it a fresh identity.
pub fn init(module: *ir.Module, name: ?ir.Name, ty: ir.Term, initial: ir.Term) error{OutOfMemory}!*Global {
    const self = try module.global_pool.create();
    self.* = Global{
        .module = module,
        .id = module.generateGlobalId(),
        .type = ty,
        .initializer = initial,

        .name = name,
    };
    return self;
}

/// Get the full CBR for this global variable.
pub fn getFullCbr(self: *Global) ir.Cbr {
    if (self.cached_cbr) |cached| {
        return cached;
    }

    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Global");

    hasher.update("name:");
    if (self.name) |name| {
        hasher.update(name.value);
    } else {
        hasher.update("[null]");
    }

    hasher.update("type:");
    hasher.update(self.type.getCbr());

    hasher.update("initializer:");
    hasher.update(self.initializer.getCbr());

    const out = hasher.final();
    self.cached_cbr = out;
    return out;
}

pub fn dehydrate(self: *const Global, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Global {
    return ir.Sma.Global{
        .name = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
        .type = try dehydrator.dehydrateTerm(self.type),
        .initializer = try dehydrator.dehydrateTerm(self.initializer),
    };
}
