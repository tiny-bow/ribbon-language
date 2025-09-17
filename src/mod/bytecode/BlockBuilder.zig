//! A bytecode basic block in unencoded form.
//!
//! A basic block is a straight-line sequence of instructions with no *local*
//! control flow, terminated by a branch or similar instruction. It is built upon
//! a `bc.SequenceBuilder` for its body, adding support for terminators and branching.

const BlockBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_block_builder);

const core = @import("core");
const binary = @import("binary");
const common = @import("common");

const bytecode = @import("../bytecode.zig");

/// The arena allocator used for this block's body.
arena: std.mem.Allocator,
/// The instructions making up the body of this block, in un-encoded form.
body: bytecode.SequenceBuilder,
/// The unique(-within-`function`) identifier for this block.
id: core.BlockId = .fromInt(0),
/// The instruction that terminates this block.
/// * Adding any instruction when this is non-`null` is a `BadEncoding` error
/// * For all other purposes, `null` is semantically equivalent to `unreachable`
terminator: ?bytecode.ProtoInstr = null,

/// ID of all functions' entry point block.
pub const entry_point_id = core.BlockId.fromInt(0);

/// Initialize a new block builder for the given function and block ids.
pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) BlockBuilder {
    return BlockBuilder{
        .arena = arena,
        .body = .init(gpa),
    };
}

/// Clear the block builder, retaining the current memory capacity.
pub fn clear(self: *BlockBuilder) void {
    self.body.clear();

    self.id = .fromInt(0);
    self.function = .fromInt(0);
    self.terminator = null;
}

/// Deinitialize the block builder, freeing all memory associated with it.
pub fn deinit(self: *BlockBuilder) void {
    self.body.deinit();
    self.* = undefined;
}

/// Get the total count of instructions in this block, including the terminator (even if implicit).
pub fn count(self: *const BlockBuilder) u64 {
    return self.body.body.items.len + 1;
}

/// Append a pre-composed instruction to the block.
/// * Violating some invariants will result in a `BadEncoding` error, but this method is generally unsafe,
///   and should be considered an escape hatch where comptime bounds on the other instruction methods are too restrictive.
pub fn proto(self: *BlockBuilder, pi: bytecode.ProtoInstr) binary.Encoder.Error!void {
    try self.ensureUnterminated();

    if (pi.instruction.code.isTerm() or pi.instruction.code.isBranch()) {
        self.terminator = pi;
    } else {
        try self.body.proto(pi);
    }
}

/// Append a pre-composed
/// Append a non-terminating one-word instruction to the block body.
pub fn instr(self: *BlockBuilder, comptime code: bytecode.Instruction.BasicOpCode, data: bytecode.Instruction.OperandSet(code.upcast())) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    try self.body.instr(code, data);
}

/// Append a two-word instruction to the block body.
pub fn instrWide(self: *BlockBuilder, comptime code: bytecode.Instruction.WideOpCode, data: bytecode.Instruction.OperandSet(code.upcast()), wide_operand: bytecode.Instruction.WideOperand(code.upcast())) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    try self.body.instrWide(code, data, wide_operand);
}

/// Append a call instruction to the block body.
pub fn instrCall(self: *BlockBuilder, comptime code: bytecode.Instruction.CallOpCode, data: bytecode.Instruction.OperandSet(code.upcast()), args: common.Buffer.fixed(core.Register, core.MAX_REGISTERS)) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    try self.body.instrCall(code, data, args);
}

/// Append an address-of instruction to the block body.
pub fn instrAddrOf(self: *BlockBuilder, comptime code: bytecode.Instruction.AddrOpCode, register: core.Register, id: bytecode.SequenceBuilder.AddrId(code)) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    try self.body.instrAddrOf(code, register, id);
}

/// Set the block terminator to a branch instruction.
pub fn instrBr(self: *BlockBuilder, target: core.BlockId) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    self.terminator = .{
        .instruction = .{
            .code = .br,
            .data = .{ .br = .{} },
        },
        .additional = .{ .branch_target = .{ target, null } },
    };
}

