//! A builder for creating a linear sequence of bytecode instructions.
//! This builder does not support terminators or branch instructions and is
//! intended for generating straight-line code fragments for specialized use cases
//! like JIT compilers or code generators.

const SequenceBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_sequence_builder);

const core = @import("core");
const binary = @import("binary");

const common = @import("common");
const Buffer = common.Buffer;

const bytecode = @import("../bytecode.zig");
const Instruction = bytecode.Instruction;
const ProtoInstr = bytecode.ProtoInstr;
const Error = bytecode.Error;
const HandlerSetBuilder = bytecode.HandlerSetBuilder;
const LocalFixupMap = bytecode.LocalFixupMap;
const UpvalueFixupMap = bytecode.UpvalueFixupMap;

test {
    // std.debug.print("semantic analysis for bytecode SequenceBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

/// The general allocator used by this sequence builder for collections.
gpa: std.mem.Allocator,
/// The collection of instructions in this sequence, in un-encoded form.
body: common.ArrayList(ProtoInstr) = .empty,
/// The function that this sequence belongs to.
function: core.FunctionId = .fromInt(0),

/// Initialize a new sequence builder with the given allocator.
pub fn init(gpa: std.mem.Allocator) SequenceBuilder {
    return .{ .gpa = gpa };
}

/// Clear the sequence builder, retaining the current memory capacity.
pub fn clear(self: *SequenceBuilder) void {
    self.body.clearRetainingCapacity();
}

/// Deinitialize the sequence builder, freeing all memory associated with it.
pub fn deinit(self: *SequenceBuilder) void {
    self.body.deinit(self.gpa);
    self.* = undefined;
}

/// Append a pre-composed `ProtoInstr` to the sequence.
/// * Violating some sequence invariants will result in a `BadEncoding` error, but this method is generally unsafe,
///   and should be considered an escape hatch where comptime bounds on the other instruction methods are too restrictive.
pub fn proto(self: *SequenceBuilder, pi: ProtoInstr) Error!void {
    if (pi.instruction.code.isTerm() or pi.instruction.code.isBranch()) {
        log.err("SequenceBuilder cannot contain terminator or branch instructions", .{});
        return error.BadEncoding;
    }

    if (pi.instruction.code.isCall()) {
        if (pi.additional != .call_args or pi.additional.call_args.len != pi.instruction.getExpectedCallArgumentCount().?) {
            log.err("SequenceBuilder cannot contain call instructions with non-standard argument counts", .{});
            return error.BadEncoding;
        }
    }

    try self.body.append(self.gpa, pi);
}

/// Append a non-terminating one-word instruction to the sequence.
pub fn instr(self: *SequenceBuilder, comptime code: Instruction.BasicOpCode, data: Instruction.OperandSet(code.upcast())) Error!void {
    try self.proto(.{
        .instruction = .{
            .code = code.upcast(),
            .data = @unionInit(Instruction.OpData, @tagName(code), data),
        },
        .additional = .none,
    });
}

/// Append a two-word instruction to the sequence.
pub fn instrWide(self: *SequenceBuilder, comptime code: Instruction.WideOpCode, data: Instruction.OperandSet(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Error!void {
    try self.proto(.{
        .instruction = .{
            .code = code.upcast(),
            .data = @unionInit(Instruction.OpData, @tagName(code), data),
        },
        .additional = .{ .wide_imm = wide_operand },
    });
}

/// Helper to get the identity type of an AddrOf proto instruction.
pub fn AddrId(comptime code: Instruction.AddrOpCode) type {
    comptime return switch (code) {
        .addr_l => core.LocalId,
        .addr_u => core.UpvalueId,
        .addr_g => core.GlobalId,
        .addr_f => core.FunctionId,
        .addr_b => core.BuiltinId,
        .addr_x => core.ForeignAddressId,
        .addr_c => core.ConstantId,
    };
}

/// Append an address-of instruction to the sequence.
pub fn instrAddrOf(self: *SequenceBuilder, comptime code: Instruction.AddrOpCode, register: core.Register, id: AddrId(code)) binary.Encoder.Error!void {
    const Set = comptime Instruction.OperandSet(code.upcast());
    const fields = comptime std.meta.fieldNames(Set);
    const id_field = comptime fields[1];
    const set_is_enum = comptime @typeInfo(@FieldType(Set, id_field)) == .@"enum";

    comptime {
        if (std.mem.eql(u8, id_field, "R") or fields.len != 2) {
            @compileError("SequenceBuilder.instrAddrOf: out of sync with ISA; expected 'R' field to be first of two fields.");
        }
    }

    var set: Set = undefined;

    set.R = register;
    @field(set, id_field) = if (comptime !set_is_enum) @intFromEnum(id) else id;

    try self.proto(.{
        .instruction = .{
            .code = code.upcast(),
            .data = @unionInit(Instruction.OpData, @tagName(code), set),
        },
        .additional = .none,
    });
}

/// Append a call instruction to the sequence.
pub fn instrCall(self: *SequenceBuilder, comptime code: Instruction.CallOpCode, data: Instruction.OperandSet(code.upcast()), args: Buffer.fixed(core.Register, core.MAX_REGISTERS)) Error!void {
    try self.proto(.{
        .instruction = .{
            .code = code.upcast(),
            .data = @unionInit(Instruction.OpData, @tagName(code), data),
        },
        .additional = .{ .call_args = args },
    });
}

/// Push an effect handler set onto the stack at the current sequence position.
pub fn pushHandlerSet(self: *SequenceBuilder, handler_set: *HandlerSetBuilder) binary.Encoder.Error!void {
    if (handler_set.function != self.function) {
        log.err("BlockBuilder.pushHandlerSet: {f} does not belong to the block's parent {any}", .{ handler_set.id, self.function });
        return error.BadEncoding;
    }

    try self.proto(.{
        .instruction = .{
            .code = .push_set,
            .data = .{ .push_set = .{ .H = handler_set.id } },
        },
        .additional = .none,
    });
}

/// Pop an effect handler set from the stack at the current sequence position.
pub fn popHandlerSet(self: *SequenceBuilder, handler_set: *HandlerSetBuilder) binary.Encoder.Error!void {
    if (handler_set.function != self.function) {
        log.err("BlockBuilder.popHandlerSet: {f} does not belong to the block's parent {any}", .{ handler_set.id, self.function });
        return error.BadEncoding;
    }

    try self.proto(.{
        .instruction = .{
            .code = .pop_set,
            .data = .{ .pop_set = .{} },
        },
        .additional = .none,
    });
}

/// Bind a handler set's cancellation location to the current offset in the sequence.
/// * The instruction that is encoded next *after this call*, will be executed first after the handler set is cancelled
/// * This allows cancellation to terminate a block and still use its terminator
pub fn bindHandlerSetCancellationLocation(self: *SequenceBuilder, handler_set: *HandlerSetBuilder) binary.Encoder.Error!void {
    if (handler_set.function != self.function) {
        log.err("BlockBuilder.bindHandlerSetCancellationLocation: {f} does not belong to the block's parent {any}", .{ handler_set.id, self.function });
        return error.BadEncoding;
    }

    try self.proto(.{
        .instruction = .{
            .code = .addr_b,
            .data = .{ .addr_b = .{} },
        },
        .additional = .{ .cancellation_location = try handler_set.cancellationLocation() },
    });
}

/// Encodes the instruction sequence into the provided encoder.
/// Does not encode a terminator; execution will fall through.
pub fn encode(self: *const SequenceBuilder, upvalue_fixups: ?*const UpvalueFixupMap, local_fixups: *const LocalFixupMap, encoder: *binary.Encoder) binary.Encoder.Error!void {
    for (self.body.items) |*pi| {
        try pi.encode(null, upvalue_fixups, local_fixups, encoder);
    }
}
