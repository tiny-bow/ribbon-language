const std = @import("std");

const utils = @import("utils");
const Rbc = @import("Rbc");

const Builder = @import("../RbcBuilder.zig");
const Error = Builder.Error;
const FunctionBuilder = Builder.FunctionBuilder;

const BlockBuilder = @This();


function: *FunctionBuilder,
parent: ?Rbc.BlockIndex,
index: Rbc.BlockIndex,
kind: Kind,
ops: Builder.InstrList,
exited: bool,


pub const Kind = union(enum) {
    basic: void,
    with: Rbc.HandlerSetIndex,

    pub fn getHandlerSet(self: BlockBuilder.Kind) ?Rbc.HandlerSetIndex {
        return switch (self) {
            .basic => null,
            .with => |w| w,
        };
    }
};

/// for use by the FunctionBuilder only
pub fn init(func: *FunctionBuilder, parent: ?Rbc.BlockIndex, index: Rbc.BlockIndex, kind: Kind) std.mem.Allocator.Error!*BlockBuilder {
    const ptr = try func.parent.allocator.create(BlockBuilder);

    var ops = Builder.InstrList {};
    try ops.ensureTotalCapacity(func.parent.allocator, 256);

    ptr.* = BlockBuilder {
        .function = func,
        .parent = parent,
        .index = index,
        .kind = kind,
        .ops = ops,
        .exited = false,
    };

    return ptr;
}


pub fn preassemble(self: *const BlockBuilder) Error!usize {
    if (!self.exited) {
        return Error.UnfinishedBlock;
    }

    return self.ops.items.len;
}

pub fn assemble(self: *const BlockBuilder, buf: []Rbc.Instruction, offset: *usize) [*]const Rbc.Instruction {
    const start = offset.*;

    for (self.ops.items) |x| {
        buf[offset.*] = x;
        offset.* += 1;
    }

    return buf.ptr + start;
}


pub fn findRelativeBlockIndex(self: *const BlockBuilder, absoluteBlockIndex: Rbc.BlockIndex) Error!Rbc.BlockIndex {
    if (self.index == absoluteBlockIndex) {
        return 0;
    }

    if (self.parent) |p| {
        if (p == absoluteBlockIndex) {
            return 1;
        }

        const parent = try self.function.getBlock(p);
        return 1 + try findRelativeBlockIndex(parent, absoluteBlockIndex);
    }

    return Error.InvalidIndex;
}

pub fn extractBlockIndex(self: *const BlockBuilder, b: anytype) Error! Rbc.BlockIndex {
    switch (@TypeOf(b)) {
        BlockBuilder => return self.extractBlockIndex(&b),
        *BlockBuilder => return self.extractBlockIndex(@as(*const BlockBuilder, b)),
        *const BlockBuilder => {
            if (b.function != self.function) {
                return Error.InvalidIndex;
            }
            return self.extractBlockIndex(b.index);
        },

        *Rbc.BlockIndex => return self.extractBlockIndex(b.*),
        Rbc.BlockIndex => return b,

        else => @compileError(std.fmt.comptimePrint(
            "invalid block index parameter, expected either `Rbc.BlockIndex` or `*Builder.BlockBuilder`, got `{s}`",
            .{@typeName(@TypeOf(b))}
        )),
    }
}




pub fn args(self: *BlockBuilder, rArgs: anytype) Error!void {
    if (rArgs.len == 0) {
        return;
    } else if (rArgs.len > Rbc.MAX_REGISTERS) {
        return Error.TooManyRegisters;
    }

    var acc = [1]Rbc.RegisterIndex {255} ** (@sizeOf(Rbc.Instruction) / @sizeOf(Rbc.RegisterIndex));

    comptime var i: usize = 0;
    inline while (i < rArgs.len) : (i += 1) {
        acc[i % acc.len] = rArgs[i];
        if (i != 0 and i % acc.len == 0) {
            try self.ops.append(self.function.parent.allocator, @as(Rbc.Instruction, @bitCast(acc)));
        }
    }

    if (i % acc.len != 0) {
        for ((i % acc.len)..acc.len) |j| acc[j] = 255;
        try self.ops.append(self.function.parent.allocator, @as(Rbc.Instruction, @bitCast(acc)));
    }
}


