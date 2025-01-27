const std = @import("std");
const utils = @import("utils");

const Rir = @import("../Rir.zig");


const HandlerList = std.ArrayHashMapUnmanaged(Rir.EvidenceId, *Rir.Function, utils.SimpleHashContext, false);

pub const HandlerSet = struct {
    pub const Id = Rir.HandlerSetId;

    ir: *Rir,

    module: *Rir.Module,

    id: Rir.HandlerSetId,

    parent: ?*Rir.Block = null,
    handlers: HandlerList = .{},

    pub fn init(module: *Rir.Module, id: Rir.HandlerSetId) !*HandlerSet {
        const ir = module.ir;

        const ptr = try ir.allocator.create(HandlerSet);
        errdefer ir.allocator.destroy(ptr);

        ptr.* = HandlerSet {
            .ir = ir,
            .module = module,
            .id = id,
        };

        return ptr;
    }

    pub fn deinit(self: *HandlerSet) void {
        for (self.handlers.values()) |h| {
            h.deinit();
        }

        self.handlers.deinit(self.ir.allocator);

        self.ir.allocator.destroy(self);
    }

    pub fn createHandler(self: *HandlerSet, name: Rir.NameId, evId: Rir.EvidenceId, typeIr: *Rir.Type) !*Rir.Function {
        if (self.handlers.contains(evId)) {
            return error.EvidenceOverlap;
        }

        // TODO: check type against evidence signature

        const func = try self.module.createFunction(name, typeIr);

        func.parent = self.parent;
        func.evidence = evId;

        try self.handlers.put(self.ir.allocator, evId, func);

        return func;
    }

    pub fn getHandler(self: *HandlerSet, evId: Rir.EvidenceId) !*Rir.Function {
        return self.handlers.get(evId) orelse error.InvalidEvidenceId;
    }
};
