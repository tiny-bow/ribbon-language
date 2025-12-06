//! An instruction within an ir basic block.
const Instruction = @This();

const std = @import("std");
const common = @import("common");

const ir = @import("../ir.zig");

/// The block that contains this operation.
block: *ir.Block,
/// Function-unique id for this instruction, used for hashing and debugging.
id: Instruction.Id,
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

/// Identifier for an instruction within a block.
pub const Id = enum(u32) { _ };

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
    /// A reference to a function.
    function: *ir.Function,
    /// A reference to an instruction producing an SSA variable.
    variable: *ir.Instruction,

    /// Get the CBR for this operand.
    pub fn getCbr(self: Operand) ir.Cbr {
        var hasher = ir.Cbr.Hasher.init();
        hasher.update("Operand");

        switch (self) {
            .term => |term| {
                hasher.update("term:");
                hasher.update(term.getCbr());
            },
            .blob => |blob| {
                hasher.update("blob:");
                hasher.update(blob.id);
            },
            .block => |block| {
                hasher.update("block:");
                hasher.update(block.id);
            },
            .function => |function| {
                // We must include the module guid to differentiate between internal and external references
                hasher.update("function.module.guid:");
                hasher.update(function.module.guid);
                hasher.update("function.id:");
                hasher.update(function.id);
            },
            .variable => |variable| {
                // We must include the block id to differentiate between variables with the same id in different blocks
                hasher.update("variable.block.id:");
                hasher.update(variable.block.id);
                hasher.update("variable.id:");
                hasher.update(variable.id);
            },
        }

        return hasher.final();
    }
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

/// A pointer to the head of the singly-linked list of all Uses that refer to this Instruction.
pub fn init(block: *ir.Block, ty: ir.Term, command: anytype, name: ?ir.Name, ops: []const Operand) error{OutOfMemory}!*Instruction {
    comptime {
        // invariant: the Instruction struct must be aligned such that the operands can be placed directly after it
        std.debug.assert(@alignOf(Instruction) >= @alignOf(Use));

        const T = @TypeOf(command);
        if (T != Operation and T != Termination) {
            @compileError("Instruction command must be an Operation or Termination");
        }
    }

    const buf = try block.arena.alignedAlloc(
        u8,
        .fromByteUnits(@alignOf(Instruction)),
        @sizeOf(Instruction) + @sizeOf(Use) * ops.len,
    );

    const self: *Instruction = @ptrCast(buf.ptr);
    const uses = self.operands();
    self.* = Instruction{
        .block = block,
        .id = block.module.generateInstruction.Id(),
        .type = ty,
        .command = @intFromEnum(command),
        .num_operands = ops.len,
        .name = name,
    };

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
    }

    return self;
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

/// Get the CBR for this instruction.
pub fn getCbr(self: *Instruction) ir.Cbr {
    var hasher = ir.Cbr.Hasher.init();
    hasher.update("Instruction");

    hasher.update("id:");
    hasher.update(self.id);

    hasher.update("name:");
    if (self.name) |name| {
        hasher.update(name.value);
    } else {
        hasher.update("[null]");
    }

    hasher.update("type:");
    hasher.update(self.type.getCbr());

    hasher.update("command:");
    hasher.update(self.command);

    for (self.operands(), 0..) |use, i| {
        hasher.update("operand.index:");
        hasher.update(i);

        hasher.update("operand.value:");
        hasher.update(use.operand.getCbr());
    }

    return hasher.final();
}
