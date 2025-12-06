//! An ir function, representing a procedure or effect handler within a module.
const Function = @This();

const std = @import("std");

const ir = @import("../ir.zig");

/// A procedure or effect handler within a module.
/// The context this function belongs to.
module: *ir.Module,
/// Globally unique id for this function, used for hashing and debugging.
id: Function.Id,
/// The kind of function, either a procedure or an effect handler.
kind: Kind,
/// The type of this function, which must be a function type or a polymorphic type that instantiates to a function.
type: ir.Term,
/// The entry block of this function.
entry: *ir.Block,
/// Storage for the function's instructions.
/// While slightly less memory efficient than a Pool, this allows us to include operands in the same allocation as the instruction.
arena: std.heap.ArenaAllocator,

/// Optional abi name for this function.
name: ?ir.Name = null,

/// Cached CBR for this function.
cached_cbr: ?ir.Cbr = null,

/// Identifier for a function within a module.
pub const Id = enum(u32) { _ };

pub fn init(module: *ir.Module, name: ?ir.Name, kind: Kind, ty: ir.Term) error{OutOfMemory}!*Function {
    const self = try module.function_pool.create();
    const entry_name = try module.root.internName("entry");
    self.* = Function{
        .module = module,
        .id = module.generateFunctionId(),
        .kind = kind,
        .type = ty,

        .entry = try ir.Block.init(module, self, entry_name),
        .arena = .init(module.root.allocator),

        .name = name,
    };
    return self;
}

pub fn deinit(self: *Function) void {
    self.arena.deinit();
}

/// The kind of a function, either a procedure or an effect handler.
pub const Kind = enum(u1) {
    /// The function is a normal procedure.
    procedure,
    /// The function is an effect handler.
    handler,
};

/// Get the CBR for this function.
pub fn getCbr(self: *Function) ir.Cbr {
    if (self.cached_cbr) |cached| {
        return cached;
    }

    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Function");

    // We must include the module guid to differentiate between internal and external references
    hasher.update("module.guid:");
    hasher.update(self.module.guid);

    hasher.update("id:");
    hasher.update(self.id);

    hasher.update("name:");
    if (self.name) |name| {
        hasher.update(name.value);
    } else {
        hasher.update("[null]");
    }

    hasher.update("type:");
    hasher.update(self.type.getCbr());

    hasher.update("kind:");
    hasher.update(self.kind);

    hasher.update("body:");
    hasher.update(self.entry.getCbr());

    const buf = hasher.final();

    self.cached_cbr = buf;

    return buf;
}
