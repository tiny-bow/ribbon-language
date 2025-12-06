/// A constant data blob, stored in the ir context. Data such as string literals are stored as blobs.
const Blob = @This();

const std = @import("std");
const core = @import("core");

const ir = @import("../ir.zig");

id: Blob.Id,
layout: core.Layout,
cached_cbr: ?ir.Cbr = null,

/// Identifier for a data blob within the ir context.
pub const Id = enum(u32) { _ };

pub fn deinit(self: *const Blob, allocator: std.mem.Allocator) void {
    const base: [*]const u8 = @ptrCast(self);
    allocator.free(base[0 .. @sizeOf(Blob) + self.layout.size]);
}

pub fn clone(self: *const Blob, allocator: std.mem.Allocator) error{OutOfMemory}!*const Blob {
    const new_buf = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Blob)), @sizeOf(Blob) + self.layout.size);
    const new_blob: *Blob = @ptrCast(new_buf.ptr);
    new_blob.* = self.*;
    @memcpy(new_buf.ptr + @sizeOf(Blob), self.getBytes());
    return new_blob;
}

pub fn deserialize(reader: *std.io.Reader, id: Blob.Id, allocator: std.mem.Allocator) error{ EndOfStream, ReadFailed, OutOfMemory }!*const Blob {
    const alignment = try reader.takeInt(u32, .little);
    const size = try reader.takeInt(u32, .little);

    const new_buf = try allocator.alignedAlloc(u8, .fromByteUnits(@alignOf(Blob)), @sizeOf(Blob) + size);
    const blob: *Blob = @ptrCast(new_buf.ptr);
    blob.* = .{
        .id = id, // id will be assigned when interned
        .layout = core.Layout{ .alignment = @intCast(alignment), .size = @intCast(size) },
    };

    const bytes = (new_buf.ptr + @sizeOf(Blob))[0..size];

    var writer = std.io.Writer.fixed(bytes);

    reader.streamExact(&writer, size) catch return error.ReadFailed;

    return blob;
}

pub fn serialize(self: *const Blob, writer: *std.io.Writer) error{WriteFailed}!void {
    try writer.writeInt(u32, @intCast(self.layout.alignment), .little);
    try writer.writeInt(u32, @intCast(self.layout.size), .little);
    try writer.writeAll(self.getBytes());
}

/// Get the (unaligned) byte value for this blob.
pub inline fn getBytes(self: *const Blob) []const u8 {
    return (@as([*]const u8, @ptrCast(self)) + @sizeOf(Blob))[0..self.layout.size];
}

/// Get the CBR for this blob.
pub fn getCbr(self: *const Blob) error{OutOfMemory}!ir.Cbr {
    if (self.cached_cbr) |cached| {
        return cached;
    }

    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Blob");

    hasher.update("id:");
    hasher.update(self.id);

    hasher.update("layout:");
    hasher.update(self.layout);

    hasher.update("bytes:");
    hasher.update(self.getBytes());

    const buf = hasher.final();
    @constCast(self).cached_cbr = buf;
    return buf;
}

/// An adapted hash context for blobs, used when interning yet-unmarshalled data.
pub const AdaptedHashContext = struct {
    pub fn hash(_: @This(), descriptor: struct { core.Alignment, []const u8 }) u64 {
        const layout = core.Layout{ .alignment = descriptor[0], .size = @intCast(descriptor[1].len) };
        var hasher = ir.QuickHasher.init();
        hasher.update(layout);
        hasher.update(descriptor[1]);
        return hasher.final();
    }

    pub fn eql(_: @This(), a: *const Blob, b: struct { core.Alignment, []const u8 }) bool {
        const layout = core.Layout{ .alignment = b[0], .size = @intCast(b[1].len) };
        if (a.layout != layout) return false;
        return std.mem.eql(u8, a.getBytes(), b[1]);
    }
};

/// The standard hash context for blobs, used in the interned data set.
pub const HashContext = struct {
    pub fn hash(_: @This(), blob: *const Blob) u64 {
        var hasher = ir.QuickHasher.init();
        hasher.update(blob.layout);
        hasher.update(blob.getBytes());
        return hasher.final();
    }

    pub fn eql(_: @This(), a: *const Blob, b: *const Blob) bool {
        if (a.layout != b.layout) return false;
        return std.mem.eql(u8, a.getBytes(), b.getBytes());
    }
};
