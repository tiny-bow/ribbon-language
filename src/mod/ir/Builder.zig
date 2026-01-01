//! A helper for constructing IR instructions and appending them to basic blocks.
//! This builder is "dumb" and "stateless" regarding type logic; it relies on the
//! caller to provide correct types for operations that require them (like load or call).

const Builder = @This();

const std = @import("std");
const log = std.log.scoped(.@"ir.builder");

const common = @import("common");
const analysis = @import("analysis");

const ir = @import("../ir.zig");

/// The global context, used for interning types and data.
context: *ir.Context,

/// The block where instructions are currently being inserted.
block: ?*ir.Block = null,

/// The instruction after which new instructions will be inserted.
/// If null, instructions are inserted at the beginning of the block.
insert_point: ?*ir.Instruction = null,

/// Api organization primitive. Groups instruction creation methods.
instr: InstructionEncoder = .{},

/// Initialize a new ir expression builder for the given context.
pub fn init(context: *ir.Context) Builder {
    return .{
        .context = context,
    };
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
    src: ?analysis.Source,
) !*ir.Instruction {
    const block = self.block orelse return error.NoInsertBlock;

    const inst = try ir.Instruction.init(block, ty, command, name, src);

    for (operands) |operand| {
        try inst.appendOperand(operand);
    }

    self.insert(inst);
    return inst;
}

pub fn createUnaryOp(
    self: *Builder,
    op: ir.Instruction.Operation,
    rhs: *ir.Instruction,
    name: ?ir.Name,
    src: ?analysis.Source,
) !*ir.Instruction {
    return self.createInstruction(
        op,
        rhs.type,
        &.{.{ .variable = rhs }},
        name,
        src,
    );
}

pub fn createBinaryOp(
    self: *Builder,
    op: ir.Instruction.Operation,
    lhs: *ir.Instruction,
    rhs: *ir.Instruction,
    name: ?ir.Name,
    src: ?analysis.Source,
) !*ir.Instruction {
    return self.createInstruction(
        op,
        lhs.type,
        &.{ .{ .variable = lhs }, .{ .variable = rhs } },
        name,
        src,
    );
}

