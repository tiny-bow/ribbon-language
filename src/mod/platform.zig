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
//! Configuration variables that apply to all of Ribbon are also stored here,
//! within the `config` sub-namespace.
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
const Fingerprint = @import("Fingerprint");
const build_info = @import("build_info");
const std = @import("std");

const log = std.log.scoped(.platform);

test {
    std.testing.refAllDecls(@This());
}

/// The exact semantic version of the Ribbon language this module was built for.
pub const VERSION = build_info.version;

/// The fingerprint of the build that produced this module.
pub const BUILD_FINGERPRINT = Fingerprint { .value = build_info.raw_fingerprint };

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
    sys_v, win,

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
    .Debug, .ReleaseSafe, => true,
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
pub const VirtualMemory = []const align(std.heap.page_size_min) u8;

/// The type of mutable virtual memory regions allocated with posix.
pub const MutVirtualMemory = []align(std.heap.page_size_min) u8;

pub const ArrayList = std.ArrayListUnmanaged;

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


pub fn UniqueReprMap(comptime K: type, comptime V: type, LOAD_PERCENTAGE: u64) type {
    return HashMap(K, V, UniqueReprHashContext64(K), LOAD_PERCENTAGE);
}

pub fn UniqueReprSet(comptime T: type, LOAD_PERCENTAGE: u64) type {
    return HashSet(T, UniqueReprHashContext64(T), LOAD_PERCENTAGE);
}

pub fn UniqueReprArrayMap(comptime K: type, comptime V: type, comptime RETAIN_HASH: bool) type {
    return ArrayMap(K, V, UniqueReprHashContext64(K), RETAIN_HASH);
}

pub fn UniqueReprArraySet(comptime T: type, comptime RETAIN_HASH: bool) type {
    return ArraySet(T, UniqueReprHashContext64(T), RETAIN_HASH);
}

/// Provides a 32-bit hash context for types with unique representation. See `std.meta.hasUniqueRepresentation`.
pub fn UniqueReprHashContext32(comptime T: type) type {
    if (comptime !std.meta.hasUniqueRepresentation(T)) {
        @compileError("IdentityHashContext32: type `" ++ @typeName(T) ++ "` must have unique representation");
    }
    return struct {
        pub fn eql(_: @This(), a: T, b: T) bool {
            return a == b;
        }

        pub fn hash(_: @This(), value: T) u32 {
            return hash32(@as([*]u8, @ptrCast(&value))[0..@sizeOf(T)]);
        }
    };
}

/// Provides a 64-bit hash context for types with unique representation. See `std.meta.hasUniqueRepresentation`.
pub fn UniqueReprHashContext64(comptime T: type) type {
    if (comptime !std.meta.hasUniqueRepresentation(T)) {
        @compileError("IdentityHashContext64: type `" ++ @typeName(T) ++ "` must have unique representation");
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


/// Represents the alignment of a value type; the max alignment is the minimum page size supported.
///
/// `0` is not an applicable *machine* alignment, but may appear in some cases, such as on zero-sized types.
/// It generally indicates a lack of a need for an address,
/// while an alignment of `1` indicates an address is required, but it may be totally arbitrary.
/// Successive integers (generally powers of two) indicate that proper use of a data structure
/// relies on being placed at an address that is a multiple of that value.
pub const Alignment: type = std.math.IntFittingRange(0, MAX_ALIGNMENT);

/// Offsets an address to the next multiple of the provided alignment, if it is not already aligned.
pub fn alignTo(address: anytype, alignment: anytype) @TypeOf(address) {
    return address + @call(.always_inline, alignDelta, .{address, alignment});
}

/// Calculates the offset necessary to increment an address to the next multiple of the provided alignment.
pub fn alignDelta(address: anytype, alignment: anytype) @TypeOf(address) {
    comptime var T = @TypeOf(address);
    comptime var A = @TypeOf(alignment);
    comptime var isComptime = false;
    if (comptime T == comptime_int or A == comptime_int) {
        T = usize;
        A = usize;
        isComptime = true;
    }

    const I = std.meta.Int(.unsigned, @bitSizeOf(T));
    const U = std.meta.Int(.unsigned, @max(@bitSizeOf(T), @bitSizeOf(A)));
    const tInfo = @typeInfo(T);

    const ptr: U = if (comptime tInfo == .pointer) @intFromPtr(address) else if (comptime !isComptime) @as(I, @bitCast(address)) else @intCast(address);
    const aln: U = alignment;

    const alnMask: U = aln - 1;
    const delta: U = (aln - (ptr & alnMask)) & alnMask;

    if (comptime tInfo == .pointer) {
        return @ptrFromInt(delta);
    } else if (comptime @bitSizeOf(T) < @bitSizeOf(U)) {
        return @intCast(delta);
    } else {
        return delta;
    }
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
        else =>
            if (@bitSizeOf(T) <= 32) f32
            else f64,
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
    return kilobytesFromBytes(bytes) / 1024.0;
}

/// Converts bytes to gigabytes.
pub fn gigabytesFromBytes(bytes: anytype) FloatOrDouble(@TypeOf(bytes)) {
    return megabytesFromBytes(bytes) / 1024.0;
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
pub const EnumLiteral = @Type(.enum_literal);

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


/// Represents a type ID.
pub const TypeId = packed struct {
    /// The type name.
    value: ?[*:0]const u8,

    pub fn of(comptime T: type) TypeId {
        const static = struct { const value = @typeName(T); };
        return .{.value = static.value };
    }

    pub fn typename(self: TypeId) ?[*:0]const u8 {
        return self.value;
    }
};

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


pub fn stream(reader: anytype, writer: anytype) !void {
    while (true) {
        const byte: u8 = reader.readByte() catch return;
        try writer.writeByte(byte);
    }
}

