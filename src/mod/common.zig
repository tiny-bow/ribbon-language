//! Common utilities used throughout the Ribbon pipeline
const common = @This();

const std = @import("std");
const log = std.log.scoped(.common);

test {
    // std.debug.print("semantic analysis for common\n", .{});
    std.testing.refAllDecls(@This());
}

pub const Buffer = @import("common/Buffer.zig");
pub const Id = @import("common/Id.zig");
pub const Stack = @import("common/Stack.zig");
pub const AllocWriter = @import("common/AllocWriter.zig");
pub const VirtualWriter = @import("common/VirtualWriter.zig");

pub const PAGE_SIZE = std.heap.page_size_min;

pub const PeekableIteratorMode = union(enum) {
    error_type: type,
    direct_call: void,

    pub fn use_try(comptime T: type) PeekableIteratorMode {
        return .{
            .error_type = T,
        };
    }
};

/// Any `Iterator` that has a next() method which returns `Element` can be peeked with this iterator.
/// This is useful for iterators that are not peekable themselves or already peekable in another capacity.
pub fn PeekableIterator(comptime Iterator: type, comptime Element: type, comptime mode: PeekableIteratorMode) type {
    return struct {
        const Self = @This();

        inner: Iterator,
        peek_cache: ?Element = null,

        pub const Result: type = if (mode == .error_type) (mode.error_type!?Element) else (?Element);

        pub fn deinit(self: *Self) void {
            if (comptime @hasDecl(Iterator, "deinit")) {
                self.inner.deinit();
            }
        }

        pub fn from(inner: Iterator) (if (mode == .error_type) (mode.error_type!Self) else Self) {
            var self = Self{
                .inner = inner,
                .peek_cache = null,
            };

            _ = if (comptime mode == .error_type) try self.peek() else self.peek();

            return self;
        }

        pub fn isEof(self: *const Self) bool {
            return self.peek_cache == null;
        }

        pub fn peek(self: *Self) Result {
            if (self.peek_cache) |v| {
                return v;
            }

            const it = if (comptime mode == .error_type) try self.inner.next() else self.inner.next();

            self.peek_cache = it;

            return it;
        }

        pub fn next(self: *Self) Result {
            if (self.peek_cache) |v| {
                if (comptime mode == .error_type) try self.advance() else self.advance();

                return v;
            }

            return null;
        }

        pub fn advance(self: *Self) (if (mode == .error_type) (mode.error_type!void) else void) {
            self.peek_cache = null;

            _ = if (comptime mode == .error_type) try self.peek() else self.peek();
        }
    };
}

/// Utf-32 codepoint (`u21`).
pub const Char: type = u21;

/// The type of constant virtual memory regions.
pub const VirtualMemory = []align(PAGE_SIZE) const u8;

/// The type of mutable virtual memory regions.
pub const MutVirtualMemory = []align(PAGE_SIZE) u8;

pub const ArrayList = std.ArrayListUnmanaged;
pub const MultiArrayList = std.MultiArrayList;

/// A dynamic array based hash table of keys where the values are void. Each key is stored sequentially.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `std.ArrayHashMapUnmanaged` for detailed documentation.
pub fn ArrayMap(comptime K: type, comptime V: type, comptime Ctx: type) type {
    return std.ArrayHashMapUnmanaged(K, V, Ctx, true);
}

/// A dynamic array based hash table of keys where the values are void. Each key is stored sequentially.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `ArrayMap` for detailed documentation.
pub fn ArraySet(comptime T: type, comptime Ctx: type) type {
    return ArrayMap(T, void, Ctx);
}

pub fn HashMap(comptime K: type, comptime V: type, comptime Ctx: type) type {
    return std.HashMapUnmanaged(K, V, Ctx, 80);
}

/// A hash table based on open addressing and linear probing. The values are void.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `HashMap` for detailed docs.
pub fn HashSet(comptime T: type, comptime Ctx: type) type {
    return HashMap(T, void, Ctx);
}

/// String map type; see `HashMap` for detailed docs.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
pub const StringMap = std.StringHashMapUnmanaged;

/// String map type; see `ArrayMap` for detailed docs.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
pub const StringArrayMap = std.StringArrayHashMapUnmanaged;

/// String map type. The values are void.
///
/// Key memory is managed by the caller. Keys will not automatically be freed.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `ArraySet` for detailed docs.
pub const StringArraySet = StringArrayMap(void);

/// String map type. The values are void.
///
/// Key memory is managed by the caller. Keys will not automatically be freed.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `HashSet` for detailed docs.
pub const StringSet = StringMap(void);

/// Indicates whether an integer type can represent negative values.
pub const Signedness = std.builtin.Signedness;

/// Indicates whether a value can be modified.
pub const Mutability = enum(u1) {
    constant,
    mutable,

    /// Create a single-value pointer type with this mutability.
    pub fn PointerType(comptime self: Mutability, comptime T: type) type {
        return switch (self) {
            .constant => [*]const T,
            .mutable => [*]T,
        };
    }

    /// Create a multi-value pointer type with this mutability.
    pub fn MultiPointerType(comptime self: Mutability, comptime T: type) type {
        return switch (self) {
            .constant => [*]const T,
            .mutable => [*]T,
        };
    }

    /// Create a slice type with this mutability.
    pub fn SliceType(comptime self: Mutability, comptime T: type) type {
        return switch (self) {
            .constant => []const T,
            .mutable => []T,
        };
    }
};

pub fn WithoutFields(comptime T: type, comptime DROPPED: []const []const u8) type {
    comptime {
        const old_fields = std.meta.fields(T);
        const Field = @TypeOf(old_fields[0]);

        var new_fields = [1]Field{undefined} ** old_fields.len;

        var i = 0;

        for (old_fields) |old_field| {
            if (for (DROPPED) |x| {
                if (std.mem.eql(u8, old_field.name, x)) break true;
            } else false) continue;
            new_fields[i] = old_field;
            i += 1;
        }

        var info = @typeInfo(T);

        switch (info) {
            .@"struct" => |*x| x.fields = new_fields[0..i],
            .@"union" => |*x| x.fields = new_fields[0..i],
            .@"enum" => |*x| x.fields = new_fields[0..i],
            .error_set => |*x| x.* = new_fields[0..i],
            else => unreachable,
        }

        return @Type(info);
    }
}

