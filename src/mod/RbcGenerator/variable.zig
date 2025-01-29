const Generator = @import("../RbcGenerator.zig");

const global = @This();

const std = @import("std");
const utils = @import("utils");
const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

pub const Global = struct {
    generator: *Generator,
    module: *Generator.Module,

    ir: *Rir.Global,

    index: Rbc.GlobalIndex,

    pub fn init(module: *Generator.Module, globalIr: *Rir.Global) error{OutOfMemory}!*Global {
        const generator = module.generator;

        const self = try generator.allocator.create(Global);

        self.* = Global{
            .generator = generator,
            .module = module,

            .ir = globalIr,
            .index = @intFromEnum(globalIr.id), // FIXME: this is a placeholder
        };

        return self;
    }

    pub fn generate(_: *Global) !void {
        @panic("TODO: Implement Global.generate");
    }
};

pub const Upvalue = struct {
    generator: *Generator,
    module: *Generator.Module,

    ir: *Rir.Upvalue,

    index: Rbc.UpvalueIndex,

    pub fn init(module: *Generator.Module, upvalueIr: *Rir.Upvalue) error{OutOfMemory}!*Upvalue {
        const generator = module.generator;

        const self = try generator.allocator.create(Upvalue);

        self.* = Upvalue{
            .generator = generator,
            .module = module,

            .ir = upvalueIr,
            .index = @intFromEnum(upvalueIr.id), // FIXME: this is a placeholder
        };

        return self;
    }

    pub fn generate(_: *Upvalue) !void {
        @panic("TODO: Implement Upvalue.generate");
    }
};
