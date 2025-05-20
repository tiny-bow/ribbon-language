const std = @import("std");
const pl = @import("platform");

const Id = @import("Id");

/// A position in the source code, in terms of the buffer.
pub const BufferPosition = u64;

/// A position in the source code, in terms of the line and column.
pub const VisualPosition = packed struct {
    /// 1-based line number.
    line: u32 = 1,
    /// 1-based column number.
    column: u32 = 1,
};

/// A `Location`, with a source name attached.
pub const Source = struct {
    name: []const u8 = "anonymous",
    location: Location = .{},

    pub fn format(self: *const Source, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("[{}:{}:{}]", .{ self.name, self.location.visual.line, self.location.visual.column });
    }

    pub fn dupe(self: *const Source, allocator: std.mem.Allocator) !Source {
        return Source{
            .name = try allocator.dupe(u8, self.name),
            .location = self.location,
        };
    }
};

pub inline fn SourceBiMap(comptime T: type, comptime Ctx: type, comptime style: pl.MapStyle) type {
    comptime return pl.BiMap(Source, T, if (style == .array) SourceContext32 else SourceContext64, Ctx, style);
}

pub inline fn UniqueReprSourceBiMap(comptime T: type, comptime style: pl.MapStyle) type {
    comptime return SourceBiMap(T, if (style == .array) pl.UniqueReprHashContext32(T) else pl.UniqueReprHashContext64(T), style);
}

pub inline fn SourceMap(comptime T: type) type {
    comptime return std.HashMapUnmanaged(Source, T, SourceContext64, 80);
}

pub inline fn SourceArrayMap(comptime T: type) type {
    return std.ArrayHashMapUnmanaged(Source, T, SourceContext64, true);
}

pub const SourceContext32 = struct {
    pub fn hash(_: SourceContext32, source: Source) u32 {
        var hasher = std.hash.Fnv1a_32.init();

        hasher.update(source.name);
        hasher.update(std.mem.asBytes(&source.location));

        return hasher.final();
    }

    pub fn eql(_: SourceContext64, source: Source, other: Source, _: usize) bool {
        return std.mem.eql(u8, source.name, other.name) and source.location == other.location;
    }
};

pub const SourceContext64 = struct {
    pub fn hash(_: SourceContext64, source: Source) u64 {
        var hasher = std.hash.Fnv1a_64.init();

        hasher.update(source.name);
        hasher.update(std.mem.asBytes(&source.location));

        return hasher.final();
    }

    pub fn eql(_: SourceContext64, source: Source, other: Source) bool {
        return std.mem.eql(u8, source.name, other.name) and source.location == other.location;
    }
};

/// A location in the source code, both buffer-wise and line and column.
pub const Location = packed struct {
    buffer: BufferPosition = 0,
    visual: VisualPosition = .{},

    pub fn localize(local_to: *const Location, to_localize: *const Location) Location {
        std.debug.assert(local_to.buffer <= to_localize.buffer);
        return .{
            .buffer = to_localize.buffer - local_to.buffer,
            .visual = VisualPosition{
                .line = to_localize.visual.line -| local_to.visual.line,
                .column = to_localize.visual.column -| local_to.visual.column,
            },
        };
    }

    pub fn format(self: *const Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("[{}:{} ({})]", .{ self.visual.line, self.visual.column, self.buffer });
    }
};

/// An error that can occur while scanning utf-8 codepoints.
pub const EncodingError = error {
    /// The iterator encountered bytes that were not valid utf-8.
    BadEncoding,
};

/// Basic utf8 scanner.
pub const CodepointIterator = struct {
    /// Utf8 encoded bytes to scan.
    bytes: []const u8,
    /// Current position in the byte array.
    i: usize,

    pub const Error = EncodingError;

    pub fn totalLength(it: *CodepointIterator) usize {
        return it.bytes.len;
    }

    pub fn remainingLength(it: *CodepointIterator) usize {
        return it.bytes.len - it.i;
    }

    pub fn from(bytes: []const u8) CodepointIterator {
        return CodepointIterator{
            .bytes = bytes,
            .i = 0,
        };
    }

    pub fn isEof(it: *CodepointIterator) bool {
        return it.i >= it.bytes.len;
    }

    pub fn nextSlice(it: *CodepointIterator) Error!?[]const u8 {
        if (it.i >= it.bytes.len) {
            return null;
        }

        const cp_len = std.unicode.utf8ByteSequenceLength(it.bytes[it.i]) catch return error.BadEncoding;
        it.i += cp_len;
        return it.bytes[it.i - cp_len .. it.i];
    }

    pub fn next(it: *CodepointIterator) Error!?u21 {
        const slice = try it.nextSlice() orelse return null;
        return std.unicode.utf8Decode(slice) catch return error.BadEncoding;
    }
};
