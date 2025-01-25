const std = @import("std");
const ISA = @import("ISA");
const RbcCore = @import("Rbc");

const Rir = @import("../Rir.zig");


pub const ZeroCheck = enum(u1) { zero, non_zero };
pub const OptZeroCheck = enum(u2) { none, zero, non_zero };
pub const BitSize = enum(u2) { b8, b16, b32, b64 };

pub const Instruction = packed struct {
    code: OpCode,
    data: OpData,

    pub fn onFormat(self: Instruction, formatter: Rir.Formatter) !void {
        const flags = formatter.getFlags();
        if (flags.show_op_code_bytes) {
            try formatter.print("{x:0<2}", .{@intFromEnum(self.code)});
            if (flags.show_op_data_bytes) {
                if (formatter.getOpCodeDataSplit()) |c| try formatter.print("{u}", .{c});
            }
        }
        if (flags.show_op_data_bytes) try formatter.print("{x:0<12} ", .{@as(u48, @bitCast(self.data))});
        try formatter.fmt(self.code);
        try formatter.writeAll(" ");
        try self.data.formatWith(formatter, self.code);
    }

    comptime {
        if (@sizeOf(Instruction) != 8) {
            @compileError(std.fmt.comptimePrint("Instruction size changed: {}", .{@sizeOf(Instruction)}));
        }
    }
};

pub const OpCode = enum(u8) {
    // ISA instructions matching ISA semantics:
    nop,
    halt, trap,
    block, with, @"if", when, re, br,
    call, prompt, ret, term,
    alloca, addr,
    read, write, load, store,
    add, sub, mul, div, rem, neg,
    band, bor, bxor, bnot, bshiftl, bshiftr,
    eq, ne, lt, gt, le, ge,
    ext, trunc, cast,

    // re-purposed ISA instructions:
    clear, swap, copy,

    // Rir-specific instructions:
    new_local,

    ref_local,
    ref_block,
    ref_function,
    ref_foreign,
    ref_global,
    ref_upvalue,

    im_b, im_s, im_i, im_w,

    pub fn format(self: OpCode, comptime _: []const u8, _: anytype, writer: anytype) !void {
        try writer.writeAll(@tagName(self));
    }

    comptime {
        for (std.meta.fieldNames(OpData)) |opName| {
            if (!@hasField(OpCode, opName)) {
                @compileError("missing OpCode: `" ++ opName ++ "`");
            }
        }
    }
};

comptime {
    for (ISA.Instructions) |category| {
        for (category.kinds) |kind| {
            const name = kind.humanFriendlyName();

            if (!@hasField(OpCode, name)) {
                @compileError("missing OpCode: `" ++ name ++ "`");
            }
        }
    }
}

pub const OpData = packed union {
    nop: void,
    halt: void, trap: void,
    block: void, with: void,
    @"if": ZeroCheck, when: ZeroCheck, re: OptZeroCheck, br: OptZeroCheck,
    call: void, prompt: void, ret: void, term: void,
    alloca: Rir.RegisterOffset, addr: void,
    read: void, write: void, load: void, store: void,
    add: void, sub: void, mul: void, div: void, rem: void, neg: void,
    band: void, bor: void, bxor: void, bnot: void, bshiftl: void, bshiftr: void,
    eq: void, ne: void, lt: void, gt: void, le: void, ge: void,
    ext: BitSize, trunc: BitSize, cast: void,

    clear: Rir.Index, swap: Rir.Index, copy: Rir.Index,

    new_local: Rir.NameId,

    ref_local: Rir.LocalId,
    ref_block: Rir.BlockId,
    ref_function: Rir.Ref(Rir.FunctionId),
    ref_foreign: Rir.ForeignId,
    ref_global: Rir.Ref(Rir.GlobalId),
    ref_upvalue: Rir.UpvalueId,

    im_b: Immediate(u8),
    im_s: Immediate(u16),
    im_i: Immediate(u32),
    im_w: Rir.TypeId,

    pub fn formatWith(self: OpData, formatter: Rir.Formatter, code: OpCode) Rir.Formatter.Error! void {
        switch (code) {
            inline
                .nop,
                .halt, .trap,
                .block, .with,
                .call, .prompt, .ret, .term,
                .addr,
                .read, .write, .load, .store,
                .add, .sub, .mul, .div, .rem, .neg,
                .band, .bor, .bxor, .bnot, .bshiftl, .bshiftr,
                .eq, .ne, .lt, .gt, .le, .ge,
                .new_local,
            => return,

            .@"if" => try formatter.fmt(self.@"if"),
            .when => try formatter.fmt(self.when),
            .re => try formatter.fmt(self.re),
            .br => try formatter.fmt(self.br),

            .alloca => try formatter.fmt(self.alloca),

            .ext => try formatter.fmt(self.ext),
            .trunc => try formatter.fmt(self.trunc),

            .cast => try formatter.fmt(self.cast),

            .clear => try formatter.fmt(self.clear),
            .swap => try formatter.fmt(self.swap),
            .copy => try formatter.fmt(self.copy),

            .ref_local => try formatter.fmt(self.ref_local),
            .ref_block => try formatter.fmt(self.ref_block),
            .ref_function => try formatter.fmt(self.ref_function),
            .ref_foreign => try formatter.fmt(self.ref_foreign),
            .ref_global => try formatter.fmt(self.ref_global),
            .ref_upvalue => try formatter.fmt(self.ref_upvalue),

            .im_b => try formatter.fmt(self.im_b),
            .im_s => try formatter.fmt(self.im_s),
            .im_i => try formatter.fmt(self.im_i),
            .im_w => try formatter.fmt(self.im_w),
        }
    }

    comptime {
        for (std.meta.fieldNames(OpCode)) |opName| {
            if (!@hasField(OpData, opName)) {
                @compileError("missing OpData: `" ++ opName ++ "`");
            }
        }
    }
};