pub fn wideImmediate(self: *BlockBuilder, w: anytype) Error!void {
    try self.ops.append(self.function.parent.allocator, @bitCast(wCast(w)));
}

pub fn op(self: *BlockBuilder, code: Rbc.Op.Code, data: *const anyopaque) Error!void {
    if (self.exited) return Error.InstructionsAfterExit;

    try self.ops.append(self.function.parent.allocator, Rbc.Instruction {
        .code = code,
        .data = inline for (comptime std.meta.fieldNames(Rbc.Op.Code)) |name| {
            if (@field(Rbc.Op.Code, name) == code) {
                const T = @TypeOf(@field(@as(Rbc.Op.Data, undefined), name));
                break @unionInit(Rbc.Op.Data, name, if (T == void) {} else @as(*align(1) const T, @ptrCast(@alignCast(data))).*);
            }
        } else unreachable,
    });
}

pub fn exitOp(self: *BlockBuilder, comptime code: Rbc.Op.Code, data: *const anyopaque) Error!void {
    if (self.exited) return Error.MultipleExits;

    try self.ops.append(self.function.parent.allocator, Rbc.Instruction {
        .code = code,
        .data = inline for (comptime std.meta.fieldNames(Rbc.Op.Code)) |name| {
            if (@field(Rbc.Op.Code, name) == code) {
                const T = @TypeOf(@field(@as(Rbc.Op.Data, undefined), name));
                break @unionInit(Rbc.Op.Data, name, if (T == void) {} else @as(*const T, @ptrCast(@alignCast(data))).*);
            }
        } else unreachable,
    });

    self.exited = true;
}


pub fn bCast(b: anytype) u8 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u8, b),
        .int => |info|
            if (info.bits <= 8) switch (info.signedness) {
                .unsigned => @as(u8, b),
                .signed => @as(u8, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 8), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u8, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub fn sCast(b: anytype) u16 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u16, b),
        .int => |info|
            if (info.bits <= 16) switch (info.signedness) {
                .unsigned => @as(u16, b),
                .signed => @as(u16, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 16), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u16, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub fn iCast(b: anytype) u32 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u32, b),
        .int => |info|
            if (info.bits <= 32) switch (info.signedness) {
                .unsigned => @as(u32, b),
                .signed => @as(u32, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 32), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u32, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub fn wCast(b: anytype) u64 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u64, b),
        .int => |info|
            if (info.bits <= 64) switch (info.signedness) {
                .unsigned => @as(u64, b),
                .signed => @as(u64, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            }
            else @bitCast(@as(std.meta.Int(info.signedness, 64), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u64, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}



pub fn nop(self: *BlockBuilder) Error!void {
    try self.op(.nop, &{});
}


pub fn halt(self: *BlockBuilder) Error!void {
    try self.exitOp(.halt, &{});
}

pub fn trap(self: *BlockBuilder) Error!void {
    try self.exitOp(.trap, &{});
}

pub fn block(self: *BlockBuilder) Error!*BlockBuilder {
    const newBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.block, &.{ .B0 = newBlock.index });

    return newBlock;
}

pub fn block_v(self: *BlockBuilder, y: Rbc.RegisterIndex) Error!*BlockBuilder {
    const newBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.block_v, &.{ .B0 = newBlock.index, .R0 = y });

    return newBlock;
}

pub fn with(self: *BlockBuilder, h: anytype) Error!*BlockBuilder {
    const handlerSetIndex = try self.function.parent.extractHandlerSetIndex(h);
    const newBlock = try self.function.newBlock(self.index, .{.with = handlerSetIndex});

    try self.op(.with, &.{ .B0 = newBlock.index, .H0 = handlerSetIndex });

    return newBlock;
}

