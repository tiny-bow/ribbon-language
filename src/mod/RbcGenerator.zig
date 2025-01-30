const RbcGenerator = @This();

const std = @import("std");
const utils = @import("utils");
const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

pub const log = std.log.scoped(.rbc_generator);

test {
    std.testing.refAllDeclsRecursive(RbcGenerator);
}

// RbcGenerator type

allocator: std.mem.Allocator,

ir: *Rir,

evidence_map: EvidenceMap = .{},
module_map: ModuleMap = .{},
foreign_map: ForeignMap = .{},

/// The allocator provided should be an arena,
/// or a similar allocator that doesn't care about freeing individual allocations
pub fn init(allocator: std.mem.Allocator, ir: *Rir) error{OutOfMemory}!RbcGenerator {
    return RbcGenerator{
        .allocator = allocator,
        .ir = ir,
    };
}

/// Allocator provided does not have to be the allocator used to create the generator,
/// a long term allocator is preferred.
///
/// In the event of an error, this function cleans up any allocations it created.
pub fn generate(self: *RbcGenerator, allocator: std.mem.Allocator, exports: []const Export) Error!Rbc {
    for (exports) |exp| {
        switch (exp) {
            .function => |ref| _ = try self.getFunction(ref),
            .global => |ref| _ = try self.getGlobal(ref),
        }
    }

    utils.todo(noreturn, allocator);
}

pub fn getModule(self: *RbcGenerator, modId: Rir.ModuleId) error{ InvalidModule, OutOfMemory }!*Module {
    const getOrPut = try self.module_map.getOrPut(self.allocator, modId);

    if (!getOrPut.found_existing) {
        const modIr = try self.ir.getModule(modId);
        getOrPut.value_ptr.* = try Module.init(self, modIr);
    }

    return getOrPut.value_ptr.*;
}

pub fn getGlobal(self: *RbcGenerator, gRef: *Rir.Global) Error!*Global {
    return (try self.getModule(gRef.module.id)).getGlobal(gRef.id);
}

pub fn getFunction(self: *RbcGenerator, fRef: *Rir.Function) Error!*Function {
    return (try self.getModule(fRef.module.id)).getFunction(fRef.id);
}

pub fn getEvidence(self: *RbcGenerator, evId: Rir.EvidenceId) !Rbc.EvidenceIndex {
    const getOrPut = try self.evidence_map.getOrPut(self.allocator, evId);

    if (!getOrPut.found_existing) {
        getOrPut.value_ptr.* = @intFromEnum(evId); // FIXME: this is a placeholder
    }

    return getOrPut.value_ptr.*;
}

pub fn getForeign(self: *RbcGenerator, foreignAddressIr: *Rir.Foreign) !Rbc.ForeignIndex {
    const getOrPut = try self.foreign_map.getOrPut(self.allocator, foreignAddressIr.id);

    if (!getOrPut.found_existing) {
        @panic("TODO: Implement getForeign");
    }

    return getOrPut.value_ptr.*;
}

pub fn freshName(self: *RbcGenerator, args: anytype) Error!Rir.NameId {
    var buf = [1]u8{0} ** MAX_FRESH_NAME_LEN;

    var fbs = std.io.fixedBufferStream(&buf);

    const w = fbs.writer();

    const formatter = try Rir.Formatter.init(self.ir, w.any());
    defer formatter.deinit();

    inline for (0..args.len) |i| {
        if (i > 0) {
            formatter.writeAll("-") catch |err| {
                return utils.types.forceErrorSet(Error, err);
            };
        }

        formatter.fmt(args[i]) catch |err| {
            return utils.types.forceErrorSet(Error, err);
        };
    }

    const str = fbs.getWritten();

    return self.ir.internName(str);
}

// RbcGenerator module

pub const Error = Rir.Error || RbcBuilder.Error || error{
    TypeMismatch,
    StackOverflow,
    StackUnderflow,
    StackNotCleared,
    StackBranchMismatch,
    LocalNotAssignedStorage,
    LocalNotAssignedRegister,
    ExpectedRegister,
    AddressOfRegister,
    InvalidBranch,
};

