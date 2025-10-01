//! Tracks the name of a source file, and the offset into it, at which an item was defined.

const Source = @This();

const std = @import("std");
const log = std.log.scoped(.source_analysis);

const common = @import("common");

test {
    // std.debug.print("semantic analysis for source\n", .{});
    std.testing.refAllDecls(@This());
}

/// A position in the source code, in terms of the buffer.
pub const BufferPosition = u64;

/// A position in the source code, in terms of the line and column.
pub const VisualPosition = packed struct {
    /// 1-based line number.
    line: u32,
    /// 1-based column number.
    column: u32,

    pub const zero = VisualPosition{ .line = 0, .column = 0 };
    pub const start = VisualPosition{ .line = 1, .column = 1 };
};

/// A location in a specific (unnamed) source file, both buffer-wise and line and column.
pub const Location = packed struct(u128) {
    buffer: BufferPosition,
    visual: VisualPosition,

    pub const none = Location{ .buffer = 0, .visual = .zero };

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

    pub fn format(self: *const Location, writer: *std.io.Writer) !void {
        try writer.print("[{d}:{d} ({d})]", .{ self.visual.line, self.visual.column, self.buffer });
    }
};

/// The name or path of the source file
name: []const u8,
/// The location within the source file
location: Location,

pub const anonymous = Source{
    .name = "anonymous",
    .location = .none,
};

/// `std.fmt` impl
pub fn format(self: *const Source, writer: *std.io.Writer) !void {
    try writer.print("[{s}:{d}:{d}]", .{ self.name, self.location.visual.line, self.location.visual.column });
}

/// Duplicate this source, allocating memory for the name using the provided allocator.
pub fn dupe(self: *const Source, allocator: std.mem.Allocator) !Source {
    return Source{
        .name = try allocator.dupe(u8, self.name),
        .location = self.location,
    };
}

/// Determine if two Sources are equal.
pub fn eql(self: *const Source, other: *const Source) bool {
    return std.mem.eql(u8, self.name, other.name) and self.location == other.location;
}

/// Hash this source into the provided hasher.
pub fn hash(self: *const Source, hasher: anytype) void {
    hasher.update(self.name);
    hasher.update(std.mem.asBytes(&self.location));
}

/// A bi-directional map from Source to some other type T, using a context Ctx for equality and hashing.
pub inline fn SourceBiMap(comptime T: type, comptime Ctx: type, comptime style: common.MapStyle) type {
    comptime return common.BiMap(Source, T, if (style == .array) SourceContext32 else SourceContext64, Ctx, style);
}

/// A bi-directional map from Source to some other type T, using a `UniqueReprHashContext` for equality and hashing.
pub inline fn UniqueReprSourceBiMap(comptime T: type, comptime style: common.MapStyle) type {
    comptime return SourceBiMap(T, if (style == .array) common.UniqueReprHashContext32(T) else common.UniqueReprHashContext64(T), style);
}

/// A map from Source to some other type T, using a `SourceContext`.
pub inline fn SourceMap(comptime T: type) type {
    comptime return common.HashMap(Source, T, SourceContext64);
}

/// A map from Source to some other type T, using a `SourceContext`.
pub inline fn SourceArrayMap(comptime T: type) type {
    comptime return common.ArrayMap(Source, T, SourceContext64);
}

/// 32-bit hashmap context for `Source`s.
pub const SourceContext32 = struct {
    pub fn hash(_: SourceContext32, src: Source) u32 {
        var hasher = std.hash.Fnv1a_32.init();

        src.hash(&hasher);

        return hasher.final();
    }

    pub fn eql(_: SourceContext64, src: Source, other: Source, _: usize) bool {
        return std.mem.eql(u8, src.name, other.name) and src.location == other.location;
    }
};

/// 64-bit hashmap context for `Source`s.
pub const SourceContext64 = struct {
    pub fn hash(_: SourceContext64, src: Source) u64 {
        var hasher = std.hash.Fnv1a_64.init();

        src.hash(&hasher);

        return hasher.final();
    }

    pub fn eql(_: SourceContext64, src: Source, other: Source) bool {
        return std.mem.eql(u8, src.name, other.name) and src.location == other.location;
    }
};
