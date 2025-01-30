const RbcBuilder = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");

pub const log = std.log.scoped(.rbc_builder);

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Error = error{
    InvalidIndex,

    TooManyBlocks,
    TooManyRegisters,
    TooManyUpvalues,

    InstructionsAfterExit,
    UnfinishedBlock,

    JumpTooLarge,
};

pub const MAX_BLOCKS = std.math.maxInt(BlockIndex);

pub const BlockIndex = u16;
pub const BlockOffset = usize;

const BlockList = std.ArrayListUnmanaged(*RbcBuilder.Block);

pub const Function = struct {
    allocator: std.mem.Allocator,

    index: Rbc.FunctionIndex,
    blocks: BlockList = .{},

    entry: *RbcBuilder.Block = undefined,
    evidence: ?Rbc.EvidenceIndex = null,
    num_locals: usize = 0,
    num_upvalues: usize = 0,

    pub fn init(allocator: std.mem.Allocator, index: Rbc.FunctionIndex) error{OutOfMemory}!*Function {
        const self = try allocator.create(Function);

        self.* = Function{
            .allocator = allocator,
            .index = index,
        };

        self.entry = try RbcBuilder.Block.init(self, 0);

        try self.blocks.append(allocator, self.entry);

        return self;
    }

    pub fn assemble(self: *const Function, allocator: std.mem.Allocator) error{ UnfinishedBlock, JumpTooLarge, InvalidIndex, OutOfMemory }!Rbc.Function {
        const blockOffsets = try self.allocator.alloc(BlockOffset, self.blocks.items.len);

        var offset: BlockOffset = 0;
        for (self.blocks.items, 0..) |builder, i| {
            blockOffsets[i] = offset;
            offset += try builder.preassemble();
        }

        const instructions = try allocator.alloc(Rbc.Instruction, offset);
        errdefer allocator.free(instructions);

        var instr_offset: BlockOffset = 0;
        for (self.blocks.items) |builder| {
            try builder.assemble(blockOffsets, &instr_offset, instructions);
        }

        return Rbc.Function{
            .num_registers = @intCast(self.num_locals),
            .bytecode = .{
                .instructions = instructions,
            },
        };
    }

    pub fn getBlock(self: *const Function, index: BlockIndex) error{InvalidIndex}!*RbcBuilder.Block {
        if (index >= self.blocks.items.len) {
            return error.InvalidIndex;
        }

        return self.blocks.items[index];
    }

    pub fn createBlock(self: *Function) error{ TooManyBlocks, OutOfMemory }!*RbcBuilder.Block {
        const index = self.blocks.items.len;
        if (index >= MAX_BLOCKS) return error.TooManyBlocks;

        const freshBlock = try RbcBuilder.Block.init(self, @intCast(index));
        try self.blocks.append(self.allocator, freshBlock);

        return freshBlock;
    }

    pub fn createRegister(self: *Function) error{TooManyRegisters}!Rbc.RegisterIndex {
        const index = self.num_locals;
        if (index >= Rbc.MAX_REGISTERS) return error.TooManyRegisters;

        self.num_locals += 1;

        return @intCast(index);
    }

    pub fn createUpvalue(self: *Function) error{TooManyUpvalues}!Rbc.UpvalueIndex {
        const index = self.num_upvalues;
        if (index >= Rbc.MAX_REGISTERS) return error.TooManyUpvalues;

        self.num_upvalues += 1;

        return @intCast(index);
    }
};

pub const Instruction = union(enum) {
    instruction: Rbc.Instruction,
    labeled: Branch,

    pub fn assemble(self: Instruction, offsetTable: []const BlockOffset, offset: BlockOffset) error{ JumpTooLarge, InvalidIndex }!Rbc.Instruction {
        return switch (self) {
            .instruction => |i| i,
            .labeled => |b| try b.assemble(offsetTable, offset),
        };
    }
};

