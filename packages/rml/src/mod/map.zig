const std = @import("std");

const Rml = @import("root.zig");
const Error = Rml.Error;
const Ordering = Rml.Ordering;
const OOM = Rml.OOM;
const const_ptr = Rml.const_ptr;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const Object = Rml.Object;
const Writer = Rml.Writer;
const getHeader = Rml.getHeader;
const getOrigin = Rml.getOrigin;
const getTypeId = Rml.getTypeId;
const getObj = Rml.getObj;
const getRml = Rml.getRml;
const forceObj = Rml.forceObj;


pub const Table = TypedMap(Rml.Symbol, Rml.ObjData);

pub const Map = TypedMap(Rml.object.ObjData, Rml.object.ObjData);

pub fn TypedMap (comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        pub const NativeIter = NativeMap.Iterator;
        pub const NativeMap = std.ArrayHashMapUnmanaged(Obj(K), Obj(V), Rml.SimpleHashContext, true);

        allocator: std.mem.Allocator,
        native_map: NativeMap = .{},


        pub fn onCompare(a: *Self, other: Object) Ordering {
            var ord = Rml.compare(getTypeId(a), other.getTypeId());
            if (ord == .Equal) {
                const b = forceObj(Self, other);
                ord = a.compare(b.data.*);
            }
            return ord;
        }

        pub fn compare(self: Self, other: Self) Ordering {
            var ord = Rml.compare(self.keys().len, other.keys().len);

            if (ord == .Equal) {
                ord = Rml.compare(self.keys(), other.keys());
            }

            if (ord == .Equal) {
                ord = Rml.compare(self.values(), other.values());
            }

            return ord;
        }

        pub fn onFormat(self: *const Self, writer: std.io.AnyWriter) anyerror! void {
            return writer.print("{}", .{self});
        }

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) Error! void {
            writer.writeAll("map{") catch |err| return Rml.errorCast(err);

            var it = self.native_map.iterator();
            while (it.next()) |entry| {
                writer.print("({} {})", .{entry.key_ptr.*, entry.value_ptr.*}) catch |err| return Rml.errorCast(err);
                if (it.index < it.len) {
                    writer.writeAll(" ") catch |err| return Rml.errorCast(err);
                }
            }

            writer.writeAll("}") catch |err| return Rml.errorCast(err);
        }




        /// Set the value associated with a key
        pub fn set(self: *Self, key: Obj(K), val: Obj(V)) OOM! void {
            if (self.native_map.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
                entry.value_ptr.* = val;
            } else {
                try self.native_map.put(self.allocator, key, val);
            }
        }

        /// Find the value associated with a key
        pub fn get(self: *const Self, key: Obj(K)) ?Obj(V) {
            return self.native_map.get(key);
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: *const Self) usize {
            return self.native_map.count();
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: *const Self, key: Obj(K)) bool {
            return self.native_map.contains(key);
        }

        // / Returns an iterator over the pairs in this map. Modifying the map may invalidate this iterator.
        // pub fn iter(self: *const Self) NativeIter {
        //     return self.native_map.iterator();
        // }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: *const Self) []Obj(K) {
            return self.native_map.keys();
        }

        /// Returns the backing array of values in this map.
        /// Modifying the map may invalidate this array.
        /// It is permitted to modify the values in this array.
        pub fn values(self: *const Self) []Obj(V) {
            return self.native_map.values();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: *Self, rml: *Rml) OOM! void {
            return self.native_map.reIndex(rml.blobAllocator());
        }

        /// Convert a map to an array of key-value pairs.
        pub fn toArray(self: *Self) OOM! Obj(Rml.Array) {
            const rml = getRml(self);
            var it = self.native_map.iterator();

            var out: Obj(Rml.Array) = try .wrap(rml, getOrigin(self), .{.allocator = rml.blobAllocator()});

            while (it.next()) |entry| {
                var pair: Obj(Rml.Array) = try .wrap(rml, getOrigin(self), try .create(rml.blobAllocator(), &.{
                    entry.key_ptr.typeErase(),
                    entry.value_ptr.typeErase(),
                }));

                try out.data.append(pair.typeErase());
            }

            return out;
        }

        pub fn clone(self: *Self) OOM! Self {
            const newMap = Self { .allocator = self.allocator, .native_map = try self.native_map.clone(self.allocator) };
            return newMap;
        }

        pub fn copyFrom(self: *Self, other: *Self) OOM! void {
            var it = other.native_map.iterator();
            while (it.next()) |entry| {
                try self.set(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    };
}