pub fn DataOf(comptime code: OpCode) type {
    @setEvalBranchQuota(2000);
    inline for (std.meta.fieldNames(OpCode)) |name| {
        if (@field(OpCode, name) == code) {
            for (std.meta.fields(OpData)) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    return field.type;
                }
            }
            unreachable;
        }
    }
    unreachable;
}

pub fn Immediate (comptime T: type) type {
    return packed struct {
        const Self = @This();

        data: T,
        type: Rir.TypeId,

        pub fn onFormat(self: *const Self, formatter: Rir.Formatter) !void {
            if (formatter.getFlag(.raw_immediates)) {
                try formatter.writeAll("0x");
                try std.fmt.formatInt(self.data, 16, .lower, .{
                    .alignment = .left,
                    .width = 2 * @sizeOf(T),
                    .fill = '0',
                }, formatter);
            } else {
                try formatter.writeAll("{");
                const t = try formatter.getIR().getType(self.type);
                try t.formatMemory(formatter, &std.mem.toBytes(self.data));
                try formatter.writeAll(" : ");
                try formatter.fmt(self.type);
                try formatter.writeAll("}");
            }
        }
    };
}

pub const RValue = union(enum) {
    im_0: void,
    im_8: Immediate(u8),
    im_16: Immediate(u16),
    im_32: Immediate(u32),
    im_64: Immediate(u64),
    register: Register,

    pub fn forceRegister(self: RValue) error{ExpectedRegister} !Register {
        return switch (self) {
            .register => |r| r,
            else => error.ExpectedRegister,
        };
    }
};

pub const Register = struct {
    type: Rir.TypeId,
    index: RbcCore.RegisterIndex,
};

