const std = @import("std");

const Rml = @import("../root.zig");



pub const Cell = struct {
    value: Rml.Object,

    pub fn onCompare(a: *Cell, other: Rml.Object) Rml.Ordering {
        var ord = Rml.compare(Rml.getTypeId(a), other.getTypeId());
        if (ord == .Equal) {
            const b = Rml.forceObj(Cell, other);
            ord = a.value.compare(b.data.value);
        } else if (Rml.compare(a.value.getTypeId(), other.getTypeId()) == .Equal) {
            ord = Rml.compare(a.value, other);
        }
        return ord;
    }

    pub fn compare(self: Cell, other: Cell) Rml.Ordering {
        return self.value.compare(other.value);
    }

    pub fn onFormat(self: *Cell, fmt: Rml.Format, w: std.io.AnyWriter) anyerror! void {
        if (fmt == .debug) {
            try w.print("Cell({s})", .{self.value});
        } else {
            try self.value.onFormat(fmt, w);
        }
    }

    pub fn format(self: *Cell, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        const fmt = Rml.Format.fromStr(fmtStr) orelse .debug;
        const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();
        try self.onFormat(fmt, w);
    }

    pub fn set(self: *Cell, value: Rml.Object) void {
        self.value = value;
    }

    pub fn get(self: *Cell) Rml.Object {
        return self.value;
    }
};
