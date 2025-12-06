//! A basic block within an ir function's control flow graph.
const Block = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// The expression this block belongs to, if any.
expression: *ir.Expression,

/// Optional debug name for this block.
name: ?ir.Name = null,

/// The first operation in this block, or null if the block is empty.
first_op: ?*ir.Instruction = null,
/// The last operation in this block, or null if the block is empty.
last_op: ?*ir.Instruction = null,

/// Predecessor blocks in the control flow graph.
predecessors: common.ArrayList(*Block) = .empty,
/// Successor blocks in the control flow graph.
successors: common.ArrayList(*Block) = .empty,

/// An iterator over the instructions in a Block.
pub const Iterator = struct {
    op: ?*ir.Instruction,
    /// Advance the linked list pointer and return the current instruction.
    pub fn next(self: *Iterator) ?*ir.Instruction {
        const current = self.op orelse return null;
        self.op = current.next;
        return current;
    }
};

pub fn init(expression: *ir.Expression, name: ?ir.Name) error{OutOfMemory}!*Block {
    const self = try expression.module.block_pool.create();
    self.* = Block{
        .name = name,
        .expression = expression,
    };
    return self;
}

pub fn deinit(self: *Block) void {
    self.predecessors.deinit(self.expression.module.root.allocator);
    self.successors.deinit(self.expression.module.root.allocator);
}

/// Get an iterator over the instructions in this block.
pub fn iterate(self: *Block) Iterator {
    return Iterator{ .op = self.first_op };
}

pub fn allocateDehydratedIndices(
    self: *Block,
    dehydrator: *ir.Sma.Dehydrator,
    handler_sets: *common.ArrayList(*ir.HandlerSet),
    out: *common.ArrayList(ir.Sma.Block),
) error{ BadEncoding, OutOfMemory }!void {
    if (dehydrator.block_to_index.contains(self)) return;

    var instr_map = common.UniqueReprMap(*ir.Instruction, u32).empty;

    var it = self.iterate();
    while (it.next()) |instr| {
        const instr_index: u32 = @intCast(instr_map.count());
        try instr_map.put(dehydrator.ctx.allocator, instr, instr_index);
        for (instr.operands()) |use| {
            if (use.operand == .handler_set) {
                try handler_sets.append(dehydrator.ctx.allocator, use.operand.handler_set);
            }
        }
    }

    try dehydrator.block_to_index.put(dehydrator.ctx.allocator, self, .{ @intCast(out.items.len), instr_map });

    _ = try out.addOne(dehydrator.ctx.allocator); // unstable pointer

    for (self.successors.items) |succ| {
        try succ.allocateDehydratedIndices(dehydrator, handler_sets, out);
    }
}

pub fn dehydrateInstructions(
    self: *Block,
    dehydrator: *ir.Sma.Dehydrator,
    out: *common.ArrayList(ir.Sma.Block),
) error{ BadEncoding, OutOfMemory }!void {
    const block_entry = dehydrator.block_to_index.getPtr(self).?;
    const block_index = block_entry[0];
    var out_block = &out.items[block_index];

    var it = self.iterate();
    while (it.next()) |instr| {
        try instr.dehydrate(dehydrator, &out_block.instructions);
    }

    for (self.successors.items) |succ| {
        try succ.dehydrateInstructions(dehydrator, out);
    }
}
