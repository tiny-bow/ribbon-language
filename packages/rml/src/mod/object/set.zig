const std = @import("std");

const Rml = @import("../root.zig");


pub const Set = TypedSet(Rml.object.ObjData);

pub fn TypedSet (comptime K: type) type {
    return struct {
        const Self = @This();

        pub const NativeIter = NativeSet.Iterator;
        pub const NativeSet = std.ArrayHashMapUnmanaged(Rml.Obj(K), void, Rml.SimpleHashContext, true);


        allocator: std.mem.Allocator,
        native_set: NativeSet = .{},


        pub fn create(rml: *Rml, initialKeys: []const Rml.Obj(K)) Rml.OOM! Self {
            var self = Self { .allocator = rml.blobAllocator() };
            for (initialKeys) |k| try self.native_set.put(rml.blobAllocator(), k, {});
            return self;
        }


        pub fn onCompare(a: *Self, other: Rml.Object) Rml.Ordering {
            var ord = Rml.compare(Rml.getTypeId(a), other.getTypeId());
            if (ord == .Equal) {
                const b = Rml.forceObj(Self, other);

                ord = a.compare(b.data.*);
            }
            return ord;
        }

        pub fn compare(self: Self, other: Self) Rml.Ordering {
            var ord = Rml.compare(self.keys().len, other.keys().len);

            if (ord == .Equal) {
                ord = Rml.compare(self.keys(), other.keys());
            }

            return ord;
        }

        pub fn onFormat(self: *const Self, writer: std.io.AnyWriter) anyerror! void {
            return writer.print("{}", .{self.native_set});
        }

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
            const ks = self.keys();
            try writer.writeAll("SET{");
            for (ks, 0..) |key, i| {
                try writer.print("{}", .{key});
                if (i < ks.len - 1) {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll("}");
        }


        /// Set a key
        pub fn set(self: *Self, key: Rml.Obj(K)) Rml.OOM! void {
            if (self.native_set.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
            } else {
                try self.native_set.put(self.allocator, key, {});
            }
        }

        /// Find a local copy matching a given key
        pub fn get(self: *const Self, key: Rml.Obj(K)) ?Rml.Obj(K) {
            return if (self.native_set.getEntry(key)) |entry| entry.key_ptr.* else null;
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: *const Self) usize {
            return self.native_set.count();
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: *const Self, key: Rml.Obj(K)) bool {
            return self.native_set.contains(key);
        }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: *const Self) []Rml.Obj(K) {
            return self.native_set.keys();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: *Self) Rml.OOM! void {
            return self.native_set.reIndex(self.allocator);
        }

        /// Clones and returns the backing array of values in this map.
        pub fn toArray(self: *Self) Rml.OOM! Rml.Obj(Rml.Array) {
            var array = try Rml.Obj(Rml.Array).wrap(Rml.getRml(self), Rml.getOrigin(self), .{.allocator = self.allocator});

            for (self.keys()) |key| {
                try array.data.append(key.typeErase());
            }

            return array;
        }

        pub fn clone(self: *Self) Rml.OOM! Self {
            return Self { .allocator = self.allocator, .native_set = try self.native_set.clone(self.allocator) };
        }

        pub fn copyFrom(self: *Self, other: *const Self) Rml.OOM! void {
            for (other.keys()) |key| {
                try self.set(key);
            }
        }
    };
}
