const std = @import("std");
const TypeUtils = @import("Utils").Type;

const Rml = @import("root.zig");
const OOM = Rml.OOM;
const Ordering = Rml.Ordering;


pub const Origin = struct {
    filename: []const u8,
    range: ?Range = null,

    pub fn fromStr(rml: *Rml, str: []const u8) OOM! Origin {
        return Origin { .filename = try rml.storage.intern(str) };
    }

    pub fn fromComptimeStr(comptime str: []const u8) Origin {
        return Origin { .filename = str };
    }

    pub fn fromComptimeFmt(comptime fmt: []const u8, comptime args: anytype) Origin {
        return Origin { .filename = comptime std.fmt.comptimePrint(fmt, args) };
    }

    pub fn compare(self: Origin, other: Origin) Ordering {
        var res = Rml.compare(self.filename, other.filename);

        if (res == Ordering.Equal) {
            res = Rml.compare(self.range, other.range);
        }

        return res;
    }

    pub fn format(self: *const Origin, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("[{s}", .{self.filename});

        if (self.range) |range| {
            try writer.print(":{" ++ fmt ++ "}", .{range});
        }

        try writer.print("]", .{});
    }

    pub fn hashWith(self: Origin, hasher: anytype) void {
        Rml.hashWith(hasher, self.filename);
        Rml.hashWith(hasher, self.range);
    }
};

pub const Range = struct {
    start: ?Pos = null,
    end: ?Pos = null,

    pub fn compare(self: Range, other: Range) Ordering {
        var res = Rml.compare(self.start, other.start);

        if (res == Ordering.Equal) {
            res = Rml.compare(self.end, other.end);
        }

        return res;
    }

    pub fn format(self: Range, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const g = "{" ++ fmt ++ "}";

        if (self.start) |start| {
            try writer.print(g, .{start});
            if (self.end) |end| {
                if (start.line == end.line and !std.mem.eql(u8, fmt, "offset")) {
                    try writer.print("-{}", .{end.column});
                } else {
                    try writer.print(" to " ++ g, .{end});
                }
            }
        } else if (self.end) |end| {
            try writer.print("?-" ++ g, .{end});
        } else {
            try writer.print("?-?", .{});
        }
    }

    pub fn hashWith(self: Range, hasher: anytype) void {
        Rml.hashWith(hasher, self.start);
        Rml.hashWith(hasher, self.end);
    }
};

pub const Pos = struct {
    line: u32 = 0,
    column: u32 = 0,
    offset: u32 = 0,
    indentation: u32 = 0,

    pub fn compare(self: Pos, other: Pos) Ordering {
        return Rml.compare(self.offset, other.offset);
    }

    pub fn format(self: Pos, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{d}:{d}", .{ self.line, self.column});
    }

    pub fn hashWith(self: Pos, hasher: anytype) void {
        Rml.hashWith(hasher, self.offset);
    }
};
