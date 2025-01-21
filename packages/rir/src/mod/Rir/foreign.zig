const std = @import("std");

const Rir = @import("../Rir.zig");


pub const ForeignAddress = struct {
    root: *Rir,
    id: Rir.ForeignId,
    name: Rir.Name,
    type: Rir.TypeId,
    locals: []Rir.TypeId,


    pub fn init(root: *Rir, id: Rir.ForeignId, name: Rir.Name, tyId: Rir.TypeId, locals: []Rir.TypeId) error{OutOfMemory}! *ForeignAddress {
        errdefer root.allocator.free(locals);

        const ptr = try root.allocator.create(ForeignAddress);
        errdefer root.allocator.destroy(ptr);

        ptr.* = ForeignAddress {
            .root = root,
            .id = id,
            .name = name,
            .type = tyId,
            .locals = locals,
        };

        return ptr;
    }

    pub fn deinit(self: *ForeignAddress) void {
        self.root.allocator.free(self.locals);
        self.root.allocator.destroy(self);
    }
};
