const Rir = @import("../Rir.zig");

const foreign = @This();

const std = @import("std");



pub const Foreign = struct {
    pub const Id = Rir.ForeignId;

    root: *Rir,
    id: Rir.ForeignId,
    name: Rir.NameId,
    type: *Rir.Type,


    pub fn init(root: *Rir, id: Rir.ForeignId, name: Rir.NameId, typeIr: *Rir.Type) error{OutOfMemory}! *Foreign {
        const ptr = try root.allocator.create(Foreign);
        errdefer root.allocator.destroy(ptr);

        ptr.* = Foreign {
            .root = root,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return ptr;
    }

    pub fn deinit(self: *Foreign) void {
        self.root.allocator.destroy(self);
    }
};
