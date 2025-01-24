const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");


const Generator = @import("../RbcGenerator.zig");


pub const Global = struct {
    module: *Generator.Module,

    ir: *Rir.Global,
    builder: *RbcBuilder.Global,


    pub fn init(module: *Generator.Module, global: *Rir.Global, builder: *RbcBuilder.Global) error{OutOfMemory}! *Global {
        const self = try module.root.allocator.create(Global);

        self.* = Global {
            .module = module,

            .ir = global,
            .builder = builder,
        };

        return self;
    }


    pub fn generate(_: *Global) !void {
        @panic("TODO: Implement Global.generate");
    }
};
