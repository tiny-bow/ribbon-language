const utils = @This();

const std = @import("std");

pub const log = std.log.scoped(.utils);


pub const ansi = @import("utils/ansi.zig");
pub const external = @import("utils/external.zig");
pub const text = @import("utils/text.zig");
pub const types = @import("utils/types.zig");


pub const Unit = extern struct {};

pub const IOError = std.fs.File.WriteError || std.fs.File.ReadError || std.fs.File.OpenError || error {
    StreamTooLong,
};

pub fn isIOError(err: anyerror) bool {
    if (err == error.Unknown) return false;

    const es = @typeInfo(IOError).error_set
        orelse [0]std.builtin.Type.Error {};

    inline for (es) |e| {
        const err2 = @field(IOError, e.name);
        if (err == err2) return true;
    }

    return false;
}

pub fn asIOError(err: anyerror) ?IOError {
    if (err == error.Unknown) return null;

    const es = @typeInfo(IOError).error_set
        orelse [0]std.builtin.Type.Error {};

    inline for (es) |e| {
        const err2 = @field(IOError, e.name);
        if (err == err2) return err2;
    }

    return null;
}

pub inline fn todo(comptime T: type, _: anytype) T {
    @panic("not yet implemented");
}

pub fn FilteredLogger(comptime scopes: []const u8) fn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    return struct {
        pub fn filteredLogFn(
            comptime level: std.log.Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            comptime var iter = std.mem.tokenizeScalar(u8, scopes, ',');

            inline while (comptime iter.next()) |scopeStr| {
                if (comptime std.mem.eql(u8, @tagName(scope), scopeStr)) {
                    return std.log.defaultLog(level, scope, format, args);
                }
            }
        }
    }.filteredLogFn;
}

pub fn BufferIterator(comptime T: type) type {
    return struct {
        buffer: []const T,
        index: usize,

        pub fn init(buffer: []const T) BufferIterator(T) {
            return BufferIterator(T){
                .buffer = buffer,
                .index = 0,
            };
        }

        pub fn next(self: *BufferIterator(T)) ?T {
            if (self.index >= self.buffer.len) {
                return null;
            }

            const elem = self.buffer[self.index];
            self.index += 1;
            return elem;
        }
    };
}

pub fn captureStackTrace(comptime N: usize, traceAddr: ?usize, allocator: std.mem.Allocator) ![*:0]u8 {
    var buf = std.ArrayList(u8).init(allocator);

    var addresses: [N]usize = [1]usize{0} ** N;
    var trace = std.builtin.StackTrace{
        .index = 0,
        .instruction_addresses = &addresses,
    };

    std.debug.captureStackTrace(traceAddr, &trace);

    try buf.writer().print("{}", .{trace});

    return try buf.toOwnedSliceSentinel(0);
}

pub fn stackAllocator(buf: []u8) std.mem.Allocator {
    const padding = utils.alignmentDelta(@intFromPtr(buf.ptr), @alignOf(std.heap.FixedBufferAllocator));
    const allocRegion = buf[padding .. padding + @sizeOf(std.heap.FixedBufferAllocator)];
    const ptr: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(allocRegion.ptr));
    const memRegion = buf[padding + @sizeOf(std.heap.FixedBufferAllocator) ..];
    ptr.* = std.heap.FixedBufferAllocator.init(memRegion);
    return ptr.allocator();
}

pub fn dumpStackTrace(comptime N: usize, traceAddr: ?usize) void {
    var buf = [1]u8{0} ** (1024 * N + @sizeOf(std.heap.FixedBufferAllocator));
    const alloc = stackAllocator(&buf);
    const trace = utils.captureStackTrace(N, traceAddr, alloc) catch unreachable;
    std.debug.print("{s}", .{trace});
}

pub fn default(comptime T: type) T {
    const info = @typeInfo(T);

    switch (info) {
        .Bool => {
            return false;
        },
        .Int, .Float, .ComptimeInt, .ComptimeFloat => {
            return 0;
        },
        .Optional => {
            return null;
        },
        else => {
            if (comptime std.meta.hasFn(T, "default")) {
                return T.default();
            } else {
                @compileError("Cannot get default value for type `" ++ @typeName(T) ++ "`");
            }
        },
    }
}

pub fn VectorFromArray(comptime T: type) type {
    const Info = @typeInfo(T).array;
    return @Type(.{ .vector = Info });
}

pub fn vectorFromArray(array: anytype) VectorFromArray(@TypeOf(array)) {
    var vector: VectorFromArray(@TypeOf(array)) = undefined;
    for (0..array.len) |i| {
        vector[i] = array[i];
    }
    return vector;
}

