//! A helper for constructing IR instructions and appending them to basic blocks.
//! This builder is "dumb" and "stateless" regarding type logic; it relies on the
//! caller to provide correct types for operations that require them (like load or call).

const Builder = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.builder");

const common = @import("common");

const ir = @import("../ir.zig");

/// The global context, used for interning types and data.
context: *ir.Context,

/// The block where instructions are currently being inserted.
block: ?*ir.Block = null,

/// The instruction after which new instructions will be inserted.
/// If null, instructions are inserted at the beginning of the block.
insert_point: ?*ir.Instruction = null,

/// Buffer for temporary intermediates when martialing operands for instruction creation.
temp_operands: common.ArrayList(ir.Instruction.Operand) = .empty,

/// Api organization primitive. Groups instruction creation methods.
instr: InstructionEncoder = .{},

/// Initialize a new ir expression builder for the given context.
pub fn init(context: *ir.Context) Builder {
    return .{
        .context = context,
    };
}

/// Free resources associated with this builder.
pub fn deinit(self: *Builder) void {
    self.temp_operands.deinit(self.context.allocator);
}

/// Sets the insertion point to the end of the specified block.
pub fn positionAtEnd(self: *Builder, block: *ir.Block) void {
    self.block = block;
    self.insert_point = block.last_op;
}

/// Sets the insertion point to immediately before the specified instruction.
pub fn positionBefore(self: *Builder, inst: *ir.Instruction) void {
    self.block = inst.block;
    self.insert_point = inst.prev;
}

/// Links a newly created instruction into the current block at the insert_point.
pub fn insert(self: *Builder, inst: *ir.Instruction) void {
    const block = self.block orelse @panic("Builder has no insert point");

    // Update linkage
    if (self.insert_point) |prev_inst| {
        // Inserting after prev_inst
        inst.prev = prev_inst;
        inst.next = prev_inst.next;
        prev_inst.next = inst;

        if (inst.next) |next_inst| {
            next_inst.prev = inst;
        } else {
            // We are at the end of the block
            block.last_op = inst;
        }
    } else {
        // Inserting at the start of the block (or empty block)
        inst.prev = null;
        inst.next = block.first_op;

        if (block.first_op) |first| {
            first.prev = inst;
        } else {
            block.last_op = inst;
        }
        block.first_op = inst;
    }

    // Advance the insert point so the next instruction follows this one
    self.insert_point = inst;
}

/// Generic method to construct and insert an instruction.
/// Wraps ir.Instruction.init.
pub fn createInstruction(
    self: *Builder,
    command: anytype,
    ty: ir.Term,
    operands: []const ir.Instruction.Operand,
    name: ?ir.Name,
) !*ir.Instruction {
    const block = self.block orelse return error.NoInsertBlock;

    // TODO: the current initialization pattern in Instruction
    // is a bit awkard, since we are going to immediately redo some of the work.
    // A better separation of concerns probably sees the Builder handle this directly.

    // ir.Instruction.init handles memory allocation via the block's arena
    // and automatically adds block successors if operands are block.
    const inst = try ir.Instruction.init(block, ty, command, name, operands);

    self.insert(inst);
    return inst;
}

pub fn createUnaryOp(
    self: *Builder,
    op: ir.Instruction.Operation,
    rhs: *ir.Instruction,
    name: ?ir.Name,
) !*ir.Instruction {
    return self.createInstruction(
        op,
        rhs.type,
        &.{.{ .variable = rhs }},
        name,
    );
}

pub fn createBinaryOp(
    self: *Builder,
    op: ir.Instruction.Operation,
    lhs: *ir.Instruction,
    rhs: *ir.Instruction,
    name: ?ir.Name,
) !*ir.Instruction {
    return self.createInstruction(
        op,
        lhs.type,
        &.{ .{ .variable = lhs }, .{ .variable = rhs } },
        name,
    );
}

pub fn createComparisonOp(
    self: *Builder,
    op: ir.Instruction.Operation,
    lhs: *ir.Instruction,
    rhs: *ir.Instruction,
    name: ?ir.Name,
) !*ir.Instruction {
    const bool_ty = try self.context.getOrCreateSharedTerm(ir.terms.BoolType{});
    return self.createInstruction(
        op,
        bool_ty,
        &.{ .{ .variable = lhs }, .{ .variable = rhs } },
        name,
    );
}

