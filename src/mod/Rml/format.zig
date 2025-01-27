const Rml = @import("../Rml.zig");

const format = @This();

const std = @import("std");

pub const Format = enum {
    debug,
    message,
    source,

    pub fn fromSymbol(s: Rml.Obj(Rml.Symbol)) ?Format {
        return Format.fromStr(s.data.text());
    }

    pub fn fromStr(s: []const u8) ?Format {
        if (std.mem.eql(u8, s, "debug")) {
            return .debug;
        } else if (std.mem.eql(u8, s, "message")) {
            return .message;
        } else if (std.mem.eql(u8, s, "source")) {
            return .source;
        } else {
            return null;
        }
    }
};

pub fn slice(buf: anytype) SliceFormatter(@typeInfo(@TypeOf(buf)).pointer.child) {
    return .{ .buf = buf };
}

pub fn SliceFormatter(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []const T,

        pub fn onFormat(self: *const Self, fmt: Format, writer: std.io.AnyWriter) anyerror!void {
            for (self.buf) |item| {
                try item.onFormat(fmt, writer);
            }
        }

        pub fn format(self: *const Self, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
            for (self.buf) |item| {
                try item.format(fmt, .{}, writer);
            }
        }
    };
}
