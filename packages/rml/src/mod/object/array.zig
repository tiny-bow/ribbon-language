const std = @import("std");

const Rml = @import("../root.zig");



pub const Array = TypedArray(Rml.object.ObjData);

pub fn TypedArray (comptime T: type) type {
    const NativeArray = std.ArrayListUnmanaged(Rml.Obj(T));

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        native_array: NativeArray = .{},

        pub fn create(allocator: std.mem.Allocator, values: []const Rml.Obj(T)) Rml.OOM! Self {
            var self = Self{.allocator = allocator};
            try self.native_array.appendSlice(allocator, values);
            return self;
        }

        pub fn onCompare(self: *Self, other: Rml.Object) Rml.Ordering {
            var ord = Rml.compare(Rml.getTypeId(self), other.getTypeId());
            if (ord == .Equal) {
                const otherObj = Rml.forceObj(Self, other);
                ord = self.compare(otherObj.data.*);
            }
            return ord;
        }

        pub fn compare(self: Self, other: Self) Rml.Ordering {
            return Rml.compare(self.native_array.items, other.native_array.items);
        }

        pub fn onFormat(self: *Self, writer: std.io.AnyWriter) anyerror! void {
            try writer.print("{}", .{self});
        }

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) anyerror! void {
            writer.print("array[{}]{{", .{self.native_array.items.len}) catch |err| return Rml.errorCast(err);
            for (self.native_array.items, 0..) |obj, i| {
                try obj.onFormat(writer);
                if (i < self.native_array.items.len - 1) writer.writeAll(" ") catch |err| return Rml.errorCast(err);
            }
            writer.writeAll("}") catch |err| return Rml.errorCast(err);
        }

        pub fn clone(self: *const Self) Rml.OOM! Self {
            const arr = try self.native_array.clone(self.allocator);
            return Self{.allocator = self.allocator, .native_array = arr};
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
        pub fn items(self: *const Self) []Rml.Obj(T) {
            return self.native_array.items;
        }

        /// Get the last element of the array.
        pub fn last(self: *const Self) ?Rml.Obj(T) {
            return if (self.native_array.items.len > 0) self.native_array.items[self.native_array.items.len - 1]
            else null;
        }

        /// Get an element of the array.
        pub fn get(self: *const Self, index: usize) ?Rml.Obj(T) {
            return if (index < self.native_array.items.len) self.native_array.items[index]
            else null;
        }

        /// Insert item at index 0.
        /// Moves list[0 .. list.len] to higher indices to make room.
        /// This operation is O(N).
        /// Invalidates element pointers.
        pub fn prepend(self: *Self, val: Rml.Obj(T)) Rml.OOM! void {
            try self.native_array.insert(self.allocator, 0, val);
        }

        /// Insert item at index i.
        /// Moves list[i .. list.len] to higher indices to make room.
        /// This operation is O(N).
        /// Invalidates element pointers.
        pub fn insert(self: *Self, index: usize, val: Rml.Obj(T)) Rml.OOM! void {
            try self.native_array.insert(self.allocator, index, val);
        }

        /// Extend the array by 1 element.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn append(self: *Self, val: Rml.Obj(T)) Rml.OOM! void {
            try self.native_array.append(self.allocator, val);
        }

        /// Append the slice of items to the array. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSlice(self: *Self, slice: []const Rml.Obj(T)) Rml.OOM! void {
            try self.native_array.appendSlice(self.allocator, slice);
        }
    };
}