pub fn with_v(self: *BlockBuilder, h: anytype, y: Rbc.RegisterIndex) Error!*BlockBuilder {
    const handlerSetIndex = try self.function.parent.extractHandlerSetIndex(h);
    const newBlock = try self.function.newBlock(self.index, .{.with_v = handlerSetIndex});

    try self.op(.with_v, &.{ .B0 = newBlock.index, .H0 = handlerSetIndex, .R0 = y });

    return newBlock;
}

pub fn if_nz(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!struct { *BlockBuilder, *BlockBuilder } {
    const thenBlock = try self.function.newBlock(self.index, .basic);
    const elseBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.if_nz, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x });

    return .{ thenBlock, elseBlock };
}

pub fn if_nz_v(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!struct { *BlockBuilder, *BlockBuilder } {
    const thenBlock = try self.function.newBlock(self.index, .basic);
    const elseBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.if_nz_v, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x, .R1 = y });

    return .{ thenBlock, elseBlock };
}

pub fn if_z(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!struct { *BlockBuilder, *BlockBuilder } {
    const thenBlock = try self.function.newBlock(self.index, .basic);
    const elseBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.if_z, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x });

    return .{ thenBlock, elseBlock };
}

pub fn if_z_v(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!struct { *BlockBuilder, *BlockBuilder } {
    const thenBlock = try self.function.newBlock(self.index, .basic);
    const elseBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.if_z_v, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x, .R1 = y });

    return .{ thenBlock, elseBlock };
}

pub fn when_nz(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!*BlockBuilder {
    const newBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.when_nz, &.{ .B0 = newBlock.index, .R0 = x });

    return newBlock;
}

pub fn when_z(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!*BlockBuilder {
    const newBlock = try self.function.newBlock(self.index, .basic);

    try self.op(.when_z, &.{ .B0 = newBlock.index, .R0 = x });

    return newBlock;
}

pub fn re(self: *BlockBuilder, b: anytype) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.re, &.{ .B0 = relativeBlockIndex });
}

pub fn re_nz(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.re_nz, &.{ .B0 = relativeBlockIndex, .R0 = x });
}

pub fn re_z(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.re_z, &.{ .B0 = relativeBlockIndex, .R0 = x });
}

pub fn br(self: *BlockBuilder, b: anytype) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br, &.{ .B0 = relativeBlockIndex });
}

pub fn br_nz(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_nz, &.{ .B0 = relativeBlockIndex, .R0 = x });
}

pub fn br_z(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_z, &.{ .B0 = relativeBlockIndex, .R0 = x });
}

pub fn br_v(self: *BlockBuilder, b: anytype, y: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_v, &.{ .B0 = relativeBlockIndex, .R0 = y });
}

pub fn br_nz_v(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_nz_v, &.{ .B0 = relativeBlockIndex, .R0 = x, .R1 = y });
}

pub fn br_z_v(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_z_v, &.{ .B0 = relativeBlockIndex, .R0 = x, .R1 = y });
}

pub fn br_im_v(self: *BlockBuilder, b: anytype, i: anytype) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_im_v, &.{ .B0 = relativeBlockIndex, .i0 = iCast(i) });
}

pub fn br_im_w_v(self: *BlockBuilder, b: anytype, w: anytype) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_im_w_v, &.{ .B0 = relativeBlockIndex });
    try self.wideImmediate(w);
}

pub fn br_nz_im_v(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, w: anytype) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_nz_im_v, &.{ .B0 = relativeBlockIndex, .R0 = x });
    try self.wideImmediate(w);
}

pub fn br_z_im_v(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, w: anytype) Error!void {
    const absoluteBlockIndex = try self.extractBlockIndex(b);
    const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

    try self.exitOp(.br_z_im_v, &.{ .B0 = relativeBlockIndex, .R0 = x });
    try self.wideImmediate(w);
}

pub fn call(self: *BlockBuilder, f: Rbc.RegisterIndex, as: anytype) Error!void {
    try self.op(.call, &.{ .F0 = f });
    try self.args(as);
}

