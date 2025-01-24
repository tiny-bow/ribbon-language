

const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const TypeUtils = @import("Utils").Type;

const Rir = @import("../Rir.zig");

pub const FormatError = anyerror;

pub const Formatter = struct {
    pub const Error = FormatError;

    state: *FormatterState,

    pub fn init(ir: *Rir, writer: std.io.AnyWriter) error{OutOfMemory}! Formatter {
        const state = try ir.allocator.create(FormatterState);
        state.* = FormatterState { .ir = ir, .writer = writer };
        return Formatter { .state = state };
    }

    pub fn deinit(self: Formatter) void {
        self.state.ir.allocator.destroy(self.state);
    }

    pub fn wrap(self: Formatter, data: anytype) Wrap(@TypeOf(data)) {
        return Wrap(@TypeOf(data)) { .formatter = self, .data = data };
    }

    pub fn sliceWrap(self: Formatter, data: anytype) SliceWrap(@TypeOf(data)) {
        return SliceWrap(@TypeOf(data)) { .formatter = self, .data = data };
    }

    pub fn getIR(self: Formatter) *const Rir {
        return self.state.ir;
    }

    pub fn setModule(self: Formatter, module: ?*const Rir.Module) void {
        self.state.module = module;
    }

    pub fn swapModule(self: Formatter, module: ?*const Rir.Module) ?*const Rir.Module {
        const oldModule = self.getModule() catch null;
        self.setModule(module);
        return oldModule;
    }

    pub fn getModule(self: Formatter) !*const Rir.Module {
        return self.state.module orelse error.NoFormatterActiveModule;
    }

    pub fn setFunction(self: Formatter, function: ?*const Rir.Function) void {
        self.state.function = function;
    }

    pub fn swapFunction(self: Formatter, function: ?*const Rir.Function) ?*const Rir.Function {
        const oldFunction = self.getFunction() catch null;
        self.setFunction(function);
        return oldFunction;
    }

    pub fn getFunction(self: Formatter) !*const Rir.Function {
        return self.state.function orelse error.NoFormatterActiveFunction;
    }

    pub fn getBlock(self: Formatter) !*const Rir.Block {
        return self.state.block orelse error.NoFormatterActiveBlock;
    }

    pub fn setBlock(self: Formatter, b: ?*const Rir.Block) void {
        self.state.block = b;
    }

    pub fn swapBlock(self: Formatter, b: ?*const Rir.Block) ?*const Rir.Block {
        const oldBlock = self.getBlock() catch null;
        self.setBlock(b);
        return oldBlock;
    }

    pub fn getOpCodeDataSplit(self: Formatter) ?u21 {
        return self.state.op_code_data_split;
    }

    pub fn setOpCodeDataSplit(self: Formatter, split: ?u21) void {
        self.state.op_code_data_split = split;
    }

    pub fn swapOpCodeDataSplit(self: Formatter, split: ?u21) ?u21 {
        const old = self.getOpCodeDataSplit();
        self.setOpCodeDataSplit(split);
        return old;
    }

    pub fn getFlags(self: Formatter) Flags {
        return self.state.flags;
    }

    pub fn setFlags(self: Formatter, flags: Flags) void {
        self.state.flags = flags;
    }

    pub fn swapFlags(self: Formatter, flags: Flags) Flags {
        const old = self.getFlags();
        self.setFlags(flags);
        return old;
    }

    pub fn getFlag(self: Formatter, comptime flag: FlagKind) bool {
        return @field(self.state.flags, @tagName(flag));
    }

    pub fn setFlag(self: Formatter, comptime flag: FlagKind, value: bool) void {
        @field(self.state.flags, @tagName(flag)) = value;
    }

    pub fn swapFlag(self: Formatter, comptime flag: FlagKind, value: bool) bool {
        const old = self.getFlag(flag);
        self.setFlag(flag, value);
        return old;
    }

    pub fn fmt(self: Formatter, value: anytype) FormatError! void {
        const T = @TypeOf(value);

        if (std.meta.hasMethod(T, "onFormat")) {
            try value.onFormat(self);
        } else switch(T) {
            Rir.NameId => {
                try self.writeAll(try self.getIR().getName(value));
            },
            Rir.ModuleId => {
                const x = self.wrap((try self.getIR().getModule(value)).name);
                if (self.getFlag(.show_ids)) try self.print("{}#{}", .{x, @intFromEnum(value)})
                else try x.fmt();
            },
            Rir.TypeId => {
                const x = try self.getIR().getType(value);
                try x.onFormat(self);
            },
            Rir.BlockId => {
                if (self.getFunction()) |func| {
                    const x = self.wrap((try func.getBlock(value)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{x, @intFromEnum(value)})
                    else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(value)});
                }
            },
            Rir.LocalId => {
                if (self.getBlock()) |bl| {
                    const x = self.wrap((try bl.getLocal(value)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{x, @intFromEnum(value)})
                    else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(value)});
                }
            },
            Rir.GlobalId => {
                if (self.getModule()) |mod| {
                    const x = self.wrap((try mod.getGlobal(value)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{x, @intFromEnum(value)})
                    else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(value)});
                }
            },
            Rir.FunctionId => {
                if (self.getModule()) |mod| {
                    const x = self.wrap((try mod.getFunction(value)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{x, @intFromEnum(value)})
                    else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(value)});
                }
            },
            else =>
                if (std.meta.hasMethod(T, "format")) try self.print("{}", .{value})
                else switch (@typeInfo(T)) {
                    .@"enum" => try self.writeAll(@tagName(value)),
                    else =>
                        if (comptime TypeUtils.isString(T)) try self.writeAll(value)
                        else try self.print("{any}", .{value})
                },
        }
    }

    pub fn commaList(self: Formatter, iterableWithFor: anytype) FormatError! void {
        return self.list(", ", iterableWithFor);
    }

    pub fn list(self: Formatter, separator: anytype, iterableWithFor: anytype) FormatError! void {
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

    pub fn block(self: Formatter, iterableWithFor: anytype) FormatError! void {
        var nth = false;

        try self.beginBlock();
        for (iterableWithFor) |func| {
            if (nth) {
                try self.endLine();
            } else {
                nth = true;
            }

            try self.fmt(func);
        }
        try self.endBlock();
    }

    pub fn parens(self: Formatter, value: anytype) FormatError! void {
        try self.writeByte('(');
        try self.fmt(value);
        try self.writeByte(')');
    }

    pub fn braces(self: Formatter, value: anytype) FormatError! void {
        try self.writeByte('{');
        try self.fmt(value);
        try self.writeByte('}');
    }

    pub fn brackets(self: Formatter, value: anytype) FormatError! void {
        try self.writeByte('[');
        try self.fmt(value);
        try self.writeByte(']');
    }

    pub fn writeByte(self: Formatter, byte: u8) FormatError! void {
        try self.state.writer.writeByte(byte);

        if (byte == '\n') {
            try self.state.writer.writeByteNTimes(' ', self.state.indent_size * self.state.indent_level);
        }
    }

    pub fn write(self: Formatter, bytes: []const u8) FormatError! usize {
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

    pub fn writeBytesNTimes(self: Formatter, bytes: []const u8, n: usize) FormatError!void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.writeAll(bytes);
        }
    }

    pub fn writeAll(self: Formatter, bytes: []const u8) FormatError! void {
        var index: usize = 0;
        while (index != bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }

    pub fn print(self: Formatter, comptime fmtStr: []const u8, args: anytype) FormatError! void {
        return std.fmt.format(self, fmtStr, args);
    }

    pub fn endLine(self: Formatter) FormatError! void {
        try self.writeByte('\n');
    }

    pub fn beginBlock(self: Formatter) FormatError! void {
        self.state.indent_level += 1;
        try self.endLine();
    }

    pub fn endBlock(self: Formatter) FormatError! void {
        self.state.indent_level -= 1;
    }
};

