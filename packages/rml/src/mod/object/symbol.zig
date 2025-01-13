const std = @import("std");
const TextUtils = @import("Utils").Text;

const Rml = @import("../root.zig");



pub const Symbol = struct {
    str: Rml.str,

    pub fn create(rml: *Rml, str: []const u8) Rml.OOM! Symbol {
        return .{ .str = try rml.data.intern(str) };
    }


    pub fn onFormat(self: *const Symbol, _: Rml.Format, w: std.io.AnyWriter) anyerror! void {
        try w.print("{s}", .{self.text()});
    }

    pub fn format(self: *const Symbol, comptime fmt: []const u8, _: std.fmt.FormatOptions, w: anytype) anyerror! void {
        return self.onFormat(comptime Rml.Format.fromStr(fmt) orelse Rml.Format.debug, if (@TypeOf(w) == std.io.AnyWriter) w else w.any());
    }

    pub fn text(self: *const Symbol) Rml.str {
        return self.str;
    }

    pub fn length(self: *const Symbol) Rml.Int {
        return @intCast(self.str.len);
    }
};