pub fn call_v(self: *BlockBuilder, f: Rbc.RegisterIndex, y: Rbc.RegisterIndex, as: anytype) Error!void {
    try self.op(.call_v, &.{ .F0 = f, .R0 = y });
    try self.args(as);
}

pub fn call_im(self: *BlockBuilder, f: anytype, as: anytype) Error!void {
    try self.op(.call_im, &.{ .F0 = try self.function.parent.extractFunctionIndex(f) });
    try self.args(as);
}

pub fn call_im_v(self: *BlockBuilder, f: anytype, y: Rbc.RegisterIndex, as: anytype) Error!void {
    try self.op(.call_im_v, &.{ .F0 = try self.function.parent.extractFunctionIndex(f), .R0 = y });
    try self.args(as);
}

pub fn tail_call(self: *BlockBuilder, f: Rbc.RegisterIndex, as: anytype) Error!void {
    try self.exitOp(.tail_call, &.{ .R0 = f });
    try self.args(as);
}

pub fn tail_call_im(self: *BlockBuilder, f: anytype, as: anytype) Error!void {
    try self.exitOp(.tail_call_im, &.{ .F0 = try self.function.parent.extractFunctionIndex(f) });
    try self.args(as);
}

pub fn prompt(self: *BlockBuilder, e: Rbc.EvidenceIndex, as: anytype) Error!void {
    try self.op(.prompt, &.{ .E0 = e });
    try self.args(as);
}

pub fn prompt_v(self: *BlockBuilder, e: Rbc.EvidenceIndex, y: Rbc.RegisterIndex, as: anytype) Error!void {
    try self.op(.prompt_v, &.{ .E0 = e, .R0 = y });
    try self.args(as);
}

pub fn ret(self: *BlockBuilder) Error!void {
    try self.exitOp(.ret, &{});
}

pub fn ret_v(self: *BlockBuilder, y: Rbc.RegisterIndex) Error!void {
    try self.exitOp(.ret_v, &.{ .R0 = y });
}

pub fn ret_im_v(self: *BlockBuilder, i: anytype) Error!void {
    try self.exitOp(.ret_im_v, &.{ .i0 = iCast(i) });
}

pub fn ret_im_w_v(self: *BlockBuilder, w: anytype) Error!void {
    try self.exitOp(.ret_im_w_v, {});
    try self.wideImmediate(w);
}

pub fn term(self: *BlockBuilder) Error!void {
    try self.exitOp(.term, &{});
}

pub fn term_v(self: *BlockBuilder, y: Rbc.RegisterIndex) Error!void {
    try self.exitOp(.term_v, &.{ .R0 = y });
}

pub fn term_im_v(self: *BlockBuilder, i: anytype) Error!void {
    try self.exitOp(.term_im_v, &.{ .i0 = iCast(i) });
}

pub fn term_im_w_v(self: *BlockBuilder, w: anytype) Error!void {
    try self.exitOp(.term_im_w_v, {});
    try self.wideImmediate(w);
}


pub fn alloca(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex) Error!void {
    try self.op(.alloca, &.{ .s0 = s, .R0 = x });
}

pub fn addr_global(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.addr_global, &.{ .G0 = g, .R0 = x });
}

pub fn addr_upvalue(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.addr_upvalue, &.{ .U0 = u, .R0 = x });
}

pub fn addr_local(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.addr_local, &.{ .R0 = x, .R1 = y });
}

pub fn read_global_8(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_global_8, &.{ .G0 = g, .R0 = x });
}

pub fn read_global_16(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_global_16, &.{ .G0 = g, .R0 = x });
}

pub fn read_global_32(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_global_32, &.{ .G0 = g, .R0 = x });
}

pub fn read_global_64(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_global_64, &.{ .G0 = g, .R0 = x });
}

pub fn read_upvalue_8(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_upvalue_8, &.{ .U0 = u, .R0 = x });
}

pub fn read_upvalue_16(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_upvalue_16, &.{ .U0 = u, .R0 = x });
}

pub fn read_upvalue_32(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_upvalue_32, &.{ .U0 = u, .R0 = x });
}

