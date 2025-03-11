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
    return enum(u64) {
        const Self = @This();

        /// The value type this ID binds.
        pub const Value = T;

        _,

        /// Convert this ID to a word-sized integer
        pub fn toInt(self: Self) pl.uword {
            return @intFromEnum(self);
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
