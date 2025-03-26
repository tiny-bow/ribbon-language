//! Basically, its a slice, but with a known (packed) layout.
const pl = @import("platform");

/// Immutable buffer of bytes.
pub const Bytes = new(u8, .constant);

/// Mutable buffer of bytes.
pub const MutBytes = new(u8, .mutable);

/// Creates a new `Buffer` type with the given element type and mutability.
pub fn new(comptime T: type, comptime MUT: pl.Mutability) type {
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

        /// Create a buffer from a slice.
        pub fn fromSlice(slice: SliceType) Self {
            return fromPtr(slice.ptr, slice.len);
        }

        /// Create a buffer from a pointer and length.
        pub fn fromPtr(ptr: PointerType, len: usize) Self {
            return Self {
                .ptr = @intCast(@intFromPtr(ptr)),
                .len = @intCast(len),
            };
        }

        /// Extract the 48-bit address part of this buffer.
        pub fn asPtr(self: Self) PointerType {
            return @ptrFromInt(@as(usize, @intCast(self.ptr)));
        }

        /// Extract both parts of this buffer and construct a slice.
        pub fn asSlice(self: Self) SliceType {
            return self.asPtr()[0..self.len];
        }
    };
}
