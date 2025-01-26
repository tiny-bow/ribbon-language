const std = @import("std");

const Rir = @import("../Rir.zig");


pub const ForeignAddress = struct {
    pub const Id = Rir.ForeignId;

    root: *Rir,
    id: Rir.ForeignId,
    name: Rir.NameId,
    type: *Rir.Type,


    pub fn init(root: *Rir, id: Rir.ForeignId, name: Rir.NameId, typeIr: *Rir.Type) error{OutOfMemory}! *ForeignAddress {
        const ptr = try root.allocator.create(ForeignAddress);
        errdefer root.allocator.destroy(ptr);

        ptr.* = ForeignAddress {
            .root = root,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return ptr;
    }

    pub fn deinit(self: *ForeignAddress) void {
        self.root.allocator.destroy(self);
    }
};
