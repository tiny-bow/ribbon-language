//! An instruction within an ir basic block.
const Instruction = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.instruction");

const common = @import("common");

const ir = @import("../ir.zig");

/// The block that contains this operation.
block: *ir.Block,
/// The type of value produced by this operation, if any.
type: ir.Term,
/// The command code for this operation, ie an Operation or Termination.
command: u8,

/// Optional debug name for the SSA variable binding the result of this operation.
name: ?ir.Name = null,

/// The first operation in the block, or null if this is the first operation.
prev: ?*Instruction = null,
/// The next operation in the block, or null if this is the last operation.
next: ?*Instruction = null,

/// The first use of the SSA variable produced by this instruction, or null if the variable is never used.
first_user: ?*Use = null,

/// The Use operands for this instruction.
uses: common.ArrayList(*Use) = .empty,

/// An iterator over the instructions in a Block.
pub const Iterator = struct {
    op: ?*Instruction,
    /// Advance the linked list pointer and return the current instruction.
    pub fn next(self: *Iterator) ?*Instruction {
        const current = self.op orelse return null;
        self.op = current.next;
        return current;
    }
};

/// A pair of references to a block and an instruction within it; used for phi nodes.
pub const PhiPair = struct {
    /// The predecessor block.
    block: *ir.Block,
    /// The instruction producing the value from that block.
    value: *ir.Instruction,
};

/// A use of an operand by an instruction.
pub const Use = struct {
    /// The operand being used.
    operand: Operand,
    /// Back pointer to the Instruction that uses this operand.
    user: *Instruction,

    /// Previous use of the same operand if it is an ssa variable.
    prev: ?*Use = null,
    /// Next use of the same operand if it is an ssa variable.
    next: ?*Use = null,

    pub fn unlink(self: *Use) void {
        if (self.prev) |prev| {
            prev.next = self.next;
        } else if (self.operand == .variable) {
            // this was the first use; update the instruction's first_user pointer
            self.operand.variable.first_user = self.next;
        }

        if (self.next) |next| {
            next.prev = self.prev;
        }
    }

    pub fn append(self: *Use, next: *Use) void {
        if (self.next) |nxt| {
            nxt.append(next);
        } else {
            next.prev = self;
            self.next = next;
        }
    }

    pub fn init(user: *Instruction, op: Operand) error{OutOfMemory}!*Use {
        const self = try user.block.expression.module.use_pool.create();
        self.* = Use{
            .operand = op,
            .user = user,
        };

        try self.link();

        return self;
    }

    pub fn link(self: *Use) error{OutOfMemory}!void {
        if (self.operand == .variable) {
            const var_inst = self.operand.variable;
            if (var_inst.first_user) |first_user| {
                first_user.append(self);
            } else {
                var_inst.first_user = self;
            }
        }

        // TODO: abstract the rest of this for extensions?
        // TODO: should extensions be able to terminate? would require a different enum construction
        // TODO: are extensions even necessary??? once we add intrinsics, they might not be
        if (self.operand == .block) {
            if (self.user.isTermination()) {
                try self.user.block.addSuccessor(self.operand.block);
            }
        }

        if (self.user.command == @intFromEnum(Termination.call_esc) or self.user.command == @intFromEnum(Termination.prompt_esc)) {
            if (self.operand == .handler_set) {
                try self.user.block.addSuccessor(self.operand.handler_set.cancellation_point);
            }
        }
    }

    pub fn deinit(self: *Use) void {
        self.user.block.expression.module.use_pool.destroy(self) catch |err| {
            log.err("Failed to destroy use on deinit: {s}\n", .{@errorName(err)});
        };
    }
};

/// An operand to an instruction.
pub const Operand = union(enum) {
    /// A term operand.
    term: ir.Term,
    /// A reference to a data blob.
    blob: *const ir.Blob,
    /// A reference to a basic block.
    block: *ir.Block,
    /// A reference to a global.
    global: *ir.Global,
    /// A reference to a handler set.
    handler_set: *ir.HandlerSet,
    /// A reference to a function.
    function: *ir.Function,
    /// A reference to an instruction producing an SSA variable.
    variable: *Instruction,
};