pub const Branch = union(enum) {
    push_set: struct {
        B0: BlockIndex,
        H0: Rbc.HandlerSetIndex,
        R0: ?Rbc.RegisterIndex,
    },
    br: struct {
        B0: BlockIndex,
        @"if": ?struct {
            B1: BlockIndex,
            R0: Rbc.RegisterIndex,
        } = null,
    },

    pub fn assemble(self: Branch, offsetTable: []const BlockOffset, offset: BlockOffset) error{ JumpTooLarge, InvalidIndex }!Rbc.Instruction {
        return switch (self) {
            .push_set => |x|
                if (x.R0) |R0| Rbc.instr(.push_set_v, &.{ .B0 = try calcOffset(offsetTable, offset, x.B0), .H0 = x.H0, .R0 = R0 })
                else Rbc.instr(.push_set, &.{ .B0 = try calcOffset(offsetTable, offset, x.B0), .H0 = x.H0 }),
            .br => |x|
                if (x.@"if") |y|
                    Rbc.instr(.br_if, &.{ .B0 = try calcOffset(offsetTable, offset, x.B0), .B1 = try calcOffset(offsetTable, offset, y.B1), .R0 = y.R0 })
                else Rbc.instr(.br, &.{ .B0 = try calcOffset(offsetTable, offset, x.B0) }),
        };
    }

    fn calcOffset(offsetTable: []const BlockOffset, offset: BlockOffset, target: BlockIndex) error{ JumpTooLarge, InvalidIndex }!Rbc.JumpOffset {
        const targetOffset = offsetTable[target];

        if (offset < targetOffset) {
            const offsetDiff = targetOffset - offset;
            if (offsetDiff > Rbc.MAX_JUMP_OFFSET) {
                return error.JumpTooLarge;
            }

            return @intCast(offsetDiff);
        } else if (offset > targetOffset) {
            const offsetDiff = offset - targetOffset;
            if (offsetDiff > Rbc.MAX_JUMP_OFFSET) {
                return error.JumpTooLarge;
            }

            return -@as(Rbc.JumpOffset, @intCast(offsetDiff));
        } else {
            return error.InvalidIndex;
        }
    }
};

const InstrList = std.ArrayListUnmanaged(Instruction);

