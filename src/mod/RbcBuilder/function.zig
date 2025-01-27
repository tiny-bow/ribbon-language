const Builder = @import("../RbcBuilder.zig");

const function = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");



const BlockList = std.ArrayListUnmanaged(*Builder.Block);

pub const Function = struct {
    parent: *Builder,
    index: Rbc.FunctionIndex,
    blocks: BlockList,
    entry: *Builder.Block = undefined,
    evidence: ?Rbc.EvidenceIndex = null,
    num_arguments: usize = 0,
    num_locals: usize = 0,
    num_upvalues: usize = 0,


    pub fn init(parent: *Builder, index: Rbc.FunctionIndex) Builder.Error!*Function {
        const ptr = try parent.allocator.create(Function);

        var blocks = BlockList {};
        try blocks.ensureTotalCapacity(parent.allocator, Rbc.MAX_BLOCKS);

        ptr.* = Function {
            .parent = parent,
            .index = index,
            .blocks = blocks,
        };

        ptr.entry = try Builder.Block.init(ptr, null, 0, .basic);

        ptr.blocks.appendAssumeCapacity(ptr.entry);

        return ptr;
    }

    pub fn assemble(self: *const Function, allocator: std.mem.Allocator) Builder.Error!Rbc.Function {
        var num_instrs: usize = 0;

        for (self.blocks.items) |builder| {
            num_instrs += try builder.preassemble();
        }

        const blocks = try allocator.alloc([*]const Rbc.Instruction, self.blocks.items.len);
        errdefer allocator.free(blocks);

        const instructions = try allocator.alloc(Rbc.Instruction, num_instrs);
        errdefer allocator.free(instructions);

        var instr_offset: usize = 0;
        for (self.blocks.items, 0..) |builder, i| {
            const block = builder.assemble(instructions, &instr_offset);
            blocks[i] = block;
        }


        return Rbc.Function {
            .num_arguments = @truncate(self.num_arguments),
            .num_registers = @truncate(self.num_arguments + self.num_locals),
            .bytecode = .{
                .blocks = blocks,
                .instructions = instructions,
            },
        };
    }

    pub fn getBlock(self: *const Function, index: Rbc.BlockIndex) Builder.Error!*Builder.Block {
        if (index >= self.blocks.items.len) {
            return Builder.Error.InvalidIndex;
        }

        return self.blocks.items[index];
    }

    pub fn newBlock(self: *Function, parent: ?Rbc.BlockIndex, kind: Builder.block.BlockKind) Builder.Error!*Builder.Block {
        const index = self.blocks.items.len;
        if (index >= Rbc.MAX_BLOCKS) return Builder.Error.TooManyBlocks;

        const block = try Builder.Block.init(self, parent, @truncate(index), kind);
        self.blocks.appendAssumeCapacity(block);

        return block;
    }

    pub fn arg(self: *Function) Builder.Error!Rbc.RegisterIndex {
        if (self.num_locals > 0) return Builder.Error.ArgumentAfterLocals;

        const index = self.num_arguments;
        if (index >= Rbc.MAX_REGISTERS) return Builder.Error.TooManyRegisters;

        self.num_arguments += 1;

        return @truncate(index);
    }

    pub fn local(self: *Function) Builder.Error!Rbc.RegisterIndex {
        const index = self.num_arguments + self.num_locals;
        if (index >= Rbc.MAX_REGISTERS) return Builder.Error.TooManyRegisters;

        self.num_locals += 1;

        return @truncate(index);
    }

    pub fn upvalue(self: *Function) Builder.Error!Rbc.UpvalueIndex {
        const index = self.num_upvalues;
        if (index >= Rbc.MAX_REGISTERS) return Builder.Error.TooManyUpvalues;

        self.num_upvalues += 1;

        return @truncate(index);
    }
};