pub fn ArrayFromVector(comptime T: type) type {
    const Info = @typeInfo(T).vector;
    return @Type(.{ .array = Info });
}

pub fn arrayFromVector(vector: anytype) ArrayFromVector(@TypeOf(vector)) {
    var array: ArrayFromVector(@TypeOf(vector)) = undefined;
    for (0..vector.len) |i| {
        array[i] = vector[i];
    }
    return array;
}

pub inline fn alignTo(baseAddress: anytype, alignment: @TypeOf(baseAddress)) @TypeOf(baseAddress) {
    return baseAddress + alignmentDelta(baseAddress, alignment);
}

pub inline fn alignmentDelta(baseAddress: anytype, alignment: @TypeOf(baseAddress)) @TypeOf(baseAddress) {
    return (alignment - (baseAddress % alignment)) % alignment;
}

pub inline fn bitOrBool(a: bool, b: bool) bool {
    return @as(u1, @intFromBool(a)) | @as(u1, @intFromBool(b)) == 1;
}

pub inline fn bitAndBool(a: bool, b: bool) bool {
    return @as(u1, @intFromBool(a)) & @as(u1, @intFromBool(b)) == 1;
}

pub inline fn sliceCast(comptime T: type, comptime U: type, buffer: []U) []T {
    const ucount = buffer.len * @sizeOf(U);
    const tcount = ucount / @sizeOf(T);
    const ptr = @intFromPtr(buffer.ptr);
    return @as([*]T, @ptrFromInt(ptr))[0..tcount];
}

pub inline fn sliceCastConst(comptime T: type, comptime U: type, buffer: []const U) []const T {
    const ucount = buffer.len * @sizeOf(U);
    const tcount = ucount / @sizeOf(T);
    const ptr = @intFromPtr(buffer.ptr);
    return @as([*]const T, @ptrFromInt(ptr))[0..tcount];
}

pub inline fn makeSlice(comptime T: type, ptr: [*]T, len: usize) []T {
    return ptr[0..len];
}

pub inline fn makeSliceConst(comptime T: type, ptr: [*]const T, len: usize) []const T {
    return ptr[0..len];
}

pub inline fn byteSlice(value: anytype) []const u8 {
    const info = @typeInfo(@TypeOf(value));
    const T = info.pointer.child;
    comptime std.debug.assert(info.pointer.size == .One);

    const size = @sizeOf(T);

    return @as([*]const u8, @ptrCast(value))[0..size];
}

pub inline fn tryCreateObj(al: std.mem.Allocator, comptime T: type) !*T {
    const obj = try al.create(T);
    obj.* = try T.init(al);
    return obj;
}

pub inline fn createObj(al: std.mem.Allocator, comptime T: type) !*T {
    const obj = try al.create(T);
    obj.* = T.init(al);
    return obj;
}

pub inline fn destroyObj(obj: anytype) void {
    const al = obj.allocator;
    obj.deinit();
    al.destroy(obj);
}

pub inline fn hashRawWith(comptime T: type, hasher: anytype, value: *const T) void {
    return hasher.update(rawBytes(T, value));
}

pub inline fn rawBytes(comptime T: type, value: *const T) []const u8 {
    return @as([*]const u8, @ptrCast(value))[0..@sizeOf(T)];
}

pub fn find(comptime T: type, buf: []const T, value: *const T) ?usize {
    const finder = Finder(T);
    finder.findComp = value;
    defer finder.findComp = null;
    return findWith(T, buf, finder.eqlFind);
}

fn Finder(comptime T: type) type {
    return struct {
        threadlocal var findComp: ?*const T = null;
        fn eqlFind(item: *const T) bool {
            return equal(item, findComp.?);
        }
    };
}

pub fn findWith(comptime T: type, buf: []const T, pred: fn (*const T) bool) ?usize {
    for (0..buf.len) |i| {
        if (pred(&buf[i])) {
            return i;
        }
    }

    return null;
}

pub const SimpleHashContext = struct {
    pub fn hash(_: SimpleHashContext, key: anytype) u32 {
        return utils.fnv1a_32(key);
    }

    pub fn eql(_: SimpleHashContext, a: anytype, b: @TypeOf(a), _: usize) bool {
        return utils.equal(a, b);
    }
};

pub fn fnv1a_32(a: anytype) u32 {
    var hasher = std.hash.Fnv1a_32.init();
    hashWith(&hasher, a);
    return hasher.final();
}

pub fn fnv1a_64(a: anytype) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hashWith(&hasher, a);
    return hasher.final();
}

