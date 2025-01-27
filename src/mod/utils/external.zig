const std = @import("std");

pub fn Option(comptime T: type) type {
    return extern struct {
        isSome: bool,
        value: Self.Union,

        const Self = @This();

        pub const Union = extern union {
            Some: T,
            None: struct {},
        };

        pub fn generate_c_repr(name: []const u8, texpr: []const u8, generator: anytype, writer: anytype) anyerror!void {
            _ = texpr;

            const child_name = try generator.findTypeName(T);

            try writer.print("typedef struct {s} {{ bool isSome; {s} some; }} {s};", .{ name, child_name, name });
        }

        pub inline fn fromNative(value: ?T) Self {
            if (value) |v| {
                return Self { .isSome = true, .value = .{ .Some = v } };
            } else {
                return Self.None;
            }
        }

        pub inline fn toNative(self: Self) ?T {
            if (self.isSome) {
                return self.value.Some;
            } else {
                return null;
            }
        }

        pub inline fn Some(value: T) Self {
            return Self{ .isSome = true, .value = .{ .Some = value } };
        }

        pub const None = Self{ .isSome = false, .value = .{ .None = .{} } };
    };
}

pub const UStr = extern struct {
    ptr: [*]const u8,
    len: usize,

    const Self = @This();

    pub inline fn fromNative(slice: []const u8) Self {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }

    pub inline fn toNative(self: Self) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const Hasher = extern struct {
    state: u32,
    proc: Proc,

    const Self = @This();

    pub const Proc = *const fn (state: *u32, byte_buf: [*]const u8, byte_len: usize) callconv(.C) void;

    pub fn initFnv1a32() Self {
        return fromNative(std.hash.Fnv1a_32.init());
    }

    pub fn fromNative(v: anytype) Self {
        const T = @TypeOf(v);

        return Self {
            .state = v.value,
            .proc = &struct {
                fn fun(state: *u32, byte_buf: [*]const u8, byte_len: usize) callconv(.C) void {
                    var nat = T{ .value = state.* };
                    nat.update(byte_buf[0..byte_len]);
                    state.* = nat.value;
                }
            }.fun,
        };
    }

    pub fn toNative(self: Self, comptime T: type) T {
        return T{ .value = self.state };
    }

    pub fn update(self: *Self, bytes: []const u8) void {
        return self.proc(&self.state, bytes.ptr, bytes.len);
    }

    pub fn hash(bytes: []const u8) u32 {
        var hasher = initFnv1a32();
        hasher.update(bytes);
        return hasher.state;
    }

    pub fn final(self: Self) u32 {
        return self.state;
    }
};

pub const Writer = extern struct {
    inner: *const std.io.AnyWriter,

    const Self = @This();

    pub fn init(writer: *const std.io.AnyWriter) Self {
        return Self{ .inner = writer };
    }

    pub fn generate_c_repr(name: []const u8, texpr: []const u8, generator: anytype, writer: anytype) anyerror!void {
        _ = texpr;
        _ = generator;

        try writer.print("typedef struct {s} {{ void* inner; }} {s};", .{ name, name });
    }

    pub fn write(self: Self, bytes: [*]const u8, bytes_len: usize, outBytesWritten: ?*usize) bool {
        const written = self.inner.write(bytes[0..bytes_len]) catch return false;
        if (outBytesWritten) |ptr| {
            ptr.* = written;
        }
        return true;
    }

    pub fn writeAll(self: Self, bytes: [*]const u8, bytes_len: usize) bool {
        self.inner.writeAll(bytes[0..bytes_len]) catch return false;
        return true;
    }

    pub fn print(self: Self, comptime format: []const u8, args: anytype) bool {
        self.inner.print(format, args) catch return false;
        return true;
    }

    pub fn writeByte(self: Self, byte: u8) bool {
        self.inner.writeByte(byte) catch return false;
        return true;
    }

    pub fn writeByteNTimes(self: Self, byte: u8, n: usize) bool {
        self.inner.writeByteNTimes(byte, n) catch return false;
        return true;
    }

    pub fn writeBytesNTimes(self: Self, bytes: [*]const u8, bytes_len: usize, n: usize) bool {
        self.inner.writeBytesNTimes(bytes[0..bytes_len], n) catch return false;
        return true;
    }

    pub inline fn writeInt(self: Self, comptime T: type, value: T, endian: std.builtin.Endian) bool {
        self.inner.writeInt(T, value, endian) catch return false;
        return true;
    }

    pub fn writeStruct(self: Self, value: anytype) bool {
        self.inner.writeStruct(value) catch return false;
        return true;
    }

    pub fn writeStructEndian(self: Self, value: anytype, endian: std.builtin.Endian) bool {
        self.inner.writeStructEndian(value, endian) catch return false;
        return true;
    }

    pub fn writeFile(self: Self, file: std.fs.File) bool {
        self.inner.writeFile(file) catch return false;
        return true;
    }
};

pub fn Union (comptime T: type) type {
    return extern struct {
        tag: Tg,
        value: Un,

        const Self = @This();
        const info = @typeInfo(T).@"union";

        const Tg = info.tag_type.?;
        const Un = @Type(.{.@"union" = .{
            .layout = .@"extern",
            .tag_type = null,
            .fields = info.fields,
        }});

        pub fn fromNative(native: T) Self {
            const activeTag = @as(Tg, native);

            inline for (info.fields) |field| {
                const tag = @field(Tg, field.name);

                if (comptime tag == activeTag) {
                    return Self {
                        .tag = activeTag,
                        .value = @unionInit(Un, field.name, @field(native, field.name))
                    };
                }
            }

            unreachable;
        }

        pub fn toNative(self: Self) T {
            inline for (info.fields) |field| {
                const tag = @field(Tg, field.name);

                if (comptime tag == self.tag) {
                    return @unionInit(T, field.name, @field(self.value, field.name));
                }
            }

            unreachable;
        }
    };
}

pub const Error = enum(std.meta.Int(.unsigned, @sizeOf(anyerror) * 8)) {
    Okay = 0,
    _,

    const Self = @This();

    pub fn generate_c_repr(name: []const u8, texpr: []const u8, generator: anytype, writer: anytype) anyerror!void {
        _ = texpr;

        try writer.print("typedef enum {s} {{ {s}OKAY }} {s};", .{ name, generator.prefix, name });
    }

    pub fn fromNative(e: anyerror) Self {
        return @enumFromInt(@intFromError(e));
    }

    pub fn toNative(self: Self) anyerror {
        return @errorFromInt(@intFromEnum(self));
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
