const Formatter = @This();

const std = @import("std");
const TypeUtils = @import("Utils").Type;

const Core = @import("../Core.zig");

state: *State,

pub const Error = anyerror;

const State = struct {
    ir: *const Core.IR,
    module: ?*const Core.Module = null,
    function: ?*const Core.Function = null,

    writer: std.io.AnyWriter,

    indent_size: u4 = 4,
    indent_level: u8 = 0,

    type_mode: TypeMode = .name_only,
    show_ids: bool = false,
    show_indices: bool = true,
    show_opcodes: bool = true,
    show_encoded: bool = true,
};

pub const TypeMode = enum { name_only, full };

pub fn Wrap (comptime T: type) type {
    return struct {
        const Self = @This();

        formatter: Formatter,
        data: T,

        pub fn format(self: Self, comptime _: []const u8, _: anytype, _: anytype) !void {
            return self.formatter.fmt(self.data);
        }
    };
}

pub fn SliceWrap (comptime T: type) type {
    return struct {
        const Self = @This();

        formatter: Formatter,
        data: []const T,

        pub fn format(self: Self, comptime _: []const u8, _: anytype, _: anytype) !void {
            self.formatter.commaList(self.data);
        }
    };
}

pub fn wrap(self: Formatter, data: anytype) Wrap(@TypeOf(data)) {
    return Wrap(@TypeOf(data)) { .formatter = self, .data = data };
}

pub fn sliceWrap(self: Formatter, data: anytype) SliceWrap(@TypeOf(data)) {
    return SliceWrap(@TypeOf(data)) { .formatter = self, .data = data };
}

pub fn init(ir: *Core.IR, writer: std.io.AnyWriter) error{OutOfMemory}! Formatter {
    const state = try ir.allocator.create(State);
    state.* = State { .ir = ir, .writer = writer };
    return Formatter { .state = state };
}

pub fn deinit(self: Formatter) void {
    self.state.ir.allocator.destroy(self.state);
}

pub fn getIR(self: Formatter) *const Core.IR {
    return self.state.ir;
}

pub fn setModule(self: Formatter, module: ?*const Core.Module) ?*const Core.Module {
    const oldModule = self.state.module;
    self.state.module = module;
    return oldModule;
}

pub fn getModule(self: Formatter) !*const Core.Module {
    return self.state.module orelse error.NoFormatterActiveModule;
}

pub fn setFunction(self: Formatter, function: ?*const Core.Function) ?*const Core.Function {
    const oldFunction = self.state.function;
    self.state.function = function;
    return oldFunction;
}

pub fn getFunction(self: Formatter) !*const Core.Function {
    return self.state.function orelse error.NoFormatterActiveFunction;
}

pub fn setTypeMode(self: Formatter, mode: TypeMode) TypeMode {
    const oldTypeMode = self.state.type_mode;
    self.state.type_mode = mode;
    return oldTypeMode;
}

pub fn getTypeMode(self: Formatter) TypeMode {
    return self.state.type_mode;
}

pub fn setShowIds(self: Formatter, showIds: bool) bool {
    const oldShowIds = self.state.show_ids;
    self.state.show_ids = showIds;
    return oldShowIds;
}

pub fn getShowIds(self: Formatter) bool {
    return self.state.show_ids;
}

pub fn setShowIndices(self: Formatter, showIndices: bool) bool {
    const oldShowIndices = self.state.show_indices;
    self.state.show_indices = showIndices;
    return oldShowIndices;
}

pub fn getShowIndices(self: Formatter) bool {
    return self.state.show_indices;
}

pub fn setShowOpCodes(self: Formatter, showOpCodes: bool) bool {
    const oldShowOpCodes = self.state.show_opcodes;
    self.state.show_opcodes = showOpCodes;
    return oldShowOpCodes;
}

pub fn getShowOpCodes(self: Formatter) bool {
    return self.state.show_opcodes;
}

pub fn setShowEncoded(self: Formatter, showEncoded: bool) bool {
    const oldShowEncoded = self.state.show_encoded;
    self.state.show_encoded = showEncoded;
    return oldShowEncoded;
}