pub fn UniqueReprMap(comptime K: type, comptime V: type) type {
    return HashMap(K, V, UniqueReprHashContext64(K));
}

pub fn UniqueReprSet(comptime T: type) type {
    return HashSet(T, UniqueReprHashContext64(T));
}

pub fn UniqueReprArrayMap(comptime K: type, comptime V: type) type {
    return ArrayMap(K, V, UniqueReprHashContext32(K));
}

pub fn UniqueReprArraySet(comptime T: type) type {
    return ArraySet(T, UniqueReprHashContext32(T));
}

/// Provides a 32-bit hash context for types with unique representation. See `std.meta.hasUniqueRepresentation`.
pub fn UniqueReprHashContext32(comptime T: type) type {
    if (comptime !std.meta.hasUniqueRepresentation(T)) {
        @compileError("UniqueReprHashContext32: type `" ++ @typeName(T) ++ "` must have unique representation");
    }
    return struct {
        pub fn eql(_: @This(), a: T, b: T, _: usize) bool {
            return a == b;
        }

        pub fn hash(_: @This(), value: T) u32 {
            return hash32(@as([*]const u8, @ptrCast(&value))[0..@sizeOf(T)]);
        }
    };
}

/// Provides a 64-bit hash context for types with unique representation. See `std.meta.hasUniqueRepresentation`.
pub fn UniqueReprHashContext64(comptime T: type) type {
    if (comptime !std.meta.hasUniqueRepresentation(T)) {
        @compileError("UniqueReprHashContext64: type `" ++ @typeName(T) ++ "` must have unique representation");
    }
    return struct {
        pub fn eql(_: @This(), a: T, b: T) bool {
            return a == b;
        }

        pub fn hash(_: @This(), value: T) u64 {
            return hash64(@as([*]const u8, @ptrCast(&value))[0..@sizeOf(T)]);
        }
    };
}

/// Returns an enum with a variant named after each field of `T`.
pub fn FieldEnumOfSize(comptime T: type, comptime bit_size: comptime_int) type {
    const field_infos = std.meta.fields(T);

    const I = std.meta.Int(.unsigned, bit_size);

    if (field_infos.len == 0) {
        return @Type(.{
            .@"enum" = .{
                .tag_type = I,
                .fields = &.{},
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    }

    if (@typeInfo(T) == .@"union") {
        if (@typeInfo(T).@"union".tag_type) |tag_type| {
            for (std.enums.values(tag_type), 0..) |v, i| {
                if (@intFromEnum(v) != i) break; // enum values not consecutive
                if (!std.mem.eql(u8, @tagName(v), field_infos[i].name)) break; // fields out of order
            } else {
                return tag_type;
            }
        }
    }

    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    var decls = [_]std.builtin.Type.Declaration{};
    inline for (field_infos, 0..) |field, i| {
        enumFields[i] = .{
            .name = field.name ++ "",
            .value = i,
        };
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = I,
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}

/// Offsets an address to the next multiple of the provided alignment, if it is not already aligned.
pub fn alignTo(address: anytype, alignment: anytype) @TypeOf(address) {
    const addr = integerFromUnknownAddressType(address);
    const algn = integerFromUnknownAddressType(alignment);
    return integerToUnknownAddressType(@TypeOf(address), (addr + algn - 1) & (~algn + 1));
}

pub fn integerFromUnknownAddressType(address: anytype) u64 {
    const T = @TypeOf(address);
    const tInfo = @typeInfo(T);
    return switch (tInfo) {
        .pointer => @intFromPtr(address),
        .comptime_int => @intCast(address),
        .int => @as(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(address)),
        else => @compileError("addressFromUnknown: invalid type " ++ @typeName(T)),
    };
}

pub fn integerToUnknownAddressType(comptime T: type, address: u64) T {
    const tInfo = @typeInfo(T);
    return switch (tInfo) {
        .pointer => @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(address)))),
        .comptime_int => @intCast(address),
        .int => |info| ints: {
            const out = @as(std.meta.Int(info.signedness, 64), @bitCast(address));
            if (@bitSizeOf(T) < 64) {
                break :ints @intCast(out);
            } else {
                break :ints out;
            }
        },
        else => @compileError("addressFromUnknown: invalid type " ++ @typeName(T)),
    };
}

/// Filter function for comptime_int types preventing errors when comparing the output of `alignDelta` with a literal.
pub fn AlignOutput(comptime T: type) type {
    return if (T != comptime_int) T else u64;
}

/// Calculates the offset necessary to increment an address to the next multiple of the provided alignment.
pub fn alignDelta(address: anytype, alignment: anytype) AlignOutput(@TypeOf(alignment)) {
    const addr = integerFromUnknownAddressType(address);
    const algn = integerFromUnknownAddressType(alignment);
    const off = (algn - (addr % algn)) % algn;
    return integerToUnknownAddressType(AlignOutput(@TypeOf(alignment)), off);
}

// This function safely applies a signed element offset to a pointer.
pub fn offsetPointerElement(ptr: anytype, offset: isize) @TypeOf(ptr) {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(@intFromPtr(ptr))) + offset * @sizeOf(@typeInfo(@TypeOf(ptr)).pointer.child))));
}

// This function safely applies a signed byte offset to a pointer.
pub fn offsetPointer(ptr: anytype, offset: isize) @TypeOf(ptr) {
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(@intFromPtr(ptr))) + offset)));
}

/// * If the input type is a `comptime_int` or `comptime_float`: returns `comptime_float`.
/// * Otherwise:
///     + if the input type is >= 64 bits in size: returns `f64`.
///     + else: returns `f32`.
pub fn FloatOrDouble(comptime T: type) type {
    comptime return switch (T) {
        comptime_int, comptime_float => comptime_float,
        else => if (@bitSizeOf(T) <= 32) f32 else f64,
    };
}

/// Converts bytes to bits.
pub fn bitsFromBytes(bytes: anytype) @TypeOf(bytes) {
    return bytes * 8;
}

/// Converts bits to bytes.
pub fn bytesFromBits(bits: anytype) FloatOrDouble(@TypeOf(bits)) {
    return @as(FloatOrDouble(@TypeOf(bits)), @floatFromInt(bits)) / 8.0;
}