pub const MAX_FRESH_NAME_LEN = 128;

const EvidenceMap = std.ArrayHashMapUnmanaged(Rir.EvidenceId, Rbc.EvidenceIndex, utils.SimpleHashContext, false);
const ModuleMap = std.ArrayHashMapUnmanaged(Rir.ModuleId, *Module, utils.SimpleHashContext, false);
const ForeignMap = std.ArrayHashMapUnmanaged(Rir.ForeignId, Rbc.ForeignIndex, utils.SimpleHashContext, false);

pub const HandlerSet = struct {
    generator: *RbcGenerator,
    module: *Module,

    ir: *Rir.HandlerSet,

    index: Rbc.HandlerSetIndex,

    pub fn init(moduleGen: *Module, ir: *Rir.HandlerSet) !*HandlerSet {
        const generator = moduleGen.generator;
        const self = try generator.allocator.create(HandlerSet);

        self.* = HandlerSet{
            .generator = generator,
            .module = moduleGen,

            .ir = ir,
            .index = @intFromEnum(ir.id), // FIXME: this is a placeholder
        };

        return self;
    }

    pub fn generate(self: *HandlerSet) !void {
        utils.todo(noreturn, self);
    }
};

pub const Export = union(enum) {
    function: *Rir.Function,
    global: *Rir.Global,

    pub fn @"export"(value: anytype) Export {
        switch (@TypeOf(value)) {
            *const Rir.Function => return .{ .function = @constCast(value) },
            *Rir.Function => return .{ .function = value },

            *const Rir.Global => return .{ .global = @constCast(value) },
            *Rir.Global => return .{ .global = value },

            else => @compileError(
                "Invalid export type " ++ @typeName(@TypeOf(value) ++ ", must be a pointer to an Rir.Function or Rir.Global"),
            ),
        }
    }
};



pub const Global = struct {
    generator: *RbcGenerator,
    module: *Module,

    ir: *Rir.Global,

    index: Rbc.GlobalIndex,

    pub fn init(moduleGen: *Module, globalIr: *Rir.Global) error{OutOfMemory}!*Global {
        const generator = moduleGen.generator;

        const self = try generator.allocator.create(Global);

        self.* = Global{
            .generator = generator,
            .module = moduleGen,

            .ir = globalIr,
            .index = @intFromEnum(globalIr.id), // FIXME: this is a placeholder
        };

        return self;
    }

    pub fn generate(_: *Global) !void {
        @panic("TODO: Implement Global.generate");
    }
};

pub const Upvalue = struct {
    generator: *RbcGenerator,
    module: *Module,

    ir: *Rir.Upvalue,

    index: Rbc.UpvalueIndex,

    pub fn init(moduleGen: *Module, upvalueIr: *Rir.Upvalue) error{OutOfMemory}!*Upvalue {
        const generator = moduleGen.generator;

        const self = try generator.allocator.create(Upvalue);

        self.* = Upvalue{
            .generator = generator,
            .module = moduleGen,

            .ir = upvalueIr,
            .index = @intFromEnum(upvalueIr.id), // FIXME: this is a placeholder
        };

        return self;
    }

    pub fn generate(_: *Upvalue) !void {
        @panic("TODO: Implement Upvalue.generate");
    }
};


