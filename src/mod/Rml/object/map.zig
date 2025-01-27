const Rml = @import("../../Rml.zig");

const std = @import("std");
const utils = @import("utils");



pub const Table = TypedMap(Rml.Symbol, Rml.ObjData);

pub const Map = TypedMap(Rml.object.ObjData, Rml.object.ObjData);

pub fn TypedMap (comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        native_map: NativeMap = .{},

        pub const NativeIter = NativeMap.Iterator;
        pub const NativeMap = std.ArrayHashMapUnmanaged(Rml.Obj(K), Rml.Obj(V), utils.SimpleHashContext, true);

        pub fn compare(self: Self, other: Self) utils.Ordering {
            var ord = utils.compare(self.keys().len, other.keys().len);

            if (ord == .Equal) {
                ord = utils.compare(self.keys(), other.keys());
            }

            if (ord == .Equal) {
                ord = utils.compare(self.values(), other.values());
            }

            return ord;
        }

        pub fn format(self: *const Self, comptime fmtStr: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
            const fmt = Rml.Format.fromStr(fmtStr) orelse .debug;
            const w = if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any();

            try w.writeAll("map{ ");

            var it = self.native_map.iterator();
            while (it.next()) |entry| {
                try w.writeAll("(");
                try entry.key_ptr.onFormat(fmt, w);
                try w.writeAll(" = ");
                try entry.value_ptr.onFormat(fmt, w);
                try w.writeAll(") ");
            }

            try w.writeAll("}");
        }


        /// Set the value associated with a key
        pub fn set(self: *Self, key: Rml.Obj(K), val: Rml.Obj(V)) Rml.OOM! void {
            if (self.native_map.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
                entry.value_ptr.* = val;
            } else {
                try self.native_map.put(self.allocator, key, val);
            }
        }

        /// Find the value associated with a key
        pub fn get(self: *const Self, key: Rml.Obj(K)) ?Rml.Obj(V) {
            return self.native_map.get(key);
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: *const Self) Rml.Int {
            return @intCast(self.native_map.count());
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: *const Self, key: Rml.Obj(K)) bool {
            return self.native_map.contains(key);
        }

        // / Returns an iterator over the pairs in this map. Modifying the map may invalidate this iterator.
        // pub fn iter(self: *const Self) NativeIter {
        //     return self.native_map.iterator();
        // }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: *const Self) []Rml.Obj(K) {
            return self.native_map.keys();
        }

        /// Returns the backing array of values in this map.
        /// Modifying the map may invalidate this array.
        /// It is permitted to modify the values in this array.
        pub fn values(self: *const Self) []Rml.Obj(V) {
            return self.native_map.values();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: *Self, rml: *Rml) Rml.OOM! void {
            return self.native_map.reIndex(rml.blobAllocator());
        }

        /// Convert a map to an array of key-value pairs.
        pub fn toArray(self: *Self) Rml.OOM! Rml.Obj(Rml.Array) {
            const rml = Rml.getRml(self);
            var it = self.native_map.iterator();

            var out: Rml.Obj(Rml.Array) = try .wrap(rml, Rml.getOrigin(self), .{.allocator = rml.blobAllocator()});

            while (it.next()) |entry| {
                var pair: Rml.Obj(Rml.Array) = try .wrap(rml, Rml.getOrigin(self), try .create(rml.blobAllocator(), &.{
                    entry.key_ptr.typeErase(),
                    entry.value_ptr.typeErase(),
                }));

                try out.data.append(pair.typeErase());
            }

            return out;
        }

        pub fn clone(self: *Self) Rml.OOM! Self {
            const newMap = Self { .allocator = self.allocator, .native_map = try self.native_map.clone(self.allocator) };
            return newMap;
        }

        pub fn copyFrom(self: *Self, other: *Self) Rml.OOM! void {
            var it = other.native_map.iterator();
            while (it.next()) |entry| {
                try self.set(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    };
}
