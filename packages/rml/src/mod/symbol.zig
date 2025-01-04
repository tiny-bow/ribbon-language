const std = @import("std");

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const OOM = Rml.OOM;
const Error = Rml.Error;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const Object = Rml.Object;
const Writer = Rml.Writer;
const getHeader = Rml.getHeader;
const forceObj = Rml.forceObj;
const getObj = Rml.getObj;
const getRml = Rml.getRml;

pub const Symbol = struct {
    str: Rml.str,

    pub fn create(rml: *Rml, str: []const u8) OOM! Symbol {
        return .{ .str = try rml.storage.intern(str) };
    }

    pub fn onCompare(self: ptr(Symbol), other: Object) Ordering {
        var ord = Rml.compare(getHeader(self).type_id, other.getTypeId());

        if (ord == .Equal) {
            const b = forceObj(Symbol, other);

            ord = Rml.compare(@intFromPtr(self.str.ptr), @intFromPtr(b.data.str.ptr));
            if (ord == .Equal) {
                ord = Rml.compare(self.str.len, b.data.str.len);
            }
        }

        return ord;
    }

    pub fn onFormat(self: ptr(Symbol), writer: std.io.AnyWriter) anyerror! void {
        // TODO: escape non-ascii & control etc chars
        try writer.print("{s}", .{self.str});
    }

    pub fn text(self: ptr(Symbol)) Rml.str {
        return self.str;
    }
};