pub fn getShowEncoded(self: Formatter) bool {
    return self.state.show_encoded;
}

pub fn fmt(self: Formatter, value: anytype) Error! void {
    const T = @TypeOf(value);

    if (std.meta.hasMethod(T, "onFormat")) {
        try value.onFormat(self);
    } else switch(T) {
        Core.ModuleId => {
            const x = self.wrap((try self.getIR().getModule(value)).name);
            if (self.getShowIds()) try self.print("({}#{})", .{@intFromEnum(value), x})
            else try self.fmt(x);
        },
        Core.TypeId => {
            const x = self.wrap(try self.getIR().getType(value));
            if (self.getShowIds()) try self.print("({}#{})", .{@intFromEnum(value), x})
            else try self.fmt(x);
        },
        Core.BlockId => {
            const x = self.wrap((try (try self.getFunction()).getBlock(value)).name);
            if (self.getShowIds()) try self.print("({}#{})", .{@intFromEnum(value), x})
            else try self.fmt(x);
        },
        Core.LocalId => {
            const x = self.wrap((try (try self.getFunction()).getLocal(value)).name);
            if (self.getShowIds()) try self.print("({}#{})", .{@intFromEnum(value), x})
            else try self.fmt(x);
        },
        Core.GlobalId => {
            const x = self.wrap((try (try self.getModule()).getGlobal(value)).name);
            if (self.getShowIds()) try self.print("({}#{})", .{@intFromEnum(value), x})
            else try self.fmt(x);
        },
        else =>
            if (comptime TypeUtils.isString(T)) try self.writeAll(value)
            else try self.print("{any}", .{value}),
    }
}

pub fn commaList(self: Formatter, iterableWithFor: anytype) Error! void {
    return self.list(", ", iterableWithFor);
}

pub fn list(self: Formatter, separator: anytype, iterableWithFor: anytype) Error! void {
    var nth = false;
    for (iterableWithFor) |x| {
        if (nth) {
            try self.fmt(separator);
        } else {
            nth = true;
        }

        try self.fmt(x);
    }
}

pub fn parens(self: Formatter, value: anytype) Error! void {
    try self.writeByte('(');
    try self.fmt(value);
    try self.writeByte(')');
}

pub fn braces(self: Formatter, value: anytype) Error! void {
    try self.writeByte('{');
    try self.fmt(value);
    try self.writeByte('}');
}

pub fn brackets(self: Formatter, value: anytype) Error! void {
    try self.writeByte('[');
    try self.fmt(value);
    try self.writeByte(']');
}

pub fn writeByte(self: Formatter, byte: u8) Error! void {
    try self.state.writer.writeByte(byte);

    if (byte == '\n') {
        try self.state.writer.writeByteNTimes(' ', self.state.indent_size * self.state.indent_level);
    }
}

pub fn write(self: Formatter, bytes: []const u8) Error! usize {
    for (bytes, 0..) |b, i| {
        if (b == '\n') {
            const sub = bytes[0..i + 1];
            try self.state.writer.writeAll(sub);
            try self.state.writer.writeByteNTimes(' ', self.state.indent_size * self.state.indent_level);

            return sub.len;
        }
    }

    try self.state.writer.writeAll(bytes);

    return bytes.len;
}

pub fn writeBytesNTimes(self: Formatter, bytes: []const u8, n: usize) Error!void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try self.writeAll(bytes);
    }
}

pub fn writeAll(self: Formatter, bytes: []const u8) Error! void {
    var index: usize = 0;
    while (index != bytes.len) {
        index += try self.write(bytes[index..]);
    }
}

pub fn print(self: Formatter, comptime fmtStr: []const u8, args: anytype) Error! void {
    return std.fmt.format(self, fmtStr, args);
}

pub fn endLine(self: Formatter) Error! void {
    try self.writeByte('\n');
}

pub fn beginBlock(self: Formatter) Error! void {
    self.state.indent_level += 1;
    try self.endLine();
}

pub fn endBlock(self: Formatter) Error! void {
    self.state.indent_level -= 1;
    try self.endLine();
}