pub const Operand = union(enum) {
    type: Rir.TypeId,
    register: Register,
    im_8: Immediate(u8),
    im_16: Immediate(u16),
    im_32: Immediate(u32),
    im_64: Immediate(u64),
    block: Rir.BlockId,
    foreign: Rir.ForeignId,
    function: Rir.Ref(Rir.FunctionId),
    global: Rir.Ref(Rir.GlobalId),
    upvalue: Rir.UpvalueId,
    handler_set: Rir.HandlerSetId,
    local: Rir.LocalId,

    pub fn to(self: Operand, comptime T: type) ?T {
        return switch (self) {
            .type => |x| if (comptime T == Rir.TypeId) x else null,
            .register => |x| if (comptime T == Register) x else null,
            .im_8 => |x| if (comptime T == Immediate(u8)) x else null,
            .im_16 => |x| if (comptime T == Immediate(u16)) x else null,
            .im_32 => |x| if (comptime T == Immediate(u32)) x else null,
            .im_64 => |x| if (comptime T == Immediate(u64)) x else null,
            .block => |x| if (comptime T == Rir.BlockId) x else null,
            .foreign => |x| if (comptime T == Rir.ForeignId) x else null,
            .function => |x| if (comptime T == Rir.Ref(Rir.FunctionId)) x else null,
            .global => |x| if (comptime T == Rir.Ref(Rir.GlobalId)) x else null,
            .upvalue => |x| if (comptime T == Rir.UpvalueId) x else null,
            .handler_set => |x| if (comptime T == Rir.HandlerSetId) x else null,
            .local => |x| if (comptime T == Rir.LocalId) x else null,
        };
    }

    pub fn from(value: anytype) Operand {
        const T = @TypeOf(value);
        return switch (T) {
            Operand => value,
            Rir.TypeId => .{ .type = value },
            Register => .{ .register = value },
            Immediate(u8) => .{ .im_8 = value },
            Immediate(u16) => .{ .im_16 = value },
            Immediate(u32) => .{ .im_32 = value },
            Immediate(u64) => .{ .im_64 = value },
            Rir.BlockId => .{ .block = value },
            Rir.ForeignId => .{ .foreign = value },
            Rir.Ref(Rir.FunctionId) => .{ .function = value },
            Rir.Ref(Rir.GlobalId) => .{ .global = value },
            Rir.UpvalueId => .{ .upvalue = value },
            Rir.HandlerSetId => .{ .handler_set = value },
            Rir.LocalId => .{ .local = value },
            else => @compileError("Unsupported operand type " ++ @typeName(T)),
        };
    }

    pub fn TypeOf(comptime tag: ?std.meta.Tag(Operand)) type {
        return if (tag) |t| switch (t) {
            .type => Rir.TypeId,
            .register => Register,
            .im_8 => Immediate(u8),
            .im_16 => Immediate(u16),
            .im_32 => Immediate(u32),
            .im_64 => Immediate(u64),
            .block => Rir.BlockId,
            .foreign => Rir.ForeignId,
            .function => Rir.Ref(Rir.FunctionId),
            .global => Rir.Ref(Rir.GlobalId),
            .upvalue => Rir.UpvalueId,
            .handler_set => Rir.HandlerSetId,
            .local => Rir.LocalId,
        }
        else Operand;
    }

    pub fn mem_const(self: *const Operand) []const u8 {
        return switch (self.*) {
            .type => |*x| std.mem.sliceAsBytes(@as([*]const Rir.TypeId, @ptrCast(x))[0..1]),
            .register => |*x| std.mem.sliceAsBytes(@as([*]const Register, @ptrCast(x))[0..1]),
            .im_8 => |*x| std.mem.sliceAsBytes(@as([*]const u8, @ptrCast(&x.data))[0..1]),
            .im_16 => |*x| std.mem.sliceAsBytes(@as([*]const u16, @ptrCast(&x.data))[0..1]),
            .im_32 => |*x| std.mem.sliceAsBytes(@as([*]const u32, @ptrCast(&x.data))[0..1]),
            .im_64 => |*x| std.mem.sliceAsBytes(@as([*]const u64, @ptrCast(&x.data))[0..1]),
            .block => |*x| std.mem.sliceAsBytes(@as([*]const Rir.BlockId, @ptrCast(x))[0..1]),
            .foreign => |*x| std.mem.sliceAsBytes(@as([*]const Rir.ForeignId, @ptrCast(x))[0..1]),
            .function => |*x| std.mem.sliceAsBytes(@as([*]const Rir.Ref(Rir.FunctionId), @ptrCast(x))[0..1]),
            .global => |*x| std.mem.sliceAsBytes(@as([*]const Rir.Ref(Rir.GlobalId), @ptrCast(x))[0..1]),
            .upvalue => |*x| std.mem.sliceAsBytes(@as([*]const Rir.UpvalueId, @ptrCast(x))[0..1]),
            .handler_set => |*x| std.mem.sliceAsBytes(@as([*]const Rir.HandlerSetId, @ptrCast(x))[0..1]),
            .local => |*x| std.mem.sliceAsBytes(@as([*]const Rir.LocalId, @ptrCast(x))[0..1]),
        };
    }

    pub fn mem(self: *Operand) []u8 {
        return switch (self.*) {
            .type => |*x| std.mem.sliceAsBytes(@as([*]Rir.TypeId, @ptrCast(x))[0..1]),
            .register => |*x| std.mem.sliceAsBytes(@as([*]Register, @ptrCast(x))[0..1]),
            .im_8 => |*x| std.mem.sliceAsBytes(@as([*]u8, @ptrCast(&x.data))[0..1]),
            .im_16 => |*x| std.mem.sliceAsBytes(@as([*]u16, @ptrCast(&x.data))[0..1]),
            .im_32 => |*x| std.mem.sliceAsBytes(@as([*]u32, @ptrCast(&x.data))[0..1]),
            .im_64 => |*x| std.mem.sliceAsBytes(@as([*]u64, @ptrCast(&x.data))[0..1]),
            .block => |*x| std.mem.sliceAsBytes(@as([*]Rir.BlockId, @ptrCast(x))[0..1]),
            .foreign => |*x| std.mem.sliceAsBytes(@as([*]Rir.ForeignId, @ptrCast(x))[0..1]),
            .function => |*x| std.mem.sliceAsBytes(@as([*]Rir.Ref(Rir.FunctionId), @ptrCast(x))[0..1]),
            .global => |*x| std.mem.sliceAsBytes(@as([*]Rir.Ref(Rir.GlobalId), @ptrCast(x))[0..1]),
            .upvalue => |*x| std.mem.sliceAsBytes(@as([*]Rir.UpvalueId, @ptrCast(x))[0..1]),
            .handler_set => |*x| std.mem.sliceAsBytes(@as([*]Rir.HandlerSetId, @ptrCast(x))[0..1]),
            .local => |*x| std.mem.sliceAsBytes(@as([*]Rir.LocalId, @ptrCast(x))[0..1]),
        };
    }

    pub fn isConstant(self: Operand) bool {
        return switch (self) {
            inline
                .register,
                .global,
                .upvalue,
                .local,
            => false,

            inline
                .im_8,
                .im_16,
                .im_32,
                .im_64,
                .type,
                .block,
                .function,
                .foreign,
                .handler_set,
             => true,
        };
    }
};
