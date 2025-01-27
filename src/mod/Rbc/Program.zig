const std = @import("std");

const Rbc = @import("../Rbc.zig");

const Program = @This();


globals: []const [*]u8,
global_memory: []u8,
functions: []const Rbc.Function,
foreign_functions: []const Rbc.Function.Foreign,
handler_sets: []const Rbc.Handler.Set,
main: Rbc.FunctionIndex,


pub fn deinit(self: Program, allocator: std.mem.Allocator) void {
    allocator.free(self.globals);

    allocator.free(self.global_memory);

    for (self.functions) |fun| {
        fun.deinit(allocator);
    }

    allocator.free(self.functions);

    allocator.free(self.foreign_functions);

    for (self.handler_sets) |handlerSet| {
        allocator.free(handlerSet);
    }

    allocator.free(self.handler_sets);
}
