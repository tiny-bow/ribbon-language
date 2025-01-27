const Generator = @import("../RbcGenerator.zig");

const module = @This();

const std = @import("std");
const utils = @import("utils");
const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");



pub const Module = struct {
    generator: *Generator,

    ir: *Rir.Module,

    global_lookup: std.ArrayHashMapUnmanaged(Rir.GlobalId, *Generator.Global, utils.SimpleHashContext, false) = .{},
    function_lookup: std.ArrayHashMapUnmanaged(Rir.FunctionId, *Generator.Function, utils.SimpleHashContext, false) = .{},
    handler_set_lookup: std.ArrayHashMapUnmanaged(Rir.HandlerSetId, *RbcBuilder.HandlerSet, utils.SimpleHashContext, false) = .{},


    pub fn init(generator: *Generator, moduleIr: *Rir.Module) error{OutOfMemory}! *Module {
        const self = try generator.allocator.create(Module);

        self.* = Module {
            .generator = generator,
            .ir = moduleIr,
        };

        return self;
    }


    pub fn getFunction(self: *Module, functionId: Rir.FunctionId) Generator.Error! *Generator.Function {
        const getOrPut = try self.function_lookup.getOrPut(self.generator.allocator, functionId);

        if (!getOrPut.found_existing) {
            const fun = try self.ir.getFunction(functionId);
            const builder = try self.generator.builder.createFunction();

            getOrPut.value_ptr.* = try compileFunction(self, fun, builder);
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getGlobal(self: *Module, globalId: Rir.GlobalId) Generator.Error! *Generator.Global {
        const getOrPut = try self.global_lookup.getOrPut(self.generator.allocator, globalId);

        if (!getOrPut.found_existing) {
            const globalIr = try self.ir.getGlobal(globalId);
            getOrPut.value_ptr.* = try compileGlobal(self, globalIr);
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getHandlerSet(self: *Module, handlerSetIr: *Rir.HandlerSet) !*RbcBuilder.HandlerSet {
        const getOrPut = try self.handler_set_lookup.getOrPut(self.generator.allocator, handlerSetIr.id);

        if (!getOrPut.found_existing) {
            const handlerSetBuilder = try self.generator.builder.createHandlerSet();

            getOrPut.value_ptr.* = handlerSetBuilder;

            try compileHandlerSet(self, handlerSetIr, handlerSetBuilder);
        }

        return getOrPut.value_ptr.*;
    }
};


pub fn compileGlobal(self: *Module, globalIr: *Rir.Global) Generator.Error! *Generator.Global {
    const globalLayout = try globalIr.type.getLayout();

    const globalInitializer =
        if (globalIr.initial_value) |ini| ini
        else noIni: {
            const mem = try self.generator.allocator.alloc(u8, globalLayout.dimensions.size);
            @memset(mem, 0);
            break :noIni mem;
        };

    const globalBuilder = try self.generator.builder.globalBytes(globalLayout.dimensions.alignment, globalInitializer);

    const globalGenerator = try Generator.Global.init(self, globalIr, globalBuilder);

    try self.global_lookup.put(self.generator.allocator, globalIr.id, globalGenerator);

    return globalGenerator;
}

pub fn compileFunction(self: *Module, functionIr: *Rir.Function, functionBuilder: *RbcBuilder.Function) Generator.Error! *Generator.Function {
    var functionGenerator = try Generator.Function.init(self, functionIr, functionBuilder);

    try self.function_lookup.put(self.generator.allocator, functionIr.id, functionGenerator);

    try functionGenerator.generate();

    return functionGenerator;
}

pub fn compileHandlerSet(self: *Module, handlerSet: *Rir.HandlerSet, builder: *RbcBuilder.HandlerSet) !void {
    var it = handlerSet.handlers.iterator();
    while (it.next()) |pair| {
        const evId = try self.generator.getEvidence(pair.key_ptr.*);
        const handlerBuilder = try builder.handler(evId);
        _ = try compileFunction(self, pair.value_ptr.*, handlerBuilder);
    }
}