/// Converts kilobytes to bytes.
pub fn bytesFromKilobytes(kb: anytype) @TypeOf(kb) {
    return kb * 1024;
}

/// Converts megabytes to bytes.
pub fn bytesFromMegabytes(mb: anytype) @TypeOf(mb) {
    return bytesFromKilobytes(mb) * 1024;
}

/// Converts gigabytes to bytes.
pub fn bytesFromGigabytes(gb: anytype) @TypeOf(gb) {
    return bytesFromMegabytes(gb) * 1024;
}

/// Converts bytes to kilobytes.
pub fn kilobytesFromBytes(bytes: anytype) FloatOrDouble(@TypeOf(bytes)) {
    const T = FloatOrDouble(@TypeOf(bytes));
    return @as(T, @floatFromInt(bytes)) / 1024.0;
}

/// Converts bytes to megabytes.
pub fn megabytesFromBytes(bytes: anytype) FloatOrDouble(@TypeOf(bytes)) {
    return @as(FloatOrDouble(@TypeOf(bytes)), @floatCast(kilobytesFromBytes(bytes))) / 1024.0;
}

/// Converts bytes to gigabytes.
pub fn gigabytesFromBytes(bytes: anytype) FloatOrDouble(@TypeOf(bytes)) {
    return @as(FloatOrDouble(@TypeOf(bytes)), @floatCast(megabytesFromBytes(bytes))) / 1024.0;
}

/// Extract the whole number part of a floating point value.
pub fn whole(value: anytype) @TypeOf(value) {
    comptime std.debug.assert(@typeInfo(@TypeOf(value)) == .float);

    const Bits = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value)));
    // Convert float to its IEEE754 32-bit representation.
    const bits: Bits = @bitCast(value);
    // Extract the exponent (bits 23-30) and remove the bias.
    const exp: Bits = ((bits >> 23) & 0xFF) - 127;

    // If x is less than 1, then the integer part is zero.
    if (exp < 0) return 0.0;

    // If the exponent is 23 or greater, all the fraction bits contribute
    // to the integer part (or x is too large), so there is no fractional part.
    if (exp >= 23) return value;

    // Create a mask that zeros out the fractional bits that represent the integer part.
    // The lower (23 - exp) bits are the fraction portion.
    const mask = ~((@as(Bits, 1) << @intCast((@as(Bits, 23) - exp) - @as(Bits, 1))));

    // Clear the fractional bits from the bit representation.
    const intBits = bits & mask;

    // Convert back to float.
    return @bitCast(intBits);
}

/// Extract the fractional part of a floating point value.
pub fn frac(value: anytype) @TypeOf(value) {
    comptime std.debug.assert(@typeInfo(@TypeOf(value)) == .float);

    return value - whole(value);
}

/// efficient memory swap implementation
pub fn swap(a: [*]u8, b: [*]u8, n: usize) void {
    const wordSize = @sizeOf(usize);
    var pa = a;
    var pb = b;
    var remaining = n;

    // If both pointers have the same alignment offset,
    // we can swap word-sized blocks.
    if (@intFromPtr(pa) % wordSize == @intFromPtr(pb) % wordSize) {
        // Swap initial misaligned bytes until both pointers are aligned.
        const offset = @intFromPtr(pa) % wordSize;
        if (offset != 0) {
            var bytesToAlign = wordSize - offset;
            if (bytesToAlign > remaining) {
                bytesToAlign = remaining;
            }
            var i: usize = 0;
            while (i < bytesToAlign) : (i += 1) {
                const tmp = pa[i];
                pa[i] = pb[i];
                pb[i] = tmp;
            }
            pa += bytesToAlign;
            pb += bytesToAlign;
            remaining -= bytesToAlign;
        }

        // Swap full word-sized blocks.
        const wordCount = remaining / wordSize;
        var i: usize = 0;
        while (i < wordCount) : (i += 1) {
            // Calculate pointers to word-sized elements.
            const p_word_a: *usize = @ptrCast(@alignCast(pa + i * wordSize));
            const p_word_b: *usize = @ptrCast(@alignCast(pb + i * wordSize));
            const tmp = p_word_a.*;
            p_word_a.* = p_word_b.*;
            p_word_b.* = tmp;
        }
        const bytesSwapped = wordCount * wordSize;
        pa += bytesSwapped;
        pb += bytesSwapped;
        remaining -= bytesSwapped;
    }

    // Swap any remaining bytes.
    var j: usize = 0;
    while (j < remaining) : (j += 1) {
        const tmp = pa[j];
        pa[j] = pb[j];
        pb[j] = tmp;
    }
}

/// Drops values from the haystack up to and optionally including the first occurrence of the needle.
/// If the needle is the empty string, or is otherwise unable to be found, the haystack is returned unchanged.
pub fn trimBeforeSub(haystack: anytype, needle: anytype, needleMode: enum { include_needle, drop_needle }) @TypeOf(haystack) {
    if (needle.len == 0) {
        return haystack;
    }

    const i = std.mem.indexOf(haystack, needle) orelse {
        return haystack;
    };

    return if (needleMode == .include_needle) haystack[i..] else haystack[i + needle.len ..];
}

/// Represents a source code location.
pub const SourceLocation = struct {
    /// The file name.
    file_name: []const u8,
    /// The line number.
    line: usize,
    /// The column number.
    column: usize,

    pub fn onFormat(self: *const SourceLocation, formatter: anytype) !void {
        var realpath: [2048]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &realpath) catch "";
        try formatter.print("[{}:{}:{}]", .{ trimBeforeSub(self.file_name, cwd, .drop_needle), self.line, self.column });
    }

    pub fn deinit(self: SourceLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.file_name);
    }
};

/// Represents a stack trace.
pub const StackTrace = std.builtin.StackTrace;
/// Represents debug information.
pub const DebugInfo = std.debug.SelfInfo;
/// Gets debug information.
pub const debugInfo = std.debug.getSelfDebugInfo;