pub const Module = struct {
    generator: *RbcGenerator,

    ir: *Rir.Module,

    global_lookup: std.ArrayHashMapUnmanaged(Rir.GlobalId, *Global, utils.SimpleHashContext, false) = .{},
    function_lookup: std.ArrayHashMapUnmanaged(Rir.FunctionId, *Function, utils.SimpleHashContext, false) = .{},
    handler_set_lookup: std.ArrayHashMapUnmanaged(Rir.HandlerSetId, *HandlerSet, utils.SimpleHashContext, false) = .{},

    pub fn init(generator: *RbcGenerator, moduleIr: *Rir.Module) error{OutOfMemory}!*Module {
        const self = try generator.allocator.create(Module);

        self.* = Module{
            .generator = generator,
            .ir = moduleIr,
        };

        return self;
    }

    pub fn getFunction(self: *Module, functionId: Rir.FunctionId) Error!*Function {
        const getOrPut = try self.function_lookup.getOrPut(self.generator.allocator, functionId);

        if (!getOrPut.found_existing) {
            const functionIr = try self.ir.getFunction(functionId);
            const functionGen = try Function.init(self, functionIr);

            getOrPut.value_ptr.* = functionGen;

            try functionGen.generate();
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getGlobal(self: *Module, globalId: Rir.GlobalId) Error!*Global {
        const getOrPut = try self.global_lookup.getOrPut(self.generator.allocator, globalId);

        if (!getOrPut.found_existing) {
            const globalIr = try self.ir.getGlobal(globalId);
            const globalGen = try Global.init(self, globalIr);

            getOrPut.value_ptr.* = globalGen;

            try globalGen.generate();
        }

        return getOrPut.value_ptr.*;
    }

    pub fn getHandlerSet(self: *Module, handlerSetId: Rir.HandlerSetId) !*HandlerSet {
        const getOrPut = try self.handler_set_lookup.getOrPut(self.generator.allocator, handlerSetId);

        if (!getOrPut.found_existing) {
            const handlerSetIr = try self.ir.getHandlerSet(handlerSetId);
            const handlerSetGen = try HandlerSet.init(self, handlerSetIr);

            getOrPut.value_ptr.* = handlerSetGen;

            try handlerSetGen.generate();
        }

        return getOrPut.value_ptr.*;
    }
};


const BlockMap = std.ArrayHashMapUnmanaged(Rir.BlockId, *Block, utils.SimpleHashContext, false);
const UpvalueMap = std.ArrayHashMapUnmanaged(Rir.UpvalueId, *Upvalue, utils.SimpleHashContext, false);

pub const Function = struct {
    generator: *RbcGenerator,
    module: *Module,

    ir: *Rir.Function,
    builder: *RbcBuilder.Function,

    block_map: BlockMap = .{},
    upvalue_map: UpvalueMap = .{},

    pub fn init(module: *Module, functionIr: *Rir.Function) error{OutOfMemory}!*Function {
        const generator = module.generator;

        const functionBuilder = try RbcBuilder.Function.init(generator.allocator, @intFromEnum(functionIr.id));

        const self = try generator.allocator.create(Function);


        self.* = Function{
            .generator = generator,
            .module = module,
            .ir = functionIr,
            .builder = functionBuilder,
        };

        return self;
    }

    pub fn generate(self: *Function) !void {
        const blockIr = self.ir.blocks.items[0];
        const blockBuilder = try self.builder.getBlock(0);
        _ = try self.compileBlock(blockIr, blockBuilder);
    }

    pub fn getBlock(self: *Function, blockIr: *Rir.Block) error{InvalidBlock}! *Block {
        return self.block_map.get(blockIr.id) orelse error.InvalidBlock;
    }

    pub fn getUpvalue(self: *Function, upvalueIr: *Rir.Upvalue) error{InvalidUpvalue}! *Upvalue {
        return self.upvalue_map.get(upvalueIr.id) orelse error.InvalidUpvalue;
    }

    pub fn setupBlock(self: *Function, blockIr: *Rir.Block, blockBuilder: ?*RbcBuilder.Block) error{TooManyBlocks, OutOfMemory}! *Block {
        const blockGenerator = try Block.init(null, self, blockIr, blockBuilder);

        try self.block_map.put(self.generator.allocator, blockIr.id, blockGenerator);

        return blockGenerator;
    }

    pub fn compileBlock(self: *Function, blockIr: *Rir.Block, blockBuilder: ?*RbcBuilder.Block) Error! *Block {
        const blockGenerator = try self.setupBlock(blockIr, blockBuilder);

        try blockGenerator.generate();

        return blockGenerator;
    }
};

const Stack = std.ArrayListUnmanaged(Rir.Operand);
const RegisterList = std.ArrayListUnmanaged(*Rir.Register);
const BlockBuilderList = std.ArrayListUnmanaged(*RbcBuilder.Block);

pub const PhiNode = struct {
    register: ?*Rir.Register,
    entry: *RbcBuilder.Block,
    exit: *RbcBuilder.Block,
};

pub const Block = struct {
    generator: *RbcGenerator,
    function: *Function,

    parent: ?*Block,

    ir: *Rir.Block,

    active_builder: *RbcBuilder.Block,
    entry_builder: *RbcBuilder.Block,
    builders: BlockBuilderList,

    register_list: RegisterList,

    phi_node: ?PhiNode = null,
    stack: Stack = .{},

    pub fn init(parent: ?*Block, function: *Function, blockIr: *Rir.Block, entryBlockBuilder: ?*RbcBuilder.Block) error{ TooManyBlocks, OutOfMemory }!*Block {
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
            .entry_builder = blockBuilder,
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

    pub fn generate(self: *Block) Error!void {
        const instrs = self.ir.instructions.items;

        var offset: Rir.Offset = 0;
        while (offset < instrs.len) {
            const instr = instrs[offset];
            offset += 1;

            const nextInstr = if (offset < instrs.len) instrs[offset] else null;

            switch (instr.code) {
                .nop => try self.active_builder.nop(),

                .halt => {
                    try self.active_builder.halt();

                    if (offset < instrs.len) log.warn("dead code at {}/{}/{}/{}", .{self.function.module.ir.id, self.function.ir.id, self.ir.id, offset});

                    break;
                },

                .trap => {
                    try self.active_builder.trap();

                    if (offset < instrs.len) log.warn("dead code at {}/{}/{}/{}", .{self.function.module.ir.id, self.function.ir.id, self.ir.id, offset});

                    break;
                },


                .block => {
                    const blockTypeId = instr.data.block;
                    const blockTypeIr = try self.generator.ir.getType(blockTypeId);

                    const blockIr = try (try self.pop(.meta)).forceBlock();
                    const blockGen = try self.function.setupBlock(blockIr, null);

                    const phiNode = try self.phi(blockTypeIr, &.{blockGen});

                    try blockGen.generate();

                    if (phiNode.register) |reg| {
                        try self.push(reg);
                    }

                    try phiNode.entry.br(blockGen.entry_builder.index);
                },

                .with => {
                    const blockTypeId = instr.data.with;
                    const blockTypeIr = try self.generator.ir.getType(blockTypeId);

                    const handlerSetIr = try (try self.pop(.meta)).forceHandlerSet();
                    const handlerSetGen = try self.function.module.getHandlerSet(handlerSetIr.id);

                    const blockIr = try (try self.pop(.meta)).forceBlock();
                    const blockGen = try self.function.setupBlock(blockIr, null);

                    const phiNode = try self.phi(blockTypeIr, &.{blockGen});

                    try blockGen.generate();

                    if (phiNode.register) |reg| {
                        try phiNode.entry.push_set_v(blockGen.entry_builder.index, handlerSetGen.index, reg.getIndex());
                        try self.push(reg);
                    } else {
                        try phiNode.entry.push_set(blockGen.entry_builder.index, handlerSetGen.index);
                    }

                    try phiNode.entry.br(blockGen.entry_builder.index);
                },

                .@"if" => {
                    const blockTypeId = instr.data.@"if";
                    const blockTypeIr = try self.generator.ir.getType(blockTypeId);

                    const condOperand = try self.pop(null);
                    const condReg = try self.coerceRegister(condOperand);

                    const thenBlockIr = try (try self.pop(.meta)).forceBlock();
                    const thenBlockGen = try self.function.setupBlock(thenBlockIr, null);

                    const elseBlockIr = try (try self.pop(.meta)).forceBlock();
                    const elseBlockGen = try self.function.setupBlock(elseBlockIr, null);

                    const phiNode = try self.phi(blockTypeIr, &.{thenBlockGen, elseBlockGen});

                    try thenBlockGen.generate();
                    try elseBlockGen.generate();

                    if (phiNode.register) |reg| {
                        try self.push(reg);
                    }

                    try phiNode.entry.br_if(thenBlockGen.entry_builder.index, elseBlockGen.entry_builder.index, condReg.getIndex());
                },

                .when => {
                    const Nil = try self.generator.ir.createType(null, .Nil);

                    const condOperand = try self.pop(null);
                    const condReg = try self.coerceRegister(condOperand);

                    const blockIr = try (try self.pop(.meta)).forceBlock();
                    const blockGen = try self.function.setupBlock(blockIr, null);

                    const phiNode = try self.phi(Nil, &.{blockGen});

                    try blockGen.generate();

                    try phiNode.entry.br_if(blockGen.entry_builder.index, phiNode.exit.index, condReg.getIndex());
                },


                .br => {
                    const check = instr.data.br;

                    switch (check) {
                        .none => {
                            const blockIr = try (try self.pop(.meta)).forceBlock();
                            const blockGen = try self.function.getBlock(blockIr);

                            const phiNode = blockGen.phi_node orelse return error.InvalidBranch;

                            if (phiNode.register) |outReg| {
                                const resultOperand = try self.pop(null);
                                const resultType = try resultOperand.getType();

                                if (utils.notEqual(resultType, outReg.type)) {
                                    return error.TypeMismatch;
                                }

                                try self.write(.from(outReg), resultOperand);
                            }

                            try self.active_builder.br(phiNode.exit.index);
                        },
                        .non_zero => {
                            const condOperand = try self.pop(null);
                            const condReg = try self.coerceRegister(condOperand);

                            const blockIr = try (try self.pop(.meta)).forceBlock();
                            const blockGen = try self.function.getBlock(blockIr);

                            const phiNode = blockGen.phi_node orelse return error.InvalidBranch;

                            const restBuilder = try self.function.builder.createBlock();
                            try self.builders.append(self.generator.allocator, restBuilder);

                            if (phiNode.register) |outReg| {
                                const resultOperand = try self.pop(null);
                                const resultType = try resultOperand.getType();

                                if (utils.notEqual(resultType, outReg.type)) {
                                    return error.TypeMismatch;
                                }

                                const storeBlockGen = try self.function.builder.createBlock();
                                try self.builders.append(self.generator.allocator, storeBlockGen);

                                try self.active_builder.br_if(storeBlockGen.index, restBuilder.index, condReg.getIndex());

                                self.active_builder = storeBlockGen;

                                try self.write(.from(outReg), resultOperand);

                                try self.active_builder.br(phiNode.exit.index);
                            } else {
                                if (self.stackDepth() > 0) {
                                    return error.StackNotCleared;
                                }

                                try self.active_builder.br_if(phiNode.exit.index, restBuilder.index, condReg.getIndex());
                            }

                            self.active_builder = restBuilder;
                        },
                    }
                },

                .re => @panic("re nyi"),


                .call => {
                    const arity = instr.data.call;

                    const Nil = try self.generator.ir.createType(null, .Nil);

                    const functionOperand = try self.pop(null);
                    const functionType = try functionOperand.getType();
                    const functionTypeInfo = try functionType.info.forceFunction();

                    var resultRegister: ?*Rir.Register = null;

                    call: {
                        if (nextInstr) |next| {
                            if (next.code == .ret) {
                                offset += 1;

                                const argOperands = try self.popN(arity);
                                const argRegisters = try self.typecheckCall(functionType, argOperands);

                                switch (functionOperand) {
                                    .meta => return error.InvalidOperand,
                                    .l_value => |l| switch (l) {
                                        .register => |functionRegister| {
                                            try self.active_builder.tail_call(functionRegister.getIndex(), argRegisters);
                                        },
                                        .multi_register => return error.InvalidOperand,
                                        .local => |localIr| {
                                            const functionRegister = try self.coerceRegister(.from(localIr));

                                            try self.active_builder.tail_call(functionRegister.getIndex(), argRegisters);
                                        },
                                        .global => |globalIr| {
                                            const globalRegister = try self.coerceRegister(.from(globalIr));

                                            try self.active_builder.tail_call(globalRegister.getIndex(), argRegisters);
                                        },
                                        .upvalue => |upvalueIr| {
                                            const upvalueRegister = try self.coerceRegister(.from(upvalueIr));

                                            try self.active_builder.tail_call(upvalueRegister.getIndex(), argRegisters);
                                        },
                                    },
                                    .r_value => |r| switch (r) {
                                        .immediate => return error.InvalidOperand,
                                        .foreign => |foreignIr| {
                                            const foreignIndex = try self.generator.getForeign(foreignIr);

                                            try self.active_builder.tail_foreign_call_im(foreignIndex, argRegisters);
                                        },
                                        .function => |functionIr| {
                                            const functionGen = try self.generator.getFunction(functionIr);

                                            try self.active_builder.tail_call_im(functionGen.builder.index, argRegisters);
                                        },
                                    },
                                }

                                break :call;
                            }
                        }

                        // NOTE: allocating here will never allocate an input register as the output
                        if (utils.notEqual(functionTypeInfo.return_type, Nil)) {
                            resultRegister = try self.allocRegister(offset, functionTypeInfo.return_type);
                        }

                        const argOperands = try self.popN(arity);
                        const argRegisters = try self.typecheckCall(functionType, argOperands);

                        switch (functionOperand) {
                            .meta => return error.InvalidOperand,
                            .l_value => |l| switch (l) { else => @panic("call lvalue nyi"), },
                            .r_value => |r| switch (r) {
                                .immediate => return error.InvalidOperand,
                                .foreign => |foreignIr| {
                                    const foreignIndex = try self.generator.getForeign(foreignIr);

                                    if (resultRegister) |out| {
                                        try self.active_builder.foreign_call_im_v(foreignIndex, out.getIndex(), argRegisters);
                                    } else {
                                        try self.active_builder.foreign_call_im(foreignIndex, argRegisters);
                                    }
                                },
                                .function => |functionIr| {
                                    const functionGen = try self.generator.getFunction(functionIr);

                                    if (resultRegister) |out| {
                                        try self.active_builder.call_im_v(functionGen.builder.index, out.getIndex(), argRegisters);
                                    } else {
                                        try self.active_builder.call_im(functionGen.builder.index, argRegisters);
                                    }
                                },
                            },
                        }
                    }

                    if (resultRegister) |out| {
                        try self.push(out);
                    }
                },
                .ret => @panic("ret nyi"),
                .cancel => @panic("cancel nyi"),

                .alloca => {
                    const typeIr = try (try self.pop(.meta)).forceType();
                    const typeLayout = try typeIr.getLayout();

                    const register = try self.allocRegister(offset, typeIr);

                    try self.active_builder.alloca(@intCast(typeLayout.dimensions.size), register.getIndex());

                    try self.push(register);
                },

                .addr => {
                    const operand: Rir.Operand = try self.pop(null);

                    try self.coerceAddress(offset, operand);
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
                    const opLocal = instr.data.new_local;
                    const typeIr = try self.generator.ir.getType(opLocal.type_id);
                    const localIr = try self.createLocal(opLocal.name, typeIr);

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

    pub fn maybePop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand))
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

    /// slice returned is valid until next push
    pub fn popN(self: *Block, n: usize) error{StackUnderflow}! []const Rir.Operand {
        if (self.stack.items.len < n) return error.StackUnderflow;

        const out = self.stack.items[self.stack.items.len - n..];

        self.stack.shrinkRetainingCapacity(self.stack.items.len - n);

        std.mem.reverse(Rir.Operand, out);

        return out;
    }

    pub fn takeFreeRegister(self: *Block, offset: Rir.Offset) ?*Rir.Register {
        for (0..Rbc.MAX_REGISTERS) |regIndex| {
            if (!self.hasReference(offset, @intCast(regIndex))) return self.register_list.items[regIndex];
        }

        return null;
    }

    pub fn allocRegister(self: *Block, offset: Rir.Offset, typeIr: *Rir.Type) error{ InvalidType, TooManyRegisters, OutOfMemory }! *Rir.Register {
        if (self.takeFreeRegister(offset)) |reg| {
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

    pub fn referenceCount(self: *Block, offset: Rir.Offset, registerIndex: Rbc.RegisterIndex) usize {
        var count: usize = 0;

        if (self.phi_node) |phiNode| {
            if (phiNode.register) |reg| {
                if (reg.getIndex() == registerIndex) count += 1;
            }
        }

        for (self.stack.items) |operand| {
            switch (operand) {
                .meta => {},
                .l_value => |l| switch (l) {
                    .register => |reg| {
                        if (reg.getIndex() == registerIndex) count += 1;
                    },
                    .multi_register => {},
                    .local => |localIr| {
                        if (localIr.register) |reg| {
                            if (reg.getIndex() == registerIndex) count += 1;
                        }
                    },
                    .global => {},
                    .upvalue => {},
                },
                .r_value => {},
            }
        }

        return count + self.ir.referenceCount(offset, registerIndex);
    }

    pub fn hasReference(self: *Block, offset: Rir.Offset, registerIndex: Rbc.RegisterIndex) bool {
        if (self.phi_node) |phiNode| {
            if (phiNode.register) |reg| {
                if (reg.getIndex() == registerIndex) return true;
            }
        }

        for (self.stack.items) |operand| {
            switch (operand) {
                .meta => {},
                .l_value => |l| switch (l) {
                    .register => |reg| {
                        if (reg.getIndex() == registerIndex) return true;
                    },
                    .multi_register => {},
                    .local => |localIr| {
                        if (localIr.register) |reg| {
                            if (reg.getIndex() == registerIndex) return true;
                        }
                    },
                    .global => {},
                    .upvalue => {},
                },
                .r_value => {},
            }
        }

        return self.ir.hasReference(offset, registerIndex);
    }

    pub fn compileImmediate(self: *Block, im: Rir.Immediate) !void {
        utils.todo(noreturn, .{self, im});
    }

    pub fn read(self: *Block, source: Rir.Operand) !Rir.Operand {
        utils.todo(noreturn, .{self, source});
    }

    pub fn write(self: *Block, destination: Rir.Operand, value: Rir.Operand) !void {
        utils.todo(noreturn, .{self, destination, value});
    }

    pub fn coerceRegister(self: *Block, operand: Rir.Operand) !*Rir.Register {
        utils.todo(noreturn, .{self, operand});
    }

    pub fn typecheckCall(self: *Block, functionTypeIr: *Rir.Type, operand: []const Rir.Operand) ![]const Rbc.RegisterIndex {
        utils.todo(noreturn, .{self, functionTypeIr, operand});
    }

    pub fn coerceAddress(self: *Block, offset: Rir.Offset, operand: Rir.Operand) !void {
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

                    const outReg = try self.allocRegister(offset, pointerType);
                    try self.active_builder.addr_global(globalGen.index, outReg.getIndex());

                    try self.push(outReg);
                },

                .upvalue => |upvalueIr| {
                    const upvalueGen = try self.function.getUpvalue(upvalueIr);

                    const outReg = try self.allocRegister(offset, pointerType);
                    try self.active_builder.addr_upvalue(upvalueGen.index, outReg.getIndex());

                    try self.push(outReg);
                },

                else => return error.InvalidOperand,
            },

            .r_value => |r| switch (r) {
                .immediate => return error.InvalidOperand,
                .foreign => |foreignIr| {
                    const foreignIndex = try self.generator.getForeign(foreignIr);

                    const outReg = try self.allocRegister(offset, pointerType);
                    try self.active_builder.addr_foreign(foreignIndex, outReg.getIndex());

                    try self.push(outReg);
                },
                .function => |functionIr| {
                    const functionGen = try self.generator.getFunction(functionIr);

                    const outReg = try self.allocRegister(offset, pointerType);
                    try self.active_builder.addr_function(functionGen.builder.index, outReg.getIndex());

                    try self.push(outReg);
                },
            },
        }
    }

    pub fn phi(self: *Block, blockTypeIr: *Rir.Type, blockGens: []const *Block) ! PhiNode {
        utils.todo(noreturn, .{self, blockTypeIr, blockGens});
    }
};
