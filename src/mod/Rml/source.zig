const Rml = @import("../Rml.zig");

const source = @This();

const std = @import("std");
const utils = @import("utils");



pub fn blobOrigin(blob: []const Rml.Object) Origin {
    if (blob.len == 0) return Origin { .filename = "system" };

    var origin = blob[0].getOrigin();

    for (blob[1..]) |obj| {
        origin = origin.merge(obj.getOrigin()) orelse return Origin { .filename = "multiple" };
    }

    return origin;
}

pub const Origin = struct {
    filename: []const u8,
    range: ?Range = null,

    pub fn merge(self: Origin, other: Origin) ?Origin {
        return if (std.mem.eql(u8, self.filename, other.filename)) Origin {
            .filename = self.filename,
            .range = rangeMerge(self.range, other.range),
        } else null;
    }

    pub fn fromStr(rml: *Rml, str: []const u8) Rml.OOM! Origin {
        return Origin { .filename = try rml.data.intern(str) };
    }

    pub fn fromComptimeStr(comptime str: []const u8) Origin {
        return Origin { .filename = str };
    }

    pub fn fromComptimeFmt(comptime fmt: []const u8, comptime args: anytype) Origin {
        return Origin { .filename = comptime std.fmt.comptimePrint(fmt, args) };
    }

    pub fn compare(self: Origin, other: Origin) utils.Ordering {
        var res = utils.compare(self.filename, other.filename);

        if (res == .Equal) {
            res = utils.compare(self.range, other.range);
        }

        return res;
    }

    pub fn format(self: *const Origin, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.print("[{s}", .{self.filename});

        if (self.range) |range| {
            try writer.print(":{" ++ fmt ++ "}", .{range});
        }

        try writer.print("]", .{});
    }

    pub fn hashWith(self: Origin, hasher: anytype) void {
        utils.hashWith(hasher, self.filename);
        utils.hashWith(hasher, self.range);
    }
};

pub fn rangeMerge(a: ?Range, b: ?Range) ?Range {
    if (a == null or b == null) return null;
    const x = a.?;
    const y = b.?;
    return Range {
        .start = posMin(x.start, y.start),
        .end = posMax(x.end, y.end),
    };
}

pub fn posMin(a: ?Pos, b: ?Pos) ?Pos {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.offset < b.?.offset) a
    else b;
}

pub fn posMax(a: ?Pos, b: ?Pos) ?Pos {
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.offset > b.?.offset) a
    else b;
}

pub const Range = struct {
    start: ?Pos = null,
    end: ?Pos = null,

    pub fn compare(self: Range, other: Range) utils.Ordering {
        var res = utils.compare(self.start, other.start);

        if (res == .Equal) {
            res = utils.compare(self.end, other.end);
        }

        return res;
    }

    pub fn format(self: *const Range, comptime fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
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
        utils.hashWith(hasher, self.start);
        utils.hashWith(hasher, self.end);
    }
};

pub const Pos = struct {
    line: u32 = 0,
    column: u32 = 0,
    offset: u32 = 0,
    indentation: u32 = 0,

    pub fn compare(self: Pos, other: Pos) utils.Ordering {
        return utils.compare(self.offset, other.offset);
    }

    pub fn format(self: *const Pos, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror!void {
        try writer.print("{d}:{d}", .{ self.line, self.column});
    }

    pub fn hashWith(self: Pos, hasher: anytype) void {
        utils.hashWith(hasher, self.offset);
    }
};
