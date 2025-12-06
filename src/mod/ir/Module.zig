//! An ir module, representing a single compilation unit within a context/compilation session.
const Module = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// The context this module belongs to.
root: *ir.Context,
/// Globally unique identifier for this module.
guid: Module.GUID,
/// Symbolic name of this module.
name: ir.Name,

/// Symbols exported from this module.
exported_symbols: common.StringMap(Module.Binding) = .empty,
/// Pool allocator for globals in this module.
global_pool: common.ManagedPool(ir.Global),
/// Pool allocator for functions in this module.
function_pool: common.ManagedPool(ir.Function),
/// Pool allocator for blocks in this module.
block_pool: common.ManagedPool(ir.Block),

/// Id generation state for this module.
fresh_ids: struct {
    global: std.meta.Tag(ir.Global.Id) = 0,
    function: std.meta.Tag(ir.Function.Id) = 0,
    block: std.meta.Tag(ir.Block.Id) = 0,
} = .{},

/// The cached CBR for the module.
cached_cbr: ?ir.Cbr = null,

/// Globally unique identifier for a module.
pub const GUID = enum(u128) { _ };

/// A binding exported from a module.
pub const Binding = union(enum) {
    /// A term binding.
    term: ir.Term,
    /// A function binding.
    function: *ir.Function,
    /// A global variable binding.
    global: *ir.Global,
};

/// Create a new module in the given context.
pub fn init(root: *ir.Context, name: ir.Name, guid: Module.GUID) !*Module {
    const self = try root.arena.allocator().create(Module);

    self.* = Module{
        .root = root,
        .guid = guid,
        .name = name,
        .global_pool = .init(root.allocator),
        .function_pool = .init(root.allocator),
        .block_pool = .init(root.allocator),
    };

    return self;
}

/// Deinitialize this module and all its contents.
pub fn deinit(self: *Module) void {
    self.exported_symbols.deinit(self.root.allocator);

    var func_it = self.function_pool.iterate();
    while (func_it.next()) |func_p2p| func_p2p.*.deinit();
    self.function_pool.deinit();

    var block_it = self.block_pool.iterate();
    while (block_it.next()) |block_p2p| block_p2p.*.deinit();
    self.block_pool.deinit();
}

/// Export a term from this module.
pub fn exportTerm(self: *Module, name: ir.Name, term: ir.Term) error{ DuplicateModuleExports, OutOfMemory }!void {
    const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
    if (gop.found_existing) {
        return error.DuplicateModuleExports;
    }
    gop.value_ptr.* = .{ .term = term };
}

/// Export a global from this module.
pub fn exportGlobal(self: *Module, name: ir.Name, global: *ir.Global) error{ DuplicateModuleExports, OutOfMemory }!void {
    const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
    if (gop.found_existing) {
        return error.DuplicateModuleExports;
    }
    gop.value_ptr.* = .{ .global = global };
}

/// Export a function from this module.
pub fn exportFunction(self: *Module, name: ir.Name, function: *ir.Function) error{ DuplicateModuleExports, OutOfMemory }!void {
    const gop = try self.exported_symbols.getOrPut(self.root.allocator, name.value);
    if (gop.found_existing) {
        return error.DuplicateModuleExports;
    }
    gop.value_ptr.* = .{ .function = function };
}

/// Generate a fresh unique ir.Global.Id for this module.
pub fn generateGlobalId(self: *Module) ir.Global.Id {
    const id = self.fresh_ids.global;
    self.fresh_ids.global += 1;
    return @enumFromInt(id);
}

/// Generate a fresh unique ir.Function.Id for this module.
pub fn generateFunctionId(self: *Module) ir.Function.Id {
    const id = self.fresh_ids.function;
    self.fresh_ids.function += 1;
    return @enumFromInt(id);
}

/// Generate a fresh unique ir.Block.Id for this module.
pub fn generateBlockId(self: *Module) ir.Block.Id {
    const id = self.fresh_ids.block;
    self.fresh_ids.block += 1;
    return @enumFromInt(id);
}

/// Calculate the cbr for this module.
pub fn getCbr(self: *Module) ir.Cbr {
    if (self.cached_cbr) |cached| {
        return cached;
    }

    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Module");

    hasher.update("guid:");
    hasher.update(self.guid);

    hasher.update("exports:");
    var exp_it = self.exported_symbols.iterator(); // TODO: this is incorrect as the map iterator order is arbitrary
    while (exp_it.next()) |exp_kv| {
        const exp_name_id = self.root.interned_name_set.get(exp_kv.key_ptr.*).?;
        const binding = exp_kv.value_ptr.*;

        hasher.update("name:");
        hasher.update(exp_name_id);

        switch (binding) {
            .term => |t| {
                hasher.update("term:");
                hasher.update(t.getCbr());
            },
            .function => |f| {
                hasher.update("function:");
                hasher.update(f.type.getCbr());
            },
            .global => |g| {
                hasher.update("global:");
                hasher.update(g.type.getCbr());
            },
        }
    }

    const buf = hasher.final();
    self.cached_cbr = buf;
    return buf;
}

/// Write the module in SMA format to the given writer.
pub fn writeSma(self: *Module, writer: *std.io.Writer) error{WriteFailed}!void {
    const mod_name_id = self.root.interned_name_set.get(self.name.value).?;

    try writer.writeInt(u128, @intFromEnum(self.guid), .little);
    try writer.writeInt(u128, @intFromEnum(self.getCbr()), .little);
    try writer.writeInt(u32, @intFromEnum(mod_name_id), .little);

    try writer.writeInt(u32, @intCast(self.exported_symbols.count()), .little);
    var exp_it = self.exported_symbols.iterator();
    while (exp_it.next()) |exp_kv| {
        const exp_name_id = self.root.interned_name_set.get(exp_kv.key_ptr.*).?;
        const binding = exp_kv.value_ptr.*;

        try writer.writeInt(u32, @intFromEnum(exp_name_id), .little);
        switch (binding) {
            .term => |t| {
                try writer.writeInt(u8, 0, .little); // term binding
                try writer.writeInt(u32, @intFromEnum(t.getId()), .little);
            },
            .function => |f| {
                try writer.writeInt(u8, 1, .little); // function binding
                try writer.writeInt(u32, @intFromEnum(f.id), .little);
            },
            .global => |g| {
                try writer.writeInt(u8, 2, .little); // global binding
                try writer.writeInt(u32, @intFromEnum(g.id), .little);
            },
        }

        // TODO:
        // write all the functions in the module
        // write all the blocks in the module
        // this also seems like it should be done via traversal of exports; but ordering is an issue here as well (see ir.Context.writeSmaTerms)
    }
}