pub fn fnv1a_128(a: anytype) u128 {
    var hasher = std.hash.Fnv1a_128.init();
    hashWith(&hasher, a);
    return hasher.final();
}

pub fn hashWith(hasher: anytype, a: anytype) void {
    const T = @TypeOf(a);

    log.debug("hashing " ++ @typeName(T), .{});

    if (comptime std.meta.hasFn(T, "hashWith")) {
        return T.hashWith(a, hasher);
    }

    switch (@typeInfo(T)) {
        .void, .undefined, .noreturn => return,
        .error_set => {
            return hashWith(hasher, @intFromError(a));
        },
        .bool, .int, .float, .comptime_int, .comptime_float => {
            return hashRawWith(T, hasher, &a);
        },
        .@"enum" => {
            return hashWith(hasher, @intFromEnum(a));
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                hashWith(hasher, @field(a, field.name));
            }
        },
        .@"union" => |info| {
            if (info.tag_type) |TT| {
                const tag = @as(TT, a);
                hashWith(hasher, tag);
                inline for (info.fields) |field| {
                    if (tag == @field(TT, field.name)) {
                        return hashWith(hasher, @field(a, field.name));
                    }
                }
                unreachable;
            } else if (info.layout == .@"packed") {
                const I = std.meta.Int(.unsigned, @bitSizeOf(T));
                const aInt: I = @bitCast(a);
                return hashWith(hasher, aInt);
            } else {
                @compileError("Cannot do compare for union type `" ++ @typeName(T) ++ "` without tag or packed layout");
            }
        },
        .optional => {
            if (a) |ax| {
                return hashWith(hasher, ax);
            } else {
                return hasher.update("\x00N\x00U\x00L\x00L\x00");
            }
        },
        .pointer => |info| {
            switch (info.size) {
                .One, .C => {
                    if (info.child == anyopaque
                    or @typeInfo(info.child) == .@"fn") {
                        return hashWith(hasher, @intFromPtr(a));
                    } else {
                        return hashWith(hasher, a.*);
                    }
                },
                .Slice => {
                    hashWith(hasher, a.len);
                    if (info.child == u8) {
                        return hasher.update(a);
                    }

                    for (a) |xa| {
                        hashWith(hasher, xa);
                    }
                },
                else => {
                    return hashWith(hasher, @intFromPtr(a));
                },
            }
        },
        .array => |info| {
            hashWith(hasher, info.len);

            if (info.child == u8) {
                return hasher.update(&a);
            }

            for (a) |xa| {
                hashWith(hasher, xa);
            }
        },
        else => {
            @compileError("Cannot do hash for type `" ++ @typeName(T) ++ "`");
        },
    }
}

pub const Ordering = enum(u8) {
    Less,
    Equal,
    Greater,
};

pub fn partialCompareSlice(a: anytype, b: @TypeOf(a)) ?Ordering {
    if (a.len < b.len) {
        return .Less;
    } else if (a.len > b.len) {
        return .Greater;
    }

    for (0..a.len) |i| {
        if (compare(a[i], b[i])) |ord| {
            if (ord != .Equal) {
                return ord;
            }
        } else {
            return null;
        }
    }

    return .Equal;
}

pub fn CompareResult(comptime T: type) type {
    if (comptime std.meta.hasFn(T, "compare")) {
        switch (@typeInfo(@TypeOf(@field(T, "compare")))) {
            .@"fn" => |info| return info.return_type.?,
            .pointer => |info| return @typeInfo(info.child).@"fn".return_type.?,
            else => @compileError("Invalid compare function type"),
        }
    } else {
        return Ordering;
    }
}