/// Set the block terminator to a conditional branch instruction.
pub fn instrBrIf(self: *BlockBuilder, condition: core.Register, then_id: core.BlockId, else_id: core.BlockId) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    self.terminator = .{
        .instruction = .{
            .code = .br_if,
            .data = .{ .br_if = .{ .R = condition } },
        },
        .additional = .{ .branch_target = .{ then_id, else_id } },
    };
}

/// Set the block terminator to a non-branching instruction.
pub fn instrTerm(self: *BlockBuilder, comptime code: bytecode.Instruction.TermOpCode, data: bytecode.Instruction.OperandSet(code.upcast())) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    self.terminator = .{
        .instruction = .{
            .code = code.upcast(),
            .data = @unionInit(bytecode.Instruction.OpData, @tagName(code), data),
        },
        .additional = .none,
    };
}

/// Push an effect handler set onto the stack at the current sequence position.
pub fn pushHandlerSet(self: *BlockBuilder, handler_set: *bytecode.HandlerSetBuilder) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    try self.body.pushHandlerSet(handler_set);
}

/// Pop an effect handler set from the stack at the current sequence position.
pub fn popHandlerSet(self: *BlockBuilder, handler_set: *bytecode.HandlerSetBuilder) binary.Encoder.Error!void {
    try self.ensureUnterminated();
    try self.body.popHandlerSet(handler_set);
}

/// Bind a handler set's cancellation location to the current offset in the sequence.
/// * The instruction that is encoded next *after this call*, will be executed first after the handler set is cancelled
/// * This allows cancellation to terminate a block and still use its terminator
pub fn bindHandlerSetCancellationLocation(self: *BlockBuilder, handler_set: *bytecode.HandlerSetBuilder) binary.Encoder.Error!void {
    try self.body.bindHandlerSetCancellationLocation(handler_set);
}

/// Encode the block into the provided encoder, including the body instructions and the terminator.
/// * The block's entry point is encoded as a location in the bytecode header, using the current region id and the block's id as the offset
/// * Other blocks' ids that are referenced by instructions are added to the provided queue in order of use
pub fn encode(self: *BlockBuilder, queue: *bytecode.BlockVisitorQueue, upvalue_fixups: ?*const bytecode.UpvalueFixupMap, local_fixups: *const bytecode.LocalFixupMap, encoder: *binary.Encoder) binary.Encoder.Error!void {
    const location = encoder.localLocationId(self.id);

    if (!try encoder.visitLocation(location)) {
        log.debug("BlockBuilder.encode: {f} has already been encoded, skipping", .{self.id});
        return;
    }

    try encoder.ensureAligned(core.BYTECODE_ALIGNMENT);

    // we can encode the current location as the block entry point
    try encoder.registerLocation(location);
    try encoder.bindLocation(location, encoder.getRelativeAddress());

    // first we emit all the body instructions by encoding the inner sequence
    try self.body.encode(upvalue_fixups, local_fixups, encoder);

    // now the terminator instruction, if any; same as body instructions, but can queue block ids
    if (self.terminator) |*pi| {
        try pi.encode(queue, upvalue_fixups, local_fixups, encoder);
    } else {
        // simply write the scaled opcode for `unreachable`, since it has no operands
        try encoder.writeValue(bytecode.Instruction.OpCode.@"unreachable".toBits());
    }
}

/// Helper method that returns a `BadEncoding` error if the block is already terminated.
pub fn ensureUnterminated(self: *BlockBuilder) binary.Encoder.Error!void {
    if (self.terminator) |_| {
        log.debug("BlockBuilder.ensureUnterminated: {f} is already terminated; cannot append additional instructions", .{self.id});
        return error.BadEncoding;
    }
}

comptime {
    const br_instr_names = std.meta.fieldNames(bytecode.Instruction.BranchOpCode);

    if (br_instr_names.len != 2) {
        @compileError("BlockBuilder: out of sync with ISA, unhandled branch opcodes");
    }

    if (common.indexOfBuf(u8, br_instr_names, "br") == null or common.indexOfBuf(u8, br_instr_names, "br_if") == null) {
        @compileError("BlockBuilder: out of sync with ISA, branch opcode names changed");
    }
}
