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

/// Initialize a new block within the given expression.
pub fn init(expression: *ir.Expression, name: ?ir.Name) error{OutOfMemory}!*Block {
    const self = try expression.module.block_pool.create();
    self.* = Block{
        .name = name,
        .expression = expression,
    };
    return self;
}

/// Free resources associated with this block.
/// * Frees the block in the module block pool for reuse.
pub fn deinit(self: *Block) void {
    var it = self.iterate();
    while (it.next()) |instr| {
        instr.deinit();
    }

    self.predecessors.deinit(self.expression.module.root.allocator);
    self.successors.deinit(self.expression.module.root.allocator);
    self.expression.module.block_pool.destroy(self) catch |err| {
        std.debug.print("Failed to destroy block on deinit: {s}\n", .{@errorName(err)});
    };
}

/// An iterator over the Blocks in an ir Expression.
pub const Iterator = struct {
    allocator: std.mem.Allocator,
    index: usize = 0,
    queue: std.ArrayList(*Block) = .empty,
    visited: common.UniqueReprSet(*Block) = .empty,

    /// Create a new iterator starting at the given entry block.
    /// * Note that this requires allocation, as it uses a queue and a visited set.
    pub fn init(allocator: std.mem.Allocator, entry: *Block) error{OutOfMemory}!Iterator {
        var it = Iterator{
            .allocator = allocator,
        };

        try it.queue.append(allocator, entry);
        try it.visited.put(allocator, entry, {});

        return it;
    }

    /// Free resources associated with this iterator.
    pub fn deinit(self: *Iterator) void {
        self.queue.deinit(self.allocator);
        self.visited.deinit(self.allocator);
    }

    /// Get the next block in the iteration, or null if the iteration is complete.
    pub fn next(self: *Iterator) error{OutOfMemory}!?*Block {
        if (self.index >= self.queue.items.len) {
            return null;
        }

        const current = self.queue.items[self.index];
        self.index += 1;

        try self.visited.put(self.allocator, current, {});

        for (current.successors.items) |succ| {
            if (!self.visited.contains(succ)) {
                try self.queue.append(self.allocator, succ);
            }
        }

        return current;
    }
};

/// Get an iterator over the instructions in this block.
pub fn iterate(self: *Block) ir.Instruction.Iterator {
    return ir.Instruction.Iterator{ .op = self.first_op };
}

/// Add a successor block to this block, updating both sides of the edge.
/// * If the successor is already present, this is a no-op.
/// * This is generally expected to be called in builder apis, not directly by the user.
pub fn addSuccessor(self: *Block, succ: *Block) error{OutOfMemory}!void {
    if (std.mem.indexOfScalar(*Block, self.successors.items, succ) == null) {
        try self.successors.append(self.expression.module.root.allocator, succ);
    }

    if (std.mem.indexOfScalar(*Block, succ.predecessors.items, self) == null) {
        try succ.predecessors.append(self.expression.module.root.allocator, self);
    }
}

pub fn dehydrate(
    self: *Block,
    dehydrator: *ir.Sma.Dehydrator,
    out: *common.ArrayList(ir.Sma.Instruction),
) error{ BadEncoding, OutOfMemory }!void {
    var it = self.iterate();
    while (it.next()) |instr| {
        try instr.dehydrate(dehydrator, out);
    }

    for (self.successors.items) |succ| {
        try succ.dehydrate(dehydrator, out);
    }
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
