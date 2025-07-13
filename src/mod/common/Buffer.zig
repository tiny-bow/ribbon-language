//! Basically, its a slice, but with a known (packed) layout.
const pl = @import("platform");
const std = @import("std");

/// Immutable buffer of bytes.
pub const Bytes = of(u8, .constant);

/// Mutable buffer of bytes.
pub const MutBytes = of(u8, .mutable);

/// Immutable short buffer of bytes.
pub const ShortBytes = of(u8, .constant);

/// Mutable short buffer of bytes.
pub const MutShortBytes = of(u8, .mutable);

/// Creates a new `Buffer` type with the given element type and mutability.
pub fn of(comptime T: type, comptime MUT: pl.Mutability) type {
    return packed struct(u128) {
        const Self = @This();

        /// pointer to the first element in the buffer.
        ptr: u64,
        /// number of elements in the buffer.
        len: u64,

        /// The pointer sibling type of this buffer.
        pub const PointerType = MUT.MultiPointerType(T);
        /// The slice sibling type of this buffer.
        pub const SliceType = MUT.SliceType(T);

        /// An empty buffer.
        pub const empty = Self{
            .ptr = 0,
            .len = 0,
        };

        /// Create a buffer from a slice.
        pub fn fromSlice(slice: SliceType) Self {
            return fromPtr(slice.ptr, slice.len);
        }

        /// Create a buffer from a pointer and length.
        pub fn fromPtr(ptr: PointerType, len: usize) Self {
            return Self{
                .ptr = @intCast(@intFromPtr(ptr)),
                .len = @intCast(len),
            };
        }

        /// Extract the 48-bit address part of this buffer.
        pub fn asPtr(self: Self) PointerType {
            std.debug.assert(self.ptr != 0);

            return @ptrFromInt(@as(usize, @intCast(self.ptr)));
        }

        /// Extract both parts of this buffer and construct a slice.
        pub fn asSlice(self: Self) SliceType {
            return if (self.ptr == 0 or self.len == 0) &.{} else self.asPtr()[0..self.len];
        }
    };
}

/// This is a slice utilizing pointer-tagging to encode the length
/// into 64 bits along with the base pointer.
///
/// * Max elements: 65,535 (u16)
/// * Pointer values on our supported architectures only use 48-bits of their word,
/// leaving us a super convenient space to store arbitrary data
/// (assuming we decompose before using it as a pointer, see methods).
pub fn short(comptime T: type, comptime MUT: pl.Mutability) type {
    return packed struct {
        const Self = @This();

        len: u16 = 0,
        ptr: u48 = 0,

        pub const PointerType: type = MUT.MultiPointerType(T);
        pub const SliceType: type = MUT.SliceType(T);
        pub const ValueType = T;

        pub const empty = Self{
            .len = 0,
            .ptr = 0,
        };

        /// Create a buffer from a slice.
        pub fn fromSlice(slice: SliceType) Self {
            return fromPtr(slice.ptr, slice.len);
        }

        /// Create a buffer from a pointer and length.
        pub fn fromPtr(ptr: PointerType, len: usize) Self {
            const i = @intFromPtr(ptr);
            std.debug.assert(i != 0);
            std.debug.assert(i != 0xaaaa_aaaa_aaaa_aaaa);
            return Self{
                .len = @intCast(len),
                .ptr = @intCast(i),
            };
        }

        /// Extract the 48-bit address part of this buffer.
        pub fn asPtr(self: Self) PointerType {
            std.debug.assert(self.ptr != 0);
            if (!std.mem.isAligned(self.ptr, @alignOf(T))) {
                std.debug.panic("Buffer.asPtr: pointer {x} not aligned to {}", .{ self.ptr, @alignOf(T) });
            }
            return @ptrFromInt(self.ptr);
        }

        /// Extract both parts of this buffer and construct a slice.
        pub fn asSlice(self: Self) SliceType {
            if (self.ptr == 0 or self.len == 0) return &.{};

            return self.asPtr()[0..self.len];
        }

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (comptime @typeInfo(PointerType).pointer.child == u8) {
                try writer.print("\"{s}\"", .{self.asSlice()});
            } else {
                try writer.print("{any}", .{self.asSlice()});
            }
        }
    };
}

/// This is a fixed-length extern buffer with a variable-length state element and slicing methods. IE, smallvec or similar. Mutation is manual for now.
pub fn fixed(comptime T: type, comptime CAPACITY: comptime_int) type {
    return extern struct {
        const Self = @This();

        len: u64 = 0,
        val: [CAPACITY]T = [1]T{undefined} ** CAPACITY,

        pub const ValueType = T;

        pub const empty = Self{};

        /// Copy a buffer from a slice.
        pub fn fromSlice(slice: []const T) Self {
            var out = Self{ .len = @intCast(slice.len) };

            @memcpy(out.asMutSlice(), slice);

            return out;
        }

        /// Copy a buffer from a pointer and length.
        pub fn fromPtr(ptr: *const T, len: usize) Self {
            return Self.fromSlice(ptr[0..len]);
        }

        /// Get a pointer to the data portion of this buffer.
        pub fn asPtr(self: *const Self) [*]const T {
            return @ptrCast(&self.val);
        }

        /// Get a mutable pointer to the data portion of this buffer.
        pub fn asMutPtr(self: *Self) [*]T {
            return @ptrCast(&self.val);
        }

        /// Get a slice of this buffer's active data portion.
        pub fn asSlice(self: *const Self) []const T {
            return self.asPtr()[0..self.len];
        }

        /// Get a mutable slice of this buffer's active data portion.
        pub fn asMutSlice(self: *Self) []T {
            return self.asMutPtr()[0..self.len];
        }

        /// `std.fmt` impl
        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (comptime T == u8) {
                try writer.print("\"{s}\"", .{self.asSlice()});
            } else {
                try writer.print("{any}", .{self.asSlice()});
            }
        }
    };
}
