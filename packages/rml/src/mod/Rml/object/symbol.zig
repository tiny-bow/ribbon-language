const std = @import("std");
const TextUtils = @import("Utils").Text;

const Rml = @import("../../Rml.zig");



pub const Symbol = struct {
    str: Rml.str,

    pub fn create(rml: *Rml, str: []const u8) Rml.OOM! Symbol {
        return .{ .str = try rml.data.intern(str) };
    }

    pub fn format(self: *const Symbol, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
        return writer.writeAll(self.text());
    }

    pub fn text(self: *const Symbol) Rml.str {
        return self.str;
    }

    pub fn length(self: *const Symbol) Rml.Int {
        return @intCast(self.str.len);
    }
};

