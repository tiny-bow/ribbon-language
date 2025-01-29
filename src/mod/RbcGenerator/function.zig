const Generator = @import("../RbcGenerator.zig");

const function = @This();

const std = @import("std");
const utils = @import("utils");
const Rir = @import("Rir");
const Rbc = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

const BlockMap = std.ArrayHashMapUnmanaged(Rir.BlockId, *Generator.Block, utils.SimpleHashContext, false);
const UpvalueMap = std.ArrayHashMapUnmanaged(Rir.UpvalueId, *Generator.Upvalue, utils.SimpleHashContext, false);

pub const Function = struct {
    generator: *Generator,
    module: *Generator.Module,

    ir: *Rir.Function,
    builder: *RbcBuilder.Function,

    block_map: BlockMap = .{},
    upvalue_map: UpvalueMap = .{},

    pub fn init(module: *Generator.Module, functionIr: *Rir.Function) error{OutOfMemory}!*Function {
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

    pub fn getBlock(self: *Function, blockIr: *Rir.Block) error{InvalidBlock}! *Generator.Block {
        return self.block_map.get(blockIr.id) orelse error.InvalidBlock;
    }

    pub fn getUpvalue(self: *Function, upvalueIr: *Rir.Upvalue) error{InvalidUpvalue}! *Generator.Upvalue {
        return self.upvalue_map.get(upvalueIr.id) orelse error.InvalidUpvalue;
    }

    pub fn setupBlock(self: *Function, blockIr: *Rir.Block, blockBuilder: ?*RbcBuilder.Block) error{TooManyBlocks, OutOfMemory}! *Generator.Block {
        const blockGenerator = try Generator.Block.init(null, self, blockIr, blockBuilder);

        try self.block_map.put(self.generator.allocator, blockIr.id, blockGenerator);

        return blockGenerator;
    }

    pub fn compileBlock(self: *Function, blockIr: *Rir.Block, blockBuilder: ?*RbcBuilder.Block) Generator.Error! *Generator.Block {
        const blockGenerator = try self.setupBlock(blockIr, blockBuilder);

        try blockGenerator.generate();

        return blockGenerator;
    }
};