pub fn read_upvalue_64(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.read_upvalue_64, &.{ .U0 = u, .R0 = x });
}

pub fn write_global_8(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_global_8, &.{ .G0 = g, .R0 = x });
}

pub fn write_global_16(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_global_16, &.{ .G0 = g, .R0 = x });
}

pub fn write_global_32(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_global_32, &.{ .G0 = g, .R0 = x });
}

pub fn write_global_64(self: *BlockBuilder, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_global_64, &.{ .G0 = g, .R0 = x });
}

pub fn write_global_8_im(self: *BlockBuilder, b: anytype, g: Rbc.GlobalIndex) Error!void {
    try self.op(.write_global_8_im, &.{ .b0 = bCast(b), .G0 = g });
}

pub fn write_global_16_im(self: *BlockBuilder, s: anytype, g: Rbc.GlobalIndex) Error!void {
    try self.op(.write_global_16_im, &.{ .s0 = sCast(s), .G0 = g });
}

pub fn write_global_32_im(self: *BlockBuilder, i: anytype, g: Rbc.GlobalIndex) Error!void {
    try self.op(.write_global_32_im, &.{ .i0 = iCast(i), .G0 = g });
}

pub fn write_global_64_im(self: *BlockBuilder, w: anytype, g: Rbc.GlobalIndex) Error!void {
    try self.op(.write_global_64_im, &.{ .G0 = g });
    try self.wideImmediate(w);
}

pub fn write_upvalue_8(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_upvalue_8, &.{ .U0 = u, .R0 = x });
}

pub fn write_upvalue_16(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_upvalue_16, &.{ .U0 = u, .R0 = x });
}

pub fn write_upvalue_32(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_upvalue_32, &.{ .U0 = u, .R0 = x });
}

pub fn write_upvalue_64(self: *BlockBuilder, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) Error!void {
    try self.op(.write_upvalue_64, &.{ .U0 = u, .R0 = x });
}

pub fn write_upvalue_8_im(self: *BlockBuilder, b: anytype, u: Rbc.UpvalueIndex) Error!void {
    try self.op(.write_upvalue_8_im, &.{ .b0 = bCast(b), .U0 = u });
}

pub fn write_upvalue_16_im(self: *BlockBuilder, s: anytype, u: Rbc.UpvalueIndex) Error!void {
    try self.op(.write_upvalue_16_im, &.{ .s0 = sCast(s), .U0 = u });
}

pub fn write_upvalue_32_im(self: *BlockBuilder, i: anytype, u: Rbc.UpvalueIndex) Error!void {
    try self.op(.write_upvalue_32_im, &.{ .i0 = iCast(i), .U0 = u });
}

pub fn write_upvalue_64_im(self: *BlockBuilder, w: anytype, u: Rbc.UpvalueIndex) Error!void {
    try self.op(.write_upvalue_64_im, &.{ .U0 = u });
    try self.wideImmediate(w);
}

pub fn load_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.load_8, &.{ .R0 = x, .R1 = y });
}

pub fn load_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.load_16, &.{ .R0 = x, .R1 = y });
}

pub fn load_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.load_32, &.{ .R0 = x, .R1 = y });
}

pub fn load_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.load_64, &.{ .R0 = x, .R1 = y });
}

pub fn store_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.store_8, &.{ .R0 = x, .R1 = y });
}

pub fn store_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.store_16, &.{ .R0 = x, .R1 = y });
}

pub fn store_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.store_32, &.{ .R0 = x, .R1 = y });
}

pub fn store_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.store_64, &.{ .R0 = x, .R1 = y });
}

pub fn store_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.store_8_im, &.{ .b0 = bCast(b), .R0 = x });
}

pub fn store_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.store_16_im, &.{ .s0 = sCast(s), .R0 = x });
}

pub fn store_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.store_32_im, &.{ .i0 = iCast(i), .R0 = x });
}

pub fn store_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.store_64_im, &.{ .R0 = x });
    try self.wideImmediate(w);
}

