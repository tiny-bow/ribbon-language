//! Simple decoder iterator for bytecode instructions.
//! * Likely not suitable for interpreters due to performance; intended for reflection.

const Decoder = @This();

const std = @import("std");

const log = std.log.scoped(.bytecode_decoder);

const core = @import("core");

const bytecode = @import("../bytecode.zig");

test {
    // std.debug.print("semantic analysis for bytecode Decoder\n", .{});
    std.testing.refAllDecls(@This());
}

/// The instruction stream for the decoder to read from.
instructions: []const core.InstructionBits = &.{},
/// Current decoding position in the instruction stream.
ip: u64 = 0,

/// A decoded instruction with its trailing operands.
pub const Item = struct {
    /// The actual decoded instruction.
    instruction: bytecode.Instruction,
    /// Any trailing operands that are not part of the instruction's main word.
    trailing: Trailing,

    /// `std.fmt` impl
    pub fn format(self: *const Item, writer: *std.io.Writer) !void {
        @setEvalBranchQuota(10_000);

        try writer.print("{s}", .{@tagName(self.instruction.code)});

        inline for (comptime std.meta.fieldNames(bytecode.Instruction.OpCode)) |opcode_name| {
            const code = comptime @field(bytecode.Instruction.OpCode, opcode_name);

            if (code == self.instruction.code) {
                const Set = comptime bytecode.Instruction.OperandSet(code);
                const operands = &@field(self.instruction.data, opcode_name);

                inline for (comptime std.meta.fieldNames(Set)) |operand_name| {
                    const operand = @field(operands, operand_name);
                    const Operand = @TypeOf(operand);

                    switch (Operand) {
                        core.Register => try writer.print(" {f}", .{operand}),

                        core.UpvalueId,
                        core.GlobalId,
                        core.FunctionId,
                        core.BuiltinId,
                        core.ForeignAddressId,
                        core.EffectId,
                        core.HandlerSetId,
                        core.ConstantId,
                        => |Static| {
                            try writer.writeAll(" " ++ operand_name ++ ":");

                            if (operand == .null) {
                                try writer.writeAll("null");
                            } else {
                                try writer.printInt(operand.toInt(), 16, .lower, .{
                                    .width = @sizeOf(Static) * 2,
                                    .fill = '0',
                                    .alignment = .right,
                                });
                            }
                        },

                        u8 => try writer.print(" " ++ operand_name ++ ":{x:0>2}", .{operand}),
                        u16 => try writer.print(" " ++ operand_name ++ ":{x:0>4}", .{operand}),
                        u32 => try writer.print(" " ++ operand_name ++ ":{x:0>8}", .{operand}),
                        u64 => try writer.print(" " ++ operand_name ++ ":{x:0>16}", .{operand}),

                        else => @compileError("Decoder: out of sync with ISA, encountered unexpected operand type " ++ @typeName(Operand)),
                    }
                }

                try self.trailing.show(code, writer);

                return;
            }
        }

        unreachable;
    }
};

/// Trailing operands for instructions that have more than one word of data, used in `Decoder.Item` for multi-word instructions' data.
pub const Trailing = union(enum) {
    /// No trailing operands.
    none: void,
    /// Trailing operands were call arguments, decoded as slice of `core.Register`.
    call_args: []const core.Register,
    /// Trailing operand is a wide immediate value, decoded as `Decoder.Imm`.
    wide_imm: Imm,

    fn show(self: Trailing, code: bytecode.Instruction.OpCode, writer: *std.io.Writer) !void {
        switch (self) {
            .none => {},
            .call_args => |args| {
                try writer.writeAll(" .. (");

                for (args, 0..) |arg, i| {
                    try writer.print("{f}", .{arg});

                    if (i < args.len - 1) {
                        try writer.writeAll(" ");
                    }
                }

                try writer.writeAll(")");
            },
            .wide_imm => |imm| try imm.show(code, writer),
        }
    }
};

/// Wrapper for all bytecode immediate operands, used in `Decoder.Trailing` for 2-word instructions' trailing operand.
pub const Imm = union(enum) {
    /// 8 bits of the immediate word were used by the trailing operand.
    byte: u8,
    /// 16 bits of the immediate word were used by the trailing operand.
    short: u16,
    /// 32 bits of the immediate word were used by the trailing operand.
    int: u32,
    /// 64 bits of the immediate word were used by the trailing operand.
    word: u64,

    fn show(self: Imm, code: bytecode.Instruction.OpCode, writer: *std.io.Writer) !void {
        const name = code.wideOperandName() orelse "UnexpectedImm";
        switch (self) {
            .byte => |operand| try writer.print(" .. {s}:{x:0>2}", .{ name, operand }),
            .short => |operand| try writer.print(" .. {s}:{x:0>4}", .{ name, operand }),
            .int => |operand| try writer.print(" .. {s}:{x:0>8}", .{ name, operand }),
            .word => |operand| try writer.print(" .. {s}:{x:0>16}", .{ name, operand }),
        }
    }
};

/// Initialize a new Decoder with the provided instruction bit buffer.
pub fn init(instructions: []const core.InstructionBits) Decoder {
    return .{ .instructions = instructions };
}

/// Clear the decoder instruction pointer.
pub fn clear(self: *Decoder) void {
    self.ip = 0;
}

/// Iterator method. Get the next instruction from the decoder.
pub fn next(self: *Decoder) error{BadEncoding}!?Item {
    if (self.ip < self.instructions.len) {
        // create the item that will be returned this iteration
        var item = Item{
            .instruction = bytecode.Instruction.fromBits(self.instructions[self.ip]),
            .trailing = Trailing.none,
        };

        // we have consumed the main instruction word
        self.ip += 1;

        // check if the instruction is a wide instruction or a call instruction
        if (item.instruction.code.isWide()) {
            if (self.ip < self.instructions.len) {
                // simple case, just copy it over and increment ip
                item.trailing = .{ .wide_imm = switch (item.instruction.code.wideOperandKind().?) {
                    .byte => .{ .byte = @truncate(self.instructions[self.ip]) },
                    .short => .{ .short = @truncate(self.instructions[self.ip]) },
                    .int => .{ .int = @truncate(self.instructions[self.ip]) },
                    .word => .{ .word = self.instructions[self.ip] },
                } };
                self.ip += 1;
            } else {
                log.debug("Decoder.next: Incomplete wide instruction at end of stream.", .{});
                return error.BadEncoding;
            }
        } else if (item.instruction.getExpectedCallArgumentCount()) |n| {
            // this case needs to create a view of a variable number of *bytes* in the word stream
            const base: [*]const core.Register = @ptrCast(self.instructions.ptr + self.ip);

            // we need to get the byte count, then round up to the nearest word size
            const arg_byte_count = n * @sizeOf(core.Register);
            const arg_word_count = (arg_byte_count + @sizeOf(core.InstructionBits) - 1) / @sizeOf(core.InstructionBits);

            // check the new instruction pointer before incrementing
            const new_ip = self.ip + arg_word_count;
            if (new_ip > self.instructions.len) {
                log.debug("Decoder.next: Incomplete call instruction at end of stream.", .{});
                return error.BadEncoding;
            }

            // setup trailing operands
            item.trailing = .{ .call_args = base[0..n] };
            self.ip = new_ip;
        }

        return item;
    }

    return null;
}
