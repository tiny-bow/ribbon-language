const std = @import("std");
const Core = @import("../Core.zig");

const Foreign = @This();


root: *Core.IR,
id: Core.ForeignId,
type: Core.TypeId,
locals: []Core.TypeId,


pub fn init(root: *Core.IR, id: Core.ForeignId, tyId: Core.TypeId, locals: []Core.TypeId) !*Foreign {
    errdefer root.allocator.free(locals);

    const ptr = try root.allocator.create(Foreign);
    errdefer root.allocator.destroy(ptr);

    ptr.* = Foreign {
        .root = root,
        .id = id,
        .type = tyId,
        .locals = locals,
    };

    return ptr;
}

pub fn deinit(self: *Foreign) void {
    self.root.allocator.free(self.locals);
    self.root.allocator.destroy(self);
}