/// Gets the source location for a given address.
pub fn sourceLocation(allocator: std.mem.Allocator, address: usize) ?SourceLocation {
    const debug_info = debugInfo() catch return null;

    const module = debug_info.getModuleForAddress(address) catch return null;

    const symbol_info = module.getSymbolAtAddress(debug_info.allocator, address) catch return null;

    if (symbol_info.source_location) |sl| {
        defer debug_info.allocator.free(sl.file_name);

        return .{
            .file_name = allocator.dupe(u8, sl.file_name) catch return null,
            .line = sl.line,
            .column = sl.column,
        };
    }

    return null;
}

/// Captures a stack trace.
pub fn stackTrace(allocator: std.mem.Allocator, traceAddr: usize, numFrames: ?usize) ?StackTrace {
    var trace = StackTrace{
        .index = 0,
        .instruction_addresses = allocator.alloc(usize, numFrames orelse 1) catch return null,
    };

    std.debug.captureStackTrace(traceAddr, &trace);

    return trace;
}

/// Represents an enum literal.
pub const EnumLiteral: type = @Type(.enum_literal);

/// Represents a to-do item.
pub const TODO = *const anyopaque;

/// Marks a to-do item.
pub fn todo(comptime T: type, args: anytype) T {
    _ = args;

    @panic("NYI");
}

/// Computes a 32-bit FNV-1a hash.
pub fn hash32(data: []const u8) u32 {
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(data);
    return hasher.final();
}

/// Computes a 64-bit FNV-1a hash.
pub fn hash64(data: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(data);
    return hasher.final();
}

/// Computes a 128-bit FNV-1a hash.
pub fn hash128(data: []const u8) u128 {
    var hasher = std.hash.Fnv1a_128.init();
    hasher.update(data);
    return hasher.final();
}

/// Determines whether a type can have declarations.
pub inline fn canHaveDecls(comptime T: type) bool {
    comptime return switch (@typeInfo(T)) {
        .@"struct",
        .@"enum",
        .@"union",
        .@"opaque",
        => true,
        else => false,
    };
}

/// Determines whether a type can have fields.
pub inline fn canHaveFields(comptime T: type) bool {
    comptime return switch (@typeInfo(T)) {
        .@"struct",
        .@"union",
        .@"enum",
        => true,
        else => false,
    };
}

/// Determines whether a type has a declaration.
pub inline fn hasDecl(comptime T: type, comptime name: EnumLiteral) bool {
    comptime return (canHaveDecls(T) and @hasDecl(T, @tagName(name)));
}

/// Determines whether a type has a field.
pub inline fn hasField(comptime T: type, comptime name: EnumLiteral) bool {
    comptime return (canHaveFields(T) and @hasField(T, @tagName(name)));
}

/// Determines whether a pointer type has a declaration.
pub inline fn pointerDecl(comptime T: type, comptime name: EnumLiteral) bool {
    comptime {
        const tInfo = @typeInfo(T);
        return switch (tInfo) {
            .pointer => |info| hasDecl(info.child, name),
            else => false,
        };
    }
}

/// Determines whether a pointer type has a field.
pub inline fn pointerField(comptime T: type, comptime name: EnumLiteral) bool {
    comptime {
        const tInfo = @typeInfo(T);
        return switch (tInfo) {
            .pointer => |info| hasField(info.child, name),
            else => false,
        };
    }
}

/// Determines whether a type has a declaration, directly or via a pointer.
pub inline fn hasDerefDecl(comptime T: type, comptime name: EnumLiteral) bool {
    comptime return hasDecl(T, name) or pointerDecl(T, name);
}

/// Gets the type of a dereferenced declaration.
pub inline fn DerefDeclType(comptime T: type, comptime name: EnumLiteral) type {
    const tInfo = @typeInfo(T);

    if (comptime hasDecl(T, name)) {
        comptime return @TypeOf(@field(T, @tagName(name)));
    } else if (comptime tInfo == .pointer) {
        comptime return @TypeOf(@field(tInfo.pointer.child, @tagName(name)));
    } else {
        @compileError("No such decl");
    }
}

/// Gets a dereferenced declaration.
pub inline fn derefDecl(comptime T: type, comptime name: EnumLiteral) DerefDeclType(T, name) {
    comptime {
        if (hasDecl(T, name)) {
            return @field(T, @tagName(name));
        } else if (pointerDecl(T, name)) {
            return @field(typeInfo(T, .pointer).child, @tagName(name));
        } else {
            @compileError("No such decl");
        }
    }
}

pub inline fn DerefFieldType(comptime T: type, comptime name: EnumLiteral) type {
    comptime {
        if (hasField(T, name)) {
            return @FieldType(T, @tagName(name));
        } else if (pointerField(T, name)) {
            return @FieldType(typeInfo(T, .pointer).child, @tagName(name));
        } else {
            @compileError("DerefFieldType: " ++ @typeName(T) ++ " has no field " ++ @tagName(name));
        }
    }
}

pub inline fn FieldType(comptime T: type, comptime name: EnumLiteral) type {
    comptime {
        if (hasField(T, name)) {
            return @FieldType(T, @tagName(name));
        } else {
            @compileError("DerefFieldType: " ++ @typeName(T) ++ " has no field " ++ @tagName(name));
        }
    }
}

/// Determines whether a type has a field, directly or via a pointer.
pub inline fn hasDerefField(comptime T: type, comptime name: EnumLiteral) bool {
    comptime return hasField(T, name) or pointerField(T, name);
}

/// Determines whether a type is an error union.
pub inline fn isErrorUnion(comptime T: type) bool {
    comptime {
        const tInfo = @typeInfo(T);
        return tInfo == .error_union;
    }
}

/// Determines whether a type is a pointer.
pub inline fn isPointer(comptime T: type, comptime Child: ?type) bool {
    comptime {
        const tInfo = @typeInfo(T);

        if (Child) |ch| {
            return tInfo == .pointer and tInfo.pointer.child == ch;
        } else {
            return tInfo == .pointer;
        }
    }
}

/// Determines whether a type is an array.
pub fn isArray(comptime T: type, comptime Child: ?type) bool {
    comptime {
        const tInfo = @typeInfo(T);

        if (Child) |ch| {
            return tInfo == .array and tInfo.array.child == ch;
        } else {
            return tInfo == .array;
        }
    }
}