const FormatterState = struct {
    ir: *const Rir,
    module: ?*const Rir.Module = null,
    function: ?*const Rir.Function = null,
    block: ?*const Rir.Block = null,

    writer: std.io.AnyWriter,

    indent_size: u4 = 4,
    indent_level: u8 = 0,
    op_code_data_split: ?u21 = null,

    flags: Flags = .{},
};

const Flags = packed struct {
    show_nominative_type_bodies: bool = false,
    show_ids: bool = false,
    show_indices: bool = false,
    show_op_code_bytes: bool = false,
    show_op_data_bytes: bool = false,
    raw_immediates: bool = false,
};

pub const FlagKind = std.meta.FieldEnum(Flags);

fn Wrap (comptime T: type) type {
    return struct {
        const Self = @This();

        formatter: Formatter,
        data: T,

        pub fn onFormat(self: Self, _: Formatter) FormatError!void {
            return self.fmt();
        }

        pub fn format(self: Self, comptime _: []const u8, _: anytype, _: anytype) FormatError!void {
            return self.fmt();
        }

        pub fn fmt(self: Self) FormatError! void {
            return self.formatter.fmt(self.data);
        }
    };
}

pub fn SliceWrap (comptime T: type) type {
    return struct {
        const Self = @This();

        formatter: Formatter,
        data: []const T,

        pub fn onFormat(self: Self, _: Formatter) FormatError!void {
            return self.fmt();
        }

        pub fn format(self: Self, comptime _: []const u8, _: anytype, _: anytype) FormatError!void {
            return self.fmt();
        }

        pub fn fmt(self: Self) FormatError! void {
            return self.formatter.commaList(self.data);
        }
    };
}