pub fn compare(a: anytype, b: @TypeOf(a)) CompareResult(@TypeOf(a)) {
    const T = @TypeOf(a);

    if (comptime std.meta.hasFn(T, "compare")) {
        return T.compare(a, b);
    }

    switch (@typeInfo(T)) {
        .void, .undefined, .noreturn => return Ordering.Equal,
        .error_set => {
            if (a == b) {
                return Ordering.Equal;
            } else if (@intFromError(a) < @intFromError(b)) {
                return Ordering.Less;
            } else {
                return Ordering.Greater;
            }
        },
        .bool => {
            if (a == b) {
                return Ordering.Equal;
            } else if (a) {
                return Ordering.Greater;
            } else {
                return Ordering.Less;
            }
        },
        .int, .float, .comptime_int, .comptime_float, .vector => {
            if (a < b) {
                return Ordering.Less;
            } else if (a > b) {
                return Ordering.Greater;
            } else {
                return Ordering.Equal;
            }
        },
        .@"enum" => {
            if (@intFromEnum(a) < @intFromEnum(b)) {
                return Ordering.Less;
            } else if (@intFromEnum(a) > @intFromEnum(b)) {
                return Ordering.Greater;
            } else {
                return Ordering.Equal;
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                const result = compare(@field(a, field.name), @field(b, field.name));
                if (result != Ordering.Equal) {
                    return result;
                }
            }
            return Ordering.Equal;
        },
        .@"union" => |info| {
            if (info.tag_type) |TT| {
                const tagA = @as(TT, a);
                const tagB = @as(TT, b);
                const result = compare(tagA, tagB);
                if (result == Ordering.Equal) {
                    inline for (info.fields) |field| {
                        if (tagA == @field(TT, field.name)) {
                            return compare(@field(a, field.name), @field(b, field.name));
                        }
                    }
                }
                return result;
            } else if (info.layout == .@"packed") {
                const I = std.meta.Int(.unsigned, @bitSizeOf(T));
                const aInt: I = @bitCast(a);
                const bInt: I = @bitCast(b);
                return compare(aInt, bInt);
            } else {
                @compileError("Cannot do compare for union type `" ++ @typeName(T) ++ "` without tag or packed layout");
            }
        },
        .optional => {
            if (a == null) {
                if (b == null) {
                    return Ordering.Equal;
                } else {
                    return Ordering.Less;
                }
            } else if (b == null) {
                return Ordering.Greater;
            } else {
                return compare(a.?, b.?);
            }
        },
        .pointer => |info| {
            switch (info.size) {
                .One, .C => {
                    if (@intFromPtr(a) == @intFromPtr(b)) {
                        return Ordering.Equal;
                    } else if (info.child == anyopaque or (@typeInfo(info.child) == .@"fn")) {
                        return compare(@intFromPtr(a), @intFromPtr(b));
                    } else {
                        return compare(a.*, b.*);
                    }
                },
                .Slice => {
                    if (@intFromPtr(a.ptr) == @intFromPtr(b.ptr)) {
                        return Ordering.Equal;
                    } else if (a.len < b.len) {
                        return Ordering.Less;
                    } else if (a.len > b.len) {
                        return Ordering.Greater;
                    } else {
                        for (0..a.len) |i| {
                            const result = compare(a[i], b[i]);
                            if (result != Ordering.Equal) {
                                return result;
                            }
                        }
                        return Ordering.Equal;
                    }
                },
                .Many =>
                    if (comptime info.sentinel) |sentinel| {
                        const sent = @as(*const info.child, @ptrCast(sentinel)).*;
                        var i: usize = 0;
                        while (true) {
                            if (a[i] == sent) {
                                if (b[i] == sent) {
                                    return Ordering.Equal;
                                } else {
                                    return Ordering.Less;
                                }
                            } else if (b[i] == sent) {
                                return Ordering.Greater;
                            }
                            const result = compare(a[i], b[i]);
                            if (result != Ordering.Equal) {
                                return result;
                            }
                            i += 1;
                        }
                    } else return compare(@intFromPtr(a), @intFromPtr(b)),
            }
        },
        .array => |info| {
            for (0..info.len) |i| {
                const result = compare(a[i], b[i]);
                if (result != Ordering.Equal) {
                    return result;
                }
            }
            return Ordering.Equal;
        },
        else => @compileError("Cannot do compare for type `" ++ @typeName(T) ++ "`"),
    }
}

