const Builder = @import("../RbcBuilder.zig");

const handler_set = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");

pub const HandlerMap = std.ArrayHashMapUnmanaged(Rbc.EvidenceIndex, Rbc.FunctionIndex, utils.SimpleHashContext, false);

pub const HandlerSet = struct {
    parent: *Builder,
    index: Rbc.HandlerSetIndex,
    handler_map: HandlerMap,

    pub fn init(parent: *Builder, index: Rbc.HandlerSetIndex) std.mem.Allocator.Error!*HandlerSet {
        const ptr = try parent.allocator.create(HandlerSet);

        var handler_map = HandlerMap{};
        try handler_map.ensureTotalCapacity(parent.allocator, 8);

        ptr.* = HandlerSet{
            .parent = parent,
            .index = index,
            .handler_map = handler_map,
        };

        return ptr;
    }

    pub fn assemble(self: *const HandlerSet, allocator: std.mem.Allocator) Builder.Error!Rbc.HandlerSet {
        const handlerSet = try allocator.alloc(Rbc.HandlerBinding, self.handler_map.count());
        errdefer allocator.free(handlerSet);

        for (self.handler_map.keys(), 0..) |e, i| {
            const funIndex = try self.getHandler(e);
            handlerSet[i] = Rbc.HandlerBinding{ .id = e, .handler = funIndex };
        }

        return handlerSet;
    }

    pub fn getEvidence(self: *const HandlerSet) []const Rbc.EvidenceIndex {
        return self.handler_map.keys();
    }

    pub fn containsEvidence(self: *const HandlerSet, e: Rbc.EvidenceIndex) bool {
        return self.handler_map.contains(e);
    }

    pub fn getHandler(self: *const HandlerSet, e: Rbc.EvidenceIndex) Builder.Error!Rbc.FunctionIndex {
        return self.handler_map.get(e) orelse Builder.Error.MissingHandler;
    }

    pub fn handler(self: *HandlerSet, e: Rbc.EvidenceIndex) Builder.Error!*Builder.Function {
        if (self.handler_map.contains(e)) {
            return Builder.Error.EvidenceOverlap;
        }

        const fun = try self.parent.createFunction();

        fun.evidence = e;

        try self.handler_map.put(self.parent.allocator, e, fun.index);

        return fun;
    }

    pub fn foreignHandler(self: *HandlerSet, e: Rbc.EvidenceIndex, num_arguments: Rbc.RegisterIndex, num_registers: Rbc.RegisterIndex) Builder.Error!*Builder.Function.Foreign {
        if (self.handler_map.contains(e)) {
            return Builder.Error.EvidenceOverlap;
        }

        const fun = try self.parent.foreign(num_arguments, num_registers);

        fun.evidence = e;

        try self.handler_map.put(self.parent.allocator, e, fun.index);

        return fun;
    }

    pub fn foreignNativeHandler(self: *HandlerSet, e: Rbc.EvidenceIndex, comptime T: type) Builder.Error!*Builder.Foreign {
        if (self.handler_map.contains(e)) {
            return Builder.Error.EvidenceOverlap;
        }

        const ev = try self.parent.getEvidence(e);

        const fun = try self.parent.foreignNative(ev.type, T);

        fun.evidence = e;

        try self.handler_map.put(self.parent.allocator, e, fun.index);

        return fun;
    }
};