/// Defines the action performed by a Termination
pub const Termination = enum(u8) {
    /// represents an unreachable point in the program
    @"unreachable",
    /// returns a value from a function
    @"return",
    /// returns a substitute value from an effect handler's binding block
    cancel,
    /// calls an effectful function with observable effects
    /// This has to be a termination because it may not return normally, rather it may cancel via an effect handler within the current handler set.
    /// The instruction must therefore be provided with the successor block for nominal flow, and with the handler set who's cancellation point will be used if the call cancels.
    call_esc,
    /// prompts a local effect handler with observable effects
    /// This has to be a termination because it may not return normally, rather it may cancel via an effect handler within the current handler set.
    /// The instruction must therefore be provided with the successor block for nominal flow, and with the handler set who's cancellation point will be used if the call cancels.
    prompt_esc,
    /// unconditionally branches to a block
    br,
    /// conditionally branches to a block
    br_if,
    /// runtime panic
    panic,
    /// returns an ssa variable as the value of a term
    lift,
};

/// Defines the action performed by an Operation
pub const Operation = enum(u8) {
    /// The offset at which Operations start in the instruction command space.
    /// We start the Operation enum at the end of the Termination enum so they can both be compared generically to u8
    pub const start_offset = calc_offset: {
        const tags = std.meta.tags(Termination);
        break :calc_offset @intFromEnum(tags[tags.len - 1]) + 1;
    };

    /// allocate a value on the stack and return a pointer to it
    stack_alloc = start_offset,
    /// load a value from an address
    load,
    /// store a value to an address
    store,
    /// get an element pointer from a pointer
    get_element_ptr,
    /// get the address of a global
    get_address,
    /// create an ssa variable merging values from predecessor blocks
    phi,
    /// addition
    add,
    /// subtraction
    sub,
    /// multiplication
    mul,
    /// division
    div,
    /// remainder division
    rem,
    /// equality comparison
    eq,
    /// inequality comparison
    ne,
    /// less than comparison
    lt,
    /// less than or equal comparison
    le,
    /// greater than comparison
    gt,
    /// greater than or equal comparison
    ge,
    /// bitwise and
    b_and,
    /// bitwise or
    b_or,
    /// bitwise xor
    b_xor,
    /// bitwise left shift
    b_shl,
    /// bitwise right shift
    b_shr,
    /// bitwise not
    b_not,
    /// direct bitcast between types, changing meaning without changing value
    bitcast,
    /// indirect cast between types, changing value without changing meaning
    convert,
    /// calls a standard function with no observable effects
    call,
    /// calls an effect handler
    prompt,
    /// lowers a term to an ssa variable; can be used to give a value from a symbolic term, or
    /// to instantiate a polymorphic term or function with concrete type arguments
    reify,
    /// pushes a new effect handler set onto the stack
    push_set,
    /// pops the current effect handler set from the stack
    pop_set,
    /// represents a debugger breakpoint
    breakpoint,
    /// user-defined operations, which must be handled by extensions
    _,

    /// The offset at which extension Operations start in the instruction command space.
    pub const extension_offset = @intFromEnum(Operation.breakpoint) + 1;
};

/// Create a new instruction in the given block, pulling memory from the pool and assigning it a fresh identity.
pub fn init(block: *ir.Block, ty: ir.Term, command: anytype, name: ?ir.Name) error{OutOfMemory}!*Instruction {
    const T = @TypeOf(command);

    const self = try block.expression.module.instruction_pool.create();

    self.* = Instruction{
        .block = block,
        .type = ty,
        .command = if (comptime T != u8) @intFromEnum(command) else command,
        .name = name,
    };

    return self;
}

