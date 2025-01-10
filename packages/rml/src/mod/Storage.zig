const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rml = @import("root.zig");

const Storage = @This();



long_term: std.mem.Allocator,
map: Map,
permanent: std.heap.ArenaAllocator,
blob: ?Blob = null,
_fresh: usize = 0,
/// callback may use rml.storage.blob for return allocator, or user must handle memory management
read_file_callback: ?*const fn (rml: *Rml, []const u8) (Rml.IOError || Rml.OOM)![]const u8 = null,
userstate: *anyopaque = undefined,
origin: Rml.Origin = undefined,




pub const ARENA_RETAIN_AMOUNT = 1024 * 1024 * 16;
const Map = std.ArrayHashMapUnmanaged([]const u8, void, MiscUtils.SimpleHashContext, true);

pub const Blob = struct {
    arena: std.heap.ArenaAllocator,
    id: BlobId,

    pub fn deinit(self: Blob) void {
        self.arena.deinit();
    }
};

pub const BlobId = enum(usize) {
    pre_blob = 0,
    _,
};


pub fn init(long_term: std.mem.Allocator) Rml.OOM! Storage {
    return .{
        .long_term = long_term,
        .map = .{},
        .permanent = std.heap.ArenaAllocator.init(long_term),
    };
}

pub fn blobId(self: *Storage) BlobId {
    return if (self.blob) |*b| b.id
    else .pre_blob;
}

pub fn blobAllocator(self: *Storage) std.mem.Allocator {
    return if (self.blob) |*b| b.arena.allocator()
    else self.permanent.allocator();
}

pub fn beginBlob(self: *Storage) void {
    std.debug.assert(self.blob == null);

    self.blob = .{
        .arena = std.heap.ArenaAllocator.init(self.long_term),
        .id = self.fresh(BlobId),
    };
}

pub fn endBlob(self: *Storage) Blob {
    if (self.blob) |b| {
        self.blob = null;
        return b;
    } else unreachable;
}

pub fn deinit(self: *Storage) void {
    self.map.deinit(self.long_term);
    if (self.blob) |*b| b.deinit();
    self.permanent.deinit();
}

pub fn fresh(self: *Storage, comptime T: type) T {
    const i = self._fresh;
    self._fresh += 1;
    return @enumFromInt(i);
}

pub fn internerLength(self: *const Storage) usize {
    return self.map.count();
}

pub fn contents(self: *const Storage) []Rml.str {
    return self.map.keys();
}

pub fn contains(self: *const Storage, key: []const u8) bool {
    return self.map.contains(key);
}

pub fn getNoAlloc(self: *const Storage, key: []const u8) ?Rml.str {
    if (self.map.getEntry(key)) |existing| {
        return existing.key_ptr.*;
    }
    return null;
}

pub fn intern(self: *Storage, key: []const u8) Rml.OOM! Rml.str {
    return self.getNoAlloc(key) orelse {
        const ownedKey = try self.permanent.allocator().dupe(u8, key);
        try self.map.put(self.long_term, ownedKey, {});

        return ownedKey;
    };
}
