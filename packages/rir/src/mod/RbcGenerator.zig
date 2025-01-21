const RbcGenerator = @This();

test {
    std.testing.refAllDeclsRecursive(RbcGenerator);
}

const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const Rbc = @import("Rbc:Core");
const RbcBuilder = @import("Rbc:Builder");

const Rir = @import("Rir");

const Error = Rir.Error || RbcBuilder.Error || error {
    StackOverflow,
    StackUnderflow,
};


allocator: std.mem.Allocator,
bytecode: RbcBuilder,
ir: *Rir,
global_lookup: std.ArrayHashMapUnmanaged(Rir.Ref(Rir.GlobalId), Rbc.GlobalIndex, MiscUtils.SimpleHashContext, false) = .{},
function_lookup: std.ArrayHashMapUnmanaged(Rir.Ref(Rir.FunctionId), Rbc.FunctionIndex, MiscUtils.SimpleHashContext, false) = .{},
evidence_lookup: std.ArrayHashMapUnmanaged(Rir.EvidenceId, Rbc.EvidenceIndex, MiscUtils.SimpleHashContext, false) = .{},
stack: std.ArrayListUnmanaged(Rir.Operand) = .{},

pub const Export = union(enum) {
    function: Rir.Ref(Rir.FunctionId),
    global: Rir.Ref(Rir.GlobalId),
};


/// Allocator provided should be an arena or a similar allocator,
/// that does not care about freeing individual allocations
pub fn init(allocator: std.mem.Allocator, ir: *Rir) !RbcGenerator {
    return RbcGenerator {
        .allocator = allocator,
        .bytecode = try RbcBuilder.init(allocator),
        .ir = ir,
    };
}


/// Allocator provided does not have to be the allocator used to create the generator,
/// a long term allocator is preferred.
///
/// In the event of an error, this function cleans up any allocations it created.
pub fn generate(self: *RbcGenerator, allocator: std.mem.Allocator, exports: []const Export) !Rbc.Program {
    for (exports) |exp| {
        switch (exp) {
            .function => |ref| _ = try self.getFunction(ref),
            .global => |ref| _ = try self.getGlobal(ref),
        }
    }

    return try self.bytecode.assemble(allocator);
}


pub fn getFunction(self: *RbcGenerator, fRef: Rir.Ref(Rir.FunctionId)) Error! Rbc.FunctionIndex {
    const getOrPut = try self.function_lookup.getOrPut(self.allocator, fRef);

    if (!getOrPut.found_existing) {
        const function = try self.ir.getFunction(fRef);
        const builder = try self.bytecode.function();

        getOrPut.value_ptr.* = try self.compileFunction(function, builder);
    }

    return getOrPut.value_ptr.*;
}


pub fn compileFunction(self: *RbcGenerator, function: *Rir.Function, builder: *RbcBuilder.FunctionBuilder) Error! Rbc.FunctionIndex {
    std.debug.assert(!self.function_lookup.contains(function.getRef()));

    var generator = try FunctionGenerator.init(self, function, builder);

    try self.function_lookup.put(self.allocator, function.getRef(), builder.index);

    try generator.generate();

    return builder.index;
}

pub fn getGlobal(self: *RbcGenerator, gRef: Rir.Ref(Rir.GlobalId)) Error! Rbc.GlobalIndex {
    const getOrPut = try self.global_lookup.getOrPut(self.allocator, gRef);

    if (!getOrPut.found_existing) {
        const global = try self.ir.getGlobal(gRef);
        getOrPut.value_ptr.* = try self.compileGlobal(global);
    }

    return getOrPut.value_ptr.*;
}

pub fn compileGlobal(self: *RbcGenerator, global: *Rir.Global) !Rbc.GlobalIndex {
    std.debug.assert(!self.global_lookup.contains(global.getRef()));

    const globalLayout = try self.ir.getTypeLayout(global.type);
    const index = try self.bytecode.globalBytes(globalLayout.dimensions.alignment, global.value);

    try self.global_lookup.put(self.allocator, global.getRef(), index);

    return index;
}