/// Free resources associated with this instruction.
/// * Frees the instruction in the module instruction pool for reuse.
pub fn deinit(self: *Instruction) void {
    for (self.operands()) |use| use.deinit();
    self.uses.deinit(self.block.expression.module.root.allocator);

    self.block.expression.module.instruction_pool.destroy(self) catch |err| {
        log.err("Failed to destroy instruction on deinit: {s}\n", .{@errorName(err)});
    };
}

/// Get a slice of the operands encoded after this Instruction in memory.
pub fn operands(self: anytype) common.ExtrapolatePtr(@TypeOf(self), .{
    .child = *Use,
    .size = .slice,
}) {
    return self.uses.items;
}

/// Append a phi pair to this instruction. Asserts this is a phi node.
pub fn appendPhiPair(self: *Instruction, pair: PhiPair) error{OutOfMemory}!void {
    std.debug.assert(self.isCommand(ir.Instruction.Operation.phi));
    try self.appendOperand(.{ .block = pair.block });
    try self.appendOperand(.{ .variable = pair.value });
}

/// Insert an operand at the given index. Moves any existing operands ahead of it forward.
pub fn insertOperand(self: *Instruction, index: usize, op: Operand) error{OutOfMemory}!void {
    const use = try Use.init(self, op);
    errdefer use.deinit();

    try self.uses.insert(self.block.expression.module.root.allocator, index, use);
}

/// Append an operand to the end of the operand list.
pub fn appendOperand(self: *Instruction, op: Operand) error{OutOfMemory}!void {
    const use = try Use.init(self, op);
    errdefer use.deinit();

    try self.uses.append(self.block.expression.module.root.allocator, use);
}

/// Remove the operand at the given index. Moves any existing operands ahead of it backward.
pub fn removeOperand(self: *Instruction, index: usize) void {
    const use = self.uses.items[index];
    use.unlink();
    _ = self.uses.orderedRemove(index);
}

/// Replace the operand at the given index with a new operand.
pub fn replaceOperand(self: *Instruction, index: usize, new_op: Operand) error{OutOfMemory}!void {
    const use = self.uses.items[index];
    use.unlink();
    use.* = Use{
        .operand = new_op,
        .user = self,
    };

    try use.link();
}

/// Determine if this Instruction is a Termination.
pub fn isTermination(self: *const Instruction) bool {
    return self.command < Operation.start_offset;
}

/// Determine if this Instruction is an Operation.
pub fn isOperation(self: *const Instruction) bool {
    return self.command >= Operation.start_offset;
}

/// Determine if this Instruction is an extension op.
pub fn isExtension(self: *const Instruction) bool {
    return self.command >= Operation.extension_offset;
}

/// Cast this Instruction's command to a Termination. Returns null if this Instruction is an Operation.
pub fn asTermination(self: *const Instruction) ?Termination {
    return if (self.isTermination()) @enumFromInt(self.command) else null;
}

/// Cast this Instruction's command to an Operation. Returns null if this Instruction is a Termination.
pub fn asOperation(self: *const Instruction) ?Operation {
    return if (self.isOperation()) @enumFromInt(self.command) else null;
}

/// Cast this Instruction's command to a specific value. Returns false if this Instruction does not match the expected command.
pub fn isCommand(self: *const Instruction, command: anytype) bool {
    const expected_command = if (comptime @TypeOf(command) != u8) @intFromEnum(command) else command;
    return self.command == expected_command;
}

