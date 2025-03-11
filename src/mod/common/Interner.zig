//! An interner is a data structure that stores a unique copy of each value that is interned.
//! This is useful for reducing memory usage and improving performance when dealing with
//! values that are frequently repeated.
//!
//! The interner uses a hash set to store the interned values. When a new value is interned,
//! the interner first checks if the value is already in the hash set. If it is, the interner
//! returns a pointer to the existing value. If it is not, the interner creates a new copy of
//! the value, adds it to the hash set, and returns a pointer to the new value.
//!
//! The interner requires a context type that provides the following:
//! * The name of the field that the interner will use for identity.
//!   ```zig
//!   pub const DATA_FIELD: EnumLiteral
//!   ```
//! * A function that compares two identity values for equality.
//!   ```zig
//!   pub fn eql(a: *const F, b: *const F) bool
//!   ```
//!   where `F = DerefFieldType(T, DATA_FIELD`.
//! * A function that is called when a new value is interned for the first time.
//!   ```zig
//!   pub fn onFirstIntern(ptr: **const T, allocator: std.mem.Allocator) error{OutOfMemory}!void
//!   ```
//!   This function is expected to perform the allocation(s) and/or copying,
//!   which are being de-duplicated by the interner.
//!   The in-out-parameter `ptr` will already be initialized with a value.
//!   It is the pointer to the temporary data that was passed to the `intern` call.
//!
//! Interned value types additionally must have (deref-accessible; a pointer to such a value is also acceptable)
//! a precomputed hash field that avoids some comparison labor.
//! The type of this field must have a unique representation (See `std.meta.hasUniqueRepresentation`).
//! Eg:
//! * It could be an integer.
//!   ```zig
//!   hash: u64,
//!   ```
//! * Enums are also acceptable.
//!   ```zig
//!   hash: Id(Foo),
//!   ```
//! * ... etc
const Interner = @This();

const std = @import("std");
const pl = @import("platform");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Creates a new `Interner` type with a specified element type and `Ctx`.
///
/// See `Interner` for details of `Ctx` interface.
pub fn new(comptime T: type, comptime Ctx: type) type {
    comptime {
        if (!pl.hasDecl(Ctx, .DATA_FIELD)) {
            @compileError("Interner(" ++ @typeName(T) ++ ", " ++ @typeName(Ctx) ++ "): Context does not have a DATA_FIELD declaration");
        }

        if (!pl.hasDecl(Ctx, .eql)) {
            @compileError("Interner(" ++ @typeName(T) ++ ", " ++ @typeName(Ctx) ++ "): Context does not have an eql method");
        }

        if (!pl.hasDerefDecl(Ctx, .onFirstIntern)) {
            @compileError("Interner(" ++ @typeName(T) ++ ", " ++ @typeName(Ctx) ++ "): Context does not have an onFirstIntern method");
        }

        if (!pl.hasDerefField(T, .hash)) {
            @compileError("Interner(" ++ @typeName(T) ++ ", " ++ @typeName(Ctx) ++ "): missing hash field");
        }

        if (!std.meta.hasUniqueRepresentation(pl.DerefFieldType(T, .hash))) {
            @compileError("Interner(" ++ @typeName(T) ++ ", " ++ @typeName(Ctx) ++ "): hash field does not have a unique representation");
        }

        const BackingCollection = pl.HashSet(T, struct {
            pub fn eql(_: @This(), a: T, b: T) bool {
                return a.hash == b.hash and Ctx.eql(&@field(a, @tagName(Ctx.DATA_FIELD)), &@field(b, @tagName(Ctx.DATA_FIELD)));
            }

            pub fn hash(_: @This(), a: T) u64 {
                return a.hash;
            }
        }, 80);

        return struct {
            const Self = @This();

            /// The underlying hash set used for interning.
            inner: BackingCollection,

            /// Default initialization value for interners.
            pub const empty = Self { .inner = .empty };

            /// Deinitializes the interner, freeing all allocated memory.
            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.inner.deinit(allocator);
            }

            /// Clones the interner, creating a new interner with the same values.
            pub fn clone(self: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}!Self {
                const inner = try self.inner.clone(allocator);
                return Self{ .inner = inner };
            }

            /// Formats the interner for debugging purposes.
            pub fn onFormat(self: *const Self, formatter: anytype) !void {
                const len = self.length();
                try formatter.print("Interner(" ++ @typeName(T) ++ " x {})", .{len});

                if (len == 0) {
                    return formatter.writeAll("[]");
                }

                try formatter.beginBlock(.Array);

                var valueIt = self.keyIterator();

                const first = valueIt.next().?;

                try formatter.fmt(first);

                while (valueIt.next()) |value| {
                    try formatter.endLine(true);

                    try formatter.fmt(value);
                }

                try formatter.endBlock();
            }

            /// Checks if the interner is empty.
            pub fn isEmpty(self: *const Self) bool {
                return self.inner.count() == 0;
            }

            /// Returns the number of interned values.
            pub fn count(self: *const Self) usize {
                return self.inner.count();
            }

            pub const Result = struct {
                ptr: *T,
                new_entry: bool,
            };

            pub const Iterator = BackingCollection.KeyIterator;

            /// Interns a value, returning a pointer to the interned value.
            pub fn intern(self: *Self, internerAllocator: std.mem.Allocator, internedValueAllocator: ?std.mem.Allocator, value: T) error{OutOfMemory}!Result {
                const getOrPut = try self.inner.getOrPut(internerAllocator, value);

                const out = Result {
                    .ptr = getOrPut.key_ptr,
                    .new_entry = !getOrPut.found_existing,
                };

                if (out.new_entry) {
                    const innerAllocator = internedValueAllocator orelse internerAllocator;

                    try Ctx.onFirstIntern(out.ptr, innerAllocator);
                }

                return out;
            }

            /// Returns an iterator over the interned values.
            pub fn keyIterator(self: *const Self) Iterator {
                return self.inner.keyIterator();
            }

            /// Creates a new interner from a set of values.
            pub fn fromSet(allocator: std.mem.Allocator, set: anytype) error{OutOfMemory}!Self {
                var out = try Self.initCapacity(allocator);

                for (set.values()) |item| {
                    _ = try out.intern(allocator, item);
                }

                return out;
            }

            /// Creates a new set from the interned values.
            pub fn toSet(self: *const Self, comptime SetCtx: type, comptime SET_LOAD_PERCENTAGE: u64, allocator: std.mem.Allocator) error{OutOfMemory}!pl.HashSet(T, SetCtx, SET_LOAD_PERCENTAGE) {
                var out = try pl.HashSet(T, SetCtx, SET_LOAD_PERCENTAGE).initCapacity(allocator, self.count());

                for (self.keyIterator()) |item| {
                    try out.put(allocator, item);
                }

                return out;
            }

            /// Creates a new interner from a slice of values.
            pub fn fromSlice(allocator: std.mem.Allocator, internedValueAllocator: ?std.mem.Allocator, slice: []T) error{OutOfMemory}!Self {
                var out = Self.empty;

                for (slice) |item| {
                    _ = try out.intern(allocator, internedValueAllocator, item);
                }

                return out;
            }

            /// Creates a new slice from the interned values.
            pub fn toOwnedSlice(self: *const Self, allocator: std.mem.Allocator) error{OutOfMemory}![]T {
                const slice = try allocator.alloc(T, self.count());

                var i: usize = 0;
                var it = self.keyIterator();
                while (it.next()) |item| {
                    slice[i] = item.*;
                    i += 1;
                }

                return slice;
            }
        };
    }
}
