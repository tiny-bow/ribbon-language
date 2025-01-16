const std = @import("std");
const TypeUtils = @import("Utils").Type;
const RbcCore = @import("Rbc:Core");

const Core = @This();

pub const log = std.log.scoped(.Rir);

pub const Block = @import("Core/Block.zig");
pub const Foreign = @import("Core/Foreign.zig");
pub const Function = @import("Core/Function.zig");
pub const Global = @import("Core/Global.zig");
pub const HandlerSet = @import("Core/HandlerSet.zig");
pub const IR = @import("Core/IR.zig");
pub const Module = @import("Core/Module.zig");
pub const Op = @import("Core/Op.zig");
pub const Operand = @import("Core/Operand.zig").Operand;

pub const types = @import("Core/types.zig");
pub const Type = types.Type;

pub const ModuleId = NewType("ModuleId", u16);
pub const RegisterId = NewType("RegisterId", RbcCore.RegisterIndex);
pub const RegisterOffset = NewType("RegisterOffset", RbcCore.RegisterLocalOffset);
pub const HandlerSetId = NewType("HandlerSetId", RbcCore.HandlerSetIndex);
pub const TypeId = NewType("TypeId", RbcCore.Info.TypeIndex);
pub const BlockId = NewType("BlockId", RbcCore.BlockIndex);
pub const FunctionId = NewType("FunctionId", RbcCore.FunctionIndex);
pub const ForeignId = NewType("ForeignId", RbcCore.ForeignId);
pub const GlobalId = NewType("GlobalId", RbcCore.GlobalIndex);
pub const UpvalueId = NewType("UpvalueId", RbcCore.UpvalueIndex);
pub const LocalId = NewType("LocalId", u16);
pub const FieldId = NewType("FieldId", u16);

pub const Name = [:0]const u8;
pub const Arity = u8;

pub const MAX_MODULES = std.math.maxInt(std.meta.Tag(Core.ModuleId));
pub const MAX_TYPES = std.math.maxInt(std.meta.Tag(Core.TypeId));
pub const MAX_GLOBALS = std.math.maxInt(std.meta.Tag(Core.GlobalId));
pub const MAX_FUNCTIONS = std.math.maxInt(std.meta.Tag(Core.FunctionId));
pub const MAX_HANDLER_SETS = std.math.maxInt(std.meta.Tag(Core.HandlerSetId));
pub const MAX_EVIDENCE = RbcCore.MAX_EVIDENCE;
pub const MAX_BLOCKS = RbcCore.MAX_BLOCKS;
pub const MAX_REGISTERS = RbcCore.MAX_REGISTERS;
pub const MAX_LOCALS = std.math.maxInt(std.meta.Tag(Core.LocalId));

pub const Formatter = struct {
    state: *State,

    pub const Error = anyerror;

    const State = struct {
        ir: *const IR,
        module: ?*const Module = null,
        function: ?*const Function = null,

        writer: std.io.AnyWriter,

        indent_size: u4 = 4,
        indent_level: u8 = 0,

        type_mode: TypeMode = .name_only,
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

    pub fn init(ir: *IR, writer: std.io.AnyWriter) error{OutOfMemory}! Formatter {
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

    pub fn fmt(self: Formatter, value: anytype) Error! void {
        const T = @TypeOf(value);

        if (std.meta.hasMethod(T, "onFormat")) {
            return value.onFormat(self);
        } else switch(T) {
            Core.ModuleId => return self.fmt((try self.getIR().getModule(value)).name),
            Core.TypeId => return self.fmt(try self.getIR().getType(value)),
            Core.BlockId => return self.fmt((try (try self.getFunction()).getBlock(value)).name),
            Core.LocalId => try self.fmt((try (try self.getFunction()).getLocal(value)).name),
            Core.GlobalId => try self.fmt((try (try self.getModule()).getGlobal(value)).name),
            else =>
                if (comptime TypeUtils.isString(T)) return self.writeAll(value)
                else return self.print("{any}", .{value}),
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
};

pub const Instruction = packed struct {
    code: Op.Code,
    data: Op.Data,

    pub fn onFormat(self: Instruction, formatter: Core.Formatter) !void {
        try formatter.fmt(self.code);
        try formatter.writeAll(" ");
        try self.data.fillFormatter(self.code, formatter);
    }

    comptime {
        if (@sizeOf(Instruction) != 8) {
            @compileError(std.fmt.comptimePrint("Instruction size changed: {}", .{@sizeOf(Instruction)}));
        }
    }
};

pub fn Ref (comptime T: type) type {
    return packed struct {
        module: Core.ModuleId,
        id: T,

        const Self = @This();

        pub fn onFormat(self: Self, formatter: Core.Formatter) !void {
            try formatter.fmt(self.module);
            try formatter.writeAll(":");
            try formatter.fmt(self.id);
        }

        pub fn format(self: Self, comptime _: []const u8, _: anytype, writer: anytype) !void {
            try writer.print("[{}:{}]", .{self.module, self.id});
        }
    };
}


fn NewType(comptime NewTypeName: []const u8, comptime Tag: type) type {
    return enum(Tag) {
        const Self = @This();
        pub const __new_type_name = NewTypeName;

        _,

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) ! void {
            return writer.print("{s}-{x}", .{NewTypeName, @intFromEnum(self)});
        }
    };
}

