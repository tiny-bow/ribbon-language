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
    handler_set_lookup: std.ArrayHashMapUnmanaged(Rir.HandlerSetId, *Generator.HandlerSet, utils.SimpleHashContext, false) = .{},

    pub fn init(generator: *Generator, moduleIr: *Rir.Module) error{OutOfMemory}!*Module {
        const self = try generator.allocator.create(Module);

        self.* = Module{
            .generator = generator,
            .ir = moduleIr,
        };

        return self;
    }

    pub fn getFunction(self: *Module, functionId: Rir.FunctionId) Generator.Error!*Generator.Function {
        const getOrPut = try self.function_lookup.getOrPut(self.generator.allocator, functionId);

        if (!getOrPut.found_existing) {
            const functionIr = try self.ir.getFunction(functionId);
            const functionGen = try Generator.Function.init(self, functionIr);

            getOrPut.value_ptr.* = functionGen;

            try functionGen.generate();
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getGlobal(self: *Module, globalId: Rir.GlobalId) Generator.Error!*Generator.Global {
        const getOrPut = try self.global_lookup.getOrPut(self.generator.allocator, globalId);

        if (!getOrPut.found_existing) {
            const globalIr = try self.ir.getGlobal(globalId);
            const globalGen = try Generator.Global.init(self, globalIr);

            getOrPut.value_ptr.* = globalGen;

            try globalGen.generate();
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getHandlerSet(self: *Module, handlerSetId: Rir.HandlerSetId) !*Generator.HandlerSet {
        const getOrPut = try self.handler_set_lookup.getOrPut(self.generator.allocator, handlerSetId);

        if (!getOrPut.found_existing) {
            const handlerSetIr = try self.ir.getHandlerSet(handlerSetId);
            const handlerSetGen = try Generator.HandlerSet.init(self, handlerSetIr);

            getOrPut.value_ptr.* = handlerSetGen;

            try handlerSetGen.generate();
        }

        return getOrPut.value_ptr.*;
    }
};
