//! Generalized unique identifier utilities.
const Id = @This();

const std = @import("std");

const pl = @import("platform");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Identity values used to create indirect references.
///
/// Associated type may be accessed with the `Value` constant.
pub fn of(comptime T: type) type {
    return enum(u16) {
        const Self = @This();

        /// The value type this ID binds.
        pub const Value = T;

        null = 0,
        _,

        /// Convert between `Id` types.
        pub fn cast(self: Self, comptime U: type) Id.of(U) {
            return @enumFromInt(@intFromEnum(self));
        }

        /// Convert this id to a 16-bit integer.
        pub fn toInt(self: Self) u16 {
            return @intFromEnum(self) - 1;
        }
    };
}

/// This is a slice utilizing pointer-tagging to encode the length
/// into 64 bits along with the base pointer.
///
/// This is possible because of two factors:
/// + `Id`s are 16-bit, so a buffer referring to values identified by them
/// could never be larger than `std.math.maxInt(u16)` elements.
/// + Pointer values on our supported architectures only use 48-bits of their word,
/// leaving us a super convenient space to store arbitrary data
/// (assuming we mask it off before using it as a pointer, see methods).
pub fn Buffer(comptime T: type, comptime MUT: pl.Mutability) type {
    return packed struct {
        const Self = @This();

        len: u16,
        ptr: u48,

        pub const PointerType = MUT.MultiPointerType(T);
        pub const SliceType = MUT.SliceType(T);

        /// Create a buffer from a slice.
        pub fn fromSlice(slice: SliceType) Self {
            return fromPtr(slice.ptr, slice.len);
        }

        /// Create a buffer from a pointer and length.
        pub fn fromPtr(ptr: PointerType, len: usize) Self {
            return Self {
                .len = @intCast(len),
                .ptr = @intCast(@intFromPtr(ptr)),
            };
        }

        /// Extract the 48-bit address part of this buffer.
        pub fn asPtr(self: Self) PointerType {
            return @ptrFromInt(self.ptr);
        }

        /// Extract both parts of this buffer and construct a slice.
        pub fn asSlice(self: Self) SliceType {
            return self.asPtr()[0..self.len];
        }
    };
}

/// `HashMap` specialized to types compatible with `IdHashCtx`.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `platform.HashMap` and `IdHashCtx` for detailed docs.
pub fn Map(comptime K: type, comptime V: type, comptime LOAD_PERCENTAGE: u64) type {
    return pl.HashMap(K, V, HashCtx(K), LOAD_PERCENTAGE);
}

/// `HashSet` specialized to types compatible with `IdHashCtx`.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `platform.HashSet` and `IdHashCtx` for detailed docs.
pub fn Set(comptime T: type, comptime LOAD_PERCENTAGE: u64) type {
    return pl.HashSet(T, HashCtx(T), LOAD_PERCENTAGE);
}

/// Creates a context for hashing and comparing values based on their ids.
///
/// The type provided must have a field `id`,
/// which must be of a type that has as a unique representation.
///
/// See `std.meta.hasUniqueRepresentation`.
pub fn HashCtx(comptime T: type) type {
    comptime {
        if(!pl.hasDerefField(T, .id)) {
            @compileError("IdHashCtx: type " ++ @typeName(T) ++ " requires a field named 'id'");
        }

        if (!std.meta.hasUniqueRepresentation(T)) {
            @compileError("IdHashCtx: field " ++ @typeName(T) ++ ".id does not have a unique representation");
        }

        return struct {
            pub fn eql(_: @This(), a: T, b: T) bool {
                return a.id == b.id;
            }

            pub fn hash(_: @This(), x: T) u64 {
                return pl.hash64(std.mem.asBytes(&x.id));
            }
        };
    }
}