pub fn getEvidence(self: *RbcGenerator, evId: Rir.EvidenceId) !Rbc.EvidenceIndex {
    const getOrPut = try self.evidence_lookup.getOrPut(self.allocator, evId);

    if (!getOrPut.found_existing) {
        const index = try self.bytecode.evidence();
        getOrPut.value_ptr.* = index;
    }

    return getOrPut.value_ptr.*;
}

pub fn pop(self: *RbcGenerator, comptime kind: ?std.meta.Tag(Rir.Operand)) !Rir.Operand.TypeOf(kind) {
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

pub const FunctionGenerator = struct {
    root: *RbcGenerator,
    function: *Rir.Function,
    builder: *RbcBuilder.FunctionBuilder,
    block_lookup: std.ArrayHashMapUnmanaged(Rir.BlockId, *RbcBuilder.BlockBuilder, MiscUtils.SimpleHashContext, false) = .{},
    handler_set_lookup: std.ArrayHashMapUnmanaged(Rir.HandlerSetId, *RbcBuilder.HandlerSetBuilder, MiscUtils.SimpleHashContext, false) = .{},

    pub fn init(root: *RbcGenerator, function: *Rir.Function, builder: *RbcBuilder.FunctionBuilder) !FunctionGenerator {
        return FunctionGenerator{
            .root = root,
            .function = function,
            .builder = builder,
        };
    }

    pub fn generate(self: *FunctionGenerator) !void {
        const entry = self.function.getEntryBlock();

        const block = try self.builder.getBlock(0);

        try self.compileBlock(entry, block);
    }

    pub fn getBlock(self: *FunctionGenerator, blockId: Rir.BlockId) !*RbcBuilder.BlockBuilder {
        return self.block_lookup.get(blockId) orelse error.InvalidBlock;
    }

    pub fn compileBlock(self: *FunctionGenerator, block: *Rir.Block, builder: *RbcBuilder.BlockBuilder) !void {
        std.debug.assert(!self.block_lookup.contains(block.id));

        try self.block_lookup.put(self.root.allocator, block.id, builder);

        const instrs = block.instructions.items;

        var i: usize = 0;
        while (i < instrs.len) {
            const instr = instrs[i];
            i += 1;

            switch (instr.code) {
                .nop => try builder.nop(),

                .halt => try builder.halt(),
                .trap => try builder.trap(),

                // TODO: block state
                .block => {
                    const blockId = try self.root.pop(.block);

                    const childBlock = try self.function.getBlock(blockId);
                    // TODO: need to switch on _v
                    const childBuilder = try builder.block();

                    try self.compileBlock(childBlock, childBuilder);
                },
                .with => {
                    const blockId = try self.root.pop(.block);
                    const childBlock = try self.function.getBlock(blockId);

                    const handlerSetId = try self.root.pop(.handler_set);
                    const handlerSet = try self.getHandlerSet(handlerSetId);

                    // TODO: need to switch on _v
                    const childBuilder = try builder.with(handlerSet);

                    try self.compileBlock(childBlock, childBuilder);
                },
                .@"if" => {
                    const zeroCheck = instr.data.@"if";

                    const condOperand = try self.root.pop(null);
                    const condReg = try self.rvalue(condOperand);

                    const thenId = try self.root.pop(.block);
                    const thenBlock = try self.function.getBlock(thenId);

                    const elseId = try self.root.pop(.block);
                    const elseBlock = try self.function.getBlock(elseId);

                    // TODO: need to also switch on _v

                    const thenBuilder, const elseBuilder = switch (zeroCheck) {
                        .zero => try builder.@"if_z"(condReg),
                        .non_zero => try builder.@"if_nz"(condReg),
                    };

                    try self.compileBlock(thenBlock, thenBuilder);
                    try self.compileBlock(elseBlock, elseBuilder);
                },
                .when => {
                    const zeroCheck = instr.data.when;

                    const condOperand = try self.root.pop(null);
                    const condReg = try self.rvalue(condOperand);

                    const thenId = try self.root.pop(.block);
                    const thenBlock = try self.function.getBlock(thenId);

                    const thenBuilder = switch (zeroCheck) {
                        .zero => try builder.when_z(condReg),
                        .non_zero => try builder.when_nz(condReg),
                    };

                    try self.compileBlock(thenBlock, thenBuilder);
                },
                .re => {
                    const zeroCheck = instr.data.re;

                    const reId = try self.root.pop(.block);
                    const reBlock = try self.getBlock(reId);

                    switch (zeroCheck) {
                        .none => try builder.re(reBlock),
                        .zero => {
                            const condOperand = try self.root.pop(null);
                            const condReg = try self.rvalue(condOperand);

                            try builder.re_z(reBlock, condReg);
                        },
                        .non_zero => {
                            const condOperand = try self.root.pop(null);
                            const condReg = try self.rvalue(condOperand);

                            try builder.re_nz(reBlock, condReg);
                        },
                    }
                },
                .br => {
                    const zeroCheck = instr.data.br;

                    const brId = try self.root.pop(.block);
                    const brBlock = try self.getBlock(brId);

                    // TODO: need to also switch on _v

                    switch (zeroCheck) {
                        .none => try builder.br(brBlock),
                        .zero => {
                            const condOperand = try self.root.pop(null);
                            const condReg = try self.rvalue(condOperand);

                            try builder.br_z(brBlock, condReg);
                        },
                        .non_zero => {
                            const condOperand = try self.root.pop(null);
                            const condReg = try self.rvalue(condOperand);

                            try builder.br_nz(brBlock, condReg);
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
                .clear => @panic("clear nyi"),
                .swap => @panic("swap nyi"),
                .copy => @panic("copy nyi"),

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

                .ref_local => @panic("ref_local nyi"),
                .ref_block => @panic("ref_block nyi"),
                .ref_function => @panic("ref_function nyi"),
                .ref_foreign => @panic("ref_foreign nyi"),
                .ref_global => @panic("ref_global nyi"),
                .ref_upvalue => @panic("ref_upvalue nyi"),

                .discard => @panic("discard nyi"),

                .im_b => @panic("im_b nyi"),
                .im_s => @panic("im_s nyi"),
                .im_i => @panic("im_i nyi"),
                .im_w => @panic("im_w nyi"),
            }
        }
    }

    pub fn getHandlerSet(self: *FunctionGenerator, hsId: Rir.HandlerSetId) !*RbcBuilder.HandlerSetBuilder {
        const getOrPut = try self.handler_set_lookup.getOrPut(self.root.allocator, hsId);

        if (!getOrPut.found_existing) {
            const handlerSet = try self.function.getHandlerSet(hsId);
            const builder = try self.root.bytecode.handlerSet();

            getOrPut.value_ptr.* = builder;

            try self.compileHandlerSet(handlerSet, builder);
        }

        return getOrPut.value_ptr.*;
    }

    pub fn compileHandlerSet(self: *FunctionGenerator, handlerSet: *Rir.HandlerSet, builder: *RbcBuilder.HandlerSetBuilder) !void {
        std.debug.assert(!self.handler_set_lookup.contains(handlerSet.id));

        var it = handlerSet.handlers.iterator();
        while (it.next()) |pair| {
            const evId = try self.root.getEvidence(pair.key_ptr.*);
            const handlerBuilder = try builder.handler(evId);
            _ = try self.root.compileFunction(pair.value_ptr.*, handlerBuilder);
        }
    }

    pub fn rvalue(self: *FunctionGenerator, operand: Rir.Operand) !Rbc.RegisterIndex {
        _ = self;

        switch (operand) {
            inline
                .type,
                .block,
                .handler_set,
                .function,
                .foreign,
            => return error.InvalidOperand,

            .register => |r| return @intFromEnum(r),

            .im_8 => @panic("im_8 nyi"),
            .im_16 => @panic("im_16 nyi"),
            .im_32 => @panic("im_32 nyi"),
            .im_64 => @panic("im_64 nyi"),

            .global => @panic("global nyi"),

            .upvalue => @panic("upvalue nyi"),

            .local => @panic("local nyi"),
        }
    }
};