pub fn clear_8(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!void {
    try self.op(.clear_8, &.{ .R0 = x });
}

pub fn clear_16(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!void {
    try self.op(.clear_16, &.{ .R0 = x });
}

pub fn clear_32(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!void {
    try self.op(.clear_32, &.{ .R0 = x });
}

pub fn clear_64(self: *BlockBuilder, x: Rbc.RegisterIndex) Error!void {
    try self.op(.clear_64, &.{ .R0 = x });
}

pub fn swap_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.swap_8, &.{ .R0 = x, .R1 = y });
}

pub fn swap_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.swap_16, &.{ .R0 = x, .R1 = y });
}

pub fn swap_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.swap_32, &.{ .R0 = x, .R1 = y });
}

pub fn swap_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.swap_64, &.{ .R0 = x, .R1 = y });
}

pub fn copy_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_8, &.{ .R0 = x, .R1 = y });
}

pub fn copy_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_16, &.{ .R0 = x, .R1 = y });
}

pub fn copy_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_32, &.{ .R0 = x, .R1 = y });
}

pub fn copy_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_64, &.{ .R0 = x, .R1 = y });
}

pub fn copy_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_8_im, &.{ .b0 = bCast(b), .R0 = x });
}

pub fn copy_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_16_im, &.{ .s0 = sCast(s), .R0 = x });
}

pub fn copy_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_32_im, &.{ .i0 = iCast(i), .R0 = x });
}

pub fn copy_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex) Error!void {
    try self.op(.copy_64_im, &.{ .R0 = x });
    try self.wideImmediate(w);
}


pub fn i_add_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_add_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_add_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_add_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_add_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn i_add_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn i_add_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn i_add_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_add_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_add_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_add_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_add_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_add_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_add_32_im(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_add_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_add_64_im(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_add_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn i_sub_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_sub_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_sub_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_sub_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_sub_8_im_a(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn i_sub_16_im_a(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn i_sub_32_im_a(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn i_sub_64_im_a(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn i_sub_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn i_sub_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn i_sub_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn i_sub_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_sub_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_sub_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_sub_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_sub_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_sub_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_sub_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_sub_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_sub_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_sub_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_sub_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_sub_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_sub_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_sub_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn i_mul_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_mul_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_mul_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_mul_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_mul_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn i_mul_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn i_mul_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn i_mul_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_mul_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_mul_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_mul_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_mul_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_mul_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_mul_32_im(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_mul_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_mul_64_im(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_mul_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_div_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_div_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_div_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_div_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_div_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_div_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_div_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_div_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_div_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_div_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_div_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_div_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_div_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_div_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_div_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_div_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_div_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_div_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_div_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_div_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_div_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_div_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_div_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_div_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_div_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_div_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_div_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_div_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_div_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_div_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_div_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_div_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_div_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_div_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_div_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_rem_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_rem_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_rem_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_rem_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_rem_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_rem_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_rem_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_rem_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_rem_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_rem_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_rem_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_rem_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_rem_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_rem_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_rem_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_rem_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_rem_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_rem_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_rem_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_rem_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_rem_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_rem_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_rem_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_rem_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_rem_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_rem_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_rem_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_rem_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_rem_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_rem_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_rem_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_rem_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_rem_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_rem_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_rem_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_neg_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_neg_8, &.{ .R0 = x, .R1 = y });
}

pub fn s_neg_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_neg_16, &.{ .R0 = x, .R1 = y });
}

pub fn s_neg_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_neg_32, &.{ .R0 = x, .R1 = y });
}

pub fn s_neg_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_neg_64, &.{ .R0 = x, .R1 = y });
}

pub fn f_neg_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_neg_32, &.{ .R0 = x, .R1 = y });
}

pub fn f_neg_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_neg_64, &.{ .R0 = x, .R1 = y });
}


