const std = @import("std");

const utils = @import("utils");

const Isa = @import("Isa");

const Rbc = @import("../Rbc.zig");


const Bytecode = @This();


blocks: []const [*]const Rbc.Instruction,
instructions: []const Rbc.Instruction,

pub fn deinit(self: Bytecode, allocator: std.mem.Allocator) void {
    allocator.free(self.blocks);
    allocator.free(self.instructions);
}


test {
    std.testing.refAllDeclsRecursive(@This());
}
