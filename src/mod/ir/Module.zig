//! An ir module, representing a single compilation unit within a context/compilation session.
const Module = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.module");

const common = @import("common");

const ir = @import("../ir.zig");

/// The context this module belongs to.
root: *ir.Context,
/// Globally unique identifier for this module.
guid: Module.GUID,
/// Symbolic name of this module.
name: ir.Name,
/// Whether or not the module is a primary module in its context.
/// I.E. whether its exports should be fully serialized, or if they are included for dependency resolution only.
is_primary: bool,

/// Symbols exported from this module.
exported_symbols: common.StringMap(Module.Binding) = .empty,
/// Pool allocator for handler sets in this module.
handler_set_pool: common.ManagedPool(ir.HandlerSet),
/// Pool allocator for globals in this module.
global_pool: common.ManagedPool(ir.Global),
/// Pool allocator for functions in this module.
function_pool: common.ManagedPool(ir.Function),
/// Pool allocator for expressions in this module.
expression_pool: common.ManagedPool(ir.Expression),
/// Pool allocator for blocks in this module.
block_pool: common.ManagedPool(ir.Block),
/// Pool allocator for instructions in this module.
instruction_pool: common.ManagedPool(ir.Instruction),
/// Operand Use pool allocator for this module.
use_pool: common.ManagedPool(ir.Instruction.Use),

/// Globally unique identifier for a module.
pub const GUID = enum(u128) {
    invalid = 0,
    _,
};

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
pub fn init(root: *ir.Context, name: ir.Name, guid: Module.GUID, is_primary: bool) !*Module {
    const self = try root.arena.allocator().create(Module);

    self.* = Module{
        .root = root,
        .guid = guid,
        .name = name,
        .is_primary = is_primary,
        .global_pool = .init(root.allocator),
        .handler_set_pool = .init(root.allocator),
        .function_pool = .init(root.allocator),
        .expression_pool = .init(root.allocator),
        .block_pool = .init(root.allocator),
        .instruction_pool = .init(root.allocator),
        .use_pool = .init(root.allocator),
    };

    return self;
}

/// Deinitialize this module and all its contents.
pub fn deinit(self: *Module) void {
    self.exported_symbols.deinit(self.root.allocator);

    var handler_it = self.handler_set_pool.iterate();
    while (handler_it.next()) |handler_p2p| handler_p2p.*.deinit();
    self.handler_set_pool.deinit();

    var global_it = self.global_pool.iterate();
    while (global_it.next()) |global_p2p| global_p2p.*.deinit();
    self.global_pool.deinit();

    var func_it = self.function_pool.iterate();
    while (func_it.next()) |func_p2p| func_p2p.*.deinit();
    self.function_pool.deinit();

    var expr_it = self.expression_pool.iterate();
    while (expr_it.next()) |expr_p2p| expr_p2p.*.deinit();
    self.expression_pool.deinit();

    var block_it = self.block_pool.iterate();
    while (block_it.next()) |block_p2p| block_p2p.*.deinit();
    self.block_pool.deinit();

    var instr_it = self.instruction_pool.iterate();
    while (instr_it.next()) |instr_p2p| instr_p2p.*.deinit();
    self.instruction_pool.deinit();

    var use_it = self.use_pool.iterate();
    while (use_it.next()) |use_p2p| use_p2p.*.deinit();
    self.use_pool.deinit();
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

/// Dehydrate this module into a serializable module artifact (SMA).
pub fn dehydrate(self: *const Module, dehydrator: *ir.Sma.Dehydrator) error{ BadEncoding, OutOfMemory }!ir.Sma.Module {
    var exports = common.ArrayList(ir.Sma.Export).empty;
    errdefer exports.deinit(dehydrator.ctx.allocator);

    var it = self.exported_symbols.iterator();
    while (it.next()) |entry| {
        const name_index = try dehydrator.dehydrateName(ir.Name{ .value = entry.key_ptr.* });
        switch (entry.value_ptr.*) {
            .term => |t| {
                try exports.append(dehydrator.ctx.allocator, ir.Sma.Export{
                    .name = name_index,
                    .value = .{ .kind = .term, .value = try dehydrator.dehydrateTerm(t) },
                });
            },
            .global => |g| {
                try exports.append(dehydrator.ctx.allocator, ir.Sma.Export{
                    .name = name_index,
                    .value = .{ .kind = .global, .value = try dehydrator.dehydrateGlobal(g) },
                });
            },
            .function => |f| {
                try exports.append(dehydrator.ctx.allocator, ir.Sma.Export{
                    .name = name_index,
                    .value = .{ .kind = .function, .value = try dehydrator.dehydrateFunction(f) },
                });
            },
        }
    }

    ir.Sma.Export.sort(exports.items);

    const name_index = try dehydrator.dehydrateName(self.name);

    return ir.Sma.Module{
        .guid = self.guid,
        .name = name_index,
        .is_primary = self.is_primary,
        .exports = exports,
    };
}

/// Rehydrate this module from its SMA representation.
pub fn rehydrate(self: *Module, sma_mod: *const ir.Sma.Module, rehydrator: *ir.Sma.Rehydrator) error{ BadEncoding, OutOfMemory }!void {
    for (sma_mod.exports.items) |sma_export| {
        const export_name = try rehydrator.rehydrateName(sma_export.name);
        switch (sma_export.value.kind) {
            .term => {
                const term = try rehydrator.rehydrateTerm(sma_export.value.value);
                self.exportTerm(export_name, term) catch |err| {
                    return switch (err) {
                        error.DuplicateModuleExports => error.BadEncoding,
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };
            },
            .global => {
                const global = try rehydrator.rehydrateGlobal(sma_export.value.value);
                self.exportGlobal(export_name, global) catch |err| {
                    return switch (err) {
                        error.DuplicateModuleExports => error.BadEncoding,
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };
            },
            .function => {
                const function = try rehydrator.rehydrateFunction(sma_export.value.value);
                self.exportFunction(export_name, function) catch |err| {
                    return switch (err) {
                        error.DuplicateModuleExports => error.BadEncoding,
                        error.OutOfMemory => error.OutOfMemory,
                    };
                };
            },
            else => {
                return error.BadEncoding;
            },
        }
    }
}

/// Disassemble this module to the given writer.
pub fn format(self: *const Module, writer: *std.io.Writer) error{WriteFailed}!void {
    try writer.print("module {s} (guid={x}) {{\n", .{ self.name.value, self.guid });
    var it = self.exported_symbols.iterator();
    while (it.next()) |entry| {
        try writer.print("  {s} := ", .{entry.key_ptr.*});
        switch (entry.value_ptr.*) {
            .term => |t| try t.format(writer),
            .global => |g| try g.format(writer),
            .function => |f| try f.format(writer),
        }
        try writer.writeAll("\n");
    }
    try writer.writeAll("}\n");
}
