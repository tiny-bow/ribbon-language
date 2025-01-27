const Generator = @import("../RbcGenerator.zig");

const block = @This();

const std = @import("std");
const utils = @import("utils");

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");



const Stack = std.ArrayListUnmanaged(Rir.Operand);
const RegisterList = std.ArrayListUnmanaged(*Rir.Register);

pub const Block = struct {
    generator: *Generator,
    function: *Generator.Function,

    parent: ?*Block,

    ir: *Rir.Block,
    builder: *RbcBuilder.Block,

    register_list: RegisterList,

    stack: Stack = .{},


    pub fn init(parent: ?*Block, function: *Generator.Function, blockIr: *Rir.Block, blockBuilder: *RbcBuilder.Block) error{OutOfMemory}! *Block {
        const generator = function.generator;
        const self = try generator.allocator.create(Block);

        self.* = Block {
            .function = function,
            .generator = generator,

            .parent = parent,

            .ir = blockIr,
            .builder = blockBuilder,

            .register_list = try RegisterList.initCapacity(generator.allocator, Rir.MAX_REGISTERS),
        };

        return self;
    }

    pub fn deinit(self: *Block) void {
        self.register_list.deinit(self.generator.allocator);
        self.stack.deinit(self.generator.allocator);

        self.generator.allocator.destroy(self);
    }

    pub fn generate(self: *Block) Generator.Error! void {
        const instrs = self.ir.instructions.items;

        var i: usize = 0;
        while (i < instrs.len) {
            const instr = instrs[i];
            i += 1;

            switch (instr.code) {
                .nop => try self.builder.nop(),
                .halt => try self.builder.halt(),
                .trap => try self.builder.trap(),

                .block => {
                    const blockIr = try (try self.pop(.meta)).forceBlock();
                    const child = try self.function.compileBlock(blockIr);

                    if (child.stackDepth() == 0) {
                        try self.builder.op(.block, &.{ .B0 = child.builder.index });
                    } else {
                        const operand = try child.pop(null);

                        if (child.stackDepth() != 0) return error.StackNotCleared;

                        const operandType = try operand.getType();

                        const resultRegister = try self.allocRegister(operandType); // FIXME: see NOTES.md#1

                        try self.builder.op(.block_v, &.{ .B0 = child.builder.index, .R0 = resultRegister.getIndex() });
                    }
                },
                .with => {
                    const handlerSetIr = try (try self.pop(.meta)).forceHandlerSet();
                    const blockIr = try (try self.pop(.meta)).forceBlock();

                    const child = try self.function.compileBlock(blockIr);

                    const handlerSetBuilder = try self.function.module.getHandlerSet(handlerSetIr);

                    if (child.stackDepth() == 0) {
                        try self.builder.op(.with, &.{ .B0 = child.builder.index, .H0 = handlerSetBuilder.index });
                    } else {
                        const operand = try child.pop(null);

                        if (child.stackDepth() != 0) return error.StackNotCleared;

                        const operandType = try operand.getType();

                        const resultRegister = try self.allocRegister(operandType); // FIXME: see NOTES.md#1

                        try self.builder.op(.with_v, &.{ .B0 = child.builder.index, .H0 = handlerSetBuilder.index, .R0 = resultRegister.getIndex() });
                    }
                },
                .@"if" => {
                    const zeroCheck = instr.data.@"if";

                    const condReg = try (try self.pop(.l_value)).forceRegister();
                    const thenBlockIr = try (try self.pop(.meta)).forceBlock();
                    const elseBlockIr = try (try self.pop(.meta)).forceBlock();

                    const thenChild = try self.function.compileBlock(thenBlockIr);
                    const elseChild = try self.function.compileBlock(elseBlockIr);

                    if (thenChild.stackDepth() != elseChild.stackDepth()) return error.StackBranchMismatch;

                    if (thenChild.stackDepth() == 0) {
                        try self.builder.op(
                            switch (zeroCheck) {
                                .zero => .if_z,
                                .non_zero => .if_nz,
                            },
                            &.{
                                .R0 = condReg.getIndex(),
                                .B0 = thenChild.builder.index,
                                .B1 = elseChild.builder.index
                            },
                        );
                    } else {
                        const thenOperand = try thenChild.pop(null);
                        const elseOperand = try elseChild.pop(null);

                        if (thenChild.stackDepth() != 0) {
                            return error.StackNotCleared;
                        }

                        const operandType = try thenOperand.getType();
                        const elseOperandType = try elseOperand.getType();

                        if (operandType.id != elseOperandType.id) {
                            return error.StackBranchMismatch;
                        }

                        const resultRegister = try self.allocRegister(operandType); // FIXME: see NOTES.md#1

                        try self.builder.op(
                            switch (zeroCheck) {
                                .zero => .if_z_v,
                                .non_zero => .if_nz_v,
                            },
                            &.{
                                .R0 = condReg.getIndex(),
                                .R1 = resultRegister.getIndex(),
                                .B0 = thenChild.builder.index,
                                .B1 = elseChild.builder.index
                            },
                        );
                    }
                },
                .when => {
                    const zeroCheck = instr.data.when;

                    const condReg = try (try self.pop(.l_value)).forceRegister();
                    const thenBlockIr = try (try self.pop(.meta)).forceBlock();

                    const thenChild = try self.function.compileBlock(thenBlockIr);

                    if (thenChild.stackDepth() == 0) {
                        try self.builder.op(
                            switch (zeroCheck) {
                                .zero => .when_z,
                                .non_zero => .when_nz,
                            },
                            &.{
                                .R0 = condReg.getIndex(),
                                .B0 = thenChild.builder.index
                            },
                        );
                    } else {
                        return error.StackBranchMismatch;
                    }
                },


                .re => {
                    const zeroCheck = instr.data.re;

                    switch (zeroCheck) {
                        .none => {
                            const blockIr = try (try self.pop(.meta)).forceBlock();
                            const blockGen = try self.function.getBlock(blockIr);

                            try self.builder.re(blockGen.builder);
                        },
                        .zero => {
                            const condReg = try (try self.pop(.l_value)).forceRegister();
                            const blockIr = try (try self.pop(.meta)).forceBlock();
                            const blockGen = try self.function.getBlock(blockIr);

                            try self.builder.re_z(blockGen.builder, condReg.getIndex());
                        },
                        .non_zero => {
                            const condReg = try (try self.pop(.l_value)).forceRegister();
                            const blockIr = try (try self.pop(.meta)).forceBlock();
                            const blockGen = try self.function.getBlock(blockIr);

                            try self.builder.re_nz(blockGen.builder, condReg.getIndex());
                        },
                    }
                },

                .br => {
                    const zeroCheck = instr.data.br;

                    const blockIr = try (try self.pop(.meta)).forceBlock();
                    const blockGen = try self.function.getBlock(blockIr);

                    switch (zeroCheck) {
                        .none => try self.builder.br(blockGen.builder),
                        .zero => switch (self.stackDepth()) {
                            0 => return error.StackUnderflow,
                            1 => {
                                const condReg = try (try self.pop(.l_value)).forceRegister();

                                try self.builder.br_z(blockGen.builder, condReg.getIndex());
                            },
                            2 => {
                                const elseOperand: Rir.Operand = try self.pop(null);

                                const condReg = try (try self.pop(.l_value)).forceRegister();

                                switch (elseOperand) {
                                    .meta => return error.InvalidOperand,
                                    .r_value => |r| switch (r) {
                                        .immediate => |im| try self.builder.br_z_im_v(blockGen.builder, condReg.getIndex(), im.data),
                                        .foreign => |f| {
                                            const foreignId = try self.generator.getForeign(f);
                                            try self.builder.br_z_im_v(blockGen.builder, condReg.getIndex(), foreignId);
                                        },
                                        .function => |f| {
                                            const function = try self.generator.getFunction(f);
                                            try self.builder.br_z_im_v(blockGen.builder, condReg.getIndex(), function.builder.index);
                                        },
                                    },
                                    .l_value => |l| switch (l) {
                                        .register => |r| try self.builder.br_z_v(blockGen.builder, condReg.getIndex(), r.getIndex()),
                                        .multi_register => @panic("multi_register nyi"),
                                        .local => @panic("local nyi"),
                                        .upvalue => @panic("upvalue nyi"),
                                        .global => @panic("global nyi"),
                                    }
                                }
                            },
                            else => return error.StackNotCleared,
                        },
                        .non_zero => @panic("br non_zero nyi"),
                    }
                },

                .call => @panic("call nyi"),
                .prompt => @panic("prompt nyi"),
                .ret => @panic("ret nyi"),
                .term => @panic("term nyi"),

                .alloca => {
                    const typeIr = try (try self.pop(.meta)).forceType();

                    const typeLayout = try typeIr.getLayout();

                    const register = try self.allocRegister(typeIr);

                    try self.builder.alloca(@intCast(typeLayout.dimensions.size), register.getIndex());

                    try self.push(register);
                },

                .addr => {
                    const operand: Rir.Operand = try self.pop(null);

                    const operandType = try operand.getType();
                    const pointerType = try operandType.createPointer();

                    switch (operand) {
                        .l_value => |l| switch (l) {
                            .local => |localIr| {
                                switch (localIr.storage) {
                                    .none => return error.InvalidOperand,
                                    .zero_size => try self.push(Rir.Immediate.zero(pointerType)),
                                    .register => return error.AddressOfRegister,
                                    .n_registers => return error.AddressOfRegister,
                                    .stack => try self.push(localIr.register orelse return error.LocalNotAssignedRegister),
                                    .@"comptime" => return error.InvalidOperand, // TODO: create global?
                                }
                            },

                            .global => |globalIr| {
                                const globalGen = try self.generator.getGlobal(globalIr);

                                const outReg = try self.allocRegister(pointerType);

                                try self.builder.addr_global(globalGen.builder.index, outReg.getIndex());
                                try self.push(outReg);
                            },

                            .upvalue => { // FIXME: see NOTES.md#2
                                @panic("addr upvalue nyi");
                                // const upvalueGen = try self.function.getUpvalue(upvalueIr);

                                // const outReg = try self.allocRegister(pointerType);

                                // try self.builder.addr_upvalue(upvalueGen.builder.index, outReg.getIndex());
                                // try self.push(outReg);
                            },

                            else => return error.InvalidOperand,
                        },
                        else => @panic("addr meta/r_value nyi"),
                    }
                },

                .read => @panic("read nyi"),

                .write => @panic("write nyi"),


                .load => @panic("load nyi"),
                .store => @panic("store nyi"),

                .add => @panic("add nyi"),
                .sub => @panic("sub nyi"),
                .mul => @panic("mul nyi"),
                .div => @panic("div nyi"),
                .rem => @panic("rem nyi"),
                .neg => @panic("neg nyi"),

                .band => @panic("band nyi"),
                .bor => @panic("bor nyi"),
                .bxor => @panic("bxor nyi"),
                .bnot => @panic("bnot nyi"),
                .bshiftl => @panic("bshiftl nyi"),
                .bshiftr => @panic("bshiftr nyi"),

                .eq => @panic("eq nyi"),
                .ne => @panic("ne nyi"),
                .lt => @panic("lt nyi"),
                .gt => @panic("gt nyi"),
                .le => @panic("le nyi"),
                .ge => @panic("ge nyi"),

                .ext => @panic("ext nyi"),
                .trunc => @panic("trunc nyi"),
                .cast => @panic("cast nyi"),

                .clear => {
                    const count = instr.data.clear;

                    if (count > self.stackDepth()) return error.StackUnderflow;

                    for (count) |_| _ = try self.pop(null);
                },
                .swap => {
                    const index = instr.data.swap;

                    if (index >= self.stackDepth()) return error.StackUnderflow;

                    const a = &self.stack.items[self.stackDepth() - 1 - index];
                    const b = &self.stack.items[self.stackDepth() - 1];

                    std.mem.swap(Rir.Operand, a, b);
                },
                .copy => {
                    const index = instr.data.copy;

                    if (index >= self.stackDepth()) return error.StackUnderflow;

                    const operand = self.stack.items[self.stackDepth() - 1 - index];

                    try self.push(operand);
                },

                .new_local => {
                    const name = instr.data.new_local;

                    const typeIr = try (try self.pop(.meta)).forceType();

                    const local = try self.createLocal(name, typeIr);

                    try self.push(local.id);
                },

                .ref_local => try self.push(instr.data.ref_local),
                .ref_block => try self.push(instr.data.ref_block),
                .ref_function => try self.push(instr.data.ref_function),
                .ref_foreign => try self.push(instr.data.ref_foreign),
                .ref_global => try self.push(instr.data.ref_global),
                .ref_upvalue => try self.push(instr.data.ref_upvalue),

                .im_i => try self.push(instr.data.im_i),
                .im_w => @panic("im_w nyi"),
            }
        }
    }

    pub fn stackDepth(self: *Block) usize {
        return self.stack.items.len;
    }

    pub fn push(self: *Block, operand: anytype) !void {
        try self.stack.append(self.generator.allocator, Rir.Operand.from(operand));
    }

    pub fn pop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand)) !if (kind) |k| switch (k) {
        .meta => Rir.Meta,
        .l_value => Rir.LValue,
        .r_value => Rir.RValue,
    } else Rir.Operand {
        if (self.stack.popOrNull()) |operand| {
            return if (comptime kind) |k| switch (operand) {
                .meta => |m| if (k == .meta) m else error.InvalidOperand,
                .l_value => |l| if (k == .l_value) l else error.InvalidOperand,
                .r_value => |r| if (k == .r_value) r else error.InvalidOperand,
            }
            else operand;
        }

        return error.StackUnderflow;
    }

    pub fn takeFreeRegister(self: *Block) ?*Rir.Register {
        for (self.register_list.items) |reg| {
            if (reg.ref_count == 0) return reg;
        }

        return null;
    }

    pub fn allocRegister(self: *Block, typeIr: *Rir.Type) error{InvalidType, TooManyRegisters, OutOfMemory}! *Rir.Register {
        if (self.takeFreeRegister()) |reg| {
            reg.type = typeIr;
            return reg;
        }

        const index = self.register_list.items.len;
        if (index >= Rbc.MAX_REGISTERS) {
            return error.TooManyRegisters;
        }

        const freshReg = try Rir.Register.init(self.ir, @enumFromInt(index), typeIr);

        try self.register_list.append(self.generator.allocator, freshReg);

        return freshReg;
    }

    pub fn createLocal(self: *Block, name: Rir.NameId, typeIr: *Rir.Type) error{TooManyLocals, OutOfMemory}! *Rir.Local {
        const out = try self.ir.createLocal(name, typeIr);
        // const localType = try self.ir.ir.getType(localTypeId);
        // const localStorage = try localType.getStorage();

        // out.storage =

        return out;
    }

    pub fn getLocal(self: *Block, id: Rir.LocalId) !*Rir.Local {
        return self.ir.getLocal(id);
    }

    pub fn generateSetLocal(_: *Block, _: Rir.LocalId, _: Rir.Operand) error{TooManyLocals, OutOfMemory}! void {
        @panic("setLocal nyi");
    }
};
