const std = @import("std");

const Rml = @import("root.zig");



pub const Cell = struct {
    value: Rml.Object,

    pub fn onCompare(a: *Cell, other: Rml.Object) Rml.Ordering {
        var ord = Rml.compare(Rml.getTypeId(a), other.getTypeId());
        if (ord == .Equal) {
            const b = Rml.forceObj(Cell, other);
            ord = a.value.compare(b.data.value);
        }
        return ord;
    }

    pub fn set(self: *Cell, value: Rml.Object) void {
        self.value = value;
    }

    pub fn get(self: *Cell) Rml.Object {
        return self.value;
    }
};