/// Determines whether a type is string-like.
pub fn isStrLike(comptime T: type) bool {
    comptime {
        const tInfo = @typeInfo(T);

        switch (tInfo) {
            .pointer => |info| return (info.size == .Slice and info.child == u8) or (info.size == .One and isStrLike(info.child)),
            .array => |info| return info.child == u8,
            else => return false,
        }
    }
}

/// Determines whether a type is a function.
pub fn isFunction(comptime T: type) bool {
    comptime {
        const tInfo = @typeInfo(T);
        return tInfo == .@"fn" or (tInfo == .pointer and @typeInfo(tInfo.pointer.child) == .@"fn");
    }
}

/// Represents type information.
pub const TypeInfo = std.builtin.Type;

/// Gets the type information for a given tag.
pub fn TypeInfoOf(comptime tag: std.meta.Tag(TypeInfo)) type {
    comptime return switch (tag) {
        .type,
        .void,
        .bool,
        .noreturn,
        .comptime_float,
        .comptime_int,
        .undefined,
        .null,
        .enum_literal,
        => void,

        .int => TypeInfo.Int,
        .float => TypeInfo.Float,
        .pointer => TypeInfo.Pointer,
        .array => TypeInfo.Array,
        .@"struct" => TypeInfo.Struct,
        .optional => TypeInfo.Optional,
        .error_union => TypeInfo.ErrorUnion,
        .error_set => TypeInfo.ErrorSet,
        .@"enum" => TypeInfo.Enum,
        .@"union" => TypeInfo.Union,
        .@"fn" => TypeInfo.Fn,
        .@"opaque" => TypeInfo.Opaque,
        .frame => TypeInfo.Frame,
        .@"anyframe" => TypeInfo.AnyFrame,
        .vector => TypeInfo.Vector,
    };
}

/// Gets type information for a given type and tag.
pub fn typeInfo(comptime T: type, comptime tag: std.meta.Tag(std.builtin.Type)) TypeInfoOf(tag) {
    comptime {
        const info = @typeInfo(T);

        if (info == tag) {
            return @field(info, @tagName(tag));
        } else if (tag == .@"fn" and info == .pointer and @typeInfo(info.pointer.child) == .@"fn") {
            return @typeInfo(info.pointer.child).@"fn";
        } else {
            @compileError("Expected a type of kind " ++ @tagName(tag) ++ ", got " ++ @tagName(info));
        }
    }
}

/// Extrapolates an error union type.
pub fn ExtrapolateErrorUnion(comptime E: type, comptime T: type) type {
    comptime return switch (@typeInfo(E)) {
        .error_union => |info| @Type(.{ .error_union = .{ .error_set = info.error_set, .payload = T } }),
        else => T,
    };
}

/// Copy and optionally overwrite pointer type attributes.
/// * e.g. `MyPtr = ExtrapolatePtr([*]align(64) const u8, .{ .is_const = false, .child = MyStruct })` == `[*]MyStruct`
/// * alignment is the only attribute overridden by default; it will be the new child type's alignment if not specified.
/// * otherwise, specify null to copy the original alignment, or .override to set a specific alignment.
pub fn ExtrapolatePtr(comptime source: type, comptime overrides: struct {
    size: ?std.builtin.Type.Pointer.Size = null,
    is_const: ?bool = null,
    is_volatile: ?bool = null,
    is_allowzero: ?bool = null,
    alignment: ?union(enum) { override: comptime_int, child } = .child,
    address_space: ?std.builtin.AddressSpace = null,
    child: ?type = null,
    sentinel_ptr: union(enum) { override: *const anyopaque, copy, none } = .copy,
}) type {
    const info = @typeInfo(source).pointer;
    const child = overrides.child orelse info.child;
    return @Type(.{
        .pointer = .{
            .size = overrides.size orelse info.size,
            .is_const = overrides.is_const orelse info.is_const,
            .is_volatile = overrides.is_volatile orelse info.is_volatile,
            .is_allowzero = overrides.is_allowzero orelse info.is_allowzero,
            .alignment = if (overrides.alignment) |aln| switch (aln) {
                .override => |amt| amt,
                .child => @alignOf(child),
            } else info.alignment,
            .address_space = overrides.address_space orelse info.address_space,
            .child = child,
            .sentinel_ptr = switch (overrides.sentinel_ptr) {
                .override => |ov| ov,
                .copy => info.sentinel_ptr,
                .none => null,
            },
        },
    });
}

/// Determines whether a function returns errors.
pub fn returnsErrors(comptime F: type) bool {
    comptime {
        const fInfo = typeInfo(F, .@"fn");
        return typeInfo(fInfo.return_type.?, null) == .error_union;
    }
}

/// Gets the return type of a function.
pub fn ReturnType(comptime F: type) type {
    comptime {
        const fInfo = typeInfo(F, .@"fn");
        return fInfo.return_type.?;
    }
}

/// Determines whether a function expects a pointer at a given argument index.
pub fn expectsPointerAtArgumentN(comptime F: type, comptime index: usize, comptime Child: ?type) bool {
    comptime {
        const fInfo = typeInfo(F, .@"fn");

        if (fInfo.params.len < index) return false;

        const P = if (fInfo.params[index].type) |T| T else return false;

        return isPointer(P, Child);
    }
}

/// A type-erased pointer to any type, used for binding arbitrary data in user-defined nodes.
/// * Does not imply ownership of the type-erased value.
pub const Any = struct {
    /// The type id of the value stored in this `Any`.
    type_name: []const u8,
    /// The pointer to the value stored in this `Any`.
    ptr: *anyopaque,

    /// Create an `Any` from a pointer of any type.
    /// * The type must be a pointer type, otherwise this will fail at compile time.
    pub fn from(value: anytype) Any {
        const T = comptime @TypeOf(value);

        if (comptime @typeInfo(T) != .pointer) {
            @compileError(@typeName(T) ++ " is not a pointer type, cannot be used with Any");
        }

        return .{
            .type_name = @typeName(T),
            .ptr = @ptrCast(value),
        };
    }

    /// Convert this `Any` to a pointer of type `T`, if the type matches.
    /// * The type must be a pointer type, otherwise this will fail at compile time.
    pub fn to(self: Any, comptime T: type) ?*T {
        if (std.mem.eql(u8, @typeName(T), self.type_name)) return null;

        return @ptrCast(@alignCast(self.ptr));
    }

    /// Convert this `Any` to a pointer of type `T`. Only checks the type id in safe modes.
    /// * The type must be a pointer type, otherwise this will fail at compile time.
    pub fn force(self: Any, comptime T: type) *T {
        const RUNTIME_SAFETY: bool = switch (@import("builtin").mode) {
            .Debug, .ReleaseSafe => true,
            .ReleaseFast, .ReleaseSmall => false,
        };

        if (comptime RUNTIME_SAFETY) {
            if (std.mem.eql(u8, @typeName(T), self.type_name.ptr)) {
                @compileError("Cannot convert Any to " ++ @typeName(T) ++ ", type mismatch");
            }
        }

        return @ptrCast(@alignCast(self.ptr));
    }
};

