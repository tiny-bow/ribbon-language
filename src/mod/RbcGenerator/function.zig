const std = @import("std");
const utils = @import("utils");

const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");


const Generator = @import("../RbcGenerator.zig");


pub const Function = struct {
    generator: *Generator,
    module: *Generator.Module,

    ir: *Rir.Function,
    builder: *RbcBuilder.FunctionBuilder,

    block_lookup: std.ArrayHashMapUnmanaged(Rir.BlockId, *Generator.Block, utils.SimpleHashContext, false) = .{},


    pub fn init(module: *Generator.Module, function: *Rir.Function, builder: *RbcBuilder.FunctionBuilder) error{OutOfMemory}! *Function {
        const generator = module.generator;

        const self = try generator.allocator.create(Function);

        self.* = Function {
            .generator = generator,
            .module = module,
            .ir = function,
            .builder = builder,
        };

        return self;
    }

    pub fn generate(self: *Function) !void {
        _ = try self.compileBlock(self.ir.blocks.items[0]);
    }

    pub fn getBlock(self: *Function, blockIr: *Rir.Block) error{InvalidBlock}! *Generator.Block {
        return self.block_lookup.get(blockIr.id)
            orelse error.InvalidBlock;
    }

    pub fn compileBlock(self: *Function, blockIr: *Rir.Block) Generator.Error! *Generator.Block {
        const blockBuilder =
            if (@intFromEnum(blockIr.id) == 0) try self.builder.getBlock(0)
            else createBlockBuilder: {
                const parent = if (blockIr.parent) |parentBlock| getParent: {
                    const blockGenerator = try self.getBlock(parentBlock);
                    break :getParent blockGenerator.builder.index;
                } else null;

                break :createBlockBuilder try self.builder.newBlock(
                    parent,
                    if (blockIr.handler_set) |handlerSetIr| RbcBuilder.BlockBuilder.Kind {
                        .with = (try self.module.getHandlerSet(handlerSetIr)).index,
                    } else .basic,
                );
            };

        var blockGenerator = try Generator.Block.init(null, self, blockIr, blockBuilder);

        try self.block_lookup.put(self.generator.allocator, blockIr.id, blockGenerator);

        try blockGenerator.generate();

        return blockGenerator;
    }
};
