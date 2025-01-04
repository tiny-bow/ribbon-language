const std = @import("std");

const Rml = @import("root.zig");
const Ordering = Rml.Ordering;
const Error = Rml.Error;
const OOM = Rml.OOM;
const ptr = Rml.ptr;
const Obj = Rml.Obj;
const Object = Rml.Object;
const Writer = Rml.Writer;
const getObj = Rml.getObj;
const getTypeId = Rml.getTypeId;
const getRml = Rml.getRml;
const forceObj = Rml.forceObj;

pub const Array = TypedArray(Rml.object.ObjData);
pub const ArrayUnmanaged = TypedArrayUnmanaged(Rml.object.ObjData);

pub fn TypedArray (comptime T: type) type {
    const Unmanaged = TypedArrayUnmanaged(T);

    return struct {
        const Self = @This();

        unmanaged: Unmanaged = .{},

        pub fn onCompare(self: ptr(Self), other: Object) Ordering {
            var ord = Rml.compare(getTypeId(self), other.getTypeId());
            if (ord == .Equal) {
                const otherObj = forceObj(Self, other);
                ord = Rml.compare(self.unmanaged, otherObj.data.unmanaged);
            }
            return ord;
        }

        pub fn onFormat(self: ptr(Self), writer: Obj(Writer)) Error! void {
            try writer.data.print("{}", .{self.unmanaged});
        }

        /// Length of the array.
        /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
        /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
        pub fn length(self: *const Self) usize {
            return self.unmanaged.length();
        }

        /// Contents of the array.
        pub fn items(self: *const Self) []Obj(T) {
            return self.unmanaged.items();
        }

        /// Get an element of the array.
        pub fn get(self: *const Self, index: usize) ?Obj(T) {
            return self.unmanaged.get(index);
        }

        /// Extend the array by 1 element.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn append(self: ptr(Self), val: Obj(T)) OOM! void {
            try self.unmanaged.append(getRml(self), val);
        }

        /// Append the slice of items to the array. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSlice(self: ptr(Self), slice: []const Obj(T)) OOM! void {
            try self.unmanaged.appendSlice(getRml(self), slice);
        }
    };
}

pub fn TypedArrayUnmanaged (comptime T: type) type {
    return struct {
        const Self = @This();

        native_array: NativeArray = .{},

        const NativeArray = std.ArrayListUnmanaged(Obj(T));

        pub fn compare(self: Self, other: Self) Ordering {
            return Rml.compare(self.native_array.items, other.native_array.items);
        }

        pub fn format(self: *const Self, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) Error! void {
            writer.print("ARRAY[{}]{{", .{self.native_array.items.len}) catch |err| return Rml.errorCast(err);
            for (self.native_array.items, 0..) |obj, i| {
                try obj.format(fmt, opts, writer);
                if (i < self.native_array.items.len - 1) writer.writeAll(" ") catch |err| return Rml.errorCast(err);
            }
            writer.writeAll("}") catch |err| return Rml.errorCast(err);
        }

        pub fn clone(self: *const Self, rml: *Rml) OOM! Self {
            const arr = try self.native_array.clone(rml.blobAllocator());
            return Self{.native_array = arr};
        }

        pub fn clear(self: *Self) void {
            self.native_array.clearRetainingCapacity();
        }

        /// Length of the array.
        pub fn length(self: *const Self) usize {
            return self.native_array.items.len;
        }

        /// Contents of the array.
        /// Pointers to elements in this slice are invalidated by various functions of this ArrayList in accordance with the respective documentation.
        /// In all cases, "invalidated" means that the memory has been passed to an allocator's resize or free function.
        pub fn items(self: *const Self) []Obj(T) {
            return self.native_array.items;
        }

        /// Get the last element of the array.
        pub fn last(self: *const Self) ?Obj(T) {
            return if (self.native_array.items.len > 0) self.native_array.items[self.native_array.items.len - 1]
            else null;
        }

        /// Get an element of the array.
        pub fn get(self: *const Self, index: usize) ?Obj(T) {
            return if (index < self.native_array.items.len) self.native_array.items[index]
            else null;
        }

        /// Insert item at index 0.
        /// Moves list[0 .. list.len] to higher indices to make room.
        /// This operation is O(N).
        /// Invalidates element pointers.
        pub fn prepend(self: *Self, rml: *Rml, val: Obj(T)) OOM! void {
            try self.native_array.insert(rml.blobAllocator(), 0, val);
        }

        /// Insert item at index i.
        /// Moves list[i .. list.len] to higher indices to make room.
        /// This operation is O(N).
        /// Invalidates element pointers.
        pub fn insert(self: *Self, rml: *Rml, index: usize, val: Obj(T)) OOM! void {
            try self.native_array.insert(rml.blobAllocator(), index, val);
        }

        /// Extend the array by 1 element.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn append(self: *Self, rml: *Rml, val: Obj(T)) OOM! void {
            try self.native_array.append(rml.blobAllocator(), val);
        }

        /// Append the slice of items to the array. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSlice(self: *Self, rml: *Rml, slice: []const Obj(T)) OOM! void {
            try self.native_array.appendSlice(rml.blobAllocator(), slice);
        }
    };
}
