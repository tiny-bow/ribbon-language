//! # platform
//! The platform module is a namespace that provides various constants, types, and utility functions
//! that are essential across the Ribbon programming language implementation.
//!
//! This module includes many comptime-accessible definitions for
//! stack sizes, register sizes, alignment values, and other platform-specific parameters.
//! It provides low-level utility functions for memory alignment, type information, and hashing,
//! and serves as a namespace for small common items that are not found in the zig std library,
//! or for raising std library items from deeply nested namespaces.
//!
//! * **Stack Sizes** - sizes for data, call, and set stacks
//! * **Register Sizes** - sizes for registers in bits and bytes, and the maximum number of registers
//! * **Alignment** - constants and functions for memory alignment
//! * **Type Information** - utilities for working with type information and type IDs
//! * **Hashing** - functions for computing
//! [FNV-1a](https://en.wikipedia.org/wiki/Fowler%E2%80%93Noll%E2%80%93Vo_hash_function)
//! hashes from byte slices
//! * **Debugging** - utilities for capturing stack traces and source locations
const platform = @This();
const build_info = @import("build_info");
const std = @import("std");

const log = std.log.scoped(.platform);

test {
    std.testing.refAllDecls(@This());
}

/// The exact semantic version of the Ribbon language this module was built for.
pub const VERSION = build_info.version;

/// The size of a virtual opcode, in bytes.
pub const OPCODE_SIZE = 2;

/// The size of a virtual opcode, in bits.
pub const OPCODE_SIZE_BITS = bitsFromBytes(OPCODE_SIZE);

/// The alignment of bytecode instructions.
pub const BYTECODE_ALIGNMENT = 8;

/// The size of the data stack in words.
pub const DATA_STACK_SIZE = bytesFromMegabytes(1) / 8;
/// The size of the call stack in frames.
pub const CALL_STACK_SIZE = 1024;
/// The size of the set stack in frames.
pub const SET_STACK_SIZE = 4096;

/// The size of a register in bits.
pub const REGISTER_SIZE_BITS = 64;
/// The size of a register in bytes.
pub const REGISTER_SIZE_BYTES = 8;
/// The maximum number of registers.
pub const MAX_REGISTERS = 255;
/// The maximum number of unique effect types within a ribbon runtime instance.
pub const MAX_EFFECT_TYPES = std.math.maxInt(u16);

// The number of bits used for symbolic identity of module level values.
pub const STATIC_ID_BITS = bitsFromBytes(STATIC_ID_BYTES);
/// The number of bytes used for symbolic identity of module level values.
pub const STATIC_ID_BYTES = 4;
/// The number of bits used for symbolic identity of local values.
pub const LOCAL_ID_BITS = bitsFromBytes(LOCAL_ID_BYTES);
/// The number of bytes used for symbolic identity of local values.
pub const LOCAL_ID_BYTES = 2;

/// The maximum alignment value.
pub const MAX_ALIGNMENT = 4096;

/// The maximum size of a bytecode section.
pub const MAX_VIRTUAL_CODE_SIZE = bytesFromMegabytes(64);

/// The maximum size of a jit-compiled machine code section.
pub const MAX_MACHINE_CODE_SIZE = bytesFromMegabytes(64);

/// The C ABI we're using.
pub const ABI: Abi = if (@import("builtin").os.tag == .windows) .win else .sys_v;

/// Description of the C ABI used by the current hardware.
pub const Abi = enum {
    sys_v,
    win,

    /// The number of registers used for passing arguments under this Abi.
    pub fn argumentRegisterCount(self: Abi) usize {
        return switch (self) {
            .sys_v => 6,
            .win => 4,
        };
    }
};

/// The maximum number of arguments we allow to be passed in `callForeign`.
pub const MAX_FOREIGN_ARGUMENTS = 16;