pub fn band_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.band_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn band_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.band_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn band_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.band_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn band_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.band_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn band_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.band_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn band_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.band_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn band_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.band_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn band_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.band_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn bor_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bor_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bor_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bor_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bor_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn bor_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn bor_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn bor_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bor_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn bxor_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bxor_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bxor_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bxor_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bxor_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn bxor_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn bxor_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn bxor_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bxor_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn bnot_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bnot_8, &.{ .R0 = x, .R1 = y });
}

pub fn bnot_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bnot_16, &.{ .R0 = x, .R1 = y });
}

pub fn bnot_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bnot_32, &.{ .R0 = x, .R1 = y });
}

pub fn bnot_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bnot_64, &.{ .R0 = x, .R1 = y });
}

pub fn bshiftl_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bshiftl_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bshiftl_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bshiftl_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn bshiftl_8_im_a(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn bshiftl_16_im_a(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn bshiftl_32_im_a(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn bshiftl_64_im_a(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn bshiftl_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn bshiftl_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn bshiftl_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn bshiftl_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: anytype, y: Rbc.RegisterIndex) Error!void {
    try self.op(.bshiftl_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_bshiftr_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_bshiftr_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_bshiftr_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_bshiftr_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_bshiftr_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_bshiftr_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_bshiftr_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_bshiftr_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_bshiftr_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_bshiftr_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_bshiftr_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_bshiftr_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_bshiftr_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_bshiftr_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_bshiftr_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_bshiftr_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_bshiftr_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_bshiftr_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_bshiftr_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_bshiftr_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_bshiftr_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_bshiftr_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_bshiftr_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_bshiftr_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_bshiftr_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_bshiftr_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}


pub fn i_eq_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_eq_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_eq_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_eq_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_eq_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn i_eq_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn i_eq_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn i_eq_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_eq_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_eq_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_eq_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_eq_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_eq_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_eq_32_im(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_eq_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_eq_64_im(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_eq_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn i_ne_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_ne_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_ne_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_ne_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn i_ne_8_im(self: *BlockBuilder, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn i_ne_16_im(self: *BlockBuilder, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn i_ne_32_im(self: *BlockBuilder, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn i_ne_64_im(self: *BlockBuilder, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_ne_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_ne_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ne_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_ne_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ne_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_ne_32_im(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ne_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_ne_64_im(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ne_64_im, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_lt_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_lt_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_lt_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_lt_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_lt_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_lt_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_lt_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_lt_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_lt_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_lt_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_lt_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_lt_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_lt_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_lt_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_lt_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_lt_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_lt_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_lt_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_lt_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_lt_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_lt_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_lt_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_lt_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_lt_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_lt_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_lt_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_lt_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_lt_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_lt_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_lt_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_lt_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_lt_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn f_lt_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_lt_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_gt_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_gt_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_gt_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_gt_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_gt_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_gt_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_gt_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_gt_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_gt_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_gt_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_gt_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_gt_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_gt_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_gt_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_gt_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_gt_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_gt_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_gt_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_gt_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_gt_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_gt_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_gt_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_gt_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_gt_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_gt_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_gt_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_gt_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_gt_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_gt_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_gt_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_gt_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_gt_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn f_gt_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_gt_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_le_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_le_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_le_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_le_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_le_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_le_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_le_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_le_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_le_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_le_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_le_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_le_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_le_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_le_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_le_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_le_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_le_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_le_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_le_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_le_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_le_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_le_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_le_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_le_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_le_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_le_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_le_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_le_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_le_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_le_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_le_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_le_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn f_le_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_le_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_ge_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_ge_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_ge_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_ge_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn u_ge_8_im_a(self: *BlockBuilder, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn u_ge_16_im_a(self: *BlockBuilder, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn u_ge_32_im_a(self: *BlockBuilder, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn u_ge_64_im_a(self: *BlockBuilder, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn u_ge_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn u_ge_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn u_ge_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn u_ge_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ge_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_ge_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_8, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_ge_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_16, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_ge_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_ge_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn s_ge_8_im_a(self: *BlockBuilder, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
}

pub fn s_ge_16_im_a(self: *BlockBuilder, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
}

pub fn s_ge_32_im_a(self: *BlockBuilder, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn s_ge_64_im_a(self: *BlockBuilder, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn s_ge_8_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
}

pub fn s_ge_16_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
}

pub fn s_ge_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn s_ge_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ge_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_ge_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_ge_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
}

pub fn f_ge_32_im_a(self: *BlockBuilder, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
}

pub fn f_ge_64_im_a(self: *BlockBuilder, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ge_64_im_a, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}

pub fn f_ge_32_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
}

pub fn f_ge_64_im_b(self: *BlockBuilder, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ge_64_im_b, &.{ .R0 = x, .R1 = y });
    try self.wideImmediate(w);
}


pub fn u_ext_8_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ext_8_16, &.{ .R0 = x, .R1 = y });
}

pub fn u_ext_8_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ext_8_32, &.{ .R0 = x, .R1 = y });
}

pub fn u_ext_8_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ext_8_64, &.{ .R0 = x, .R1 = y });
}

pub fn u_ext_16_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ext_16_32, &.{ .R0 = x, .R1 = y });
}

pub fn u_ext_16_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ext_16_64, &.{ .R0 = x, .R1 = y });
}

pub fn u_ext_32_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u_ext_32_64, &.{ .R0 = x, .R1 = y });
}

pub fn s_ext_8_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ext_8_16, &.{ .R0 = x, .R1 = y });
}