pub fn compareAddress(a: anytype, b: @TypeOf(a)) Ordering {
    const T = @TypeOf(a);

    if (comptime std.meta.hasFn(T, "compareAddress")) {
        return T.compareAddress(a, b);
    }

    switch (@typeInfo(T)) {
        .void, .undefined, .noreturn => return Ordering.Equal,
        .error_set => {
            if (a == b) {
                return Ordering.Equal;
            } else if (@intFromError(a) < @intFromError(b)) {
                return Ordering.Less;
            } else {
                return Ordering.Greater;
            }
        },
        .bool => {
            if (a == b) {
                return Ordering.Equal;
            } else if (a) {
                return Ordering.Greater;
            } else {
                return Ordering.Less;
            }
        },
        .int, .float, .comptime_int, .comptime_float, .vector => {
            if (a < b) {
                return Ordering.Less;
            } else if (a > b) {
                return Ordering.Greater;
            } else {
                return Ordering.Equal;
            }
        },
        .@"enum" => {
            if (@intFromEnum(a) < @intFromEnum(b)) {
                return Ordering.Less;
            } else if (@intFromEnum(a) > @intFromEnum(b)) {
                return Ordering.Greater;
            } else {
                return Ordering.Equal;
            }
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                const result = compareAddress(@field(a, field.name), @field(b, field.name));
                if (result != Ordering.Equal) {
                    return result;
                }
            }
            return Ordering.Equal;
        },
        .@"union" => |info| {
            if (info.tag_type) |TT| {
                const tagA = @as(TT, a);
                const tagB = @as(TT, b);
                const result = compareAddress(tagA, tagB);
                if (result == Ordering.Equal) {
                    inline for (info.fields) |field| {
                        if (comptime tagA == @field(TT, field.name)) {
                            return compareAddress(@field(a, field.name), @field(b, field.name));
                        }
                    }
                }
                return result;
            } else if (info.layout == .@"packed") {
                const I = std.meta.Int(.unsigned, @bitSizeOf(T));
                const aInt: I = @bitCast(a);
                const bInt: I = @bitCast(b);
                return compareAddress(aInt, bInt);
            } else {
                @compileError("Cannot do compareAddress for union type `" ++ @typeName(T) ++ "` without tag or packed layout");
            }
        },
        .optional => {
            if (a == null) {
                if (b == null) {
                    return Ordering.Equal;
                } else {
                    return Ordering.Less;
                }
            } else if (b == null) {
                return Ordering.Greater;
            } else {
                return compare(a.?, b.?);
            }
        },
        .pointer => |info| {
            switch (info.size) {
                .One, .C, .Many => return compare(@intFromPtr(a), @intFromPtr(b)),
                .Slice => return compare(@intFromPtr(a.ptr), @intFromPtr(b.ptr)),
            }
        },
        .array => |info| {
            for (0..info.len) |i| {
                const result = compareAddress(a[i], b[i]);
                if (result != Ordering.Equal) {
                    return result;
                }
            }
            return Ordering.Equal;
        },
        else => @compileError("Cannot do compareAddress for type `" ++ @typeName(T) ++ "`"),
    }
}

pub inline fn less(a: anytype, b: @TypeOf(a)) bool {
    return compare(a, b) == Ordering.Less;
}

pub inline fn greater(a: anytype, b: @TypeOf(a)) bool {
    return compare(a, b) == Ordering.Greater;
}

pub inline fn greaterOrEqual(a: anytype, b: @TypeOf(a)) bool {
    return compare(a, b) != Ordering.Less;
}

pub inline fn lessOrEqual(a: anytype, b: @TypeOf(a)) bool {
    return compare(a, b) != Ordering.Greater;
}

pub inline fn equal(a: anytype, b: @TypeOf(a)) bool {
    return compare(a, b) == Ordering.Equal;
}

pub inline fn notEqual(a: anytype, b: @TypeOf(a)) bool {
    return compare(a, b) != Ordering.Equal;
}

pub inline fn lessAddress(a: anytype, b: @TypeOf(a)) bool {
    return compareAddress(a, b) == Ordering.Less;
}

pub inline fn greaterAddress(a: anytype, b: @TypeOf(a)) bool {
    return compareAddress(a, b) == Ordering.Greater;
}

pub inline fn greaterOrEqualAddress(a: anytype, b: @TypeOf(a)) bool {
    return compareAddress(a, b) != Ordering.Less;
}

pub inline fn lessOrEqualAddress(a: anytype, b: @TypeOf(a)) bool {
    return compareAddress(a, b) != Ordering.Greater;
}

pub inline fn equalAddress(a: anytype, b: @TypeOf(a)) bool {
    return compareAddress(a, b) == Ordering.Equal;
}

pub inline fn notEqualAddress(a: anytype, b: @TypeOf(a)) bool {
    return compareAddress(a, b) != Ordering.Equal;
}

test {
    std.testing.refAllDeclsRecursive(@This());

    const expectEqual = std.testing.expectEqual;

    {
        var mem = [1]u128{0} ** 4;
        const buf: []u128 = &mem;

        const res = sliceCast(u8, u128, buf);

        try expectEqual(@intFromPtr(buf.ptr), @intFromPtr(res.ptr));
        try expectEqual(buf.len * @sizeOf(u128), res.len);
    }

    {
        const mem = [1]u128{0} ** 4;
        const buf: []const u128 = &mem;

        const res = sliceCastConst(u8, u128, buf);

        try expectEqual(@intFromPtr(buf.ptr), @intFromPtr(res.ptr));
        try expectEqual(buf.len * @sizeOf(u128), res.len);
    }
}
