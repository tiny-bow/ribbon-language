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
    builder: *RbcBuilder.Global,


    pub fn init(module: *Generator.Module, globalIr: *Rir.Global, globalBuilder: *RbcBuilder.Global) error{OutOfMemory}! *Global {
        const generator = module.generator;
        const self = try generator.allocator.create(Global);

        self.* = Global {
            .generator = generator,
            .module = module,

            .ir = globalIr,
            .builder = globalBuilder,
        };

        return self;
    }


    pub fn generate(_: *Global) !void {
        @panic("TODO: Implement Global.generate");
    }
};