pub fn s_ext_8_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ext_8_32, &.{ .R0 = x, .R1 = y });
}

pub fn s_ext_8_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ext_8_64, &.{ .R0 = x, .R1 = y });
}

pub fn s_ext_16_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ext_16_32, &.{ .R0 = x, .R1 = y });
}

pub fn s_ext_16_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ext_16_64, &.{ .R0 = x, .R1 = y });
}

pub fn s_ext_32_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s_ext_32_64, &.{ .R0 = x, .R1 = y });
}

pub fn f_ext_32_64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_ext_32_64, &.{ .R0 = x, .R1 = y });
}

pub fn i_trunc_64_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_trunc_64_32, &.{ .R0 = x, .R1 = y });
}

pub fn i_trunc_64_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_trunc_64_16, &.{ .R0 = x, .R1 = y });
}

pub fn i_trunc_64_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_trunc_64_8, &.{ .R0 = x, .R1 = y });
}

pub fn i_trunc_32_16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_trunc_32_16, &.{ .R0 = x, .R1 = y });
}

pub fn i_trunc_32_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_trunc_32_8, &.{ .R0 = x, .R1 = y });
}

pub fn i_trunc_16_8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.i_trunc_16_8, &.{ .R0 = x, .R1 = y });
}

pub fn f_trunc_64_32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f_trunc_64_32, &.{ .R0 = x, .R1 = y });
}

pub fn u8_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u8_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn u16_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u16_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn u32_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u32_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn u64_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u64_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn s8_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s8_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn s16_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s16_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn s32_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s32_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn s64_to_f32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s64_to_f32, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_u8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_u8, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_u16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_u16, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_u32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_u32, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_u64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_u64, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_s8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_s8, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_s16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_s16, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_s32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_s32, &.{ .R0 = x, .R1 = y });
}

pub fn f32_to_s64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f32_to_s64, &.{ .R0 = x, .R1 = y });
}

pub fn u8_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u8_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn u16_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u16_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn u32_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u32_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn u64_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.u64_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn s8_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s8_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn s16_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s16_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn s32_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s32_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn s64_to_f64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.s64_to_f64, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_u8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_u8, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_u16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_u16, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_u32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_u32, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_u64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_u64, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_s8(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_s8, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_s16(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_s16, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_s32(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_s32, &.{ .R0 = x, .R1 = y });
}

pub fn f64_to_s64(self: *BlockBuilder, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) Error!void {
    try self.op(.f64_to_s64, &.{ .R0 = x, .R1 = y });
}


comptime {
    for (std.meta.fieldNames(Rbc.Op.Code)) |name| {
        if (!@hasDecl(BlockBuilder, name)) {
            @compileError("missing method: BlockBuilder." ++ name);
        }
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
