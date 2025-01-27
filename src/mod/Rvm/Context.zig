//! Global state shared by all threads

const std = @import("std");

const Context = @This();


allocator: std.mem.Allocator,


pub fn init(allocator: std.mem.Allocator) !*Context {
    const ptr = try allocator.create(Context);

    ptr.* = Context {
        .allocator = allocator,
    };

    return ptr;
}

pub fn deinit(self: *Context) void {
    self.allocator.destroy(self);
}