/// Call a foreign function with a dynamic number of arguments.
/// * It is (debug safety-checked) undefined behavior to call this function with slices of a length more than `MAX_FOREIGN_ARGUMENTS`.
pub fn callForeign(fnPtr: *const anyopaque, args: []const usize) usize {
    return switch (args.len) {
        0 => @as(*const fn () usize, @alignCast(@ptrCast(fnPtr)))(),
        1 => @as(*const fn (usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0]),
        2 => @as(*const fn (usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1]),
        3 => @as(*const fn (usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2]),
        4 => @as(*const fn (usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3]),
        5 => @as(*const fn (usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4]),
        6 => @as(*const fn (usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        9 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8]),
        10 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9]),
        11 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10]),
        12 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11]),
        13 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12]),
        14 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13]),
        15 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14]),
        16 => @as(*const fn (usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize, usize) usize, @alignCast(@ptrCast(fnPtr)))(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8], args[9], args[10], args[11], args[12], args[13], args[14], args[15]),
        else => unreachable,
    };
}

/// Whether runtime safety checks are enabled.
pub const RUNTIME_SAFETY: bool = switch (@import("builtin").mode) {
    .Debug,
    .ReleaseSafe,
    => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// The size of a page.
pub const PAGE_SIZE = std.heap.pageSize();

comptime {
    if (PAGE_SIZE < MAX_ALIGNMENT) {
        @compileError("Unsupported target; the page size must be comptime known, and at least as large as MAX_ALIGNMENT");
    }
}

/// Utf-32 codepoint (`u21`).
pub const Char: type = u21;

/// The type of constant virtual memory regions allocated with posix.
pub const VirtualMemory = []align(std.heap.page_size_min) const u8;

/// The type of mutable virtual memory regions allocated with posix.
pub const MutVirtualMemory = []align(std.heap.page_size_min) u8;

pub const ArrayList = std.ArrayListUnmanaged;
pub const MultiArrayList = std.MultiArrayList;

pub const ArrayMap = std.ArrayHashMapUnmanaged;

/// A dynamic array based hash table of keys where the values are void. Each key is stored sequentially.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `ArrayMap` for detailed documentation.
pub fn ArraySet(comptime T: type, comptime Ctx: type, comptime RETAIN_HASH: bool) type {
    return ArrayMap(T, void, Ctx, RETAIN_HASH);
}

pub const HashMap = std.HashMapUnmanaged;

/// A hash table based on open addressing and linear probing. The values are void.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `HashMap` for detailed docs.
pub fn HashSet(comptime T: type, comptime Ctx: type, comptime LOAD_PERCENTAGE: u64) type {
    return HashMap(T, void, Ctx, LOAD_PERCENTAGE);
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
pub const StringArraySet = std.StringArrayHashMapUnmanaged(void);

/// String map type. The values are void.
///
/// Key memory is managed by the caller. Keys will not automatically be freed.
///
/// Default initialization of this struct is deprecated; use `.empty` instead.
///
/// See `HashSet` for detailed docs.
pub fn StringSet(comptime Ctx: type, comptime LOAD_PERCENTAGE: u64) type {
    return StringMap(void, Ctx, LOAD_PERCENTAGE);
}

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

pub fn UniqueReprMap(comptime K: type, comptime V: type, LOAD_PERCENTAGE: u64) type {
    return HashMap(K, V, UniqueReprHashContext64(K), LOAD_PERCENTAGE);
}

pub fn UniqueReprSet(comptime T: type, LOAD_PERCENTAGE: u64) type {
    return HashSet(T, UniqueReprHashContext64(T), LOAD_PERCENTAGE);
}

pub fn UniqueReprArrayMap(comptime K: type, comptime V: type, comptime RETAIN_HASH: bool) type {
    return ArrayMap(K, V, UniqueReprHashContext32(K), RETAIN_HASH);
}

pub fn UniqueReprArraySet(comptime T: type, comptime RETAIN_HASH: bool) type {
    return ArraySet(T, UniqueReprHashContext32(T), RETAIN_HASH);
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

/// Represents the alignment of a value type; the max alignment is the minimum page size supported.
///
/// `0` is not an applicable *machine* alignment, but may appear in some cases, such as on zero-sized types.
/// It generally indicates a lack of a need for an address,
/// while an alignment of `1` indicates an address is required, but it may be totally arbitrary.
/// Successive integers (generally powers of two) indicate that proper use of a data structure
/// relies on being placed at an address that is a multiple of that value.
pub const Alignment: type = std.math.IntFittingRange(0, MAX_ALIGNMENT);

/// Represents the size of a value type; the max size is determined by the maximum alignment's bit representation.
pub const Size: type = std.meta.Int(.unsigned, 64 - @bitSizeOf(Alignment));

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

/// Represents the bit size of an integer type; we allow arbitrary bit-width integers, from 0 up to the max `Alignment`.
pub const IntegerBitSize: type = std.math.IntFittingRange(0, MAX_ALIGNMENT);

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

/// Extrapolates an error union type.
pub fn ExtrapolatePointer(comptime P: type, comptime C: type) type {
    var P_info = @typeInfo(P);

    P_info.pointer.child = C;
    P_info.pointer.size = .one;

    return @Type(P_info);
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

/// A type id, which is a unique identifier for a *Zig* type.
pub const TypeId = packed struct {
    ptr: [*:0]const u8,

    /// Create a type id from a comptime-known Zig type.
    pub fn of(comptime T: type) TypeId {
        return .{ .ptr = @typeName(T) };
    }

    /// Determine if a type id is the id of a specific type.
    pub fn is(self: TypeId, comptime T: type) bool {
        return self.ptr == @typeName(T);
    }
};

/// A type-erased pointer to any type, used for binding arbitrary data in user-defined nodes.
/// * Does not imply ownership of the type-erased value.
pub const Any = packed struct {
    /// The type id of the value stored in this `Any`.
    type_id: TypeId,
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
            .type_id = TypeId.of(T),
            .ptr = @ptrCast(value),
        };
    }

    /// Convert this `Any` to a pointer of type `T`, if the type matches.
    /// * The type must be a pointer type, otherwise this will fail at compile time.
    pub fn to(self: Any, comptime T: type) ?*T {
        if (TypeId.of(T).ptr != self.type_id.ptr) return null;

        return @alignCast(@ptrCast(self.ptr));
    }

    /// Convert this `Any` to a pointer of type `T`. Only checks the type id in safe modes.
    /// * The type must be a pointer type, otherwise this will fail at compile time.
    pub fn force(self: Any, comptime T: type) *T {
        if (comptime RUNTIME_SAFETY) {
            if (TypeId.of(T).ptr != self.type_id.ptr) {
                @compileError("Cannot convert Any to " ++ @typeName(T) ++ ", type mismatch");
            }
        }

        return @alignCast(@ptrCast(self.ptr));
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

pub fn stream(reader: anytype, writer: anytype) !void {
    while (true) {
        const byte: u8 = reader.readByte() catch return;
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
    var failures = std.ArrayList(usize).init(std.heap.page_allocator);
    defer failures.deinit();

    testing: for (tests, 0..) |t, i| {
        log.info("test {}/{}", .{ i, tests.len });
        const input = t.input;

        if (t.expect) |expect_str| {
            test_func(input, expect_str) catch |err| {
                log.err("input {s} failed: {}", .{ input, err });
                failures.append(i) catch unreachable;
                continue :testing;
            };

            log.info("input {s} succeeded: {s}", .{ input, expect_str });
        } else |expect_err| {
            std.debug.assert(expect_err != error.TestFailure);

            const maybe_err = test_func(input, "");
            if (maybe_err) |_| { // void
                log.err("input {s} succeeded; but expected {}", .{ input, expect_err });
                failures.append(i) catch unreachable;
            } else |err| {
                if (err == error.TestFailure or err == error.TestExpectedEqual) {
                    log.err("input {s} succeeded, but the output was wrong; expected {}", .{ input, expect_err });
                    failures.append(i) catch unreachable;
                } else if (expect_err != err) {
                    log.err("input {s} failed: {}; but expected {}", .{ input, err, expect_err });
                    failures.append(i) catch unreachable;
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
            return if (style == .array) ArrayMap(X, Y, C, false) else HashMap(X, Y, C, 80);
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
            return if (style == .array) UniqueReprArrayMap(X, Y, false) else UniqueReprMap(X, Y, 80);
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
                .a_to_b = Map(A, B, 80),
                .b_to_a = Map(B, A, 80),
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
        visited_values: UniqueReprSet(T, 80),

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .visited_values = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.visited_values.deinit(self.allocator);
        }

        pub fn clearVisited(self: *Self) void {
            self.visited_values.clearRetainingCapacity();
        }

        pub fn visit(self: *Self, value: T) !bool {
            const value_gop = try self.visited_values.getOrPut(self.allocator, value);
            return value_gop.found_existing;
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
