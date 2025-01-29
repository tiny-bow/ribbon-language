const Generator = @import("../RbcGenerator.zig");

const block = @This();

const std = @import("std");
const utils = @import("utils");

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

const Stack = std.ArrayListUnmanaged(Rir.Operand);
const RegisterList = std.ArrayListUnmanaged(*Rir.Register);
const BlockBuilderList = std.ArrayListUnmanaged(*RbcBuilder.Block);

pub const Block = struct {
    generator: *Generator,
    function: *Generator.Function,

    parent: ?*Block,

    ir: *Rir.Block,

    active_builder: *RbcBuilder.Block,
    builders: BlockBuilderList,

    register_list: RegisterList,

    stack: Stack = .{},

    pub fn init(parent: ?*Block, function: *Generator.Function, blockIr: *Rir.Block, entryBlockBuilder: ?*RbcBuilder.Block) error{ TooManyBlocks, OutOfMemory }!*Block {
        const generator = function.generator;
        const self = try generator.allocator.create(Block);

        const blockBuilder = entryBlockBuilder
            orelse try function.builder.createBlock();

        self.* = Block{
            .function = function,
            .generator = generator,

            .parent = parent,

            .ir = blockIr,

            .active_builder = blockBuilder,
            .builders = try BlockBuilderList.initCapacity(generator.allocator, 16),

            .register_list = try RegisterList.initCapacity(generator.allocator, Rir.MAX_REGISTERS),
        };

        self.builders.appendAssumeCapacity(self.active_builder);

        return self;
    }

    pub fn deinit(self: *Block) void {
        self.builders.deinit(self.generator.allocator);
        self.register_list.deinit(self.generator.allocator);
        self.stack.deinit(self.generator.allocator);

        self.generator.allocator.destroy(self);
    }

    pub fn generate(self: *Block) Generator.Error!void {
        const instrs = self.ir.instructions.items;

        var i: usize = 0;
        while (i < instrs.len) {
            const instr = instrs[i];
            i += 1;

            switch (instr.code) {
                .nop => try self.active_builder.nop(),

                .halt => {
                    try self.active_builder.halt();

                    if (i < instrs.len) Generator.log.warn("dead code at {}/{}/{}/{}", .{self.function.module.ir.id, self.function.ir.id, self.ir.id, i});

                    break;
                },

                .trap => {
                    try self.active_builder.trap();

                    if (i < instrs.len) Generator.log.warn("dead code at {}/{}/{}/{}", .{self.function.module.ir.id, self.function.ir.id, self.ir.id, i});

                    break;
                },


                .block => {
                    const blockIr = try (try self.pop(.meta)).forceBlock();
                    const blockGen = try self.function.setupBlock(blockIr, null);
                    const blockEntryIndex = blockGen.active_builder.index;
                    try blockGen.generate();

                    const finallyBlockBuilder = try self.function.builder.createBlock();
                    try self.builders.append(self.generator.allocator, finallyBlockBuilder);

                    try self.active_builder.br(blockEntryIndex);

                    self.active_builder = finallyBlockBuilder;

                    if (try self.phi(&.{blockGen})) |out| {
                        try self.push(out);
                    }
                },

                .with => {
                    const bodyBlockIr = try (try self.pop(.meta)).forceBlock();
                    const bodyBlockGen = try self.function.setupBlock(bodyBlockIr, null);
                    const bodyBlockEntryIndex = bodyBlockGen.active_builder.index;
                    try bodyBlockGen.generate();

                    const handlerSetIr = try (try self.pop(.meta)).forceHandlerSet();
                    const handlerSetGen = try self.function.module.getHandlerSet(handlerSetIr.id);

                    const finallyBlockBuilder = try self.function.builder.createBlock();
                    try self.builders.append(self.generator.allocator, finallyBlockBuilder);

                    const entryBuilder = self.active_builder;
                    self.active_builder = finallyBlockBuilder;

                    if (try self.phi(&.{bodyBlockGen})) |out| {
                        try self.push(out);

                        try entryBuilder.push_set_v(finallyBlockBuilder.index, handlerSetGen.index, out.getIndex());
                    } else {
                        try entryBuilder.push_set(finallyBlockBuilder.index, handlerSetGen.index);
                    }

                    try entryBuilder.br(bodyBlockEntryIndex);
                },

                .@"if" => {
                    const zeroCheck = instr.data.@"if";

                    const thenBlockIr = try (try self.pop(.meta)).forceBlock();
                    const thenBlockGen = try self.function.setupBlock(thenBlockIr, null);
                    const thenBlockEntryIndex = thenBlockGen.active_builder.index;
                    try thenBlockGen.generate();

                    const elseBlockIr = try (try self.pop(.meta)).forceBlock();
                    const elseBlockGen = try self.function.setupBlock(elseBlockIr, null);
                    const elseBlockEntryIndex = elseBlockGen.active_builder.index;
                    try elseBlockGen.generate();

                    const condOperand = try self.pop(null);
                    const condRegister = try self.coerceRegister(condOperand);

                    const finallyBlockBuilder = try self.function.builder.createBlock();
                    try self.builders.append(self.generator.allocator, finallyBlockBuilder);

                    switch (zeroCheck) {
                        .zero => try self.active_builder.br_z(thenBlockEntryIndex, elseBlockEntryIndex, condRegister.getIndex()),
                        .non_zero => try self.active_builder.br_nz(thenBlockEntryIndex, elseBlockEntryIndex, condRegister.getIndex()),
                    }

                    self.active_builder = finallyBlockBuilder;

                    if (try self.phi(&.{thenBlockGen, elseBlockGen})) |out| {
                        try self.push(out);
                    }
                },

                .when => {
                    const zeroCheck = instr.data.@"when";

                    const thenBlockIr = try (try self.pop(.meta)).forceBlock();
                    const thenBlockGen = try self.function.compileBlock(thenBlockIr, null);

                    const condOperand = try self.pop(null);
                    const condRegister = try self.coerceRegister(condOperand);

                    const finallyBlockBuilder = try self.function.builder.createBlock();
                    try self.builders.append(self.generator.allocator, finallyBlockBuilder);

                    switch (zeroCheck) {
                        .zero => try self.active_builder.br_z(thenBlockGen.active_builder.index, finallyBlockBuilder.index, condRegister.getIndex()),
                        .non_zero => try self.active_builder.br_nz(thenBlockGen.active_builder.index, finallyBlockBuilder.index, condRegister.getIndex()),
                    }

                    self.active_builder = finallyBlockBuilder;

                    if (try self.phi(&.{thenBlockGen})) |out| {
                        try self.push(out);
                    }
                },


                .re => @panic("re nyi"),

                .br => @panic("br nyi"),

                .call => @panic("call nyi"),
                .prompt => @panic("prompt nyi"),
                .ret => @panic("ret nyi"),
                .cancel => @panic("cancel nyi"),

                .alloca => {
                    const typeIr = try (try self.pop(.meta)).forceType();
                    const typeLayout = try typeIr.getLayout();

                    const register = try self.allocRegister(typeIr);

                    try self.active_builder.alloca(@intCast(typeLayout.dimensions.size), register.getIndex());

                    try self.push(register);
                },

                .addr => {
                    const operand: Rir.Operand = try self.pop(null);

                    const operandType = try operand.getType();
                    const pointerType = try operandType.createPointer();

                    switch (operand) {
                        .meta => return error.InvalidOperand,

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
                                try self.active_builder.addr_global(globalGen.index, outReg.getIndex());

                                try self.push(outReg);
                            },

                            .upvalue => |upvalueIr| {
                                const upvalueGen = try self.function.getUpvalue(upvalueIr);

                                const outReg = try self.allocRegister(pointerType);
                                try self.active_builder.addr_upvalue(upvalueGen.index, outReg.getIndex());

                                try self.push(outReg);
                            },

                            else => return error.InvalidOperand,
                        },

                        .r_value => |r| switch (r) {
                            .immediate => return error.InvalidOperand,
                            .foreign => |foreignIr| {
                                const foreignIndex = try self.generator.getForeign(foreignIr);

                                const outReg = try self.allocRegister(pointerType);
                                try self.active_builder.addr_foreign(foreignIndex, outReg.getIndex());

                                try self.push(outReg);
                            },
                            .function => |functionIr| {
                                const functionGen = try self.generator.getFunction(functionIr);

                                const outReg = try self.allocRegister(pointerType);
                                try self.active_builder.addr_function(functionGen.builder.index, outReg.getIndex());

                                try self.push(outReg);
                            },
                        },
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
                    const localIr = try self.createLocal(name, typeIr);

                    try self.push(localIr);
                },

                .ref_local => {
                    const id = instr.data.ref_local;
                    const localIr = try self.getLocal(id);

                    try self.push(localIr);
                },
                .ref_block => {
                    const id = instr.data.ref_block;
                    const blockIr = try self.function.ir.getBlock(id);

                    try self.push(blockIr);
                },
                .ref_function => {
                    const ref = instr.data.ref_function;
                    const moduleGen = try self.generator.getModule(ref.module_id);
                    const functionGen = try moduleGen.getFunction(ref.id);

                    try self.push(functionGen.ir);
                },
                .ref_foreign => {
                    const id = instr.data.ref_foreign;
                    const foreignIr = try self.generator.ir.getForeign(id);

                    try self.push(foreignIr);
                },
                .ref_global => {
                    const ref = instr.data.ref_global;
                    const moduleGen = try self.generator.getModule(ref.module_id);
                    const globalGen = try moduleGen.getGlobal(ref.id);

                    try self.push(globalGen.ir);
                },
                .ref_upvalue => {
                    const id = instr.data.ref_upvalue;
                    const upvalueIr = try self.function.ir.getUpvalue(id);

                    try self.push(upvalueIr);
                },

                .im_i => {
                    const im = instr.data.im_i;
                    const typeIr = try self.generator.ir.getType(im.type_id);

                    try self.push(Rir.Immediate{ .type = typeIr, .data = im.data });
                },
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

    pub fn tryPop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand))
        error{InvalidOperand}!
            ? if (kind) |k| switch (k) {
                .meta => Rir.Meta,
                .l_value => Rir.LValue,
                .r_value => Rir.RValue,
            } else Rir.Operand
    {
        if (self.stack.popOrNull()) |operand| {
            return if (comptime kind) |k| switch (operand) {
                .meta => |m| if (k == .meta) m else error.InvalidOperand,
                .l_value => |l| if (k == .l_value) l else error.InvalidOperand,
                .r_value => |r| if (k == .r_value) r else error.InvalidOperand,
            } else operand;
        }

        return null;
    }

    pub fn pop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand))
        error{InvalidOperand, StackUnderflow}!
            if (kind) |k| switch (k){
                .meta => Rir.Meta,
                .l_value => Rir.LValue,
                .r_value => Rir.RValue,
            } else Rir.Operand
    {
        if (self.stack.popOrNull()) |operand| {
            return if (comptime kind) |k| switch (operand) {
                .meta => |m| if (k == .meta) m else error.InvalidOperand,
                .l_value => |l| if (k == .l_value) l else error.InvalidOperand,
                .r_value => |r| if (k == .r_value) r else error.InvalidOperand,
            } else operand;
        }

        return error.StackUnderflow;
    }

    pub fn takeFreeRegister(self: *Block) ?*Rir.Register {
        for (self.register_list.items) |reg| {
            if (reg.ref_count == 0) return reg;
        }

        return null;
    }

    pub fn allocRegister(self: *Block, typeIr: *Rir.Type) error{ InvalidType, TooManyRegisters, OutOfMemory }!*Rir.Register {
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

    pub fn createLocal(self: *Block, name: Rir.NameId, typeIr: *Rir.Type) error{ TooManyLocals, OutOfMemory }!*Rir.Local {
        const out = try self.ir.createLocal(name, typeIr);
        // const localType = try self.ir.ir.getType(localTypeId);
        // const localStorage = try localType.getStorage();

        // out.storage =

        return out;
    }

    pub fn getLocal(self: *Block, id: Rir.LocalId) !*Rir.Local {
        return self.ir.getLocal(id);
    }

    pub fn generateSetLocal(_: *Block, _: Rir.LocalId, _: Rir.Operand) error{ TooManyLocals, OutOfMemory }!void {
        @panic("setLocal nyi");
    }

    pub fn compileImmediate(self: *Block, im: Rir.Immediate) !void {
        utils.todo(noreturn, .{self, im});
    }

    pub fn load(self: *Block, register: *Rir.Register) !Rir.Operand {
        utils.todo(noreturn, .{self, register});
    }

    pub fn store(self: *Block, register: *Rir.Register, value: Rir.Operand) !void {
        utils.todo(noreturn, .{self, register, value});
    }

    pub fn coerceRegister(self: *Block, operand: Rir.Operand) !*Rir.Register {
        utils.todo(noreturn, .{self, operand});
    }

    pub fn phi(self: *Block, blockGens: []const *Block) ! ?*Rir.Register {
        utils.todo(noreturn, .{self, blockGens});
    }
};
