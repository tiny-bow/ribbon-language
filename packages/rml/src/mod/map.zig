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


pub const Table = Rml.map.TypedMap(Rml.Symbol, Rml.ObjData);
pub const TableUnmanaged = Rml.map.TypedMapUnmanaged(Rml.Symbol, Rml.ObjData);

pub const Map = TypedMap(Rml.object.ObjData, Rml.object.ObjData);
pub const MapUnmanaged = TypedMapUnmanaged(Rml.object.ObjData, Rml.object.ObjData);

pub fn TypedMap (comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        pub const NativeIter = NativeMap.Iterator;
        pub const NativeMap = std.ArrayHashMapUnmanaged(Obj(K), Obj(V), Rml.SimpleHashContext, true);


        unmanaged: TypedMapUnmanaged(K, V) = .{},


        pub fn onCompare(a: ptr(Self), other: Object) Ordering {
            var ord = Rml.compare(getTypeId(a), other.getTypeId());
            if (ord == .Equal) {
                const b = forceObj(Self, other);
                ord = a.unmanaged.compare(b.data.unmanaged);
            }
            return ord;
        }

        pub fn onFormat(self: const_ptr(Self), writer: Rml.Obj(Writer)) Error! void {
            return writer.data.print("{}", .{self.unmanaged});
        }

        /// Set the value associated with a key
        pub fn set(self: ptr(Self), key: Obj(K), v: Obj(V)) OOM! void {
            const rml = getRml(self);
            return self.unmanaged.set(rml, key, v);
        }

        /// Find the value associated with a key
        pub fn get(self: ptr(Self), key: Obj(K)) ?Obj(V) {
            return self.unmanaged.get(key);
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: ptr(Self)) usize {
            return self.unmanaged.length();
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: ptr(Self), key: Obj(K)) bool {
            return self.unmanaged.contains(key);
        }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: ptr(Self)) []Obj(K) {
            return self.unmanaged.keys();
        }

        /// Returns the backing array of values in this map.
        /// Modifying the map may invalidate this array.
        /// It is permitted to modify the values in this array.
        pub fn values(self: ptr(Self)) []Obj(V) {
            return self.unmanaged.values();
        }

        /// Convert a map to an array of key-value pairs.
        pub fn toArray(self: ptr(Self)) OOM! Obj(Rml.Array) {
            const rml = getRml(self);
            const pairs = try self.unmanaged.toArray(rml);
            return Obj(Rml.Array).wrap(rml, getOrigin(self), .{ .unmanaged = pairs });
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: ptr(Self)) OOM! void {
            return self.unmanaged.reIndex(getRml(self));
        }

        pub fn copyFrom(self: ptr(Self), other: Obj(Self)) OOM! void {
            const rml = getRml(self);
            return self.unmanaged.copyFrom(rml, &other.data.unmanaged);
        }
    };
}

pub fn TypedMapUnmanaged (comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        native_map: NativeMap = .{},

        pub const NativeIter = NativeMap.Iterator;
        pub const NativeMap = std.ArrayHashMapUnmanaged(Obj(K), Obj(V), Rml.SimpleHashContext, true);

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

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) Error! void {
            writer.writeAll("MAP{") catch |err| return Rml.errorCast(err);

            var it = self.iter();
            while (it.next()) |entry| {
                writer.print("({} {})", .{entry.key_ptr.*, entry.value_ptr.*}) catch |err| return Rml.errorCast(err);
                if (it.index < it.len) {
                    writer.writeAll(" ") catch |err| return Rml.errorCast(err);
                }
            }

            writer.writeAll("}") catch |err| return Rml.errorCast(err);
        }

        /// Set the value associated with a key
        pub fn set(self: *Self, rml: *Rml, key: Obj(K), val: Obj(V)) OOM! void {
            if (self.native_map.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
                entry.value_ptr.* = val;
            } else {
                try self.native_map.put(rml.blobAllocator(), key, val);
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

        /// Returns an iterator over the pairs in this map. Modifying the map may invalidate this iterator.
        pub fn iter(self: *const Self) NativeIter {
            return self.native_map.iterator();
        }

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
        pub fn toArray(self: *Self, rml: *Rml) OOM! Rml.array.ArrayUnmanaged {
            var it = self.iter();

            var out: Rml.array.ArrayUnmanaged = .{};

            while (it.next()) |entry| {
                var pair: Rml.array.ArrayUnmanaged = .{};

                try pair.append(rml, entry.key_ptr.typeErase());
                try pair.append(rml, entry.value_ptr.typeErase());

                try out.append(rml, (try Obj(Rml.Array).wrap(rml, entry.key_ptr.getOrigin(), .{ .unmanaged = pair })).typeErase());
            }

            return out;
        }

        pub fn clone(self: *Self, rml: *Rml) OOM! Self {
            const newMap = Self { .native_map = try self.native_map.clone(rml.blobAllocator()) };
            return newMap;
        }

        pub fn copyFrom(self: *Self, rml: *Rml, other: *Self) OOM! void {
            var it = other.iter();
            while (it.next()) |entry| {
                try self.set(rml, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    };
}
