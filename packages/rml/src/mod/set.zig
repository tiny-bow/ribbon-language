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


pub const Set = TypedSet(Rml.object.ObjData);
pub const SetUnmanaged = TypedSetUnmanaged(Rml.object.ObjData);

pub fn TypedSet (comptime K: type) type {
    return struct {
        const Self = @This();

        unmanaged: TypedSetUnmanaged (K) = .{},


        pub fn onCompare(a: ptr(Self), other: Object) Ordering {
            var ord = Rml.compare(getTypeId(a), other.getTypeId());
            if (ord == .Equal) {
                const b = forceObj(Self, other);

                ord = a.unmanaged.compare(b.data.unmanaged);
            }
            return ord;
        }

        pub fn onFormat(self: const_ptr(Self), writer: std.io.AnyWriter) anyerror! void {
            return writer.print("{}", .{self.unmanaged});
        }

        /// Set a key
        pub fn set(self: ptr(Self), key: Obj(K)) OOM! void {
            return self.unmanaged.set(getRml(self), key);
        }

        /// Find a local copy matching a key
        pub fn get(self: ptr(Self), key: Obj(K)) ?Obj(K) {
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
        pub fn keys(self: ptr(Self)) []Object {
            return self.unmanaged.keys();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: ptr(Self)) OOM! void {
            return self.unmanaged.reIndex(getRml(self));
        }

        /// Clones and returns the backing array of values in this map.
        pub fn toArray(self: ptr(Self)) OOM! Obj(Rml.Array) {
            const rml = getRml(self);

            const array = try self.unmanaged.toArray(rml);

            return Obj(Rml.Array).wrap(rml, getOrigin(self), .{ .unmanaged = array });
        }
    };
}

pub fn TypedSetUnmanaged  (comptime K: type) type {
    return struct {
        const Self = @This();

        native_map: NativeSet = .{},

        pub const NativeIter = NativeSet.Iterator;
        pub const NativeSet = std.ArrayHashMapUnmanaged(Obj(K), void, Rml.SimpleHashContext, true);

        pub fn compare(self: Self, other: Self) Ordering {
            var ord = Rml.compare(self.keys().len, other.keys().len);

            if (ord == .Equal) {
                ord = Rml.compare(self.keys(), other.keys());
            }

            return ord;
        }

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) Error! void {
            const ks = self.keys();
            writer.writeAll("SET{") catch |err| return Rml.errorCast(err);
            for (ks, 0..) |key, i| {
                writer.print("{}", .{key}) catch |err| return Rml.errorCast(err);
                if (i < ks.len - 1) {
                    writer.writeAll(" ") catch |err| return Rml.errorCast(err);
                }
            }
            writer.writeAll("}") catch |err| return Rml.errorCast(err);
        }


        /// Set a key
        pub fn set(self: *Self, rml: *Rml, key: Obj(K)) OOM! void {
            if (self.native_map.getEntry(key)) |entry| {
                entry.key_ptr.* = key;
            } else {
                try self.native_map.put(rml.blobAllocator(), key, {});
            }
        }

        /// Find a local copy matching a given key
        pub fn get(self: *const Self, key: Obj(K)) ?Obj(K) {
            return if (self.native_map.getEntry(key)) |entry| entry.key_ptr.* else null;
        }

        /// Returns the number of key-value pairs in the map
        pub fn length(self: *const Self) usize {
            return self.native_map.count();
        }

        /// Check whether a key is stored in the map
        pub fn contains(self: *const Self, key: Obj(K)) bool {
            return self.native_map.contains(key);
        }

        /// Returns the backing array of keys in this map. Modifying the map may invalidate this array.
        /// Modifying this array in a way that changes key hashes or key equality puts the map into an unusable state until reIndex is called.
        pub fn keys(self: *const Self) []Obj(K) {
            return self.native_map.keys();
        }

        /// Recomputes stored hashes and rebuilds the key indexes.
        /// If the underlying keys have been modified directly,
        /// call this method to recompute the denormalized metadata
        /// necessary for the operation of the methods of this map that lookup entries by key.
        pub fn reIndex(self: *Self, rml: *Rml) OOM! void {
            return self.native_map.reIndex(rml.blobAllocator());
        }

        /// Clones and returns the backing array of values in this map.
        pub fn toArray(self: *Self, rml: *Rml) OOM! Rml.array.ArrayUnmanaged {
            var array = Rml.array.ArrayUnmanaged {};

            for (self.keys()) |key| {
                try array.append(rml, key.typeErase());
            }

            return array;
        }

        pub fn clone(self: *Self, rml: *Rml) OOM! Self {
            return Self { .native_map = try self.native_map.clone(rml.blobAllocator()) };
        }

        pub fn copyFrom(self: *Self, rml: *Rml, other: *const Self) OOM! void {
            for (other.keys()) |key| {
                try self.set(rml, key);
            }
        }
    };
}