pub fn enumFieldArray(comptime T: type) [@typeInfo(T).@"enum".fields.len]std.meta.Tag(T) {
    comptime {
        const field_names = std.meta.fieldNames(T);
        var field_values = [1]std.meta.Tag(T){undefined} ** field_names.len;

        for (field_names, 0..) |field, i| {
            field_values[i] = @intFromEnum(@field(T, field));
        }

        return field_values;
    }
}

pub fn isEnumVariant(comptime T: type, value: anytype) bool {
    const field_values = comptime enumFieldArray(T);

    return std.mem.indexOfScalar(std.meta.Tag(T), &field_values, value) != null;
}

pub fn stream(reader: *std.io.Reader, writer: *std.io.Writer) !void {
    while (true) {
        const byte: u8 = reader.takeByte() catch return;
        try writer.writeByte(byte);
    }
}

/// Similar to `std.mem.indexOf`, but for slices of slices.
pub fn indexOfBuf(comptime T: type, haystack: []const []const T, needle: []const T) ?usize {
    if (needle.len == 0) return 0;

    for (haystack, 0..) |h, i| {
        if (std.mem.eql(T, h, needle)) {
            return i;
        }
    }

    return null;
}

/// See `snapshotTest` for usage.
pub const SnapshotTestName = union(enum) {
    none: void,
    use_log_info: []const u8,
    use_debug_print: []const u8,

    pub fn use_log(name: []const u8) SnapshotTestName {
        return SnapshotTestName{ .use_log_info = name };
    }

    pub fn use_debug(name: []const u8) SnapshotTestName {
        return SnapshotTestName{ .use_debug_print = name };
    }
};

/// Run a suite of input/output tests.
pub fn snapshotTest(comptime test_name: SnapshotTestName, comptime test_func: fn (input: []const u8, expect: []const u8) anyerror!void, comptime tests: []const struct { input: []const u8, expect: anyerror![]const u8 }) !void {
    var failures = ArrayList(usize).empty;
    defer failures.deinit(std.heap.page_allocator);

    testing: for (tests, 0..) |t, i| {
        log.info("test {}/{}", .{ i, tests.len });
        const input = t.input;

        if (t.expect) |expect_str| {
            test_func(input, expect_str) catch |err| {
                log.err("input {s} failed: {}", .{ input, err });
                failures.append(std.heap.page_allocator, i) catch unreachable;
                continue :testing;
            };

            log.info("input {s} succeeded: {s}", .{ input, expect_str });
        } else |expect_err| {
            std.debug.assert(expect_err != error.TestFailure);

            const maybe_err = test_func(input, "");
            if (maybe_err) |_| { // void
                log.err("input {s} succeeded; but expected {}", .{ input, expect_err });
                failures.append(std.heap.page_allocator, i) catch unreachable;
            } else |err| {
                if (err == error.TestFailure or err == error.TestExpectedEqual) {
                    log.err("input {s} succeeded, but the output was wrong; expected {}", .{ input, expect_err });
                    failures.append(std.heap.page_allocator, i) catch unreachable;
                } else if (expect_err != err) {
                    log.err("input {s} failed: {}; but expected {}", .{ input, err, expect_err });
                    failures.append(std.heap.page_allocator, i) catch unreachable;
                } else {
                    log.info("input {s} failed as expected", .{input});
                }
            }
        }
    }

    if (failures.items.len > 0) {
        log.err("Failed {}/{} tests: {any}", .{ failures.items.len, tests.len, failures.items });
        return error.TestFailed;
    } else {
        switch (test_name) {
            .none => {},
            .use_log_info => log.info("All snapshot tests for {s} passed", .{test_name.use_log_info}),
            .use_debug_print => std.debug.print("All snapshot tests for {s} passed", .{test_name.use_debug_print}),
        }
    }
}

pub fn FixedArray(comptime N: comptime_int, comptime T: type) type {
    return struct {
        items: [N]T = undefined,
        len: usize = 0,

        pub fn append(self: *FixedArray, item: T) error{OutOfMemory}!void {
            if (self.len >= N) return error.OutOfMemory;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn pop(self: *FixedArray) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.items[self.len];
        }

        pub fn remove(self: *FixedArray, index: usize) error{OutOfBounds}!void {
            if (index >= self.len) return error.OutOfBounds;
            for (index..self.len - 1) |i| {
                self.items[i] = self.items[i + 1];
            }
            self.len -= 1;
        }

        pub fn insert(self: *FixedArray, index: usize, item: T) error{ OutOfBounds, OutOfMemory }!void {
            if (index > self.len) return error.OutOfBounds;
            if (self.len >= N) return error.OutOfMemory;
            var i: usize = self.len;
            while (i > index) : (i -= 1) {
                self.items[i] = self.items[i - 1];
            }
            self.items[index] = item;
            self.len += 1;
        }

        pub fn asSlice(self: *FixedArray) []T {
            return self.items[0..self.len];
        }
    };
}

pub const MapStyle = enum {
    array,
    bucket,
};

pub inline fn StringBiMap(comptime B: type, comptime B_Ctx: type, comptime style: MapStyle) type {
    comptime return BiMap([]const u8, B, if (style == .array) std.array_hash_map.StringContext else std.hash_map.StringContext, B_Ctx, style);
}

