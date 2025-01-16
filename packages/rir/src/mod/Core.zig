const std = @import("std");
const TypeUtils = @import("Utils").Type;
const RbcCore = @import("Rbc:Core");

const Core = @This();

pub const log = std.log.scoped(.Rir);

pub const Block = @import("Core/Block.zig");
pub const Foreign = @import("Core/Foreign.zig");
pub const Formatter = @import("Core/Formatter.zig");
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

pub const Instruction = packed struct {
    code: Op.Code,
    data: Op.Data,

    pub fn onFormat(self: Instruction, formatter: Core.Formatter) !void {
        if (formatter.getShowOpCodes()) {
            try formatter.print("{x:0<2}", .{@intFromEnum(self.code)});
            if (formatter.getShowEncoded()) try formatter.writeAll(":")
            else try formatter.writeAll(" ");
        }
        if (formatter.getShowEncoded()) try formatter.print("{x:0<12} ", .{@as(u48, @bitCast(self.data))});
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
            try formatter.writeAll("/");
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

