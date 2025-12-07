//! An instruction within an ir basic block.
const Instruction = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// The block that contains this operation.
block: *ir.Block,
/// The type of value produced by this operation, if any.
type: ir.Term,
/// The command code for this operation, ie an Operation or Termination.
command: u8,
/// The number of operands encoded after this Instruction in memory.
num_operands: usize,

/// Optional debug name for the SSA variable binding the result of this operation.
name: ?ir.Name = null,

/// The first operation in the block, or null if this is the first operation.
prev: ?*Instruction = null,
/// The next operation in the block, or null if this is the last operation.
next: ?*Instruction = null,

/// The first use of the SSA variable produced by this instruction, or null if the variable is never used.
first_user: ?*Use = null,

/// A use of an operand by an instruction.
pub const Use = struct {
    /// The operand being used.
    operand: Operand,
    /// Back pointer to the Instruction that uses this operand.
    user: *Instruction,
    /// Next use of the same operand if it is an ssa variable.
    next: ?*Use = null,
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
    variable: *ir.Instruction,
};

/// Defines the action performed by a Termination
pub const Termination = enum(u8) {
    /// represents an unreachable point in the program
    @"unreachable",
    /// returns a value from a function
    @"return",
    /// calls an effect handler;
    /// must provide one successor block for the nominal return; a second successor block is taken from the handlerset for the cancellation
    // TODO: should this just take two successor blocks directly? not sure which would be better
    prompt,
    /// returns a substitute value from an effect handler's binding block
    cancel,
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
    /// logical and
    l_and,
    /// logical or
    l_or,
    /// logical not
    l_not,
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
    /// calls a standard function
    call,
    /// lowers a term to an ssa variable
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

pub fn init(
    block: *ir.Block,
    ty: ir.Term,
    command: anytype,
    name: ?ir.Name,
    ops: []const Operand,
) error{ InvalidInitializer, OutOfMemory }!*Instruction {
    const self = try ir.Instruction.preinit(block, ops.len);
    // TODO: errdefer destroy
    try self.postinit(ty, command, name, ops);
    return self;
}

pub fn preinit(block: *ir.Block, num_ops: usize) error{OutOfMemory}!*Instruction {
    const buf = try block.expression.arena.allocator().alignedAlloc(
        u8,
        .fromByteUnits(@alignOf(Instruction)),
        @sizeOf(Instruction) + @sizeOf(Use) * num_ops,
    );

    const self_ptr: *Instruction = @ptrCast(buf.ptr);
    self_ptr.* = Instruction{
        .block = block,
        .type = undefined,
        .command = undefined,
        .num_operands = num_ops,
        .name = null,
    };

    return self_ptr;
}

pub fn postinit(self: *Instruction, ty: ir.Term, command: anytype, name: ?ir.Name, ops: []const Operand) error{ InvalidInitializer, OutOfMemory }!void {
    const T = @TypeOf(command);

    if (self.num_operands != ops.len) {
        return error.InvalidInitializer;
    }

    comptime {
        // invariant: the Instruction struct must be aligned such that the operands can be placed directly after it
        std.debug.assert(@alignOf(Instruction) >= @alignOf(Use));

        if (T != Operation and T != Termination and T != u8) {
            @compileError("Instruction command must be an Operation, Termination or raw u8");
        }
    }

    self.type = ty;
    self.command = if (comptime T != u8) @intFromEnum(command) else command;
    self.name = name;

    const uses = self.operands();
    for (ops, uses) |op, *use| {
        use.* = Use{
            .operand = op,
            .user = self,
        };

        if (op == .variable) {
            const var_inst = op.variable;
            const var_first_user = var_inst.first_user;
            use.next = var_first_user;
            var_inst.first_user = use;
        }

        // TODO: abstract the rest of this for extensions?
        // TODO: should extensions be able to terminate? would require a different enum construction
        // TODO: are extensions even necessary??? once we add intrinsics, they might not be
        if (op == .block) {
            if (self.isTermination()) {
                try self.block.addSuccessor(op.block);
            }
        }

        if (self.command == @intFromEnum(Termination.prompt)) {
            if (op == .handler_set) {
                try self.block.addSuccessor(op.handler_set.cancellation_point);
            }
        }
    }
}

/// Get a slice of the operands encoded after this Instruction in memory.
pub fn operands(self: *Instruction) []Use {
    // invariant: the Instruction struct must be sized such that the operands can be placed directly after it
    comptime std.debug.assert(common.alignDelta(@sizeOf(Instruction), @alignOf(Use)) == 0);

    return @as([*]Use, @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + @sizeOf(Instruction))))[0..self.num_operands];
}

/// Determine if this Instruction is a Termination.
pub fn isTermination(self: *Instruction) bool {
    return self.command < Operation.start_offset;
}

/// Determine if this Instruction is an Operation.
pub fn isOperation(self: *Instruction) bool {
    return self.command >= Operation.start_offset;
}

/// Determine if this Instruction is an extension op.
pub fn isExtension(self: *Instruction) bool {
    return self.command >= Operation.extension_offset;
}

/// Cast this Instruction's command to a Termination. Returns null if this Instruction is an Operation.
pub fn asTermination(self: *Instruction) ?Termination {
    return if (self.isTermination()) @enumFromInt(self.command) else null;
}

/// Cast this Instruction's command to an Operation. Returns null if this Instruction is a Termination.
pub fn asOperation(self: *Instruction) ?Operation {
    return if (self.isOperation()) @enumFromInt(self.command) else null;
}

/// Cast this Instruction's command to a specific value. Returns false if this Instruction does not match the expected command.
pub fn isCommand(self: *Instruction, command: anytype) bool {
    const expected_command = @intFromEnum(command);
    return self.command == expected_command;
}

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

pub fn rehydrate(
    self: *Instruction,
    sma_instr: *const ir.Sma.Instruction,
    rehydrator: *ir.Sma.Rehydrator,
    index_to_block: []const *ir.Block,
    index_to_instr: []const *ir.Instruction,
) error{ BadEncoding, OutOfMemory }!void {
    const ty = try rehydrator.rehydrateTerm(sma_instr.type);
    const name = try rehydrator.tryRehydrateName(sma_instr.name);

    var ops = common.ArrayList(Operand).empty;
    defer ops.deinit(rehydrator.ctx.allocator);

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
        try ops.append(rehydrator.ctx.allocator, operand);
    }

    self.postinit(ty, sma_instr.command, name, ops.items) catch |err| {
        switch (err) {
            error.InvalidInitializer => @panic("Rehydrated instruction has invalid initializer"),
            error.OutOfMemory => return error.OutOfMemory,
        }
    };
}
