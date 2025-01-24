const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");


const Generator = @import("../RbcGenerator.zig");


pub const Module = struct {
    root: *Generator,
    ir: *Rir.Module,


    global_lookup: std.ArrayHashMapUnmanaged(Rir.GlobalId, *Generator.Global, MiscUtils.SimpleHashContext, false) = .{},
    function_lookup: std.ArrayHashMapUnmanaged(Rir.FunctionId, *Generator.Function, MiscUtils.SimpleHashContext, false) = .{},
    handler_set_lookup: std.ArrayHashMapUnmanaged(Rir.HandlerSetId, *RbcBuilder.HandlerSetBuilder, MiscUtils.SimpleHashContext, false) = .{},


    pub fn init(root: *Generator, moduleIr: *Rir.Module) error{OutOfMemory}! *Module {
        const self = try root.allocator.create(Module);

        self.* = Module {
            .root = root,
            .ir = moduleIr,
        };

        return self;
    }


    pub fn getFunction(self: *Module, functionId: Rir.FunctionId) Generator.Error! *Generator.Function {
        const getOrPut = try self.function_lookup.getOrPut(self.root.allocator, functionId);

        if (!getOrPut.found_existing) {
            const fun = try self.ir.getFunction(functionId);
            const builder = try self.root.builder.function();

            getOrPut.value_ptr.* = try compileFunction(self, fun, builder);
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getGlobal(self: *Module, globalId: Rir.GlobalId) Generator.Error! *Generator.Global {
        const getOrPut = try self.global_lookup.getOrPut(self.root.allocator, globalId);

        if (!getOrPut.found_existing) {
            const globalIr = try self.ir.getGlobal(globalId);
            getOrPut.value_ptr.* = try compileGlobal(self, globalIr);
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getHandlerSet(self: *Module, handlerSetId: Rir.HandlerSetId) !*RbcBuilder.HandlerSetBuilder {
        const getOrPut = try self.handler_set_lookup.getOrPut(self.root.allocator, handlerSetId);

        if (!getOrPut.found_existing) {
            const handlerSetIr = try self.ir.getHandlerSet(handlerSetId);
            const handlerSetBuilder = try self.root.builder.handlerSet();

            getOrPut.value_ptr.* = handlerSetBuilder;

            try compileHandlerSet(self, handlerSetIr, handlerSetBuilder);
        }

        return getOrPut.value_ptr.*;
    }
};


pub fn compileGlobal(self: *Module, globalIr: *Rir.Global) Generator.Error! *Generator.Global {
    const globalLayout = try self.root.ir.getTypeLayout(globalIr.type);
    const globalBuilder = try self.root.builder.globalBytes(globalLayout.dimensions.alignment, globalIr.value);

    const globalGenerator = try Generator.Global.init(self, globalIr, globalBuilder);

    try self.global_lookup.put(self.root.allocator, globalIr.id, globalGenerator);

    return globalGenerator;
}

pub fn compileFunction(self: *Module, functionIr: *Rir.Function, functionBuilder: *RbcBuilder.FunctionBuilder) Generator.Error! *Generator.Function {
    var functionGenerator = try Generator.Function.init(self, functionIr, functionBuilder);

    try self.function_lookup.put(self.root.allocator, functionIr.id, functionGenerator);

    try functionGenerator.generate();

    return functionGenerator;
}

pub fn compileHandlerSet(self: *Module, handlerSet: *Rir.HandlerSet, builder: *RbcBuilder.HandlerSetBuilder) !void {
    var it = handlerSet.handlers.iterator();
    while (it.next()) |pair| {
        const evId = try self.root.getEvidence(pair.key_ptr.*);
        const handlerBuilder = try builder.handler(evId);
        _ = try compileFunction(self, pair.value_ptr.*, handlerBuilder);
    }
}
