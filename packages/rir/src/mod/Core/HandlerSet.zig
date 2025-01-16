const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Core = @import("../Core.zig");

const HandlerSet = @This();


parent: *Core.Function,
id: Core.HandlerSetId,
handlers: std.ArrayHashMapUnmanaged(Core.TypeId, *Core.Function, MiscUtils.SimpleHashContext, false) = .{},


pub fn init(parent: *Core.Function, id: Core.HandlerSetId) !*HandlerSet {
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

pub fn handler(self: *HandlerSet, evId: Core.TypeId) !*Core.Function {
    if (self.handlers.contains(evId)) {
        return error.EvidenceOverlap;
    }

    const func = try self.parent.module.function(evId);

    func.parent = self.parent;

    try self.handlers.put(self.parent.module.root.allocator, evId, func);

    return func;
}

pub fn getHandler(self: *HandlerSet, evId: Core.TypeId) !*Core.Function {
    return self.handlers.get(evId) orelse error.InvalidEvidenceId;
}
