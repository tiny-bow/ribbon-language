//! A basic block within an ir function's control flow graph.
const Block = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// The module this block belongs to.
module: *ir.Module,

/// The arena allocator for instructions in this block.
arena: std.mem.Allocator,
/// Globally unique id for this block within its function, used for hashing and debugging.
id: Block.Id,

/// Optional debug name for this block.
name: ?ir.Name = null,

/// The function this block belongs to, if any.
function: ?*ir.Function = null,

/// The first operation in this block, or null if the block is empty.
first_op: ?*ir.Instruction = null,
/// The last operation in this block, or null if the block is empty.
last_op: ?*ir.Instruction = null,

/// Predecessor blocks in the control flow graph.
predecessors: common.ArrayList(*Block) = .empty,
/// Successor blocks in the control flow graph.
successors: common.ArrayList(*Block) = .empty,

/// Cached CBR for this block.
cached_cbr: ?ir.Cbr = null,

/// Source for instruction ids within this block.
fresh_instruction_id: std.meta.Tag(ir.Instruction.Id) = 0,

/// Identifier for a basic block within a function.
pub const Id = enum(u32) { _ };

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

pub fn init(module: *ir.Module, function: ?*ir.Function, name: ?ir.Name) error{OutOfMemory}!*Block {
    const self = try module.block_pool.create();
    self.* = Block{
        .module = module,
        .id = module.generateBlockId(),
        .name = name,
        .arena = if (function) |f| f.arena.allocator() else module.root.arena.allocator(),
        .function = function,
    };
    return self;
}

pub fn deinit(self: *Block) void {
    self.predecessors.deinit(self.module.root.allocator);
    self.successors.deinit(self.module.root.allocator);
}

/// Get an iterator over the instructions in this block.
pub fn iterate(self: *Block) Iterator {
    return Iterator{ .op = self.first_op };
}

pub fn generateInstructionId(self: *Block) ir.Instruction.Id {
    const id = self.fresh_instruction_id;
    self.fresh_instruction_id += 1;
    return @enumFromInt(id);
}

/// Get the CBR for this block.
pub fn getCbr(self: *Block) ir.Cbr {
    if (self.cached_cbr) |cached| {
        return cached;
    }

    var visited = common.UniqueReprSet(*Block).empty;
    defer visited.deinit(self.module.root.allocator);

    return self.getCbrRecurse(&visited) catch |err| {
        std.debug.panic("Failed to compute CBR for Block: {}\n", .{err});
    };
}

/// Recursive helper for computing the CBR of this block, tracking visited blocks to avoid cycles.
fn getCbrRecurse(self: *Block, visited: *common.UniqueReprSet(*Block)) error{OutOfMemory}!ir.Cbr {
    if (self.cached_cbr) |cached| {
        return cached;
    }

    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Block");

    // We must include the module guid to differentiate between internal and external references
    hasher.update("module.guid:");
    hasher.update(self.module.guid);

    hasher.update("id:");
    hasher.update(self.id);

    if (visited.contains(self)) {
        return hasher.final();
    }

    try visited.put(self.module.root.allocator, self, {});

    // name has no effect on canonical identity

    {
        var op_it = self.iterate();
        var i: usize = 0;

        hasher.update("operations:");
        while (op_it.next()) |op| : (i += 1) {
            hasher.update("op.index:");
            hasher.update(i);

            hasher.update("op.value:");
            hasher.update(op.getCbr());
        }
    }

    hasher.update("predecessors:");
    for (self.predecessors.items, 0..) |pred, i| {
        hasher.update("pred.index:");
        hasher.update(i);

        hasher.update("pred.value:");
        hasher.update(pred.getCbrRecurse(visited));
    }

    hasher.update("successors:");
    for (self.successors.items, 0..) |succ, i| {
        hasher.update("succ.index:");
        hasher.update(i);

        hasher.update("succ.value:");
        hasher.update(succ.getCbrRecurse(visited));
    }

    const buf = hasher.final();
    self.cached_cbr = buf;
    return buf;
}