pub inline fn UniqueReprStringBiMap(comptime B: type, comptime style: MapStyle) type {
    comptime return StringBiMap(B, if (style == .array) UniqueReprHashContext32(B) else UniqueReprHashContext64(B), style);
}

pub inline fn BiMap(comptime A: type, comptime B: type, comptime A_Ctx: type, comptime B_Ctx: type, comptime style: MapStyle) type {
    comptime return struct {
        const Self = @This();

        fn Map(comptime X: type, comptime Y: type, comptime C: type) type {
            return if (style == .array) ArrayMap(X, Y, C) else HashMap(X, Y, C);
        }

        a_to_b: Map(A, B, A_Ctx),
        b_to_a: Map(B, A, B_Ctx),

        pub const empty = Self{
            .a_to_b = .empty,
            .b_to_a = .empty,
        };

        pub fn count(self: *Self) usize {
            const out = self.a_to_b.count();
            std.debug.assert(out == self.b_to_a.count());
            return out;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.a_to_b.ensureTotalCapacity(allocator, @intCast(capacity));
            try self.b_to_a.ensureTotalCapacity(allocator, @intCast(capacity));
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.a_to_b.ensureUnusedCapacity(allocator, @intCast(capacity));
            try self.b_to_a.ensureUnusedCapacity(allocator, @intCast(capacity));
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.a_to_b.clearRetainingCapacity();
            self.b_to_a.clearRetainingCapacity();
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, a: A, b: B) !void {
            try self.a_to_b.put(allocator, a, b);
            try self.b_to_a.put(allocator, b, a);
        }

        pub fn get_b(self: *Self, a: A) ?B {
            return self.a_to_b.get(a);
        }

        pub fn get_a(self: *Self, b: B) ?A {
            return self.b_to_a.get(b);
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .inner = self.a_to_b.iterator(),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.a_to_b.deinit(allocator);
            self.b_to_a.deinit(allocator);
        }

        pub const Iterator = struct {
            inner: Map(A, B, A_Ctx).Iterator,

            pub const Entry = struct {
                a: A,
                b: B,
            };

            pub fn next(self: *Iterator) ?Entry {
                const elem = self.inner.next() orelse return null;

                return Entry{
                    .a = elem.key_ptr.*,
                    .b = elem.value_ptr.*,
                };
            }
        };
    };
}

pub fn UniqueReprBiMap(comptime A: type, comptime B: type, comptime style: MapStyle) type {
    return struct {
        const Self = @This();

        fn Map(comptime X: type, comptime Y: type) type {
            return if (style == .array) UniqueReprArrayMap(X, Y) else UniqueReprMap(X, Y);
        }

        a_to_b: Map(A, B),
        b_to_a: Map(B, A),

        pub const empty = Self{
            .a_to_b = .empty,
            .b_to_a = .empty,
        };

        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = Self{
                .a_to_b = Map(A, B),
                .b_to_a = Map(B, A),
            };
            errdefer self.deinit(allocator);

            return self;
        }

        pub fn count(self: *Self) usize {
            const out = self.a_to_b.count();
            std.debug.assert(out == self.b_to_a.count());
            return out;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.a_to_b.ensureTotalCapacity(allocator, @intCast(capacity));
            try self.b_to_a.ensureTotalCapacity(allocator, @intCast(capacity));
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, capacity: usize) !void {
            try self.a_to_b.ensureUnusedCapacity(allocator, @intCast(capacity));
            try self.b_to_a.ensureUnusedCapacity(allocator, @intCast(capacity));
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.a_to_b.clearRetainingCapacity();
            self.b_to_a.clearRetainingCapacity();
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, a: A, b: B) !void {
            try self.a_to_b.put(allocator, a, b);
            try self.b_to_a.put(allocator, b, a);
        }

        pub fn remove_a(self: *Self, a: A) void {
            const b = self.a_to_b.get(a) orelse return;
            _ = self.a_to_b.remove(a);
            _ = self.b_to_a.remove(b);
        }

        pub fn remove_b(self: *Self, b: B) void {
            const a = self.b_to_a.get(b) orelse return;
            _ = self.b_to_a.remove(b);
            _ = self.a_to_b.remove(a);
        }

        pub fn get_b(self: *Self, a: A) ?B {
            return self.a_to_b.get(a);
        }

        pub fn get_a(self: *Self, b: B) ?A {
            return self.b_to_a.get(b);
        }

        pub fn iterator(self: *Self) Iterator {
            return .{
                .inner = self.a_to_b.iterator(),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.a_to_b.deinit(allocator);
            self.b_to_a.deinit(allocator);
        }

        pub const Iterator = struct {
            inner: Map(A, B).Iterator,

            pub const Entry = struct {
                a: A,
                b: B,
            };

            pub fn next(self: *Iterator) ?Entry {
                const elem = self.inner.next() orelse return null;

                return Entry{
                    .a = elem.key_ptr.*,
                    .b = elem.value_ptr.*,
                };
            }
        };
    };
}

pub fn Visitor(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        visited_values: UniqueReprSet(T),

        /// Create a new visitor using the provided allocator.
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .visited_values = .empty,
            };
        }

        /// Deinitialize the visitor, freeing any allocated memory.
        pub fn deinit(self: *Self) void {
            self.visited_values.deinit(self.allocator);
        }

        /// Clear the visitor set, retaining its capacity.
        pub fn clearVisited(self: *Self) void {
            self.visited_values.clearRetainingCapacity();
        }

        /// Poll the visitor set to see if a value should be visited.
        /// * Returns `true` if the value has not yet been visited, and puts it into the set.
        pub fn visit(self: *Self, value: T) !bool {
            const value_gop = try self.visited_values.getOrPut(self.allocator, value);
            return !value_gop.found_existing;
        }
    };
}

