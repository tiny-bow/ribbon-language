const std = @import("std");

const Rbc = @import("../Rbc.zig");

const Function = @This();

num_arguments: Rbc.RegisterIndex,
num_registers: Rbc.RegisterIndex,
bytecode: Rbc.Bytecode,

pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
    self.bytecode.deinit(allocator);
}


pub const Foreign = struct {
    num_arguments: Rbc.RegisterIndex,
    num_registers: Rbc.RegisterIndex,
};