/// Dehydrate this instruction into an SMA instruction.
pub fn dehydrate(self: *Instruction, dehydrator: *ir.Sma.Dehydrator, out: *common.ArrayList(ir.Sma.Instruction)) error{ BadEncoding, OutOfMemory }!void {
    const type_id = try dehydrator.dehydrateTerm(self.type);
    const name_id = if (self.name) |n| try dehydrator.dehydrateName(n) else ir.Sma.sentinel_index;

    var instr = ir.Sma.Instruction{
        .command = self.command,
        .name = name_id,
        .type = type_id,
    };
    errdefer instr.deinit(dehydrator.sma.allocator);

    for (self.operands()) |use| {
        const operand: ir.Sma.Operand = switch (use.operand) {
            .term => |x| .{ .kind = .term, .value = try dehydrator.dehydrateTerm(x) },
            .blob => |x| .{ .kind = .blob, .value = try dehydrator.dehydrateBlob(x) },
            .block => |x| .{ .kind = .block, .value = dehydrator.block_to_index.get(x).?[0] },
            .global => |x| .{ .kind = .global, .value = try dehydrator.dehydrateGlobal(x) },
            .handler_set => |x| .{ .kind = .handler_set, .value = dehydrator.handler_set_to_index.get(x).? },
            .function => |x| .{ .kind = .function, .value = try dehydrator.dehydrateFunction(x) },
            .variable => |x| .{ .kind = .variable, .value = dehydrator.block_to_index.get(x.block).?[1].get(x).? },
        };
        try instr.operands.append(dehydrator.sma.allocator, operand);
    }

    try out.append(dehydrator.sma.allocator, instr);
}

/// Rehydrate this instruction from an SMA instruction.
pub fn rehydrate(
    self: *Instruction,
    sma_instr: *const ir.Sma.Instruction,
    rehydrator: *ir.Sma.Rehydrator,
    index_to_block: []const *ir.Block,
    index_to_instr: []const *Instruction,
) error{ BadEncoding, OutOfMemory }!void {
    for (sma_instr.operands.items) |sma_op| {
        const operand: Operand = switch (sma_op.kind) {
            .term => .{ .term = try rehydrator.rehydrateTerm(sma_op.value) },
            .blob => .{ .blob = try rehydrator.rehydrateBlob(sma_op.value) },
            .block => .{ .block = index_to_block[sma_op.value] },
            .global => .{ .global = try rehydrator.rehydrateGlobal(sma_op.value) },
            .handler_set => .{ .handler_set = self.block.expression.handler_sets.items[sma_op.value] },
            .function => .{ .function = try rehydrator.rehydrateFunction(sma_op.value) },
            .variable => .{ .variable = index_to_instr[sma_op.value] },
            else => return error.BadEncoding,
        };

        try self.appendOperand(operand);
    }
}

/// Disassemble this instruction to the given writer.
pub fn format(self: *const Instruction, writer: *std.io.Writer) error{WriteFailed}!void {
    if (self.name) |n| {
        try writer.print("{s} = ", .{n.value});
    } else {
        try writer.print("<unnamed{x}> = ", .{@intFromPtr(self)});
    }

    if (self.isTermination()) {
        const term = self.asTermination().?;
        try writer.print("{s}", .{@tagName(term)});
    } else if (self.isExtension()) {
        try writer.print("ext_{x}", .{self.command});
    } else {
        const op = self.asOperation().?;
        try writer.print("{s}", .{@tagName(op)});
    }

    for (self.operands()) |use| {
        try writer.print(" ", .{});
        switch (use.operand) {
            .term => |t| try t.format(writer),
            .blob => |b| try writer.print("<blob_{x}>", .{@intFromPtr(b)}),
            .block => |b| {
                if (b.name) |n| {
                    try writer.print(":{s}", .{n.value});
                } else {
                    try writer.print(":<unnamed{x}>", .{@intFromPtr(b)});
                }
            },
            .global => |g| {
                if (g.name) |n| {
                    try writer.print("%{s}", .{n.value});
                } else {
                    try writer.print("%<unnamed{x}>", .{@intFromPtr(g)});
                }
            },
            .handler_set => |hs| {
                try writer.print("<handler_set{x}>", .{@intFromPtr(hs)});
            },
            .function => |f| {
                if (f.name) |n| {
                    try writer.print("@{s}", .{n.value});
                } else {
                    try writer.print("@<unnamed{x}>", .{@intFromPtr(f)});
                }
            },
            .variable => |v| {
                if (v.name) |n| {
                    try writer.print("{s}", .{n.value});
                } else {
                    try writer.print("<unnamed{x}>", .{@intFromPtr(v)});
                }
            },
        }
    }
}
