const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("../Rir.zig");


const HandlerList = std.ArrayHashMapUnmanaged(Rir.EvidenceId, *Rir.Function, MiscUtils.SimpleHashContext, false);

pub const HandlerSet = struct {
    module: *Rir.Module,
    id: Rir.HandlerSetId,

    parent: ?*Rir.Block = null,
    handlers: HandlerList = .{},

    pub fn init(module: *Rir.Module, id: Rir.HandlerSetId) !*HandlerSet {
        const ptr = try module.root.allocator.create(HandlerSet);
        errdefer module.root.allocator.destroy(ptr);

        ptr.* = HandlerSet {
            .module = module,
            .id = id,
        };

        return ptr;
    }

    pub fn deinit(self: *HandlerSet) void {
        for (self.handlers.values()) |h| {
            h.deinit();
        }

        self.handlers.deinit(self.module.root.allocator);

        self.module.root.allocator.destroy(self);
    }

    pub fn createHandler(self: *HandlerSet, name: Rir.NameId, evId: Rir.EvidenceId, tyId: Rir.TypeId) !*Rir.Function {
        if (self.handlers.contains(evId)) {
            return error.EvidenceOverlap;
        }

        // TODO: check type against evidence signature

        const func = try self.module.createFunction(name, tyId);

        func.parent = self.parent;
        func.evidence = evId;

        try self.handlers.put(self.module.root.allocator, evId, func);

        return func;
    }

    pub fn getHandler(self: *HandlerSet, evId: Rir.EvidenceId) !*Rir.Function {
        return self.handlers.get(evId) orelse error.InvalidEvidenceId;
    }
};
