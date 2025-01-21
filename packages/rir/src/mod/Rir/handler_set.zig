const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("../Rir.zig");


pub const HandlerSet = struct {
    parent: *Rir.Function,
    id: Rir.HandlerSetId,
    handlers: std.ArrayHashMapUnmanaged(Rir.TypeId, *Rir.Function, MiscUtils.SimpleHashContext, false) = .{},

    pub fn init(parent: *Rir.Function, id: Rir.HandlerSetId) !*HandlerSet {
        const ptr = try parent.module.root.allocator.create(HandlerSet);
        errdefer parent.module.root.allocator.destroy(ptr);

        ptr.* = HandlerSet {
            .parent = parent,
            .id = id,
        };

        return ptr;
    }

    pub fn deinit(self: *HandlerSet) void {
        for (self.handlers.values()) |h| {
            h.deinit();
        }

        self.handlers.deinit(self.parent.module.root.allocator);

        self.parent.module.root.allocator.destroy(self);
    }

    pub fn createHandler(self: *HandlerSet, name: Rir.Name, evId: Rir.TypeId) !*Rir.Function {
        if (self.handlers.contains(evId)) {
            return error.EvidenceOverlap;
        }

        const func = try self.parent.module.createFunction(name, evId);

        func.parent = self.parent;

        try self.handlers.put(self.parent.module.root.allocator, evId, func);

        return func;
    }

    pub fn getHandler(self: *HandlerSet, evId: Rir.TypeId) !*Rir.Function {
        return self.handlers.get(evId) orelse error.InvalidEvidenceId;
    }
};
