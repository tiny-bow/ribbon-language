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

    for (0..args.len) |i| {
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
    StackUnderflow,
    StackNotCleared,
    StackBranchMismatch,
    LocalNotAssignedStorage,
    LocalNotAssignedRegister,
    ExpectedRegister,
    AddressOfRegister,
    InvalidBranch,
    InvalidOpCode,
    UnexpectedEndOfInput,
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

    pub fn getBlock(self: *Function, blockIr: *Rir.Block) error{InvalidBlock}!*Block {
        return self.block_map.get(blockIr.id) orelse error.InvalidBlock;
    }

    pub fn getUpvalue(self: *Function, upvalueIr: *Rir.Upvalue) error{InvalidUpvalue}!*Upvalue {
        return self.upvalue_map.get(upvalueIr.id) orelse error.InvalidUpvalue;
    }

    pub fn setupBlock(self: *Function, blockIr: *Rir.Block, blockBuilder: ?*RbcBuilder.Block) error{ TooManyBlocks, OutOfMemory }!*Block {
        const blockGenerator = try Block.init(null, self, blockIr, blockBuilder);

        try self.block_map.put(self.generator.allocator, blockIr.id, blockGenerator);

        return blockGenerator;
    }

    pub fn compileBlock(self: *Function, blockIr: *Rir.Block, blockBuilder: ?*RbcBuilder.Block) Error!*Block {
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

pub const OperationValidity = enum {
    unsigned,
    signed,
    floating,
};

pub const WriteOp = enum {
    store,
    copy,
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
    offset: ?Rir.Offset = null,

    pub fn init(parent: ?*Block, function: *Function, blockIr: *Rir.Block, entryBlockBuilder: ?*RbcBuilder.Block) error{ TooManyBlocks, OutOfMemory }!*Block {
        const generator = function.generator;
        const self = try generator.allocator.create(Block);

        const blockBuilder = entryBlockBuilder orelse try function.builder.createBlock();

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
        std.debug.assert(self.offset == null);

        self.offset = 0;
        const offset: *Rir.Offset = &self.offset.?;

        const instrs = self.ir.instructions.items;

        while (offset.* < instrs.len) {
            const instr = instrs[offset.*];
            offset.* += 1;

            const nextInstr = if (offset.* < instrs.len) instrs[offset.*] else null;

            switch (instr.code) {
                .nop => try self.active_builder.nop(),

                .halt => {
                    try self.active_builder.halt();

                    if (offset.* < instrs.len) log.warn("dead code at {}/{}/{}/{}", .{ self.function.module.ir.id, self.function.ir.id, self.ir.id, offset });

                    break;
                },

                .trap => {
                    try self.active_builder.trap();

                    if (offset.* < instrs.len) log.warn("dead code at {}/{}/{}/{}", .{ self.function.module.ir.id, self.function.ir.id, self.ir.id, offset });

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
                    const boolTypeIr = try self.generator.ir.createType(null, .Bool);
                    const condReg = try self.coerceRegister(condOperand, boolTypeIr);

                    const thenBlockIr = try (try self.pop(.meta)).forceBlock();
                    const thenBlockGen = try self.function.setupBlock(thenBlockIr, null);

                    const elseBlockIr = try (try self.pop(.meta)).forceBlock();
                    const elseBlockGen = try self.function.setupBlock(elseBlockIr, null);

                    const phiNode = try self.phi(blockTypeIr, &.{ thenBlockGen, elseBlockGen });

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
                    const boolTypeIr = try self.generator.ir.createType(null, .Bool);
                    const condReg = try self.coerceRegister(condOperand, boolTypeIr);

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

                                try self.assign(.from(outReg), resultOperand);
                            }

                            try self.active_builder.br(phiNode.exit.index);
                        },
                        .non_zero => {
                            const condOperand = try self.pop(null);
                            const boolTypeIr = try self.generator.ir.createType(null, .Bool);
                            const condReg = try self.coerceRegister(condOperand, boolTypeIr);

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

                                try self.assign(.from(outReg), resultOperand);

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

                .re => {
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

                                try self.assign(.from(outReg), resultOperand);
                            }

                            try self.active_builder.br(phiNode.entry.index);
                        },
                        .non_zero => {
                            const condOperand = try self.pop(null);
                            const boolTypeIr = try self.generator.ir.createType(null, .Bool);
                            const condReg = try self.coerceRegister(condOperand, boolTypeIr);

                            const blockIr = try (try self.pop(.meta)).forceBlock();
                            const blockGen = try self.function.getBlock(blockIr);

                            if (self.stackDepth() > 0) {
                                return error.StackNotCleared;
                            }

                            const restBuilder = try self.function.builder.createBlock();
                            try self.builders.append(self.generator.allocator, restBuilder);

                            const phiNode = blockGen.phi_node orelse return error.InvalidBranch;

                            if (phiNode.register != null) {
                                return error.StackBranchMismatch;
                            }

                            try self.active_builder.br_if(phiNode.entry.index, restBuilder.index, condReg.getIndex());
                        },
                    }
                },

                .call => {
                    const arity = instr.data.call;

                    const Nil = try self.generator.ir.createType(null, .Nil);

                    const functionOperand: Rir.Operand = try self.pop(null);
                    const functionType = try functionOperand.getType();
                    const functionTypeInfo = try functionType.info.forceFunction();

                    var resultRegister: ?*Rir.Register = null;

                    call: {
                        if (nextInstr) |next| {
                            if (next.code == .ret) {
                                offset.* += 1;

                                const argOperands = try self.popN(arity);
                                const argRegisters = try self.setupCall(functionType, argOperands);

                                switch (functionOperand) {
                                    .meta => return error.InvalidOperand,
                                    .l_value => |l| switch (l) {
                                        .register => |functionRegister| {
                                            try self.active_builder.tail_call(functionRegister.getIndex(), argRegisters);
                                        },
                                        .multi_register => return error.InvalidOperand,
                                        .local => |localIr| {
                                            const functionRegister = try self.coerceRegister(.from(localIr), null); // TODO: could pass .Function here?

                                            try self.active_builder.tail_call(functionRegister.getIndex(), argRegisters);
                                        },
                                        .global => |globalIr| {
                                            const globalRegister = try self.coerceRegister(.from(globalIr), null);

                                            try self.active_builder.tail_call(globalRegister.getIndex(), argRegisters);
                                        },
                                        .upvalue => |upvalueIr| {
                                            const upvalueRegister = try self.coerceRegister(.from(upvalueIr), null);

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
                        // TODO: is this desirable?
                        if (utils.notEqual(functionTypeInfo.return_type, Nil)) {
                            resultRegister = try self.allocRegister(functionTypeInfo.return_type);
                        }

                        const argOperands = try self.popN(arity);
                        const argRegisters = try self.setupCall(functionType, argOperands);

                        switch (try self.coerceRegisterOrRValue(functionOperand, null)) {
                            .register => |functionRegister| {
                                if (resultRegister) |out| {
                                    try self.active_builder.call_v(functionRegister.getIndex(), out.getIndex(), argRegisters);
                                } else {
                                    try self.active_builder.call(functionRegister.getIndex(), argRegisters);
                                }
                            },
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

                .ret => {
                    const resultMaybeOperand = try self.maybePop(null);

                    if (self.stackDepth() > 0) {
                        return error.StackNotCleared;
                    }

                    if (resultMaybeOperand) |resultOperand| {
                        const functionTypeInfo = try self.function.ir.getTypeInfo();
                        switch (try self.coerceRegisterOrRValue(resultOperand, functionTypeInfo.return_type)) {
                            .register => |reg| {
                                const regLayout = try reg.type.getLayout();

                                switch (regLayout.local_storage) {
                                    .none,
                                    .@"comptime",
                                    => return error.InvalidOperand,

                                    .zero_size => try self.active_builder.ret(),

                                    .n_registers,
                                    .stack,
                                    => @panic("stack return nyi"),

                                    .register => try self.active_builder.ret_v(reg.getIndex()),
                                }
                            },
                            .r_value => |r| switch (r) {
                                .immediate => |im| {
                                    const imLayout = try im.type.getLayout();

                                    switch (imLayout.local_storage) {
                                        .none,
                                        .@"comptime",
                                        => return error.InvalidOperand,

                                        .zero_size => try self.active_builder.ret(),

                                        .n_registers,
                                        .stack,
                                        => @panic("stack return nyi"),

                                        .register => if (imLayout.dimensions.size <= 32) try self.active_builder.ret_im_v(im.data) else try self.active_builder.ret_im_w_v(im.data),
                                    }
                                },
                                .foreign => |foreignIr| {
                                    const foreignIndex = try self.generator.getForeign(foreignIr);

                                    try self.active_builder.ret_im_v(foreignIndex);
                                },
                                .function => |functionIr| {
                                    const functionGen = try self.generator.getFunction(functionIr);

                                    try self.active_builder.ret_im_v(functionGen.builder.index);
                                },
                            },
                        }
                    }
                },

                .cancel => {
                    const resultMaybeOperand = try self.maybePop(null);

                    if (self.stackDepth() > 0) {
                        return error.StackNotCleared;
                    }

                    if (resultMaybeOperand) |resultOperand| {
                        const cancellationTypeIr = try self.function.ir.getCancellationType();

                        switch (try self.coerceRegisterOrRValue(resultOperand, cancellationTypeIr)) {
                            .register => |reg| {
                                const regLayout = try reg.type.getLayout();

                                switch (regLayout.local_storage) {
                                    .none,
                                    .@"comptime",
                                    => return error.InvalidOperand,

                                    .zero_size => try self.active_builder.cancel(),

                                    .n_registers,
                                    .stack,
                                    => @panic("stack cancel nyi"),

                                    .register => try self.active_builder.cancel_v(reg.getIndex()),
                                }
                            },
                            .r_value => |r| switch (r) {
                                .immediate => |im| {
                                    const imLayout = try im.type.getLayout();

                                    switch (imLayout.local_storage) {
                                        .none,
                                        .@"comptime",
                                        => return error.InvalidOperand,

                                        .zero_size => try self.active_builder.cancel(),

                                        .n_registers,
                                        .stack,
                                        => @panic("stack cancel nyi"),

                                        .register => if (imLayout.dimensions.size <= 32) try self.active_builder.cancel_im_v(im.data) else try self.active_builder.cancel_im_w_v(im.data),
                                    }
                                },
                                .foreign => |foreignIr| {
                                    const foreignIndex = try self.generator.getForeign(foreignIr);

                                    try self.active_builder.cancel_im_v(foreignIndex);
                                },
                                .function => |functionIr| {
                                    const functionGen = try self.generator.getFunction(functionIr);

                                    try self.active_builder.cancel_im_v(functionGen.builder.index);
                                },
                            },
                        }
                    }
                },

                .addr => {
                    const location = try self.pop(null);
                    const output = try self.coerceAddress(location);

                    try self.push(output);
                },

                .load => {
                    const source = try self.pop(null);
                    const output = try self.load(source);

                    try self.push(output);
                },

                .store => {
                    const destination = try self.pop(null);
                    const source = try self.pop(null);

                    try self.store(destination, source);
                },

                .add => try self.binary(.add),
                .sub => try self.binary(.sub),
                .mul => try self.binary(.mul),
                .div => try self.binary(.div),
                .rem => try self.binary(.rem),
                .neg => try self.unary(.neg),

                .band => try self.binary(.band),
                .bor => try self.binary(.bor),
                .bxor => try self.binary(.bxor),
                .bnot => try self.unary(.bnot),
                .bshiftl => try self.binary(.bshiftl),
                .bshiftr => try self.binary(.bshiftr),

                .eq => try self.binary(.eq),
                .ne => try self.binary(.ne),
                .lt => try self.binary(.lt),
                .gt => try self.binary(.gt),
                .le => try self.binary(.le),
                .ge => try self.binary(.ge),

                .cast => {
                    const typeId = instr.data.cast;
                    const typeIr = try self.generator.ir.getType(typeId);

                    try self.cast(typeIr);
                },

                .clear => try self.clear(instr.data.clear),
                .swap => try self.swap(instr.data.swap),
                .copy => try self.copy(instr.data.copy),

                .assign => {
                    const destination = try self.pop(null);
                    const source = try self.pop(null);

                    try self.assign(destination, source);
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

                .im_w => {
                    const typeId = instr.data.im_w;
                    const typeIr = try self.generator.ir.getType(typeId);

                    if (nextInstr) |next| {
                        offset.* += 1;

                        const im: u64 = @bitCast(next);

                        try self.push(Rir.Immediate{ .type = typeIr, .data = im });
                    } else {
                        return error.UnexpectedEndOfInput;
                    }
                },
            }
        }
    }

    pub fn stackDepth(self: *Block) usize {
        return self.stack.items.len;
    }

    pub fn push(self: *Block, operand: anytype) error{OutOfMemory}!void {
        try self.stack.append(self.generator.allocator, Rir.Operand.from(operand));
    }

    pub fn clear(self: *Block, count: usize) error{StackUnderflow}!void {
        if (count > self.stackDepth()) return error.StackUnderflow;

        for (count) |_| _ = try self.pop(null);
    }

    pub fn swap(self: *Block, index: usize) error{StackUnderflow}!void {
        if (index >= self.stackDepth()) return error.StackUnderflow;

        const a = &self.stack.items[self.stackDepth() - 1 - index];
        const b = &self.stack.items[self.stackDepth() - 1];

        std.mem.swap(Rir.Operand, a, b);
    }

    pub fn copy(self: *Block, index: usize) error{ StackUnderflow, OutOfMemory }!void {
        if (index >= self.stackDepth()) return error.StackUnderflow;

        const operand = self.stack.items[self.stackDepth() - 1 - index];

        try self.push(operand);
    }

    pub fn maybePop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand)) error{InvalidOperand}!?if (kind) |k| switch (k) {
        .meta => Rir.Meta,
        .l_value => Rir.LValue,
        .r_value => Rir.RValue,
    } else Rir.Operand {
        if (self.stack.popOrNull()) |operand| {
            return if (comptime kind) |k| switch (operand) {
                .meta => |m| if (k == .meta) m else error.InvalidOperand,
                .l_value => |l| if (k == .l_value) l else error.InvalidOperand,
                .r_value => |r| if (k == .r_value) r else error.InvalidOperand,
            } else operand;
        }

        return null;
    }

    pub fn pop(self: *Block, comptime kind: ?std.meta.Tag(Rir.Operand)) if (kind) |k| error{ InvalidOperand, StackUnderflow }!switch (k) {
        .meta => Rir.Meta,
        .l_value => Rir.LValue,
        .r_value => Rir.RValue,
    } else error{StackUnderflow}!Rir.Operand {
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
    pub fn popN(self: *Block, n: usize) error{StackUnderflow}![]const Rir.Operand {
        if (self.stack.items.len < n) return error.StackUnderflow;

        const out = self.stack.items[self.stack.items.len - n ..];

        self.stack.shrinkRetainingCapacity(self.stack.items.len - n);

        std.mem.reverse(Rir.Operand, out);

        return out;
    }

    pub fn takeFreeRegister(self: *Block) ?*Rir.Register {
        for (0..Rbc.MAX_REGISTERS) |regIndex| {
            if (!self.hasReference(@intCast(regIndex))) return self.register_list.items[regIndex];
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

    pub fn createLocal(self: *Block, name: Rir.NameId, typeIr: *Rir.Type) Error!*Rir.Local {
        const out = try self.ir.createLocal(name, typeIr);
        const localLayout = try typeIr.getLayout();

        out.storage = localLayout.local_storage;

        switch (out.storage) {
            .none => unreachable,
            .zero_size => {},
            .@"comptime" => @panic("comptime local nyi"),
            .n_registers => @panic("n_registers local nyi"),

            .register => {
                const reg = try self.allocRegister(typeIr);
                out.register = reg;
            },

            .stack => {
                const regType = try typeIr.createPointer();
                const reg = try self.allocRegister(regType);
                try self.active_builder.alloca(@intCast(localLayout.dimensions.size), reg.getIndex()); // FIXME: stack layouts should be able to be larger than 64k
                out.register = reg;
            },
        }

        return out;
    }

    pub fn getLocal(self: *Block, id: Rir.LocalId) !*Rir.Local {
        return self.ir.getLocal(id);
    }

    pub fn referenceCount(self: *Block, registerIndex: Rbc.RegisterIndex) usize {
        var count: usize = 0;

        if (self.phi_node) |phiNode| {
            if (phiNode.register) |reg| {
                if (reg.getIndex() == registerIndex) count += 1;
            }
        }

        for (self.stack.items) |operand| {
            switch (operand) {
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
                else => continue,
            }
        }

        return count + self.ir.referenceCount(self.offset orelse 0, registerIndex);
    }

    pub fn hasReference(self: *Block, registerIndex: Rbc.RegisterIndex) bool {
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

        return self.ir.hasReference(self.offset orelse 0, registerIndex);
    }

    pub fn load(self: *Block, source: Rir.Operand) !Rir.Operand {
        utils.todo(noreturn, .{ self, source });
    }

    pub fn store(self: *Block, source: Rir.Operand, value: Rir.Operand) !void {
        utils.todo(noreturn, .{ self, source, value });
    }

    pub fn memcpy(self: *Block, location: enum { register, memory }, size: Rir.Size, destination: *Rir.Register, source: *Rir.Register) !void {
        switch (location) {
            .register =>
                if (size <= 0) return
                else if (size <= 1) try self.active_builder.copy_8(destination.getIndex(), source.getIndex())
                else if (size <= 2) try self.active_builder.copy_16(destination.getIndex(), source.getIndex())
                else if (size <= 4) try self.active_builder.copy_32(destination.getIndex(), source.getIndex())
                else if (size <= 8) try self.active_builder.copy_64(destination.getIndex(), source.getIndex())
                else return error.InvalidOperand,
            .memory => @panic("memcpy memory nyi"),
        }
    }

    pub fn assign(self: *Block, destination: Rir.Operand, newValue: Rir.Operand) !void {
        const destType = try destination.getType();
        const rValue = try self.coerceRegisterOrRValue(newValue, destType);

        return switch (destination) {
            .meta => error.InvalidOperand,
            .r_value => error.InvalidOperand,
            .l_value => |lValue| try assign1(self, lValue, rValue),
        };
    }

    pub fn writeRValue(self: *Block, comptime operationKind: ?WriteOp, destination: *Rir.Register, rValue: Rir.RValue) Error!void {
        const Fns = struct {
            write8: *const fn(*RbcBuilder.Block, u8, Rbc.RegisterIndex) Error!void,
            write16: *const fn(*RbcBuilder.Block, u16, Rbc.RegisterIndex) Error!void,
            write32: *const fn(*RbcBuilder.Block, u32, Rbc.RegisterIndex) Error!void,
            write64: *const fn(*RbcBuilder.Block, u64, Rbc.RegisterIndex) Error!void,
        };

        const copyFns = comptime Fns {
            .write8 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u8, register: Rbc.RegisterIndex) Error!void { return block.copy_8_im(value, register); } }.fun,
            .write16 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u16, register: Rbc.RegisterIndex) Error!void { return block.copy_16_im(value, register); } }.fun,
            .write32 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u32, register: Rbc.RegisterIndex) Error!void { return block.copy_32_im(value, register); } }.fun,
            .write64 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u64, register: Rbc.RegisterIndex) Error!void { return block.copy_64_im(value, register); } }.fun,
        };

        const storeFns = comptime Fns {
            .write8 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u8, register: Rbc.RegisterIndex) Error!void { return block.store_8_im(value, register); } }.fun,
            .write16 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u16, register: Rbc.RegisterIndex) Error!void { return block.store_16_im(value, register); } }.fun,
            .write32 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u32, register: Rbc.RegisterIndex) Error!void { return block.store_32_im(value, register); } }.fun,
            .write64 = &struct { pub fn fun (block: *RbcBuilder.Block, value: u64, register: Rbc.RegisterIndex) Error!void { return block.store_64_im(value, register); } }.fun,
        };

        const typeLayout = try destination.type.getLayout();

        const fns = switch (operationKind orelse if (typeLayout.dimensions.size > 8) WriteOp.store else WriteOp.copy) {
            .store => storeFns,
            .copy => copyFns,
        };

        switch (rValue) {
            .immediate => |im| {
                // Immediates are always <=64 bits as of now
                const registerSize = typeLayout.dimensions.registerSize() orelse unreachable;

                switch(registerSize) {
                    0 => return,
                    8 => try fns.write8(self.active_builder, im.asU8Unchecked(), destination.getIndex()),
                    16 => try fns.write16(self.active_builder, im.asU16Unchecked(), destination.getIndex()),
                    32 => try fns.write32(self.active_builder, im.asU32Unchecked(), destination.getIndex()),
                    64 => try fns.write64(self.active_builder, im.asU64Unchecked(), destination.getIndex()),
                    else => unreachable,
                }
            },
            .function => |functionIr| {
                const functionGen = try self.generator.getFunction(functionIr);
                try fns.write16(self.active_builder, functionGen.builder.index, destination.getIndex());
            },
            .foreign => |foreignIr| {
                const foreignIndex = try self.generator.getForeign(foreignIr);
                try fns.write16(self.active_builder, foreignIndex, destination.getIndex());
            },
        }
    }

    pub fn coerceRegister(self: *Block, operand: Rir.Operand, maybeExpectedTypeIr: ?*Rir.Type) !*Rir.Register {
        const typeIr = maybeExpectedTypeIr orelse try operand.getType();

        switch (operand) {
            .meta => return error.InvalidOperand,
            .l_value => |l| switch (l) {
                .register => |reg|
                    if (utils.equal(reg.type, typeIr)) {
                        return reg;
                    } else if (reg.type.isRegisterCoercibleTo(false, false, typeIr)) {
                        if (self.hasReference(reg.getIndex())) {
                            const outReg = try self.allocRegister(typeIr);

                            try self.assign(.from(outReg), .from(reg));

                            return outReg;
                        } else {
                            reg.type = typeIr;
                            return reg;
                        }
                    },
                .multi_register => @panic("multi register coercion to register nyi"),
                .local => |localIr|
                    if (localIr.register) |reg| {
                        if (utils.equal(reg.type, typeIr)) {
                            return reg;
                        } else if (reg.type.isRegisterCoercibleTo(false, false, typeIr)) {
                            const outReg = try self.allocRegister(typeIr);

                            try self.assign(.from(outReg), operand);

                            return outReg;
                        }
                    } else {
                        return error.LocalNotAssignedRegister;
                    },
                .upvalue => {
                    const outReg = try self.allocRegister(typeIr);
                    try self.assign(.from(outReg), operand);

                    return outReg;
                },
                .global => {
                    const outReg = try self.allocRegister(typeIr);
                    try self.assign(.from(outReg), operand);

                    return outReg;
                },
            },
            .r_value => |r| switch (r) {
                .immediate => {
                    const outReg = try self.allocRegister(typeIr);
                    try self.assign(.from(outReg), operand);

                    return outReg;
                },
                .foreign => {
                    const outReg = try self.allocRegister(typeIr);
                    try self.assign(.from(outReg), operand);

                    return outReg;
                },
                .function => {
                    const outReg = try self.allocRegister(typeIr);
                    try self.assign(.from(outReg), operand);

                    return outReg;
                },
            },
        }

        log.err("cannot coerce operand {} to a register of type {}", .{operand, typeIr});
        return error.InvalidOperand;
    }

    pub fn coerceImmediate(_: *Block, operand: Rir.Operand, maybeTypeIr: ?*Rir.Type) Error!Rir.Immediate {
        switch (operand) {
            .meta => return error.InvalidOperand,
            .l_value => return error.InvalidOperand,
            .r_value => |r| switch (r) {
                .immediate => |im| {
                    if (maybeTypeIr) |typeIr| {
                        if (utils.equal(im.type, typeIr)) {
                            return im;
                        } else {
                            return (im.cast(typeIr) catch return error.TypeMismatch).r_value.immediate;
                        }
                    } else {
                        return im;
                    }
                },
                .foreign => return error.InvalidOperand,
                .function => return error.InvalidOperand,
            },
        }
    }

    pub fn coerceRValue(self: *Block, operand: Rir.Operand, maybeTypeIr: ?*Rir.Type) Error!Rir.RValue {
        switch (operand) {
            .meta => return error.InvalidOperand,
            .l_value => return error.InvalidOperand,
            .r_value => |r| switch (r) {
                .immediate => return .{ .immediate = try self.coerceImmediate(operand, maybeTypeIr) },
                .foreign => |foreignIr| {
                    if (maybeTypeIr) |typeIr| {
                        if (utils.equal(foreignIr.type, typeIr)) {
                            return r;
                        } else {
                            return error.TypeMismatch;
                        }
                    } else {
                        return r;
                    }
                },
                .function => |functionIr| {
                    if (maybeTypeIr) |typeIr| {
                        if (utils.equal(functionIr.type, typeIr)) {
                            return r;
                        } else {
                            return error.TypeMismatch;
                        }
                    } else {
                        return r;
                    }
                },
            },
        }
    }

    pub fn coerceRegisterOrRValue(self: *Block, operand: Rir.Operand, typeIr: ?*Rir.Type) Error!Rir.RegisterOrRValue {
        return switch (operand) {
            .meta => return error.InvalidOperand,
            .l_value => .{ .register = try self.coerceRegister(operand, typeIr) },
            .r_value => .{ .r_value = try self.coerceRValue(operand, typeIr) },
        };
    }

    pub fn coerceRegisterOrImmediate(self: *Block, operand: Rir.Operand, typeIr: ?*Rir.Type) !Rir.RegisterOrImmediate {
        return switch (operand) {
            .meta => return error.InvalidOperand,
            .l_value => .{ .register = try self.coerceRegister(operand, typeIr) },
            .r_value => .{ .immediate = try self.coerceImmediate(operand, typeIr) },
        };
    }

    pub fn setupCall(self: *Block, functionTypeIr: *Rir.Type, operand: []const Rir.Operand) ![]const Rbc.RegisterIndex {
        utils.todo(noreturn, .{ self, functionTypeIr, operand });
    }

    pub fn coerceAddress(self: *Block, operand: Rir.Operand) !Rir.Operand {
        const operandType = try operand.getType();
        const pointerType = try operandType.createPointer();

        switch (operand) {
            .meta => return error.InvalidOperand,

            .l_value => |l| switch (l) {
                .local => |localIr| {
                    switch (localIr.storage) {
                        .none => return error.InvalidOperand,
                        .zero_size => return .from(Rir.Immediate.zero(pointerType)),
                        .register => return error.AddressOfRegister,
                        .n_registers => return error.AddressOfRegister,
                        .stack => return .from(localIr.register orelse return error.LocalNotAssignedRegister),
                        .@"comptime" => return error.InvalidOperand, // TODO: create global?
                    }
                },

                .global => |globalIr| {
                    const globalGen = try self.generator.getGlobal(globalIr);

                    const outReg = try self.allocRegister(pointerType);
                    try self.active_builder.addr_global(globalGen.index, outReg.getIndex());

                    return .from(outReg);
                },

                .upvalue => |upvalueIr| {
                    const upvalueGen = try self.function.getUpvalue(upvalueIr);

                    const outReg = try self.allocRegister(pointerType);
                    try self.active_builder.addr_upvalue(upvalueGen.index, outReg.getIndex());

                    return .from(outReg);
                },

                else => return error.InvalidOperand,
            },

            .r_value => |r| switch (r) {
                .immediate => return error.InvalidOperand,
                .foreign => |foreignIr| {
                    const foreignIndex = try self.generator.getForeign(foreignIr);

                    const outReg = try self.allocRegister(pointerType);
                    try self.active_builder.addr_foreign(foreignIndex, outReg.getIndex());

                    return .from(outReg);
                },
                .function => |functionIr| {
                    const functionGen = try self.generator.getFunction(functionIr);

                    const outReg = try self.allocRegister(pointerType);
                    try self.active_builder.addr_function(functionGen.builder.index, outReg.getIndex());

                    return .from(outReg);
                },
            },
        }
    }

    pub fn phi(self: *Block, blockTypeIr: *Rir.Type, blockGens: []const *Block) !PhiNode {
        utils.todo(noreturn, .{ self, blockTypeIr, blockGens });
    }

    pub fn unary(self: *Block, op: Rir.OpCode) !void {
        const a: Rir.RegisterOrImmediate = try self.coerceRegisterOrImmediate(try self.pop(null), null);

        const output = switch (op) {
            .neg => try unary1(self, a.getType(), a, .neg, .signed, &.{ .floating, .signed }),
            .bnot => try unary1(self, a.getType(), a, .bnot, .no_sign, &.{ .unsigned, .signed }),
            else => utils.todo(noreturn, .{ a, op, }),
        };

        try self.push(output);
    }

    pub fn binary(self: *Block, op: Rir.OpCode) !void {
        const a: Rir.RegisterOrImmediate = try self.coerceRegisterOrImmediate(try self.pop(null), null);
        const b: Rir.RegisterOrImmediate = try self.coerceRegisterOrImmediate(try self.pop(null), a.getType());

        const typeIr = a.getType();

        if (!utils.equal(typeIr, b.getType())) {
            return error.TypeMismatch;
        }

        const output: Rir.Operand = switch (op) {
            .add => try binary1(self, typeIr, a, b, .add, .sign_agnostic, .commutative, &.{ .floating, .unsigned, .signed }),
            .sub => try binary1(self, typeIr, a, b, .sub, .sign_agnostic, .non_commutative, &.{ .floating, .unsigned, .signed }),
            .mul => try binary1(self, typeIr, a, b, .mul, .sign_agnostic, .commutative, &.{ .floating, .unsigned, .signed }),
            .div => try binary1(self, typeIr, a, b, .div, .signed, .non_commutative, &.{ .floating, .unsigned, .signed }),
            .rem => try binary1(self, typeIr, a, b, .rem, .signed, .non_commutative, &.{ .floating, .unsigned, .signed }),
            .band => try binary1(self, typeIr, a, b, .band, .no_sign, .commutative, &.{ .unsigned, .signed }),
            .bor => try binary1(self, typeIr, a, b, .bor, .no_sign, .commutative, &.{ .unsigned, .signed }),
            .bxor => try binary1(self, typeIr, a, b, .bxor, .no_sign, .commutative, &.{ .unsigned, .signed }),
            .bshiftl => try binary1(self, typeIr, a, b, .bshiftl, .no_sign, .non_commutative, &.{ .unsigned, .signed }),
            .bshiftr => try binary1(self, typeIr, a, b, .bshiftr, .signed, .non_commutative, &.{ .unsigned, .signed }),
            .eq => try binary1(self, typeIr, a, b, .eq, .sign_agnostic, .commutative, &.{ .floating, .unsigned, .signed }),
            .ne => try binary1(self, typeIr, a, b, .ne, .sign_agnostic, .commutative, &.{ .floating, .unsigned, .signed }),
            .lt => try binary1(self, typeIr, a, b, .lt, .signed, .non_commutative, &.{ .floating, .unsigned, .signed }),
            .gt => try binary1(self, typeIr, a, b, .gt, .signed, .non_commutative, &.{ .floating, .unsigned, .signed }),
            .le => try binary1(self, typeIr, a, b, .le, .signed, .non_commutative, &.{ .floating, .unsigned, .signed }),
            .ge => try binary1(self, typeIr, a, b, .ge, .signed, .non_commutative, &.{ .floating, .unsigned, .signed }),
            else => return error.InvalidOpCode,
        };

        try self.push(output);
    }

    pub fn cast(self: *Block, outputTypeIr: *Rir.Type) !void {
        const a = try self.pop(null);
        const inputTypeIr = try a.getType();

        const output: Rir.Operand = switch (inputTypeIr.info) {
            .U8 => switch (outputTypeIr.info) {
                .U8 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .U16 => try cast1(self, .u_ext_8_16, outputTypeIr, a),
                .U32 => try cast1(self, .u_ext_8_32, outputTypeIr, a),
                .U64 => try cast1(self, .u_ext_8_64, outputTypeIr, a),
                .S8 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S16 => try cast1(self, .s_ext_8_16, outputTypeIr, a),
                .S32 => try cast1(self, .s_ext_8_32, outputTypeIr, a),
                .S64 => try cast1(self, .s_ext_8_64, outputTypeIr, a),
                .F32 => try cast1(self, .u8_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .u8_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .U16 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .i_trunc_16_8, outputTypeIr, a),
                .U16 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .U32 => try cast1(self, .u_ext_16_32, outputTypeIr, a),
                .U64 => try cast1(self, .u_ext_16_64, outputTypeIr, a),
                .S8 => try cast1(self, .i_trunc_16_8, outputTypeIr, a),
                .S16 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S32 => try cast1(self, .s_ext_16_32, outputTypeIr, a),
                .S64 => try cast1(self, .s_ext_16_64, outputTypeIr, a),
                .F32 => try cast1(self, .u16_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .u16_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .U32 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .i_trunc_32_8, outputTypeIr, a),
                .U16 => try cast1(self, .i_trunc_32_16, outputTypeIr, a),
                .U32 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .U64 => try cast1(self, .u_ext_32_64, outputTypeIr, a),
                .S8 => try cast1(self, .i_trunc_32_8, outputTypeIr, a),
                .S16 => try cast1(self, .i_trunc_32_16, outputTypeIr, a),
                .S32 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S64 => try cast1(self, .s_ext_32_64, outputTypeIr, a),
                .F32 => try cast1(self, .u32_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .u32_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .U64 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .i_trunc_64_8, outputTypeIr, a),
                .U16 => try cast1(self, .i_trunc_64_16, outputTypeIr, a),
                .U32 => try cast1(self, .i_trunc_64_32, outputTypeIr, a),
                .U64 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S8 => try cast1(self, .i_trunc_64_8, outputTypeIr, a),
                .S16 => try cast1(self, .i_trunc_64_16, outputTypeIr, a),
                .S32 => try cast1(self, .i_trunc_64_32, outputTypeIr, a),
                .S64 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .F32 => try cast1(self, .u64_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .u64_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .S8 => switch (outputTypeIr.info) {
                .U8 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .U16 => try cast1(self, .u_ext_8_16, outputTypeIr, a),
                .U32 => try cast1(self, .u_ext_8_32, outputTypeIr, a),
                .U64 => try cast1(self, .u_ext_8_64, outputTypeIr, a),
                .S8 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S16 => try cast1(self, .s_ext_8_16, outputTypeIr, a),
                .S32 => try cast1(self, .s_ext_8_32, outputTypeIr, a),
                .S64 => try cast1(self, .s_ext_8_64, outputTypeIr, a),
                .F32 => try cast1(self, .s8_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .s8_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .S16 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .i_trunc_16_8, outputTypeIr, a),
                .U16 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .U32 => try cast1(self, .u_ext_16_32, outputTypeIr, a),
                .U64 => try cast1(self, .u_ext_16_64, outputTypeIr, a),
                .S8 => try cast1(self, .i_trunc_16_8, outputTypeIr, a),
                .S16 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S32 => try cast1(self, .s_ext_16_32, outputTypeIr, a),
                .S64 => try cast1(self, .s_ext_16_64, outputTypeIr, a),
                .F32 => try cast1(self, .s16_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .s16_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .S32 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .i_trunc_32_8, outputTypeIr, a),
                .U16 => try cast1(self, .i_trunc_32_16, outputTypeIr, a),
                .U32 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .U64 => try cast1(self, .u_ext_32_64, outputTypeIr, a),
                .S8 => try cast1(self, .i_trunc_32_8, outputTypeIr, a),
                .S16 => try cast1(self, .i_trunc_32_16, outputTypeIr, a),
                .S32 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S64 => try cast1(self, .s_ext_32_64, outputTypeIr, a),
                .F32 => try cast1(self, .s32_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .s32_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .S64 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .i_trunc_64_8, outputTypeIr, a),
                .U16 => try cast1(self, .i_trunc_64_16, outputTypeIr, a),
                .U32 => try cast1(self, .i_trunc_64_32, outputTypeIr, a),
                .U64 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .S8 => try cast1(self, .i_trunc_64_8, outputTypeIr, a),
                .S16 => try cast1(self, .i_trunc_64_16, outputTypeIr, a),
                .S32 => try cast1(self, .i_trunc_64_32, outputTypeIr, a),
                .S64 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .F32 => try cast1(self, .s64_to_f32, outputTypeIr, a),
                .F64 => try cast1(self, .s64_to_f64, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .F32 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .f32_to_u8, outputTypeIr, a),
                .U16 => try cast1(self, .f32_to_u16, outputTypeIr, a),
                .U32 => try cast1(self, .f32_to_u32, outputTypeIr, a),
                .U64 => try cast1(self, .f32_to_u64, outputTypeIr, a),
                .S8 => try cast1(self, .f32_to_s8, outputTypeIr, a),
                .S16 => try cast1(self, .f32_to_s16, outputTypeIr, a),
                .S32 => try cast1(self, .f32_to_s32, outputTypeIr, a),
                .S64 => try cast1(self, .f32_to_s64, outputTypeIr, a),
                .F32 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                .F64 => try cast1(self, .f_trunc_64_32, outputTypeIr, a),
                else => return error.InvalidOperand,
            },
            .F64 => switch (outputTypeIr.info) {
                .U8 => try cast1(self, .f64_to_u8, outputTypeIr, a),
                .U16 => try cast1(self, .f64_to_u16, outputTypeIr, a),
                .U32 => try cast1(self, .f64_to_u32, outputTypeIr, a),
                .U64 => try cast1(self, .f64_to_u64, outputTypeIr, a),
                .S8 => try cast1(self, .f64_to_s8, outputTypeIr, a),
                .S16 => try cast1(self, .f64_to_s16, outputTypeIr, a),
                .S32 => try cast1(self, .f64_to_s32, outputTypeIr, a),
                .S64 => try cast1(self, .f64_to_s64, outputTypeIr, a),
                .F32 => try cast1(self, .f_ext_32_64, outputTypeIr, a),
                .F64 => .from(try self.coerceRegisterOrImmediate(a, outputTypeIr)),
                else => return error.InvalidOperand,
            },
            else => return error.InvalidOperand,
        };

        try self.push(output);
    }
};

fn unary2(
    self: *Block,
    typeIr: *Rir.Type,
    a: Rir.RegisterOrImmediate,
    comptime im: anytype,
    comptime dyn: anytype,
) !Rir.Operand {
    if (comptime @typeInfo(@TypeOf(im)) != .@"fn") {
        @compileError(std.fmt.comptimePrint("im parameter must be a function, got {any}: {s}", .{ dyn, @typeName(@TypeOf(im)) }));
    }

    if (comptime @typeInfo(@TypeOf(dyn)) != .@"fn") {
        @compileError(std.fmt.comptimePrint("dyn parameter must be a function, got {any}: {s}", .{ dyn, @typeName(@TypeOf(dyn)) }));
    }

    switch (a) {
        .register => |reg| {
            const out = try self.allocRegister(typeIr);
            try dyn(self.active_builder, reg.getIndex(), out.getIndex());
            return .from(out);
        },
        .immediate => |*x| return .from(try im(x)),
    }
}

fn binary2(
    self: *Block,
    typeIr: *Rir.Type,
    a: Rir.RegisterOrImmediate,
    b: Rir.RegisterOrImmediate,
    comptime downcast: anytype,
    comptime both_im: anytype,
    comptime neither_im: anytype,
    comptime lhs_im: anytype,
    comptime rhs_im: anytype,
) !Rir.Operand {
    if (a == .immediate and b == .register) {
        const out = try self.allocRegister(typeIr);
        try lhs_im(self.active_builder, downcast(&a.immediate), b.register.getIndex(), out.getIndex());
        return .from(out);
    } else if (a == .register and b == .immediate) {
        const out = try self.allocRegister(typeIr);
        if (comptime @typeInfo(@TypeOf(rhs_im)) == .null) {
            try lhs_im(self.active_builder, downcast(&b.immediate), a.register.getIndex(), out.getIndex());
        } else {
            try rhs_im(self.active_builder, a.register.getIndex(), downcast(&b.immediate), out.getIndex());
        }
        return .from(out);
    } else if (a == .register and b == .register) {
        const out = try self.allocRegister(typeIr);
        try neither_im(self.active_builder, a.register.getIndex(), b.register.getIndex(), out.getIndex());
        return .from(out);
    } else {
        return .from(try both_im(&a.immediate, &b.immediate));
    }
}

fn unary1(
    self: *Block,
    typeIr: *Rir.Type,
    a: Rir.RegisterOrImmediate,
    comptime opCode: Rir.OpCode,
    comptime intSignStyle: enum { signed, sign_agnostic, no_sign },
    comptime validity: []const OperationValidity,
) !Rir.Operand {
    const opName = comptime @tagName(opCode);
    const validForUnsigned = comptime std.mem.indexOfScalar(OperationValidity, validity, .unsigned) != null;
    const validForSigned = comptime std.mem.indexOfScalar(OperationValidity, validity, .signed) != null;
    const validForFloat = comptime std.mem.indexOfScalar(OperationValidity, validity, .floating) != null;
    const unsigned_prefix = comptime switch (intSignStyle) {
        .signed => "u_",
        .sign_agnostic => "i_",
        .no_sign => "",
    };
    const signed_prefix = comptime switch (intSignStyle) {
        .signed => "s_",
        .sign_agnostic => "i_",
        .no_sign => "",
    };

    comptime std.debug.assert(@hasDecl(Rir.Immediate, opName));
    comptime std.debug.assert(@typeInfo(@TypeOf(@field(Rir.Immediate, opName))) == .@"fn");

    const im = @field(Rir.Immediate, opName);

    switch (typeIr.info) {
        .U8 => if (comptime validForUnsigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_8")) else return error.InvalidOperand,
        .U16 => if (comptime validForUnsigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_16")) else return error.InvalidOperand,
        .U32 => if (comptime validForUnsigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_32")) else return error.InvalidOperand,
        .U64 => if (comptime validForUnsigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_64")) else return error.InvalidOperand,
        .S8 => if (comptime validForSigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_8")) else return error.InvalidOperand,
        .S16 => if (comptime validForSigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_16")) else return error.InvalidOperand,
        .S32 => if (comptime validForSigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_32")) else return error.InvalidOperand,
        .S64 => if (comptime validForSigned) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_64")) else return error.InvalidOperand,
        .F32 => if (comptime validForFloat) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, "f_" ++ opName ++ "_32")) else return error.InvalidOperand,
        .F64 => if (comptime validForFloat) return try unary2(self, typeIr, a, im, @field(RbcBuilder.Block, "f_" ++ opName ++ "_64")) else return error.InvalidOperand,
        else => return error.InvalidOperand,
    }
}

fn binary1(
    self: *Block,
    typeIr: *Rir.Type,
    a: Rir.RegisterOrImmediate,
    b: Rir.RegisterOrImmediate,
    comptime opCode: Rir.OpCode,
    comptime intSignStyle: enum { sign_agnostic, signed, no_sign },
    comptime commutativity: enum { commutative, non_commutative },
    comptime validity: []const OperationValidity,
) !Rir.Operand {
    const opName = comptime @tagName(opCode);
    const validForUnsigned = comptime std.mem.indexOfScalar(OperationValidity, validity, .unsigned) != null;
    const validForSigned = comptime std.mem.indexOfScalar(OperationValidity, validity, .signed) != null;
    const validForFloat = comptime std.mem.indexOfScalar(OperationValidity, validity, .floating) != null;

    const unsigned_prefix = comptime switch (intSignStyle) {
        .sign_agnostic => "i_",
        .signed => "u_",
        .no_sign => "",
    };
    const signed_prefix = comptime switch (intSignStyle) {
        .sign_agnostic => "i_",
        .signed => "s_",
        .no_sign => "",
    };

    const suffixA = comptime if (commutativity != .commutative) "_im_a" else "_im";
    const suffixB = comptime if (commutativity != .commutative) "_im_b" else "_im";

    switch (typeIr.info) {
        .U8 => if (comptime validForUnsigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asU8Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_8"),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_8" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_8" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .U16 => if (comptime validForUnsigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asU16Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_16"),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_16" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_16" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .U32 => if (comptime validForUnsigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asU32Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_32"),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_32" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_32" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .U64 => if (comptime validForUnsigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asU64Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_64"),
            @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_64" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, unsigned_prefix ++ opName ++ "_64" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .S8 => if (comptime validForSigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asS8Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_8"),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_8" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_8" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .S16 => if (comptime validForSigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asS16Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_16"),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_16" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_16" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .S32 => if (comptime validForSigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asS32Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_32"),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_32" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_32" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .S64 => if (comptime validForSigned) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asS64Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_64"),
            @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_64" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, signed_prefix ++ opName ++ "_64" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .F32 => if (comptime validForFloat) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asF32Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, "f_" ++ opName ++ "_32"),
            @field(RbcBuilder.Block, "f_" ++ opName ++ "_32" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, "f_" ++ opName ++ "_32" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        .F64 => if (comptime validForFloat) return try binary2(
            self,
            typeIr,
            a,
            b,
            Rir.Immediate.asF64Unchecked,
            @field(Rir.Immediate, opName),
            @field(RbcBuilder.Block, "f_" ++ opName ++ "_64"),
            @field(RbcBuilder.Block, "f_" ++ opName ++ "_64" ++ suffixA),
            if (commutativity != .commutative) @field(RbcBuilder.Block, "f_" ++ opName ++ "_64" ++ suffixB) else null,
        ) else return error.InvalidOperand,
        else => return error.InvalidOperand,
    }
}

fn cast1(self: *Block, comptime opCode: Rbc.Code, outputTypeIr: *Rir.Type, a: Rir.Operand) !Rir.Operand {
    return switch (try self.coerceRegisterOrRValue(a, outputTypeIr)) {
        .register => |aRegister| reg: {
            if (a == .l_value and utils.equal(a.l_value.register, aRegister)) {
                break :reg .from(aRegister);
            }
            const bRegister = try self.allocRegister(outputTypeIr);
            try @field(RbcBuilder.Block, @tagName(opCode))(self.active_builder, aRegister.getIndex(), bRegister.getIndex());
            break :reg .from(bRegister);
        },
        .r_value => |r| .from(r),
    };
}

fn assign1(self: *Block, lValue: Rir.LValue, rValue: Rir.RegisterOrRValue) !void {
    const typeLayout = try lValue.getType().getLayout();

    switch (lValue) {
        .register => |outReg| switch (rValue) {
            .register => |inReg| {
                if (outReg.id == inReg.id) return;

                try self.memcpy(.register, typeLayout.dimensions.size, outReg, inReg);
            },
            .r_value => |r| try self.writeRValue(null, outReg, r),
        },
        .multi_register => @panic("multi register assignment nyi"),
        .local => |localIr| {
            const localRegister = localIr.register orelse return error.LocalNotAssignedRegister;

            switch (localIr.storage) {
                .none => return error.LocalNotAssignedStorage,

                .n_registers => @panic("n_registers local assignment nyi"),
                .@"comptime" => @panic("comptime local assignment nyi"),

                .zero_size => {},

                .register => switch (rValue) {
                    .register => |inReg| {
                        if (localRegister.id == inReg.id) return;

                        try self.memcpy(.register, typeLayout.dimensions.size, localRegister, inReg);
                    },
                    .r_value => |r| try self.writeRValue(null, localRegister, r),
                },

                .stack => switch (rValue) {
                    .register => |inReg| {
                        if (localRegister.id == inReg.id) return;

                        try self.memcpy(.memory, typeLayout.dimensions.size, localRegister, inReg);
                    },
                    .r_value => |r| try self.writeRValue(.store, localRegister, r),
                }
            }
        },
        .upvalue => |upvalueIr| {
            const upvalueGen = try self.function.getUpvalue(upvalueIr);

            switch (rValue) {
                .register => |inReg| {
                    if (typeLayout.dimensions.registerSize()) |registerSize| {
                        switch(registerSize) {
                            0 => return,
                            8 => try self.active_builder.write_upvalue_8(upvalueGen.index, inReg.getIndex()),
                            16 => try self.active_builder.write_upvalue_16(upvalueGen.index, inReg.getIndex()),
                            32 => try self.active_builder.write_upvalue_32(upvalueGen.index, inReg.getIndex()),
                            64 => try self.active_builder.write_upvalue_64(upvalueGen.index, inReg.getIndex()),
                            else => unreachable,
                        }
                    } else {
                        const addrTypeIr = try upvalueGen.ir.type.createPointer();
                        const addrReg = try self.allocRegister(addrTypeIr);

                        try self.active_builder.addr_upvalue(upvalueGen.index, addrReg.getIndex());

                        try self.memcpy(.memory, typeLayout.dimensions.size, addrReg, inReg);
                    }
                },
                .r_value => |r| switch (r) {
                    .immediate => |im| {
                        // Immediates are always <=64 bits as of now
                        const registerSize = typeLayout.dimensions.registerSize() orelse unreachable;

                        switch (registerSize) {
                            0 => return,
                            8 => try self.active_builder.write_upvalue_8_im(im.asU8Unchecked(), upvalueGen.index),
                            16 => try self.active_builder.write_upvalue_16_im(im.asU16Unchecked(), upvalueGen.index),
                            32 => try self.active_builder.write_upvalue_32_im(im.asU32Unchecked(), upvalueGen.index),
                            64 => try self.active_builder.write_upvalue_64_im(im.asU64Unchecked(), upvalueGen.index),
                            else => unreachable,
                        }
                    },
                    .function => |functionIr| {
                        const functionGen = try self.generator.getFunction(functionIr);
                        try self.active_builder.write_upvalue_16_im(functionGen.builder.index, upvalueGen.index);
                    },
                    .foreign => |foreignIr| {
                        const foreignIndex = try self.generator.getForeign(foreignIr);
                        try self.active_builder.write_upvalue_16_im(foreignIndex, upvalueGen.index);
                    },
                },
            }
        },
        .global => |globalIr| {
            const globalGen = try self.generator.getGlobal(globalIr);

            switch (rValue) {
                .register => |inReg| {
                    if (typeLayout.dimensions.registerSize()) |registerSize| {
                        switch(registerSize) {
                            0 => return,
                            8 => try self.active_builder.write_global_8(globalGen.index, inReg.getIndex()),
                            16 => try self.active_builder.write_global_16(globalGen.index, inReg.getIndex()),
                            32 => try self.active_builder.write_global_32(globalGen.index, inReg.getIndex()),
                            64 => try self.active_builder.write_global_64(globalGen.index, inReg.getIndex()),
                            else => unreachable,
                        }
                    } else {
                        const addrTypeIr = try globalGen.ir.type.createPointer();
                        const addrReg = try self.allocRegister(addrTypeIr);

                        try self.active_builder.addr_global(globalGen.index, addrReg.getIndex());

                        try self.memcpy(.memory, typeLayout.dimensions.size, addrReg, inReg);
                    }
                },
                .r_value => |r| switch (r) {
                    .immediate => |im| {
                        // Immediates are always <=64 bits as of now
                        const registerSize = typeLayout.dimensions.registerSize() orelse unreachable;

                        switch(registerSize) {
                            0 => return,
                            8 => try self.active_builder.write_global_8_im(im.asU8Unchecked(), globalGen.index),
                            16 => try self.active_builder.write_global_16_im(im.asU16Unchecked(), globalGen.index),
                            32 => try self.active_builder.write_global_32_im(im.asU32Unchecked(), globalGen.index),
                            64 => try self.active_builder.write_global_64_im(im.asU64Unchecked(), globalGen.index),
                            else => unreachable,
                        }
                    },
                    .function => |functionIr| {
                        const functionGen = try self.generator.getFunction(functionIr);
                        try self.active_builder.write_global_16_im(functionGen.builder.index, globalGen.index);
                    },
                    .foreign => |foreignIr| {
                        const foreignIndex = try self.generator.getForeign(foreignIr);
                        try self.active_builder.write_global_16_im(foreignIndex, globalGen.index);
                    },
                }
            }
        },
    }
}
