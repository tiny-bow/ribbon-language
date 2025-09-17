//! Simple intermediate representing complete, possibly multiword instructions.
//! * This is a temporary intermediate type produced and consumed during the building/encoding process
//! * Used as an input to various builders' and encoder methods, to represent full instructions; necessary to store multi-word instructions, before encoding
const ProtoInstr = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_proto_instr);

const core = @import("core");
const binary = @import("binary");

const common = @import("common");
const Buffer = common.Buffer;

const bytecode = @import("../bytecode.zig");

/// The instruction itself, containing the opcode and data.
instruction: bytecode.Instruction,
/// Additional information for the instruction, such as wide immediate values or call arguments.
additional: AdditionalInfo,

/// Additional information for `ProtoInstr`, capturing data that does not fit into an instruction word.
pub const AdditionalInfo = union(enum) {
    /// No additional information, basic instruction.
    none,
    /// The immediate value half of a 2-word instruction.
    wide_imm: u64,
    /// The arguments of variable-width call instructions.
    call_args: Buffer.fixed(core.Register, core.MAX_REGISTERS),
    /// The destination(s) of branch instructions.
    branch_target: struct { core.BlockId, ?core.BlockId },
    /// The address of a handler set cancellation location.
    cancellation_location: binary.Location,
};

/// Encode this instruction into the provided encoder at the current relative address.
/// * Uses the `binary.Encoder.temp_allocator` to allocate local variable fixups in the provided `bytecode.LocalFixupMap`.
/// * This method is used by the `BlockBuilder` to encode instructions into the
/// * It is not intended to be used directly; instead, use the `BlockBuilder` methods to append instructions.
/// * Also available are convenience methods in `binary.Encoder` for appending instructions directly.
/// * The queue is used to track branch targets and ensure they are visited in the correct order. Pass `null` for body sequences to ensure no branches are allowed inside.
pub fn encode(self: *const ProtoInstr, maybe_queue: ?*bytecode.BlockVisitorQueue, upvalue_fixups: ?*const bytecode.UpvalueFixupMap, local_fixups: *const bytecode.LocalFixupMap, encoder: *binary.Encoder) binary.Encoder.Error!void {
    try encoder.ensureAligned(core.BYTECODE_ALIGNMENT);

    // Cancellation locations do not encode any bytes to the stream, they simply bind a binary.Fixup location
    if (self.additional == .cancellation_location) {
        const loc = self.additional.cancellation_location;

        try encoder.registerLocation(loc);
        try encoder.bindLocation(loc, encoder.getRelativeAddress());

        return;
    }

    var instr = self.instruction;

    // We fix up the local and upvalue stack-relative addresses here, before encoding bytes to the stream
    if (self.instruction.code.isAddr()) is_addr: {
        const addr_code: bytecode.Instruction.AddrOpCode = @enumFromInt(@intFromEnum(self.instruction.code));

        switch (addr_code) {
            .addr_l => {
                const local_id: core.LocalId = @enumFromInt(self.instruction.data.addr_l.I);
                instr.data.addr_l.I = @intCast(local_fixups.get(local_id) orelse {
                    log.err("ProtoInstr.encode: Local variable {f} not found in local binary.Fixup map", .{local_id});
                    return error.BadEncoding;
                });
            },

            .addr_u => {
                const map = upvalue_fixups orelse {
                    log.debug("ProtoInstr.encode: Upvalue address instruction without upvalue binary.Fixup map; this is not allowed", .{});
                    return error.BadEncoding;
                };

                const upvalue_id: core.UpvalueId = @enumFromInt(self.instruction.data.addr_u.I);
                instr.data.addr_u.I = @intCast(map.get(upvalue_id) orelse {
                    log.err("ProtoInstr.encode: Upvalue {f} not found in upvalue binary.Fixup map", .{upvalue_id});
                    return error.BadEncoding;
                });
            },

            .addr_g,
            .addr_f,
            .addr_b,
            .addr_x,
            .addr_c,
            => break :is_addr,
        }
    }

    const rel_addr = encoder.getRelativeAddress();
    try encoder.writeValue(instr.toBits());

    switch (self.additional) {
        .none => {},
        .cancellation_location => unreachable,
        .wide_imm => |bits| try encoder.writeValue(bits),
        .call_args => |args| try encoder.writeAll(std.mem.sliceAsBytes(args.asSlice())),
        .branch_target => |ids| {
            const then_id, const maybe_else_id = ids;
            const then_dest = encoder.localLocationId(then_id);

            const queue = maybe_queue orelse {
                log.debug("ProtoInstr.encode: Branch instruction without a queue; this is not allowed", .{});
                return error.BadEncoding;
            };

            switch (instr.code) {
                .br => {
                    if (maybe_else_id) |_| {
                        log.err("BlockBuilder.encode: Branch instruction `br` cannot have an else target", .{});
                        return error.BadEncoding;
                    }

                    const then_bit_offset = @bitOffsetOf(bytecode.Instruction.operand_sets.br, "I") + @bitSizeOf(bytecode.Instruction.OpCode);

                    try encoder.bindFixup(
                        .relative_words,
                        .{ .relative = rel_addr },
                        .{ .location = then_dest },
                        then_bit_offset,
                    );

                    try queue.add(then_id);
                },
                .br_if => {
                    if (maybe_else_id) |else_id| {
                        const else_dest = encoder.localLocationId(else_id);

                        const then_bit_offset = @bitOffsetOf(bytecode.Instruction.operand_sets.br_if, "Ix") + @bitSizeOf(bytecode.Instruction.OpCode);
                        const else_bit_offset = @bitOffsetOf(bytecode.Instruction.operand_sets.br_if, "Iy") + @bitSizeOf(bytecode.Instruction.OpCode);

                        try encoder.bindFixup(
                            .relative_words,
                            .{ .relative = rel_addr },
                            .{ .location = then_dest },
                            then_bit_offset,
                        );

                        try encoder.bindFixup(
                            .relative_words,
                            .{ .relative = rel_addr },
                            .{ .location = else_dest },
                            else_bit_offset,
                        );

                        try queue.add(then_id);
                        try queue.add(else_id);
                    } else {
                        log.err("BlockBuilder.encode: Branch instruction `br_if` must have an else target", .{});
                        return error.BadEncoding;
                    }
                },
                else => |code| {
                    log.err("BlockBuilder.encode: `{s}` is not an expected branch instruction ", .{@tagName(code)});
                    return error.BadEncoding;
                },
            }
        },
    }

    try encoder.alignTo(core.BYTECODE_ALIGNMENT);
}