/// Utility for queueing and unqueuing items.
/// * Not suitable for concurrent use.
/// * Not suitable for large or managed data structures.
pub fn VisitorQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        to_visit: ArrayList(T) = .{},
        visited: u64 = 0,

        /// Create a new visitor queue.
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{ .allocator = allocator };
        }

        /// Erase the items in the queue and reset the visited count.
        /// Retains the capacity of the queue.
        pub fn clear(self: *Self) void {
            self.to_visit.clearRetainingCapacity();
            self.visited = 0;
        }

        /// Deinitialize the visitor queue, freeing any allocated memory.
        /// * This leaves the queue in a safe default state, with no items to visit.
        pub fn deinit(self: *Self) void {
            self.to_visit.deinit(self.allocator);
            self.to_visit = .{};
            self.visited = 0;
        }

        /// Add an item to the queue.
        pub fn add(self: *Self, elem: T) error{OutOfMemory}!void {
            for (self.to_visit.items) |id| {
                if (id == elem) return;
            }

            try self.to_visit.append(self.allocator, elem);
        }

        /// Get the next item to visit.
        pub fn visit(self: *Self) ?T {
            if (self.visited >= self.to_visit.items.len) return null;

            const elem = self.to_visit.items[self.visited];

            self.visited += 1;

            return elem;
        }
    };
}

/// Similar to std.heap.MemoryPool, but supports iteration over live items.
pub fn ManagedPool(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: std.heap.ArenaAllocator,
        live_list: UniqueReprSet(*T) = .empty,
        free_list: ArrayList(*T) = .empty,

        /// Create a new ManagedPool backed by the provided allocator.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .arena = .init(allocator),
            };
        }

        /// Deinitialize the ManagedPool, freeing all allocated memory.
        pub fn deinit(self: *Self) void {
            self.live_list.deinit(self.arena.child_allocator);
            self.free_list.deinit(self.arena.child_allocator);
            self.arena.deinit();
        }

        /// Clear the ManagedPool, freeing all live items and retaining capacity.
        pub fn clear(self: *Self) !void {
            var it = self.iterate();
            while (it.next()) |item| {
                try self.free_list.append(self.arena.child_allocator, item);
            }
            self.live_list.clearRetainingCapacity();
        }

        /// Create a new item from the pool.
        pub fn create(self: *Self) !*T {
            if (self.free_list.pop()) |reusable_ptr| {
                return reusable_ptr;
            } else {
                const new_item = try self.arena.allocator().create(T);
                try self.live_list.put(self.arena.child_allocator, new_item, {});
                return new_item;
            }
        }

        /// Destroy an item, returning it to the pool.
        pub fn destroy(self: *Self, item: *T) error{ ItemNotFromPool, OutOfMemory }!void {
            if (!self.live_list.remove(item)) {
                return error.ItemNotFromPool;
            }

            try self.free_list.append(self.arena.child_allocator, item);
        }

        /// Iterate over live items in the pool.
        pub fn iterate(self: *Self) UniqueReprSet(*T).KeyIterator {
            return self.live_list.keyIterator();
        }
    };
}

// Can't use std.SemanticVersion because we need static size
pub const SemVer = struct {
    pub const text_segment_len = 32;

    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    pre: [SemVer.text_segment_len]u8 = [1]u8{0} ** SemVer.text_segment_len,
    build: [SemVer.text_segment_len]u8 = [1]u8{0} ** SemVer.text_segment_len,

    pub fn eql(self: *const SemVer, other: *const SemVer) bool {
        return self.major == other.major and self.minor == other.minor and self.patch == other.patch and std.mem.eql(u8, &self.pre, &other.pre) and std.mem.eql(u8, &self.build, &other.build);
    }

    pub fn hash(self: *const SemVer, hasher: anytype) void {
        hasher.update(std.mem.asBytes(&self.major));
        hasher.update(std.mem.asBytes(&self.minor));
        hasher.update(std.mem.asBytes(&self.patch));
        hasher.update(self.pre);
        hasher.update(self.build);
    }

    pub fn format(self: *const SemVer, writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        const pre_str = std.mem.trimEnd(u8, &self.pre, &.{0});
        if (pre_str.len > 0) {
            try writer.print("-{s}", .{pre_str});
        }
        const build_str = std.mem.trimEnd(u8, &self.build, &.{0});
        if (build_str.len > 0) {
            try writer.print("+{s}", .{build_str});
        }
    }

    pub fn preSlice(self: *const SemVer) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.pre)));
    }

    pub fn buildSlice(self: *const SemVer) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.build)));
    }

    pub fn deserialize(reader: *std.io.Reader) std.io.Reader.Error!SemVer {
        var self = SemVer{};
        self.major = try reader.takeInt(u32, .little);
        self.minor = try reader.takeInt(u32, .little);
        self.patch = try reader.takeInt(u32, .little);

        var writer = std.io.Writer.fixed(&self.pre);
        reader.streamExact(&writer, SemVer.text_segment_len) catch return error.ReadFailed;

        writer = std.io.Writer.fixed(&self.build);
        reader.streamExact(&writer, SemVer.text_segment_len) catch return error.ReadFailed;

        return self;
    }

    pub fn serialize(self: *const SemVer, writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.writeInt(u32, self.major, .little);
        try writer.writeInt(u32, self.minor, .little);
        try writer.writeInt(u32, self.patch, .little);
        try writer.writeAll(&self.pre);
        try writer.writeAll(&self.build);
    }

    pub fn fromStd(std_ver: std.SemanticVersion) SemVer {
        var self = SemVer{
            .major = std_ver.major,
            .minor = std_ver.minor,
            .patch = std_ver.patch,
        };

        if (std_ver.pre) |pre| {
            const len = @min(pre.len, SemVer.text_segment_len - 1);
            @memcpy(self.pre[0..len], pre[0..len]);
        }

        if (std_ver.build) |build| {
            const len = @min(build.len, SemVer.text_segment_len - 1);
            @memcpy(self.build[0..len], build[0..len]);
        }

        return self;
    }

    pub fn toStdBorrowed(self: *const SemVer) std.SemanticVersion {
        const pre = self.preSlice();
        const build = self.buildSlice();
        return std.SemanticVersion{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (pre.len > 0) pre else null,
            .build = if (build.len > 0) build else null,
        };
    }

    pub fn toStdOwned(self: *const SemVer, allocator: std.mem.Allocator) error{OutOfMemory}!std.SemanticVersion {
        const pre = self.preSlice();
        const build = self.buildSlice();

        return std.SemanticVersion{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (pre.len > 0) try std.mem.dupe(allocator, pre) else null,
            .build = if (build.len > 0) try std.mem.dupe(allocator, build) else null,
        };
    }
};
