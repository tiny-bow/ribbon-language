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
    index_counter: *u32,
    out: *common.ArrayList(ir.Sma.Block),
) error{ BadEncoding, OutOfMemory }!void {
    if (dehydrator.block_to_index.contains(self)) return;

    var instr_map = common.UniqueReprMap(*ir.Instruction, u32).empty;

    const start = index_counter.*;

    var it = self.iterate();
    while (it.next()) |instr| {
        const instr_index: u32 = index_counter.*;
        index_counter.* += 1;

        try instr_map.put(dehydrator.ctx.allocator, instr, instr_index);
    }

    const end = index_counter.*;
    const count = end - start;

    try dehydrator.block_to_index.put(dehydrator.ctx.allocator, self, .{ @intCast(out.items.len), instr_map });

    try out.append(dehydrator.ctx.allocator, ir.Sma.Block{
        .name = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index,
        .start = start,
        .count = count,
    });

    for (self.successors.items) |succ| {
        try succ.allocateDehydratedIndices(dehydrator, index_counter, out);
    }
}

pub fn dehydrateInstructions(
    self: *Block,
    dehydrator: *ir.Sma.Dehydrator,
    out: *common.ArrayList(ir.Sma.Instruction),
) error{ BadEncoding, OutOfMemory }!void {
    var it = self.iterate();
    while (it.next()) |instr| {
        try instr.dehydrate(dehydrator, out);
    }

    for (self.successors.items) |succ| {
        try succ.dehydrateInstructions(dehydrator, out);
    }
}

pub fn addSuccessor(self: *Block, succ: *Block) error{OutOfMemory}!void {
    if (std.mem.indexOfScalar(*Block, self.successors.items, succ) != null) return;

    try self.successors.append(self.expression.module.root.allocator, succ);
    try succ.predecessors.append(self.expression.module.root.allocator, self);
}

pub fn rehydrate(
    self: *Block,
    rehydrator: *ir.Sma.Rehydrator,
    blocks: []const ir.Sma.Block,
    instrs: []const ir.Sma.Instruction,
    index_to_block: []const *ir.Block,
    index_to_instr: []const *ir.Instruction,
) error{ BadEncoding, OutOfMemory }!void {
    const index = std.mem.indexOfScalar(*ir.Block, index_to_block, self).?;
    const sma_block = &blocks[index];

    // name was already rehydrated during init

    for (sma_block.start..sma_block.start + sma_block.count) |instr_index| {
        const instr = index_to_instr[instr_index];
        const sma_instr = &instrs[instr_index];

        try instr.rehydrate(sma_instr, rehydrator, index_to_block, index_to_instr);

        if (self.first_op == null) {
            self.first_op = instr;
            self.last_op = instr;
        } else {
            instr.prev = self.last_op;
            self.last_op.?.next = instr;
            self.last_op = instr;
        }
    }

    for (self.successors.items) |succ| {
        try succ.rehydrate(rehydrator, blocks, instrs, index_to_block, index_to_instr);
    }
}
