const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");


const Generator = @import("../RbcGenerator.zig");


pub const Function = struct {
    module: *Generator.Module,

    ir: *Rir.Function,
    builder: *RbcBuilder.FunctionBuilder,

    block_lookup: std.ArrayHashMapUnmanaged(Rir.BlockId, *Generator.Block, MiscUtils.SimpleHashContext, false) = .{},


    pub fn init(module: *Generator.Module, function: *Rir.Function, builder: *RbcBuilder.FunctionBuilder) error{OutOfMemory}! *Function {
        const self = try module.root.allocator.create(Function);

        self.* = Function {
            .module = module,
            .ir = function,
            .builder = builder,
        };

        return self;
    }

    pub fn generate(self: *Function) !void {
        _ = try self.compileBlock(@enumFromInt(0));
    }

    pub fn getBlock(self: *Function, blockId: Rir.BlockId) error{InvalidBlock}! *Generator.Block {
        return self.block_lookup.get(blockId)
            orelse error.InvalidBlock;
    }

    pub fn compileBlock(self: *Function, blockId: Rir.BlockId) Generator.Error! *Generator.Block {
        const blockIr = try self.ir.getBlock(blockId);

        const blockBuilder =
            if (@intFromEnum(blockId) == 0) try self.builder.getBlock(0)
            else createBlockBuilder: {
                const parent = if (blockIr.parent) |parentBlock| getParent: {
                    const blockGenerator = try self.getBlock(parentBlock.id);
                    break :getParent blockGenerator.builder.index;
                } else null;

                break :createBlockBuilder try self.builder.newBlock(parent, switch (blockIr.kind) {
                    .basic => .basic,
                    .with => |handlerSetId| RbcBuilder.BlockBuilder.Kind {
                        .with = (try self.module.getHandlerSet(handlerSetId)).index,
                    },
                });
            };

        var blockGenerator = try Generator.Block.init(null, self, blockIr, blockBuilder);

        try self.block_lookup.put(self.module.root.allocator, blockIr.id, blockGenerator);

        try blockGenerator.generate();

        return blockGenerator;
    }
};
