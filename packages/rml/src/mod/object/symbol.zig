const std = @import("std");

const Rml = @import("../root.zig");



pub const Symbol = struct {
    str: Rml.str,

    pub fn create(rml: *Rml, str: []const u8) Rml.OOM! Symbol {
        return .{ .str = try rml.data.intern(str) };
    }

    pub fn onCompare(self: *Symbol, other: Rml.Object) Rml.Ordering {
        var ord = Rml.compare(Rml.getHeader(self).type_id, other.getTypeId());

        if (ord == .Equal) {
            const b = Rml.forceObj(Symbol, other);

            ord = Rml.compare(@intFromPtr(self.str.ptr), @intFromPtr(b.data.str.ptr));
            if (ord == .Equal) {
                ord = Rml.compare(self.str.len, b.data.str.len);
            }
        }

        return ord;
    }

    pub fn onFormat(self: *Symbol, writer: std.io.AnyWriter) anyerror! void {
        // TODO: escape non-ascii & control etc chars
        try writer.print("{s}", .{self.str});
    }

    pub fn text(self: *Symbol) Rml.str {
        return self.str;
    }
};

