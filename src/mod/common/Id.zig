//! Generalized unique identifier utilities.
const Id = @This();

const std = @import("std");
const common = @import("../common.zig");

test {
    // std.debug.print("semantic analysis for Id\n", .{});
    std.testing.refAllDeclsRecursive(@This());
}

/// Identity values used to create indirect references.
///
/// Associated type may be accessed with the `Value` constant.
///
/// Null ids are encoded as part of the enum for layout efficiency; the methods account for this by
/// incrementing integers when creating enums, and decrementing enums when creating integers.
/// Therefore, despite the null id being zero, we can still index into arrays simply by calling `.toInt()`.
/// Additionally, "null dereference" will be caught by safe-mode checks due to overflow.
pub fn of(comptime T: type, comptime bits: comptime_int) type {
    const I = std.meta.Int(.unsigned, bits);
    return enum(I) {
        const Self = @This();

        /// The value type this ID binds.
        pub const Value = T;

        null = 0,
        _,

        /// The maximum integer that can be converted to an `Id`.
        pub const MAX_INT = std.math.maxInt(I) - 1;

        /// Convert between `Id` types.
        pub fn cast(self: Self, comptime U: type) Id.of(U, bits) {
            return self.bitcast(U, bits);
        }

        /// Convert between `Id` types of different sizes.
        pub fn bitcast(self: Self, comptime U: type, comptime new_bits: comptime_int) Id.of(U, new_bits) {
            return @enumFromInt(@intFromEnum(self));
        }

        /// Convert this id to an integer.
        pub fn toInt(self: Self) I {
            return @intFromEnum(self) - 1;
        }

        /// Convert an integer to an `Id`.
        pub fn fromInt(i: anytype) Self {
            return @enumFromInt(i + 1);
        }

        /// Takes a copy of an `Id`, performs a mutating increment on itself, and returns the copy.
        pub fn next(self: *Self) Self {
            const old = self.*;
            self.* = @enumFromInt(@intFromEnum(old) + 1);
            return old;
        }

        /// Convert an `Id` to an optional of itself.
        /// This is useful for `orelse` clauses on the null status of the id.
        pub fn maybe(self: Self) ?Self {
            if (self == .null) {
                return null;
            }
            return self;
        }

        pub fn format(self: Self, writer: *std.io.Writer) !void {
            if (self == .null) {
                try writer.writeAll(@typeName(T) ++ ":null");
            } else {
                try writer.print(@typeName(T) ++ ":{d}", .{self.toInt()});
            }
        }
    };
}

pub fn Table(comptime T: type, comptime id_size: comptime_int) type {
    return struct {
        const Self = @This();
        pub const Id = of(T, id_size);

        data: common.MultiArrayList(T) = .empty,

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
            var self = Self.empty;

            try self.data.ensureTotalCapacity(allocator, capacity);
            errdefer self.data.deinit(allocator);

            return self;
        }

        pub fn ensureCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.data.ensureUnusedCapacity(allocator, capacity);
        }

        pub fn deinitData(self: *Self, allocator: std.mem.Allocator) void {
            if (comptime common.hasDecl(T, .deinit)) {
                for (0..self.data.len) |i| {
                    var a = self.data.get(i);
                    a.deinit(allocator);
                }
            }

            self.data.len = 0;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.deinitData(allocator);
            self.data.deinit(allocator);
        }

        pub fn clear(self: *Self) void {
            self.data.clearRetainingCapacity();
        }

        pub fn rowCount(self: *Self) usize {
            return self.data.len;
        }

        pub fn column(self: *Self, comptime name: std.meta.FieldEnum(T)) []std.meta.FieldType(T, name) {
            return self.data.items(name);
        }

        pub fn cell(self: *Self, id: Self.Id, comptime name: std.meta.FieldEnum(T)) *std.meta.FieldType(T, name) {
            return &self.data.items(name)[id.toInt()];
        }

        pub fn getRow(self: *Self, id: Self.Id) ?T {
            if (id == .null) return null;

            return self.data.get(id.toInt());
        }

        pub fn addRow(self: *Self, allocator: std.mem.Allocator, data: T) !Self.Id {
            std.debug.assert(self.data.len <= std.math.maxInt(std.meta.Tag(Self.Id)));

            const id = Self.Id.fromInt(self.data.len);

            try self.data.append(allocator, data);

            return id;
        }
    };
}

/// `HashMap` specialized to types compatible with `IdHashCtx`.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `common.HashMap` and `IdHashCtx` for detailed docs.
pub fn Map(comptime K: type, comptime V: type, comptime LOAD_PERCENTAGE: u64) type {
    return common.HashMap(K, V, HashCtx(K), LOAD_PERCENTAGE);
}

/// `HashSet` specialized to types compatible with `IdHashCtx`.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `common.HashSet` and `IdHashCtx` for detailed docs.
pub fn Set(comptime T: type, comptime LOAD_PERCENTAGE: u64) type {
    return common.HashSet(T, HashCtx(T), LOAD_PERCENTAGE);
}

/// Creates a context for hashing and comparing values based on their ids.
///
/// The type provided must have a field `id`,
/// which must be of a type that has as a unique representation.
///
/// See `std.meta.hasUniqueRepresentation`.
pub fn HashCtx(comptime T: type) type {
    comptime {
        if (!common.hasDerefField(T, .id)) {
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
                return common.hash64(std.mem.asBytes(&x.id));
            }
        };
    }
}
