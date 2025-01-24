const std = @import("std");

const MiscUtils = @import("Utils").Misc;
const Core = @import("Core");

const Builder = @import("root.zig");
const Error = Builder.Error;
const BlockBuilder = Builder.BlockBuilder;

const FunctionBuilder = @This();


parent: *Builder,
index: Core.FunctionIndex,
blocks: Builder.BlockList,
entry: *BlockBuilder = undefined,
evidence: ?Core.EvidenceIndex = null,
num_arguments: usize = 0,
num_locals: usize = 0,
num_upvalues: usize = 0,



/// For use by the parent Builder only
pub fn init(parent: *Builder, index: Core.FunctionIndex) Error!*FunctionBuilder {
    const ptr = try parent.allocator.create(FunctionBuilder);

    var blocks = Builder.BlockList {};
    try blocks.ensureTotalCapacity(parent.allocator, Core.MAX_BLOCKS);

    ptr.* = FunctionBuilder {
        .parent = parent,
        .index = index,
        .blocks = blocks,
    };

    ptr.entry = try BlockBuilder.init(ptr, null, 0, .basic);

    ptr.blocks.appendAssumeCapacity(ptr.entry);

    return ptr;
}

pub fn assemble(self: *const FunctionBuilder, allocator: std.mem.Allocator) Error!Core.Function {
    var num_instrs: usize = 0;

    for (self.blocks.items) |builder| {
        num_instrs += try builder.preassemble();
    }

    const blocks = try allocator.alloc([*]const Core.Instruction, self.blocks.items.len);
    errdefer allocator.free(blocks);

    const instructions = try allocator.alloc(Core.Instruction, num_instrs);
    errdefer allocator.free(instructions);

    var instr_offset: usize = 0;
    for (self.blocks.items, 0..) |builder, i| {
        const block = builder.assemble(instructions, &instr_offset);
        blocks[i] = block;
    }


    return Core.Function {
        .num_arguments = @truncate(self.num_arguments),
        .num_registers = @truncate(self.num_arguments + self.num_locals),
        .bytecode = .{
            .blocks = blocks,
            .instructions = instructions,
        },
    };
}

pub fn getBlock(self: *const FunctionBuilder, index: Core.BlockIndex) Error!*BlockBuilder {
    if (index >= self.blocks.items.len) {
        return Error.InvalidIndex;
    }

    return self.blocks.items[index];
}

pub fn newBlock(self: *FunctionBuilder, parent: ?Core.BlockIndex, kind: BlockBuilder.Kind) Error!*BlockBuilder {
    const index = self.blocks.items.len;
    if (index >= Core.MAX_BLOCKS) return Error.TooManyBlocks;

    const block = try BlockBuilder.init(self, parent, @truncate(index), kind);
    self.blocks.appendAssumeCapacity(block);

    return block;
}

pub fn arg(self: *FunctionBuilder) Error!Core.RegisterIndex {
    if (self.num_locals > 0) return Error.ArgumentAfterLocals;

    const index = self.num_arguments;
    if (index >= Core.MAX_REGISTERS) return Error.TooManyRegisters;

    self.num_arguments += 1;

    return @truncate(index);
}

pub fn local(self: *FunctionBuilder) Error!Core.RegisterIndex {
    const index = self.num_arguments + self.num_locals;
    if (index >= Core.MAX_REGISTERS) return Error.TooManyRegisters;

    self.num_locals += 1;

    return @truncate(index);
}

pub fn upvalue(self: *FunctionBuilder) Error!Core.UpvalueIndex {
    const index = self.num_upvalues;
    if (index >= Core.MAX_REGISTERS) return Error.TooManyUpvalues;

    self.num_upvalues += 1;

    return @truncate(index);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