/// Api organization primitive. Groups instruction creation methods.
pub const InstructionEncoder = struct {
    //
    // --- Terminators ---
    //

    fn getBuilder(self: *InstructionEncoder) *Builder {
        return @alignCast(@fieldParentPtr("instr", self));
    }

    pub fn @"unreachable"(self: *InstructionEncoder) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Termination.@"unreachable", void_ty, &.{}, null);
    }

    pub fn @"return"(self: *InstructionEncoder, value: ?*ir.Instruction) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        if (value) |v| {
            return builder.createInstruction(ir.Instruction.Termination.@"return", void_ty, &.{.{ .variable = v }}, null);
        } else {
            return builder.createInstruction(ir.Instruction.Termination.@"return", void_ty, &.{}, null);
        }
    }

    pub fn br(self: *InstructionEncoder, dest: *ir.Block) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Termination.br, void_ty, &.{.{ .block = dest }}, null);
    }

    pub fn br_if(
        self: *InstructionEncoder,
        condition: *ir.Instruction,
        then_block: *ir.Block,
        else_block: *ir.Block,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(
            ir.Instruction.Termination.br_if,
            void_ty,
            &.{ .{ .variable = condition }, .{ .block = then_block }, .{ .block = else_block } },
            null,
        );
    }

    pub fn panic(self: *InstructionEncoder) !*ir.Instruction {
        const builder = self.getBuilder();
        // TODO: Add operand for panic message/code if supported later
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Termination.panic, void_ty, &.{}, null);
    }

    // TODO: prompt and cancel instructions
    // TODO: lift instruction

    //
    // --- Operations ---
    //

    pub fn stack_alloc(self: *InstructionEncoder, result_type: ir.Term, alloc_type: ir.Term, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.stack_alloc,
            result_type,
            &.{.{ .term = alloc_type }},
            name,
        );
    }

    pub fn load(self: *InstructionEncoder, result_type: ir.Term, ptr: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.load,
            result_type,
            &.{.{ .variable = ptr }},
            name,
        );
    }

    pub fn store(self: *InstructionEncoder, val: *ir.Instruction, ptr: *ir.Instruction) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(
            ir.Instruction.Operation.store,
            void_ty,
            &.{ .{ .variable = val }, .{ .variable = ptr } },
            null,
        );
    }

    pub fn get_element_ptr(
        self: *InstructionEncoder,
        result_type: ir.Term,
        ptr: *ir.Instruction,
        index: *ir.Instruction,
        name: ?ir.Name,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.get_element_ptr,
            result_type, // Explicitly provided; builder does not calculate struct offsets
            &.{ .{ .variable = ptr }, .{ .variable = index } },
            name,
        );
    }

    pub fn get_address(self: *InstructionEncoder, result_type: ir.Term, global: *ir.Global, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.get_address,
            result_type,
            &.{.{ .global = global }},
            name,
        );
    }

    pub fn phi(self: *InstructionEncoder, result_type: ir.Term, name: ?ir.Name, joins: []const *ir.Instruction) !*ir.Instruction {
        // TODO: most ir builder apis would allow adding operands after the phi node is created. This may in fact be necessary for certain flow patterns.
        // previously, this wasn't possible since instruction operand lists are immutable after creation.
        // since we now use a pool + arraylist pattern like higher level items, instead, it should be possible to mutate the operand list after creation.
        // however, this requires some care to update all the links correctly.
        const builder = self.getBuilder();
        builder.temp_operands.clearRetainingCapacity();
        for (joins) |join| {
            try builder.temp_operands.append(builder.context.allocator, .{ .variable = join });
        }
        return builder.createInstruction(ir.Instruction.Operation.phi, result_type, builder.temp_operands.items, name);
    }

    //
    // --- Arithmetic & Logic ---
    //

    pub fn add(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.add, lhs, rhs, name);
    }
    pub fn sub(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.sub, lhs, rhs, name);
    }
    pub fn mul(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.mul, lhs, rhs, name);
    }
    pub fn div(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.div, lhs, rhs, name);
    }
    pub fn rem(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.rem, lhs, rhs, name);
    }

    pub fn eq(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.eq, lhs, rhs, name);
    }
    pub fn ne(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.ne, lhs, rhs, name);
    }
    pub fn lt(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.lt, lhs, rhs, name);
    }
    pub fn le(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.le, lhs, rhs, name);
    }
    pub fn gt(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.gt, lhs, rhs, name);
    }
    pub fn ge(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.ge, lhs, rhs, name);
    }

    //
    // --- Bitwise & Logical ---
    //

    // TODO: do these logical ops even make sense given we want explicit control flow? seems like short-circuiting is the responsibility of the frontend.

    pub fn l_and(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.l_and, lhs, rhs, name);
    }

    pub fn l_or(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.l_or, lhs, rhs, name);
    }

    pub fn l_not(self: *InstructionEncoder, val: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createUnaryOp(ir.Instruction.Operation.l_not, val, name);
    }

    pub fn b_and(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.b_and, lhs, rhs, name);
    }

    pub fn b_or(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.b_or, lhs, rhs, name);
    }

    pub fn b_xor(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.b_xor, lhs, rhs, name);
    }

    pub fn b_not(self: *InstructionEncoder, val: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createUnaryOp(ir.Instruction.Operation.b_not, val, name);
    }

    //
    // --- Casts ---
    //

    pub fn bitcast(self: *InstructionEncoder, result_type: ir.Term, val: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(ir.Instruction.Operation.bitcast, result_type, &.{.{ .variable = val }}, name);
    }

    pub fn convert(self: *InstructionEncoder, result_type: ir.Term, val: *ir.Instruction, name: ?ir.Name) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(ir.Instruction.Operation.convert, result_type, &.{.{ .variable = val }}, name);
    }

    // TODO: reify and instantiate instructions

    //
    // --- Control & Effects ---
    //

    pub fn call(
        self: *InstructionEncoder,
        result_type: ir.Term,
        callee: *ir.Instruction,
        args: []const *ir.Instruction,
        name: ?ir.Name,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        builder.temp_operands.clearRetainingCapacity();

        try builder.temp_operands.append(builder.context.allocator, .{ .variable = callee });

        for (args) |arg| {
            try builder.temp_operands.append(builder.context.allocator, .{ .variable = arg });
        }

        return builder.createInstruction(ir.Instruction.Operation.call, result_type, builder.temp_operands.items, name);
    }

    pub fn push_set(self: *InstructionEncoder, handler_set: *ir.HandlerSet) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Operation.push_set, void_ty, &.{.{ .handler_set = handler_set }}, null);
    }

    pub fn pop_set(self: *InstructionEncoder) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Operation.pop_set, void_ty, &.{}, null);
    }

    pub fn breakpoint(self: *InstructionEncoder) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Operation.breakpoint, void_ty, &.{}, null);
    }
};