pub fn createComparisonOp(
    self: *Builder,
    op: ir.Instruction.Operation,
    lhs: *ir.Instruction,
    rhs: *ir.Instruction,
    name: ?ir.Name,
    src: ?analysis.Source,
) !*ir.Instruction {
    const bool_ty = try self.context.getOrCreateSharedTerm(ir.terms.BoolType{});
    return self.createInstruction(
        op,
        bool_ty,
        &.{ .{ .variable = lhs }, .{ .variable = rhs } },
        name,
        src,
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

    pub fn @"unreachable"(self: *InstructionEncoder, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const no_ret_ty = try builder.context.getOrCreateSharedTerm(ir.terms.NoReturnType{});
        return builder.createInstruction(ir.Instruction.Termination.@"unreachable", no_ret_ty, &.{}, null, src);
    }

    pub fn @"return"(self: *InstructionEncoder, value: ?*ir.Instruction, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const no_ret_ty = try builder.context.getOrCreateSharedTerm(ir.terms.NoReturnType{});
        if (value) |v| {
            return builder.createInstruction(ir.Instruction.Termination.@"return", no_ret_ty, &.{.{ .variable = v }}, null, src);
        } else {
            return builder.createInstruction(ir.Instruction.Termination.@"return", no_ret_ty, &.{}, null, src);
        }
    }

    pub fn cancel(self: *InstructionEncoder, value: ?*ir.Instruction, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const no_ret_ty = try builder.context.getOrCreateSharedTerm(ir.terms.NoReturnType{});
        if (value) |v| {
            return builder.createInstruction(ir.Instruction.Termination.cancel, no_ret_ty, &.{.{ .variable = v }}, null, src);
        } else {
            return builder.createInstruction(ir.Instruction.Termination.cancel, no_ret_ty, &.{}, null, src);
        }
    }

    pub fn br(self: *InstructionEncoder, dest: *ir.Block, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Termination.br, void_ty, &.{.{ .block = dest }}, null, src);
    }

    pub fn br_if(
        self: *InstructionEncoder,
        condition: *ir.Instruction,
        then_block: *ir.Block,
        else_block: *ir.Block,
        src: ?analysis.Source,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(
            ir.Instruction.Termination.br_if,
            void_ty,
            &.{ .{ .variable = condition }, .{ .block = then_block }, .{ .block = else_block } },
            null,
            src,
        );
    }

    pub fn panic(self: *InstructionEncoder, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        // TODO: Add operand for panic message/code if supported later
        const no_ret_ty = try builder.context.getOrCreateSharedTerm(ir.terms.NoReturnType{});
        return builder.createInstruction(ir.Instruction.Termination.panic, no_ret_ty, &.{}, null, src);
    }

    pub fn call_esc(
        self: *InstructionEncoder,
        handler_set: *ir.HandlerSet,
        return_ty: ir.Term,
        callee: *ir.Instruction,
        args: []const *ir.Instruction,
        name: ?ir.Name,
        src: ?analysis.Source,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        const out = try builder.createInstruction(
            ir.Instruction.Termination.call_esc,
            return_ty,
            &.{
                .{ .handler_set = handler_set },
                .{ .term = return_ty },
                .{ .variable = callee },
            },
            name,
            src,
        );

        for (args) |arg| {
            try out.appendOperand(.{ .variable = arg });
        }

        return out;
    }

    pub fn prompt_esc(
        self: *InstructionEncoder,
        handler_set: *ir.HandlerSet,
        return_ty: ir.Term,
        effect_ty: ir.Term,
        args: []const *ir.Instruction,
        name: ?ir.Name,
        src: ?analysis.Source,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        const out = try builder.createInstruction(
            ir.Instruction.Termination.prompt_esc,
            return_ty,
            &.{
                .{ .handler_set = handler_set },
                .{ .term = return_ty },
                .{ .term = effect_ty },
            },
            name,
            src,
        );

        for (args) |arg| {
            try out.appendOperand(.{ .variable = arg });
        }

        return out;
    }

    pub fn lift(self: *InstructionEncoder, value: ?*ir.Instruction, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();

        const no_ret_ty = try builder.context.getOrCreateSharedTerm(ir.terms.NoReturnType{});

        return builder.createInstruction(ir.Instruction.Termination.lift, no_ret_ty, if (value) |v| &.{.{ .variable = v }} else &.{}, null, src);
    }

    //
    // --- Operations ---
    //

    pub fn stack_alloc(self: *InstructionEncoder, result_type: ir.Term, alloc_type: ir.Term, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.stack_alloc,
            result_type,
            &.{.{ .term = alloc_type }},
            name,
            src,
        );
    }

    pub fn load(self: *InstructionEncoder, result_type: ir.Term, ptr: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.load,
            result_type,
            &.{.{ .variable = ptr }},
            name,
            src,
        );
    }

    pub fn store(self: *InstructionEncoder, val: *ir.Instruction, ptr: *ir.Instruction, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(
            ir.Instruction.Operation.store,
            void_ty,
            &.{ .{ .variable = val }, .{ .variable = ptr } },
            null,
            src,
        );
    }

    pub fn get_element_ptr(
        self: *InstructionEncoder,
        result_type: ir.Term,
        ptr: *ir.Instruction,
        index: *ir.Instruction,
        name: ?ir.Name,
        src: ?analysis.Source,
    ) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.get_element_ptr,
            result_type, // Explicitly provided; builder does not calculate struct offsets
            &.{ .{ .variable = ptr }, .{ .variable = index } },
            name,
            src,
        );
    }

    pub fn get_address(self: *InstructionEncoder, result_type: ir.Term, global: *ir.Global, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(
            ir.Instruction.Operation.get_address,
            result_type,
            &.{.{ .global = global }},
            name,
            src,
        );
    }

    pub fn phi(self: *InstructionEncoder, result_type: ir.Term, name: ?ir.Name, src: ?analysis.Source, pairs: []const ir.Instruction.PhiPair) !*ir.Instruction {
        const builder = self.getBuilder();
        const out = try builder.createInstruction(ir.Instruction.Operation.phi, result_type, &.{}, name, src);

        for (pairs) |pair| {
            try out.appendPhiPair(pair);
        }

        return out;
    }

    //
    // --- Arithmetic & Logic ---
    //

    pub fn add(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.add, lhs, rhs, name, src);
    }
    pub fn sub(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.sub, lhs, rhs, name, src);
    }
    pub fn mul(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.mul, lhs, rhs, name, src);
    }
    pub fn div(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.div, lhs, rhs, name, src);
    }
    pub fn rem(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.rem, lhs, rhs, name, src);
    }

    pub fn eq(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.eq, lhs, rhs, name, src);
    }
    pub fn ne(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.ne, lhs, rhs, name, src);
    }
    pub fn lt(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.lt, lhs, rhs, name, src);
    }
    pub fn le(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.le, lhs, rhs, name, src);
    }
    pub fn gt(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.gt, lhs, rhs, name, src);
    }
    pub fn ge(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createComparisonOp(.ge, lhs, rhs, name, src);
    }

    //
    // --- Bitwise & Logical ---
    //

    pub fn b_and(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.b_and, lhs, rhs, name, src);
    }

    pub fn b_or(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.b_or, lhs, rhs, name, src);
    }

    pub fn b_xor(self: *InstructionEncoder, lhs: *ir.Instruction, rhs: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createBinaryOp(.b_xor, lhs, rhs, name, src);
    }

    pub fn b_not(self: *InstructionEncoder, val: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createUnaryOp(ir.Instruction.Operation.b_not, val, name, src);
    }

    //
    // --- Casts ---
    //

    pub fn bitcast(self: *InstructionEncoder, result_type: ir.Term, val: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(ir.Instruction.Operation.bitcast, result_type, &.{.{ .variable = val }}, name, src);
    }

    pub fn convert(self: *InstructionEncoder, result_type: ir.Term, val: *ir.Instruction, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        return builder.createInstruction(ir.Instruction.Operation.convert, result_type, &.{.{ .variable = val }}, name, src);
    }

    pub fn reify(self: *InstructionEncoder, result_type: ir.Term, val: ir.Term, args: []const ir.Instruction.Operand, name: ?ir.Name, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const out = try builder.createInstruction(ir.Instruction.Operation.reify, result_type, &.{.{ .term = val }}, name, src);

        for (args) |arg| {
            try out.appendOperand(arg);
        }

        return out;
    }

    //
    // --- Control & Effects ---
    //

    pub fn call(
        self: *InstructionEncoder,
        result_type: ir.Term,
        callee: *ir.Instruction,
        args: []const *ir.Instruction,
        name: ?ir.Name,
        src: ?analysis.Source,
    ) !*ir.Instruction {
        const builder = self.getBuilder();

        const out = try builder.createInstruction(ir.Instruction.Operation.call, result_type, &.{.{ .variable = callee }}, name, src);

        for (args) |arg| {
            try out.appendOperand(.{ .variable = arg });
        }

        return out;
    }

    pub fn prompt(
        self: *InstructionEncoder,
        result_type: ir.Term,
        effect_type: ir.Term,
        args: []const *ir.Instruction,
        name: ?ir.Name,
        src: ?analysis.Source,
    ) !*ir.Instruction {
        const builder = self.getBuilder();

        const out = try builder.createInstruction(ir.Instruction.Operation.prompt, result_type, &.{.{ .term = effect_type }}, name, src);
        for (args) |arg| {
            try out.appendOperand(.{ .variable = arg });
        }

        return out;
    }

    pub fn push_set(self: *InstructionEncoder, handler_set: *ir.HandlerSet, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Operation.push_set, void_ty, &.{.{ .handler_set = handler_set }}, null, src);
    }

    pub fn pop_set(self: *InstructionEncoder, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Operation.pop_set, void_ty, &.{}, null, src);
    }

    pub fn breakpoint(self: *InstructionEncoder, src: ?analysis.Source) !*ir.Instruction {
        const builder = self.getBuilder();
        const void_ty = try builder.context.getOrCreateSharedTerm(ir.terms.VoidType{});
        return builder.createInstruction(ir.Instruction.Operation.breakpoint, void_ty, &.{}, null, src);
    }
};
