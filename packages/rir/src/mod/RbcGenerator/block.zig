const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");


const Generator = @import("../RbcGenerator.zig");

pub const Block = struct {
    parent: ?*Block,
    function: *Generator.Function,

    ir: *Rir.Block,
    builder: *RbcBuilder.BlockBuilder,

    stack: std.ArrayListUnmanaged(Rir.Operand) = .{},


    pub fn init(parent: ?*Block, function: *Generator.Function, blockIr: *Rir.Block, blockBuilder: *RbcBuilder.BlockBuilder) !*Block {
        const self = try function.module.root.allocator.create(Block);

        self.* = Block {
            .parent = parent,
            .function = function,
            .ir = blockIr,
            .builder = blockBuilder,
        };

        return self;
    }

    pub fn deinit(self: *Block) void {
        self.stack.deinit(self.function.module.root.allocator);

        self.function.module.root.allocator.destroy(self);
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
                    const blockId = try self.pop(.block);
                    const child = try self.function.compileBlock(blockId);

                    if (child.stackDepth() == 0) {
                        try self.builder.op(.block, &.{ .B0 = child.builder.index });
                    } else {
                        const operand = try child.pop(null);

                        if (child.stackDepth() != 0) return error.StackNotCleared;

                        const operandType = try self.getType(operand);

                        const newLocalName = try self.function.module.root.freshName(.{child.ir.name, "result"});

                        const resultLocal = try self.createLocal(newLocalName, operandType);

                        try self.generateSetLocal(resultLocal.id, operand);

                        const resultRegister = try self.lvalue(.{.local = resultLocal.id});

                        try self.builder.op(.block_v, &.{ .B0 = child.builder.index, .R0 = resultRegister.index });
                    }
                },
                .with => {
                    const blockId = try self.pop(.block);
                    const handlerSetId = try self.pop(.handler_set);

                    const child = try self.function.compileBlock(blockId);

                    const handlerSetBuilder = try self.function.module.getHandlerSet(handlerSetId);

                    if (child.stackDepth() == 0) {
                        try self.builder.op(.with, &.{ .B0 = child.builder.index, .H0 = handlerSetBuilder.index });
                    } else {
                        const operand = try child.pop(null);

                        if (child.stackDepth() != 0) return error.StackNotCleared;

                        const operandType = try self.getType(operand);

                        const newLocalName = try self.function.module.root.freshName(.{child.ir.name, "result"});

                        const resultLocal = try self.createLocal(newLocalName, operandType);

                        try self.generateSetLocal(resultLocal.id, operand);

                        const resultRegister = try self.lvalue(.{.local = resultLocal.id});

                        try self.builder.op(.with_v, &.{ .B0 = child.builder.index, .H0 = handlerSetBuilder.index, .R0 = resultRegister.index });
                    }
                },
                .@"if" => {
                    const zeroCheck = instr.data.@"if";

                    const condOperand = try self.pop(null);
                    const thenId = try self.pop(.block);
                    const elseId = try self.pop(.block);

                    const condReg = try (try self.rvalue(condOperand)).forceRegister();

                    const thenChild = try self.function.compileBlock(thenId);
                    const elseChild = try self.function.compileBlock(elseId);

                    if (thenChild.stackDepth() != elseChild.stackDepth()) return error.StackBranchMismatch;

                    if (thenChild.stackDepth() == 0) {
                        try self.builder.op(
                            switch (zeroCheck) {
                                .zero => .if_z,
                                .non_zero => .if_nz,
                            },
                            &.{
                                .R0 = condReg.index,
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

                        const operandType = try self.getType(thenOperand);
                        const elseOperandType = try self.getType(elseOperand);

                        if (operandType != elseOperandType) {
                            return error.StackBranchMismatch;
                        }

                        const newLocalName = try self.function.module.root.freshName(.{thenChild.ir.name, "result"});

                        const resultLocal = try self.createLocal(newLocalName, operandType);

                        try self.generateSetLocal(resultLocal.id, thenOperand);

                        const resultRegister = try self.lvalue(.{.local = resultLocal.id});

                        try self.builder.op(
                            switch (zeroCheck) {
                                .zero => .if_z_v,
                                .non_zero => .if_nz_v,
                            },
                            &.{
                                .R0 = condReg.index,
                                .R1 = resultRegister.index,
                                .B0 = thenChild.builder.index,
                                .B1 = elseChild.builder.index
                            },
                        );
                    }
                },
                .when => {
                    const zeroCheck = instr.data.when;

                    const condOperand = try self.pop(null);
                    const thenId = try self.pop(.block);

                    const condReg = try (try self.rvalue(condOperand)).forceRegister();

                    const thenChild = try self.function.compileBlock(thenId);

                    if (thenChild.stackDepth() == 0) {
                        try self.builder.op(
                            switch (zeroCheck) {
                                .zero => .when_z,
                                .non_zero => .when_nz,
                            },
                            &.{
                                .R0 = condReg.index,
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
                            const reId = try self.pop(.block);
                            const reBlock = try self.function.getBlock(reId);

                            try self.builder.re(reBlock.builder);
                        },
                        .zero => {
                            const condOperand = try self.pop(null);
                            const reId = try self.pop(.block);

                            const condReg = try (try self.rvalue(condOperand)).forceRegister();

                            const reBlock = try self.function.getBlock(reId);

                            try self.builder.re_z(reBlock.builder, condReg.index);
                        },
                        .non_zero => {
                            const condOperand = try self.pop(null);
                            const reId = try self.pop(.block);

                            const condReg = try (try self.rvalue(condOperand)).forceRegister();

                            const reBlock = try self.function.getBlock(reId);

                            try self.builder.re_nz(reBlock.builder, condReg.index);
                        },
                    }
                },
                .br => {
                    const zeroCheck = instr.data.br;

                    const brId = try self.pop(.block);
                    const brBlock = try self.function.getBlock(brId);

                    switch (zeroCheck) {
                        .none => try self.builder.br(brBlock.builder),
                        .zero => switch (self.stackDepth()) {
                            0 => return error.StackUnderflow,
                            1 => {
                                const condOperand = try self.pop(null);
                                const condReg = try (try self.rvalue(condOperand)).forceRegister();

                                try self.builder.br_z(brBlock.builder, condReg.index);
                            },
                            2 => {
                                const condOperand = try self.pop(null);
                                const condReg = try (try self.rvalue(condOperand)).forceRegister();

                                const elseOperand = try self.pop(null);
                                const elseRValue = try self.rvalue(elseOperand);

                                switch (elseRValue) {
                                    .register => |r| try self.builder.br_z_v(brBlock.builder, condReg.index, r.index),
                                    .im_0 => try self.builder.br_z(brBlock.builder, condReg.index),
                                    inline .im_8, .im_16, .im_32, .im_64  => |im| try self.builder.br_z_im_v(brBlock.builder, condReg.index, im.data),
                                }
                            },
                            else => return error.StackNotCleared,
                        },
                        .non_zero => switch (self.stackDepth()) {
                            0 => return error.StackUnderflow,
                            1 => {
                                const condOperand = try self.pop(null);
                                const condReg = try (try self.rvalue(condOperand)).forceRegister();

                                try self.builder.br_nz(brBlock.builder, condReg.index);
                            },
                            2 => {
                                const condOperand = try self.pop(null);
                                const condReg = try (try self.rvalue(condOperand)).forceRegister();

                                const elseOperand = try self.pop(null);
                                const elseRValue = try self.rvalue(elseOperand);

                                switch (elseRValue) {
                                    .register => |r| try self.builder.br_nz_v(brBlock.builder, condReg.index, r.index),
                                    .im_0 => try self.builder.br_nz(brBlock.builder, condReg.index),
                                    inline .im_8, .im_16, .im_32, .im_64  => |im| try self.builder.br_nz_im_v(brBlock.builder, condReg.index, im.data),
                                }
                            },
                            else => return error.StackNotCleared,
                        },
                    }
                },

                .call => @panic("call nyi"),
                .prompt => @panic("prompt nyi"),
                .ret => @panic("ret nyi"),
                .term => @panic("term nyi"),

                .alloca => @panic("alloca nyi"),
                .addr => @panic("addr nyi"),

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

                    const tyId = try self.pop(.type);

                    const local = try self.createLocal(name, tyId);

                    try self.push(local.id);
                },

                .ref_local => try self.push(instr.data.ref_local),
                .ref_block => try self.push(instr.data.ref_block),
                .ref_function => try self.push(instr.data.ref_function),
                .ref_foreign => try self.push(instr.data.ref_foreign),
                .ref_global => try self.push(instr.data.ref_global),
                .ref_upvalue => try self.push(instr.data.ref_upvalue),

                .im_b => try self.push(instr.data.im_b),
                .im_s => try self.push(instr.data.im_s),
                .im_i => try self.push(instr.data.im_i),
                .im_w => try self.push(instr.data.im_w),
            }
        }
    }

    pub fn stackDepth(self: *Block) usize {
        return self.stack.items.len;
    }

    pub fn push(self: *Block, operand: anytype) !void {
        try self.stack.append(self.function.module.root.allocator, Rir.Operand.from(operand));
    }

    pub fn pop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand)) !Rir.Operand.TypeOf(kind) {
        if (self.stack.popOrNull()) |operand| {
            return if (comptime kind) |k| switch (operand) {
                .type => |x| if (comptime .type == k) x else error.InvalidOperand,
                .register => |x| if (comptime .register == k) x else error.InvalidOperand,
                .im_8 => |x| if (comptime .im_8 == k) x else error.InvalidOperand,
                .im_16 => |x| if (comptime .im_16 == k) x else error.InvalidOperand,
                .im_32 => |x| if (comptime .im_32 == k) x else error.InvalidOperand,
                .im_64 => |x| if (comptime .im_64 == k) x else error.InvalidOperand,
                .block => |x| if (comptime .block == k) x else error.InvalidOperand,
                .foreign => |x| if (comptime .foreign == k) x else error.InvalidOperand,
                .function => |x| if (comptime .function == k) x else error.InvalidOperand,
                .global => |x| if (comptime .global == k) x else error.InvalidOperand,
                .upvalue => |x| if (comptime .upvalue == k) x else error.InvalidOperand,
                .handler_set => |x| if (comptime .handler_set == k) x else error.InvalidOperand,
                .local => |x| if (comptime .local == k) x else error.InvalidOperand,
            }
            else operand;
        }

        return error.StackUnderflow;
    }

    pub fn createLocal(self: *Block, name: Rir.NameId, ty: Rir.TypeId) error{TooManyLocals, OutOfMemory}! *Rir.Local {
        return self.ir.createLocal(name, ty);
    }

    pub fn getLocal(self: *Block, id: Rir.LocalId) !*Rir.Local {
        return self.ir.getLocal(id);
    }

    pub fn generateSetLocal(_: *Block, _: Rir.LocalId, _: Rir.Operand) error{TooManyLocals, OutOfMemory}! void {
        @panic("setLocal nyi");
    }

    pub fn getType(self: *Block, operand: Rir.Operand) Generator.Error! Rir.TypeId {
        return switch (operand) {
            .type => Rir.type_info.BASIC_TYPE_IDS.Type,
            .register => |reg| reg.type,
            .im_8 => |im| im.type,
            .im_16 => |im| im.type,
            .im_32 => |im| im.type,
            .im_64 => |im| im.type,
            .block => Rir.type_info.BASIC_TYPE_IDS.Block,
            .foreign => |foreignId| (try self.function.module.root.ir.getForeign(foreignId)).type,
            .function => |functionRef| (try self.function.module.root.ir.getFunction(functionRef)).type,
            .global => |globalRef| (try self.function.module.root.ir.getGlobal(globalRef)).type,
            .upvalue => |upvalueId| (try self.function.ir.getUpvalue(upvalueId)).type,
            .handler_set => Rir.type_info.BASIC_TYPE_IDS.HandlerSet,
            .local => |localId| (try self.getLocal(localId)).type,
        };
    }

    // lvalue and rvalue conversion
    //
    // these both attempt to convert the provided operand to a typed Register;
    //
    // lvalue is used when
    // - the operand is being assigned to
    //
    // rvalue is used when
    // - the operand is being used as a value
    //
    // in both cases, we may not actually be reading/writing directly to the Register.
    // for example, a local variable will resolve to a register, but if the actual value does not fit,
    // it will be spilled to the stack, and the register will hold a pointer.

    pub fn lvalue(_: *Block, _: Rir.Operand) !Rir.Register {
        @panic("lvalue nyi");
    }

    pub fn rvalue(self: *Block, operand: Rir.Operand) error{InvalidOperand, InvalidLocal, LocalNotAssignedStorage, LocalNotAssignedRegister}! Rir.RValue {
        return switch (operand) {
            inline
                .type,
                .block,
                .handler_set,
                .function,
                .foreign,
            => error.InvalidOperand,

            .register => |r| .{.register = r},

            .im_8 => |im| .{.im_8 = im},
            .im_16 => |im| .{.im_16 = im},
            .im_32 => |im| .{.im_32 = im},
            .im_64 => |im| .{.im_64 = im},

            .global => @panic("global nyi"),

            .upvalue => @panic("upvalue nyi"),

            .local => |id| local: {
                const local = try self.getLocal(id);

                break :local switch (local.storage) {
                    .none => error.LocalNotAssignedStorage,
                    .zero_size => .im_0,
                    .register, .stack => Rir.RValue {
                        .register = Rir.Register {
                            .type = local.type,
                            .index = local.register
                                orelse return error.LocalNotAssignedRegister,
                        },
                    },
                };
            },
        };
    }

};