pub fn bCast(b: anytype) u8 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u8, b),
        .int => |info| if (info.bits <= 8) switch (info.signedness) {
            .unsigned => @as(u8, b),
            .signed => @as(u8, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
        } else @bitCast(@as(std.meta.Int(info.signedness, 8), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u8, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub fn sCast(b: anytype) u16 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u16, b),
        .int => |info| if (info.bits <= 16) switch (info.signedness) {
            .unsigned => @as(u16, b),
            .signed => @as(u16, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
        } else @bitCast(@as(std.meta.Int(info.signedness, 16), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u16, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub fn iCast(b: anytype) u32 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u32, b),
        .int => |info| if (info.bits <= 32) switch (info.signedness) {
            .unsigned => @as(u32, b),
            .signed => @as(u32, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
        } else @bitCast(@as(std.meta.Int(info.signedness, 32), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u32, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub fn wCast(b: anytype) u64 {
    return switch (@typeInfo(@TypeOf(b))) {
        .comptime_int => @as(u64, b),
        .int => |info| if (info.bits <= 64) switch (info.signedness) {
            .unsigned => @as(u64, b),
            .signed => @as(u64, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
        } else @bitCast(@as(std.meta.Int(info.signedness, 64), @intCast(b))),
        .@"enum" => bCast(@intFromEnum(b)),
        else => @as(u64, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
    };
}

pub const Block = struct {
    function: *RbcBuilder.Function,
    index: BlockIndex,
    exited: bool = false,
    ops: InstrList = .{},

    pub fn init(func: *RbcBuilder.Function, index: BlockIndex) error{OutOfMemory}!*Block {
        const self = try func.allocator.create(Block);

        self.* = Block{
            .function = func,
            .index = index,
            .exited = false,
        };

        return self;
    }

    pub fn preassemble(self: *const Block) error{UnfinishedBlock}!BlockOffset {
        if (!self.exited) {
            return error.UnfinishedBlock;
        }

        return self.ops.items.len;
    }

    pub fn assemble(self: *const Block, offsetTable: []const BlockOffset, offset: *BlockOffset, buf: []Rbc.Instruction) error{ JumpTooLarge, InvalidIndex }!void {
        for (self.ops.items) |x| {
            buf[offset.*] = try x.assemble(offsetTable, offset.*);
            offset.* += 1;
        }
    }

    pub fn args(self: *Block, rArgs: []const Rbc.RegisterIndex) error{ TooManyRegisters, OutOfMemory }!void {
        if (rArgs.len == 0) {
            return;
        } else if (rArgs.len > Rbc.MAX_REGISTERS) {
            return error.TooManyRegisters;
        }

        var acc = [1]Rbc.RegisterIndex{Rbc.MAX_REGISTERS} ** (@sizeOf(Rbc.Instruction) / @sizeOf(Rbc.RegisterIndex));

        var i: BlockOffset = 0;
        while (i < rArgs.len) : (i += 1) {
            acc[i % acc.len] = rArgs[i];
            if (i != 0 and i % acc.len == 0) {
                try self.ops.append(self.function.allocator, Instruction { .instruction = @as(Rbc.Instruction, @bitCast(acc)) });
            }
        }

        if (i % acc.len != 0) {
            for ((i % acc.len)..acc.len) |j| acc[j] = Rbc.MAX_REGISTERS;
            try self.ops.append(self.function.allocator, Instruction { .instruction = @as(Rbc.Instruction, @bitCast(acc)) });
        }
    }

    pub fn wideImmediate(self: *Block, w: anytype) error{OutOfMemory}!void {
        try self.ops.append(self.function.allocator, .{ .instruction = @bitCast(wCast(w)) });
    }

    pub fn op(self: *Block, code: Rbc.Code, data: *const anyopaque) error{ InstructionsAfterExit, OutOfMemory }!void {
        if (self.exited) return error.InstructionsAfterExit;

        try self.ops.append(self.function.allocator, .{ .instruction = Rbc.instr(code, data) });
    }

    pub fn nop(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.nop, &{});
    }

    pub fn eof(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.eof, &{});
    }

    pub fn halt(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.halt, &{});

        self.exited = true;
    }

    pub fn trap(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.trap, &{});

        self.exited = true;
    }

    pub fn push_set(self: *Block, b: BlockIndex, h: Rbc.HandlerSetIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        if (self.exited) return error.InstructionsAfterExit;
        try self.ops.append(self.function.allocator, .{ .labeled = .{ .push_set = .{ .B0 = b, .H0 = h, .R0 = null } } });
    }

    pub fn push_set_v(self: *Block, b: BlockIndex, h: Rbc.HandlerSetIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        if (self.exited) return error.InstructionsAfterExit;
        try self.ops.append(self.function.allocator, .{ .labeled = .{ .push_set = .{ .B0 = b, .H0 = h, .R0 = y } } });
    }

    pub fn pop_set(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.pop_set, &{});
    }

    pub fn br(self: *Block, b: BlockIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        if (self.exited) return error.InstructionsAfterExit;
        try self.ops.append(self.function.allocator, .{ .labeled = .{ .br = .{ .B0 = b } } });
        self.exited = true;
    }

    pub fn br_if(self: *Block, t: BlockIndex, e: BlockIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        if (self.exited) return error.InstructionsAfterExit;
        try self.ops.append(self.function.allocator, .{ .labeled = .{ .br = .{ .B0 = t, .@"if" = .{ .B1 = e, .R0 = x } } } });
        self.exited = true;
    }

    pub fn call(self: *Block, f: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.call, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f });
        try self.args(as);
    }

    pub fn call_v(self: *Block, f: Rbc.RegisterIndex, y: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.call_v, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f, .R0 = y });
        try self.args(as);
    }

    pub fn call_im(self: *Block, f: Rbc.FunctionIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.call_im, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f });
        try self.args(as);
    }

    pub fn call_im_v(self: *Block, f: Rbc.FunctionIndex, y: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.call_im_v, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f, .R0 = y });
        try self.args(as);
    }

    pub fn tail_call(self: *Block, f: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.tail_call, &.{ .b0 = @as(u8, @truncate(as.len)), .R0 = f });
        try self.args(as);
        self.exited = true;
    }

    pub fn tail_call_im(self: *Block, f: Rbc.FunctionIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.tail_call_im, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f });
        try self.args(as);
        self.exited = true;
    }

    pub fn foreign_call(self: *Block, f: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.foreign_call, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f });
        try self.args(as);
    }

    pub fn foreign_call_v(self: *Block, f: Rbc.RegisterIndex, y: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.foreign_call_v, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f, .R0 = y });
        try self.args(as);
    }

    pub fn foreign_call_im(self: *Block, f: Rbc.ForeignIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.foreign_call_im, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f });
        try self.args(as);
    }

    pub fn foreign_call_im_v(self: *Block, f: Rbc.ForeignIndex, y: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.foreign_call_im_v, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f, .R0 = y });
        try self.args(as);
    }

    pub fn tail_foreign_call(self: *Block, f: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.tail_foreign_call, &.{ .b0 = @as(u8, @truncate(as.len)), .R0 = f });
        try self.args(as);
        self.exited = true;
    }

    pub fn tail_foreign_call_im(self: *Block, f: Rbc.ForeignIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.tail_foreign_call_im, &.{ .b0 = @as(u8, @truncate(as.len)), .F0 = f });
        try self.args(as);
        self.exited = true;
    }

    pub fn prompt(self: *Block, e: Rbc.EvidenceIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.prompt, &.{ .b0 = @as(u8, @truncate(as.len)), .E0 = e });
        try self.args(as);
    }

    pub fn prompt_v(self: *Block, e: Rbc.EvidenceIndex, y: Rbc.RegisterIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.prompt_v, &.{ .b0 = @as(u8, @truncate(as.len)), .E0 = e, .R0 = y });
        try self.args(as);
    }

    pub fn tail_prompt(self: *Block, e: Rbc.EvidenceIndex, as: []const Rbc.RegisterIndex) error{ TooManyRegisters, InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.prompt, &.{ .E0 = e });
        try self.args(as);
    }

    pub fn ret(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.ret, &{});
        self.exited = true;
    }

    pub fn ret_v(self: *Block, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.ret_v, &.{ .R0 = y });
        self.exited = true;
    }

    pub fn ret_im_v(self: *Block, i: anytype) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.ret_im_v, &.{ .i0 = iCast(i) });
        self.exited = true;
    }

    pub fn ret_im_w_v(self: *Block, w: anytype) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.ret_im_w_v, {});
        self.exited = true;
        try self.wideImmediate(w);
    }

    pub fn cancel(self: *Block) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.cancel, &{});
        self.exited = true;
    }

    pub fn cancel_v(self: *Block, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.cancel_v, &.{ .R0 = y });
        self.exited = true;
    }

    pub fn cancel_im_v(self: *Block, i: anytype) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.cancel_im_v, &.{ .i0 = iCast(i) });
        self.exited = true;
    }

    pub fn cancel_im_w_v(self: *Block, w: anytype) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.cancel_im_w_v, {});
        self.exited = true;
        try self.wideImmediate(w);
    }

    pub fn alloca(self: *Block, s: u16, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.alloca, &.{ .s0 = s, .R0 = x });
    }

    pub fn addr_global(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.addr_global, &.{ .G0 = g, .R0 = x });
    }

    pub fn addr_upvalue(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.addr_upvalue, &.{ .U0 = u, .R0 = x });
    }

    pub fn addr_foreign(self: *Block, x: Rbc.ForeignIndex, r: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.addr_foreign, &.{ .X0 = x, .R0 = r });
    }

    pub fn addr_function(self: *Block, f: Rbc.FunctionIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.addr_function, &.{ .F0 = f, .R0 = x });
    }

    pub fn read_global_8(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_global_8, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_global_16(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_global_16, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_global_32(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_global_32, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_global_64(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_global_64, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_upvalue_8(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_upvalue_8, &.{ .U0 = u, .R0 = x });
    }

    pub fn read_upvalue_16(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_upvalue_16, &.{ .U0 = u, .R0 = x });
    }

    pub fn read_upvalue_32(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_upvalue_32, &.{ .U0 = u, .R0 = x });
    }

    pub fn read_upvalue_64(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.read_upvalue_64, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_global_8(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_8, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_16(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_16, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_32(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_32, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_64(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_64, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_8_im(self: *Block, b: anytype, g: Rbc.GlobalIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_8_im, &.{ .b0 = bCast(b), .G0 = g });
    }

    pub fn write_global_16_im(self: *Block, s: anytype, g: Rbc.GlobalIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_16_im, &.{ .s0 = sCast(s), .G0 = g });
    }

    pub fn write_global_32_im(self: *Block, i: anytype, g: Rbc.GlobalIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_32_im, &.{ .i0 = iCast(i), .G0 = g });
    }

    pub fn write_global_64_im(self: *Block, w: anytype, g: Rbc.GlobalIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_global_64_im, &.{ .G0 = g });
        try self.wideImmediate(w);
    }

    pub fn write_upvalue_8(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_8, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_16(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_16, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_32(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_32, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_64(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_64, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_8_im(self: *Block, b: anytype, u: Rbc.UpvalueIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_8_im, &.{ .b0 = bCast(b), .U0 = u });
    }

    pub fn write_upvalue_16_im(self: *Block, s: anytype, u: Rbc.UpvalueIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_16_im, &.{ .s0 = sCast(s), .U0 = u });
    }

    pub fn write_upvalue_32_im(self: *Block, i: anytype, u: Rbc.UpvalueIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_32_im, &.{ .i0 = iCast(i), .U0 = u });
    }

    pub fn write_upvalue_64_im(self: *Block, w: anytype, u: Rbc.UpvalueIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.write_upvalue_64_im, &.{ .U0 = u });
        try self.wideImmediate(w);
    }

    pub fn load_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.load_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn load_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.load_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn load_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.load_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn load_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.load_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_8_im, &.{ .b0 = bCast(b), .R0 = x });
    }

    pub fn store_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_16_im, &.{ .s0 = sCast(s), .R0 = x });
    }

    pub fn store_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_32_im, &.{ .i0 = iCast(i), .R0 = x });
    }

    pub fn store_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.store_64_im, &.{ .R0 = x });
        try self.wideImmediate(w);
    }

    pub fn clear_8(self: *Block, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.clear_8, &.{ .R0 = x });
    }

    pub fn clear_16(self: *Block, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.clear_16, &.{ .R0 = x });
    }

    pub fn clear_32(self: *Block, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.clear_32, &.{ .R0 = x });
    }

    pub fn clear_64(self: *Block, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.clear_64, &.{ .R0 = x });
    }

    pub fn swap_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.swap_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn swap_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.swap_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn swap_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.swap_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn swap_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.swap_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_8_im, &.{ .b0 = bCast(b), .R0 = x });
    }

    pub fn copy_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_16_im, &.{ .s0 = sCast(s), .R0 = x });
    }

    pub fn copy_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_32_im, &.{ .i0 = iCast(i), .R0 = x });
    }

    pub fn copy_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.copy_64_im, &.{ .R0 = x });
        try self.wideImmediate(w);
    }

    pub fn i_add_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_add_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_add_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_add_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_add_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_add_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_add_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_add_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_add_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_add_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_add_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_add_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_add_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_sub_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_8_im_a(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_sub_16_im_a(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_sub_32_im_a(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_sub_64_im_a(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_sub_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn i_sub_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn i_sub_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn i_sub_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_sub_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_sub_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_sub_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_sub_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_sub_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_sub_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_sub_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_sub_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_sub_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_sub_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_sub_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_sub_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_sub_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_mul_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_mul_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_mul_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_mul_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_mul_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_mul_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_mul_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_mul_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_mul_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_mul_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_mul_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_mul_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_mul_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_div_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_div_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_div_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_div_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_div_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_div_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_div_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_div_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_div_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_div_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_div_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_div_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_div_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_div_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_div_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_div_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_div_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_div_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_div_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_div_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_div_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_div_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_div_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_div_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_div_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_div_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_div_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_rem_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_rem_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_rem_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_rem_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_rem_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_rem_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_rem_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_rem_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_rem_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_rem_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_rem_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_rem_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_rem_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_rem_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_rem_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_rem_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_rem_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_rem_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_rem_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_rem_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_rem_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_rem_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_rem_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_rem_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_rem_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_rem_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_rem_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_neg_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_neg_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_neg_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_neg_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_neg_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_neg_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_neg_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_neg_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_neg_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_neg_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_neg_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_neg_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn band_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn band_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn band_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn band_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.band_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bor_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn bor_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn bor_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn bor_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bor_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bxor_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn bxor_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn bxor_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn bxor_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bxor_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bnot_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bnot_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn bnot_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bnot_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn bnot_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bnot_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn bnot_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bnot_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn bshiftl_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_8_im_a(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn bshiftl_16_im_a(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn bshiftl_32_im_a(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn bshiftl_64_im_a(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bshiftl_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn bshiftl_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn bshiftl_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn bshiftl_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: anytype, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.bshiftl_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_bshiftr_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_bshiftr_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_bshiftr_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_bshiftr_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_bshiftr_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_bshiftr_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_bshiftr_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_bshiftr_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_bshiftr_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_bshiftr_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_bshiftr_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_bshiftr_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_bshiftr_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_bshiftr_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_bshiftr_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_bshiftr_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_bshiftr_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_bshiftr_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_eq_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_eq_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_eq_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_eq_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_eq_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_eq_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_eq_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_eq_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_eq_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_eq_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_eq_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_eq_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_eq_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_ne_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_ne_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_ne_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_ne_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_ne_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_ne_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ne_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ne_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ne_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ne_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ne_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_ne_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ne_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_lt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_lt_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_lt_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_lt_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_lt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_lt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_lt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_lt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_lt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_lt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_lt_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_lt_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_lt_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_lt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_lt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_lt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_lt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_lt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_lt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_lt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_lt_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_lt_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_lt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_lt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_lt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_lt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_gt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_gt_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_gt_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_gt_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_gt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_gt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_gt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_gt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_gt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_gt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_gt_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_gt_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_gt_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_gt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_gt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_gt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_gt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_gt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_gt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_gt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_gt_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_gt_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_gt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_gt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_gt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_gt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_le_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_le_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_le_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_le_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_le_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_le_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_le_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_le_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_le_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_le_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_le_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_le_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_le_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_le_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_le_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_le_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_le_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_le_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_le_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_le_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_le_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_le_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_le_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_le_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_le_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_le_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_ge_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_ge_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_ge_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_ge_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_ge_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_ge_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_ge_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_ge_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ge_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_ge_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_ge_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_ge_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_ge_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_ge_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_ge_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_ge_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_ge_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ge_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_ge_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ge_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ge_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_ge_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ge_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_ge_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_ge_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ge_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_ext_8_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ext_8_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_8_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ext_8_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_8_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ext_8_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_16_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ext_16_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_16_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ext_16_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_32_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u_ext_32_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_8_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ext_8_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_8_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ext_8_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_8_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ext_8_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_16_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ext_16_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_16_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ext_16_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_32_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s_ext_32_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_ext_32_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_ext_32_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_64_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_trunc_64_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_64_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_trunc_64_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_64_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_trunc_64_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_32_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_trunc_32_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_32_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_trunc_32_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_16_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.i_trunc_16_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_trunc_64_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f_trunc_64_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u8_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u8_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u16_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u16_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u32_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u32_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u64_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u64_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s8_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s8_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s16_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s16_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s32_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s32_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s64_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s64_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_u8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_u16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_u32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_u64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_s8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_s16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_s32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f32_to_s64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u8_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u8_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u16_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u16_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u32_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u32_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u64_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.u64_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s8_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s8_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s16_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s16_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s32_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s32_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s64_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.s64_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_u8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_u16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_u32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_u64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_s8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_s16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_s32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) error{ InstructionsAfterExit, OutOfMemory }!void {
        try self.op(.f64_to_s64, &.{ .R0 = x, .R1 = y });
    }
};

comptime {
    for (std.meta.fieldNames(Rbc.Code)) |name| {
        if (!@hasDecl(Block, name)) {
            @compileError("missing method: BlockRbcBuilder." ++ name);
        }
    }
}
