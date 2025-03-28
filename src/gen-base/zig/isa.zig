//! # isa
//! This is a namespace defining the Ribbon bytecode ISA, containing
//! compile-time accessible representations of all of Ribbon's bytecode instructions,
//! as well as types and functions for working with these.
//!
//! From this data, we generate the following (via `bin/tools/gen`):
//! * The instruction type definition exported at `ribbon.bytecode.Instruction`.
//! * Interpreter assembly, using asm source components from `gen-base`.
//! * `docs/Isa.md`, using `gen-base/Isa_intro.md`.
const Isa = @This();

const std = @import("std");
const log = std.log.scoped(.Isa);

const pl = @import("platform");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Represents the name of an rvm bytecode instruction in an `InstructionDescriptor`.
pub const InstructionName = union(enum) {
    /// The name of the instruction is the same as its parent mnemonic.
    mnemonic: void,
    /// The name of the instruction is not based on its parent mnemonic.
    overridden: []const u8,
    /// The name of the instruction is the `base_name` of its parent mnemonic with a prefix.
    prefixed: []const u8,
    /// The name of the instruction is the `base_name` of its parent mnemonic with a suffix.
    suffixed: []const u8,
    /// The name of the instruction is the `base_name` of its parent mnemonic with a prefix and a suffix.
    wrapped: struct { []const u8, []const u8 },

    /// Writes the instruction name to the given `writer`, formatted with using the provided mnemonic.
    pub fn fmt(self: *const InstructionName, mnemonic: []const u8, writer: anytype) !void {
        try formatInstructionName(mnemonic, self.*, writer);
    }

    /// `Formatter.fmt` impl
    pub fn onFormat(self: *const InstructionName, formatter: anytype) !void {
        try formatInstructionName("%", self.*, formatter);
    }

    /// `std.fmt.format` impl
    pub fn format(self: *const InstructionName, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try formatInstructionName("%", self.*, writer);
    }

    fn override(str: []const u8) InstructionName {
        return InstructionName{ .overridden = str };
    }

    fn prefix(str: []const u8) InstructionName {
        return InstructionName{ .prefixed = str };
    }

    fn suffix(str: []const u8) InstructionName {
        return InstructionName{ .suffixed = str };
    }

    fn wrap(pre: []const u8, suf: []const u8) InstructionName {
        return InstructionName{ .wrapped = .{ pre, suf } };
    }
};

/// A set of Rvm bytecode `Mnemonic`s.
pub const Category = struct {
    /// The name of the instruction category.
    name: []const u8,
    /// A description of the instruction category.
    description: []const u8,
    /// The mnemonics in this category.
    mnemonics: []const Mnemonic = &.{},

    fn category(name: []const u8, description: []const u8, mnemonics: []const Mnemonic) Category {
        return Category{ .name = name, .description = description, .mnemonics = mnemonics };
    }
};

/// Represents a particular mnemonic group in a `Category`.
pub const Mnemonic = struct {
    /// The name of the mnemonic.
    ///
    /// * This is the name of contained instructions without any prefixes, suffixes, or overrides.
    name: []const u8,

    /// A description of the mnemonic.
    description: []const u8,

    /// The instructions based on this mnemonic.
    instructions: []const Instruction,

    fn mnemonic(name: []const u8, description: []const u8, instructions: []const Instruction) Mnemonic {
        return Mnemonic{ .name = name, .description = description, .instructions = instructions };
    }

    fn basicSingleton(name: []const u8, description: []const u8, operands: []const Operand) Mnemonic {
        return Mnemonic{
            .name = name,
            .description = "",
            .instructions = &.{ .basic(.mnemonic, description, operands) },
        };
    }

    fn terminatorSingleton(name: []const u8, description: []const u8, operands: []const Operand) Mnemonic {
        return Mnemonic{
            .name = name,
            .description = "",
            .instructions = &.{ .terminator(.mnemonic, description, operands) },
        };
    }
};

/// Represents an Rvm bytecode instruction inside a `Category`.
pub const Instruction = struct {
    /// The name of the instruction.
    name: InstructionName,
    /// A description of the instruction, if it requires extra context.
    description: []const u8,
    /// Operands encoded into the instruction word.
    operands: []const Operand = &.{},
    /// Whether this instruction is only used in JIT mode.
    jit_only: bool = false,
    /// Whether this instruction terminates the basic block it is in.
    terminal: bool = false,
    /// Whether this instruction expects a variable-length amount of data to be encoded after it.
    variable_length: bool = false,

    fn basic(name: InstructionName, description: []const u8, operands: []const Operand) Instruction {
        return Instruction{ .name = name, .description = description, .operands = operands };
    }

    fn jitBasic(name: InstructionName, description: []const u8, operands: []const Operand) Instruction {
        return Instruction{ .name = name, .description = description, .operands = operands, .jit_only = true };
    }

    fn terminator(name: InstructionName, description: []const u8, operands: []const Operand) Instruction {
        return Instruction{ .name = name, .description = description, .operands = operands, .terminal = true };
    }

    fn jitTerminator(name: InstructionName, description: []const u8, operands: []const Operand) Instruction {
        return Instruction{ .name = name, .description = description, .operands = operands, .jit_only = true, .terminal = true };
    }

    fn variable(name: InstructionName, description: []const u8, operands: []const Operand) Instruction {
        return Instruction{ .name = name, .description = description, .operands = operands, .variable_length = true };
    }

    fn jitVariable(name: InstructionName, description: []const u8, operands: []const Operand) Instruction {
        return Instruction{ .name = name, .description = description, .operands = operands, .jit_only = true, .variable_length = true };
    }
};

/// Describes the type of an operand encoded in an `Instruction`.
pub const Operand = enum {
    /// The operand is one of the current function's registers.
    register,
    /// The operand is a static reference to a dynamically bound variable.
    upvalue,
    /// The operand is a static reference to a global variable in the current program.
    global,
    /// The operand is a static reference to a function in the current program.
    function,
    /// The operand is a static discriminator indicating the abi with which to call a function.
    abi,
    /// The operand is a static reference to a builtin value in the current program.
    builtin,
    /// The operand is a static reference to a C ABI value in the current program.
    /// * Operands of this kind are only used in JIT mode.
    foreign,
    /// The operand is an effect identifier.
    effect,
    /// The operand is a static reference to an effect handler set in the current program.
    handler_set,
    /// The operand is a static reference to data encoded in the constant section of the current program.
    constant, // TODO: re-evaluate the need for constants

    /// The operand is a constant value encoded into 1 byte.
    byte,
    /// The operand is a constant value encoded into 2 bytes.
    short,
    /// The operand is a constant value encoded into 4 bytes.
    int,
    /// Indicates the operand is a constant value encoded into 8 bytes.
    /// This will follow the instruction itself, as the next word.
    /// Only valid in tail position.
    word,

    fn multipleEntries(operand: Operand, operands: []const Operand) bool {
        var seen = false;

        for (operands) |op| {
            if (op.getShortcode() == operand.getShortcode()) {
                if (seen) {
                    return true;
                } else {
                    seen = true;
                }
            }
        }

        return false;
    }

    /// Writes a *markdown* typename-style representation of an `Operand` type.
    /// ### Example
    /// ```
    /// .register => "`Register`"
    /// ```
    pub fn writeContextualReference(self: Operand, writer: anytype) !void {
        try writer.writeByte('`');
        _ = try self.writeShorthandType(writer);
        try writer.writeByte('`');
    }


    /// Returns whether the operand type is a an immediate value.
    /// ### Example
    /// ```
    /// .register => false
    /// .byte => true
    /// ```
    pub fn isImmediate(self: Operand) bool {
        switch (self) {
            .register, .upvalue, .global, .function, .abi,
            .builtin, .foreign, .effect, .handler_set, .constant,
            => return false,

            .byte, .short, .int, .word,
            => return true,
        }
    }

    /// Writes a typename-style representation of an `Operand` type.
    /// ### Example
    /// ```
    /// .register => "Register"
    /// ```
    pub fn writeShorthandType(self: Operand, writer: anytype) !void {
        switch (self) {
            .register => try writer.writeAll("Register"),
            .upvalue => try writer.writeAll("Id.of(Upvalue)"),
            .global => try writer.writeAll("Id.of(Global)"),
            .function => try writer.writeAll("Id.of(Function)"),
            .abi => try writer.writeAll("Abi"),
            .builtin => try writer.writeAll("Id.of(BuiltinAddress)"),
            .foreign => try writer.writeAll("Id.of(ForeignAddress)"),
            .effect => try writer.writeAll("Id.of(Effect)"),
            .handler_set => try writer.writeAll("Id.of(HandlerSet)"),
            .constant => try writer.writeAll("Id.of(Constant)"),
            .byte => try writer.writeAll("u8"),
            .short => try writer.writeAll("u16"),
            .int => try writer.writeAll("u32"),
            .word => try writer.writeAll("u64"),
        }
    }

    /// Writes a single byte representation of an `Operand` type.
    /// ### Example
    /// ```
    /// .register => "R"
    /// ```
    pub fn writeShortcode(self: Operand, writer: anytype) !void {
        try writer.writeByte(self.getShortcode());
    }

    /// Returns a single byte representation of an `Operand` type.
    /// ### Example
    /// ```
    /// .register => "R"
    /// ```
    pub fn getShortcode(self: Operand) u8 {
        return switch (self) {
            .register => 'R',
            .upvalue => 'U',
            .global => 'G',
            .abi => 'A',
            .function => 'F',
            .builtin => 'B',
            .foreign => 'X',
            .effect => 'E',
            .handler_set => 'H',
            .constant => 'C',
            .byte => 'I',
            .short => 'I',
            .int => 'I',
            .word => 'I',
        };
    }

    /// Gives the size of an `Operand` type in bytes.
    pub fn sizeOf(self: Operand) usize {
        return switch (self) {
            .register => 1,
            .upvalue => 1,
            .global => 2,
            .function => 2,
            .abi => 1,
            .builtin => 2,
            .foreign => 2,
            .effect => 2,
            .handler_set => 2,
            .constant => 2,
            .byte => 1,
            .short => 2,
            .int => 4,
            .word => 8,
        };
    }

    /// Simple sum of the sizes of a list of operands.
    pub fn totalSizeNoPadding(operands: []const Operand) usize {
        var size: usize = 0;

        for (operands) |op| {
            size += op.sizeOf();
        }

        return size;
    }
};

fn startsWithDigits(str: []const u8) bool {
    return str.len != 0 and str[0] >= '0' and str[0] <= '9';
}

fn endsWithDigits(str: []const u8) bool {
    return str.len != 0 and str[str.len - 1] >= '0' and str[str.len - 1] <= '9';
}

pub fn wordBoundaryHeuristic(operand: Operand, remSize: anytype, wordOffset: anytype) bool {
    const wordRem = 8 - wordOffset;
    const operandSize = operand.sizeOf();

    // we of course break at actual word boundaries
    if (wordOffset >= 8) return true;

    // or if the operand cant fit in this word
    if (operandSize > wordRem) return true;

    // if we reached here, we *could* fit it //

    // only consider ending early if we definitely need another word
    if (operandSize + remSize <= wordRem) return false;

    // personal preference here, but only packing the immediates into the next word seems nicer
    if (!operand.isImmediate()) return false;

    // but if we do need another word, and we'd be left with a single fully-packed word of immediates,
    // we should break now because it will make the decode operation cleaner
    if (operandSize + remSize == 8) return true;

    // otherwise let's only break now when doing so doesnt cause us to require an extra word
    return (operandSize + remSize < 8);
}

pub fn formatInstructionName(mnemonic: []const u8, instr: InstructionName, writer: anytype) !void {
    switch (instr) {
        .mnemonic => try writer.print("{s}", .{ mnemonic }),
        .overridden => |o| try writer.print("{s}", .{ o }),
        .prefixed => |p| {
            try writer.writeAll(p);

            if (!endsWithDigits(p)) {
                try writer.writeAll("_");
            }

            try writer.writeAll(mnemonic);
        },
        .suffixed => |s| {
            try writer.writeAll(mnemonic);

            if (!startsWithDigits(s)) {
                try writer.writeAll("_");
            }

            try writer.writeAll(s);
        },
        .wrapped => |w| {
            try writer.writeAll(w[0]);

            if (!endsWithDigits(w[0])) {
                try writer.writeAll("_");
            }

            try writer.writeAll(mnemonic);

            if (!startsWithDigits(w[1])) {
                try writer.writeAll("_");
            }

            try writer.writeAll(w[1]);
        },
    }
}

pub fn formatIndex(index: usize, operands: []const Operand, writer: anytype) !void {
    var relativeIndex: usize = 0;

    for (0..index) |i| {
        if (operands[i].getShortcode() == operands[index].getShortcode()) {
            relativeIndex += 1;
        }
    }

    try writer.writeByte("xyzw"[relativeIndex]);
}

pub fn formatOperand(index: usize, operands: []const Operand, writer: anytype) !usize {
    const operand = operands[index];

    try operand.writeShortcode(writer);

    if (operand.multipleEntries(operands)) {
        try formatIndex(index, operands, writer);
        return 2;
    } else {
        return 1;
    }
}


/// The exact semantic version of this specification.
pub const VERSION = pl.VERSION; // TODO: make isa version independent when it has stabilized

/// Compile-time accessible data describing all of Ribbon's bytecode instructions.
pub const CATEGORIES: []const Category = &.{
    .category("Miscellaneous",
        "Items that do not fit into another category",
        &.{
            .basicSingleton("nop", "No operation", &.{}),
            .basicSingleton("breakpoint", "Triggers a breakpoint in debuggers; does nothing otherwise", &.{}),
        },
    ),

    .category("Control flow",
        "Instructions that control the flow of execution",
        &.{
            .terminatorSingleton("halt", "Halts execution at this instruction offset", &.{}),

            .mnemonic("trap",
                "Marks a point in the code as not normally reachable, in two ways",
                &.{
                    .terminator(.mnemonic,
                        \\Traps execution of the `Rvm.Fiber` at this instruction offset
                        \\Unlike `unreachable`, this indicates expected behavior; optimizing compilers should *not* assume it is never reached
                        , &.{},
                    ),
                    .terminator(.override("unreachable"),
                        \\Marks a point in the code as unreachable; if executed in Rvm, it is the same as `trap`
                        \\Unlike `trap`, however, this indicates undefined behavior; optimizing compilers should assume it is never reached
                        , &.{},
                    ),
                },
            ),

            .mnemonic("set",
                "Effect handler set stack manipulation",
                &.{
                    .basic(.prefix("push"),
                        \\Pushes {0} onto the stack.
                        \\The handlers in this set will be first in line for their effects' prompts until a corresponding `pop` operation.
                        , &.{ .handler_set },
                    ),
                    .basic(.prefix("pop"),
                        "Pops the top most {.handler_set} from the stack, restoring the previous if present",
                        &.{},
                    ),
                },
            ),

            .mnemonic("br",
                "Instruction pointer manipulation",
                &.{
                    .terminator(.mnemonic, "Applies a signed integer offset {0} to the instruction pointer", &.{ .int }),
                    .terminator(.suffix("if"), "Applies a signed integer offset {1} to the instruction pointer, if the value stored in {0} is non-zero", &.{ .register, .int }),
                },
            ),

            .mnemonic("call",
                \\Various ways of calling functions, in all cases taking up to max({.byte}) number of arguments.
                \\Arguments are expected to be {.register} values, encoded in the instruction stream after the call instruction.
                \\* {.register} is not instruction-aligned; padding bytes may need to be added and accounted for following the arguments, to ensure the next instruction is aligned
                , &.{
                    .variable(.mnemonic, "Calls the function in {1} using {2}, placing the result in {0}", &.{ .register, .register, .abi, .byte }),
                    .variable(.suffix("c"), "Calls the function at {1} using {2}, placing the result in {0}", &.{ .register, .function, .abi, .byte }),

                    .variable(.override("prompt"),
                        \\Calls the effect handler designated by {1} using {2}, placing the result in {0}.
                        , &.{ .register, .effect, .abi, .byte },
                    ),
                },
            ),

            .mnemonic("return",
                "End the current function, in one of two ways",
                &.{
                    .terminator(.mnemonic, "Returns flow control to the caller of current function, yielding {0} to the caller", &.{ .register }),
                    .terminator(.override("cancel"), "Returns flow control to the offset associated with the current effect handler's {.handler_set}, yielding {0} as the cancellation value", &.{ .register }),
                },
            ),
        },
    ),

    .category("Memory",
        "Instructions that provide memory access",
        &.{
            .mnemonic("mem_set",
                "Set bytes in memory",
                &.{
                    .basic(.mnemonic,
                        "Each byte, starting from the address in {0}, up to an offset of {2}, is set to the least significant byte of {1}",
                        &.{ .register, .register, .register },
                    ),
                    .basic(.suffix("a"),
                        "Each byte, starting from the address in {0}, up to an offset of {2}, is set to {1}",
                        &.{ .register, .register, .int },
                    ),
                    .basic(.suffix("b"),
                        "Each byte, starting from the address in {0}, up to an offset of {1}, is set to {2}",
                        &.{ .register, .register, .byte },
                    ),
                },
            ),
            .mnemonic("mem_copy",
                "Copy bytes in memory",
                &.{
                    .basic(.mnemonic,
                        "Each byte, starting from the address in {1}, up to an offset of {2}, is copied to the same offset of the address in {0}",
                        &.{ .register, .register, .register },
                    ),
                    .basic(.suffix("a"),
                        "Each byte, starting from the address in {1}, up to an offset of {2}, is copied to the same offset from the address in {0}",
                        &.{ .register, .register, .int },
                    ),
                    .basic(.suffix("b"),
                        "Each byte, starting from the address of {2}, up to an offset of {1}, is copied to the same offset from the address in {0}",
                        &.{ .register, .register, .constant },
                    ),
                },
            ),
            .mnemonic("mem_swap",
                "Swap bytes in memory.",
                &.{
                    .basic(.mnemonic,
                        "Each byte, starting from the addresses in {0} and {1}, up to an offset of {2}, are swapped with each-other",
                        &.{ .register, .register, .register },
                    ),
                    .basic(.suffix("c"),
                        "Each byte, starting from the addresses in {0} and {1}, up to an offset of {2}, are swapped with each-other",
                        &.{ .register, .register, .int },
                    ),
                },
            ),

            .mnemonic("addr",
                "Get addresses from special values.",
                &.{
                    .basic(.suffix("l"), "Get the address of a signed integer frame-relative operand stack offset {1}, placing it in {0}.\n\nAn operand stack offset of 1 is equivalent to 8 bytes down from the base of the stack frame", &.{.register, .int}),
                    .basic(.suffix("u"), "Get the address of {1}, placing it in {0}", &.{ .register, .upvalue }),
                    .basic(.suffix("g"), "Get the address of {1}, placing it in {0}", &.{ .register, .global }),
                    .basic(.suffix("f"), "Get the address of {1}, placing it in {0}", &.{ .register, .function }),
                    .basic(.suffix("b"), "Get the address of {1}, placing it in {0}", &.{ .register, .builtin }),
                    .basic(.suffix("x"), "Get the address of {1}, placing it in {0}", &.{ .register, .foreign }),
                    .basic(.suffix("c"), "Get the address of {1}, placing it in {0}", &.{ .register, .constant }),
                },
            ),

            .mnemonic("load",
                "Loads a value from memory",
                &.{
                    .basic(.suffix("8"), "Loads an 8-bit value from memory at the address in {1} offset by {2}, placing the result in {0}", &.{ .register, .register, .int }),
                    .basic(.suffix("16"), "Loads a 16-bit value from memory at the address in {1} offset by {2}, placing the result in {0}", &.{ .register, .register, .int }),
                    .basic(.suffix("32"), "Loads a 32-bit value from memory at the address in {1} offset by {2}, placing the result in {0}", &.{ .register, .register, .int }),
                    .basic(.suffix("64"), "Loads a 64-bit value from memory at the address in {1} offset by {2}, placing the result in {0}", &.{ .register, .register, .int }),
                },
            ),
            .mnemonic("store",
                "Stores a value to memory",
                &.{
                    .basic(.suffix("8"), "Stores an 8-bit value from {1} to memory at the address in {0} offset by {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("16"), "Stores a 16-bit value from {1} to memory at the address in {0} offset by {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("32"), "Stores a 32-bit value from {1} to memory at the address in {0} offset by {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64"), "Stores a 64-bit value from {1} to memory at the address in {0} offset by {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("8c"), "Stores an 8-bit value to memory at the address in {0} offset by {2}", &.{ .register, .byte, .int }),
                    .basic(.suffix("16c"), "Stores a 16-bit value to memory at the address in {0} offset by {2}", &.{ .register, .short, .int }),
                    .basic(.suffix("32c"), "Stores a 32-bit value to memory at the address in {0} offset by {2}", &.{ .register, .int, .int }),
                    .basic(.suffix("64c"), "Stores a 64-bit value (encoded as {2}) to memory at the address in {0} offset by {1}", &.{ .register, .int, .word }),
                },
            ),
        },
    ),

    .category("Bitwise",
        \\Instructions that manipulate values at the bit level.
        \\* Where the size is < 64-bits, the least significant bits of the input value(s) are used, and the remainder of the output value is zeroed
        , &.{
            .mnemonic("bit_swap",
                "Swaps bits of two registers",
                &.{
                    .basic(.suffix("8"), "8-bit {0} *xor_swap* {1}", &.{ .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} *xor_swap* {1}", &.{ .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} *xor_swap* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} *xor_swap* {1}", &.{ .register, .register }),
                },
            ),
            .mnemonic("bit_copy",
                "Copies bits from one register into another",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1}", &.{ .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1}", &.{ .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1}", &.{ .register, .register }),

                    .basic(.suffix("8c"), "Loads an 8-bit value into {0}", &.{ .register, .byte }),
                    .basic(.suffix("16c"), "Loads a 16-bit value into {0}", &.{ .register, .short }),
                    .basic(.suffix("32c"), "Loads a 32-bit value into {0}", &.{ .register, .int }),
                    .basic(.suffix("64c"), "Loads a 64-bit value into {0}", &.{ .register, .word }),
                },
            ),

            .mnemonic("bit_clz",
                "Counts the number of leading zero bits in the provided value",
                &.{
                    .basic(.suffix("8"), "Counts the leading zeroes in 8-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("16"), "Counts the leading zeroes in 16-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("32"), "Counts the leading zeroes in 32-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("64"), "Counts the leading zeroes in 64-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                },
            ),
            .mnemonic("bit_pop",
                "Counts the number of bits that are set to 1 in the provided value",
                &.{
                    .basic(.suffix("8"), "Counts the set bits in 8-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("16"), "Counts the set bits in 16-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("32"), "Counts the set bits in 32-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("64"), "Counts the set bits in 64-bits of {1}, placing the result in {0}", &.{ .register, .register }),
                },
            ),

            .mnemonic("bit_not",
                "Performs a bitwise `NOT` operation on the provided value",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = *not* {1}", &.{ .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = *not* {1}", &.{ .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = *not* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *not* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("bit_and",
                "Performs a bitwise `AND` operation on the provided values",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} *and* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "6-bit {0} = {1} *and* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} *and* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} *and* {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8c"), "8-bit {0} = {1} *and* {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16c"), "6-bit {0} = {1} *and* {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} *and* {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} *and* {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("bit_or",
                "Performs a bitwise `OR` operation on the provided values",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} *or* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} *or* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} *or* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} *or* {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8c"), "8-bit {0} = {1} *or* {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16c"), "16-bit {0} = {1} *or* {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} *or* {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} *or* {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("bit_xor",
                "Performs a bitwise `XOR` operation on the provided values",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} *xor* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} *xor* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} *xor* {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} *xor* {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8c"), "8-bit {0} = {1} *xor* {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16c"), "16-bit {0} = {1} *xor* {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} *xor* {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} *xor* {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("bit_lshift",
                "Performs a bitwise left shift operation on the provided values",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} << {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} << {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} << {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} << {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8a"), "8-bit {0} = {2} << {1}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16a"), "16-bit {0} = {2} << {1}", &.{ .register, .register, .short }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} << {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} << {1}", &.{ .register, .register, .word }),

                    .basic(.suffix("8b"), "8-bit {0} = {1} << {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16b"), "16-bit {0} = {1} << {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} << {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} << {2}", &.{ .register, .register, .byte }),
                },
            ),

            .mnemonic("bit_rshift",
                "Performs a bitwise right shift operation on the provided values",
                &.{
                    .basic(.override("u_rshift8"), "8-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .register }),
                    .basic(.override("u_rshift16"), "16-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .register }),
                    .basic(.override("u_rshift32"), "32-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .register }),
                    .basic(.override("u_rshift64"), "64-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .register }),

                    .basic(.override("u_rshift8a"), "8-bit unsigned/logical {0} = {2} >> {1}", &.{ .register, .register, .byte }),
                    .basic(.override("u_rshift16a"), "16-bit unsigned/logical {0} = {2} >> {1}", &.{ .register, .register, .short }),
                    .basic(.override("u_rshift32a"), "32-bit unsigned/logical {0} = {2} >> {1}", &.{ .register, .register, .int }),
                    .basic(.override("u_rshift64a"), "64-bit unsigned/logical {0} = {2} >> {1}", &.{ .register, .register, .word }),

                    .basic(.override("u_rshift8b"), "8-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                    .basic(.override("u_rshift16b"), "16-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                    .basic(.override("u_rshift32b"), "32-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                    .basic(.override("u_rshift64b"), "64-bit unsigned/logical {0} = {1} >> {2}", &.{ .register, .register, .byte }),

                    .basic(.override("s_rshift8"), "8-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .register }),
                    .basic(.override("s_rshift16"), "16-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .register }),
                    .basic(.override("s_rshift32"), "32-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .register }),
                    .basic(.override("s_rshift64"), "64-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .register }),

                    .basic(.override("s_rshift8a"), "8-bit signed/arithmetic {0} = {2} >> {1}", &.{ .register, .register, .byte }),
                    .basic(.override("s_rshift16a"), "16-bit signed/arithmetic {0} = {2} >> {1}", &.{ .register, .register, .short }),
                    .basic(.override("s_rshift32a"), "32-bit signed/arithmetic {0} = {2} >> {1}", &.{ .register, .register, .int }),
                    .basic(.override("s_rshift64a"), "64-bit signed/arithmetic {0} = {2} >> {1}", &.{ .register, .register, .word }),

                    .basic(.override("s_rshift8b"), "8-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                    .basic(.override("s_rshift16b"), "16-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                    .basic(.override("s_rshift32b"), "32-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                    .basic(.override("s_rshift64b"), "64-bit signed/arithmetic {0} = {1} >> {2}", &.{ .register, .register, .byte }),
                },
            ),
        },
    ),

    .category("Comparison",
        "Instructions that compare values",
        &.{
            .mnemonic("eq",
                "Performs an equality comparison on the provided values",
                &.{
                    .basic(.wrap("i", "8"), "8-bit integer {0} = {1} == {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("i", "16"), "16-bit integer {0} = {1} == {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("i", "32"), "32-bit integer {0} = {1} == {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("i", "64"), "64-bit integer {0} = {1} == {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("i", "8c"), "8-bit integer {0} = {1} == {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("i", "16c"), "16-bit integer {0} = {1} == {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("i", "32c"), "32-bit integer {0} = {1} == {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("i", "64c"), "64-bit integer {0} = {1} == {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("f", "32"), "32-bit floating point {0} = {1} == {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "64"), "64-bit floating point {0} = {1} == {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("f", "32c"), "32-bit floating point {0} = {1} == {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("f", "64c"), "64-bit floating point {0} = {1} == {2}", &.{ .register, .register, .word }),
                },
            ),
            .mnemonic("ne",
                "Performs an inequality comparison on the provided values",
                &.{
                    .basic(.wrap("i", "8"), "8-bit integer {0} = {1} != {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("i", "16"), "16-bit integer {0} = {1} != {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("i", "32"), "32-bit integer {0} = {1} != {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("i", "64"), "64-bit integer {0} = {1} != {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("i", "8c"), "8-bit integer {0} = {1} != {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("i", "16c"), "16-bit integer {0} = {1} != {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("i", "32c"), "32-bit integer {0} = {1} != {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("i", "64c"), "64-bit integer {0} = {1} != {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("f", "32"), "32-bit floating point {0} = {1} != {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "64"), "64-bit floating point {0} = {1} != {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("f", "32c"), "32-bit floating point {0} = {1} != {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("f", "64c"), "64-bit floating point {0} = {1} != {2}", &.{ .register, .register, .word }),
                },
            ),
            .mnemonic("lt",
                "Performs a less-than comparison on the provided values",
                &.{
                    .basic(.wrap("u", "8"), "8-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "16"), "16-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "32"), "32-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "64"), "64-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("u", "8a"), "8-bit unsigned integer {0} = {2} < {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16a"), "16-bit unsigned integer {0} = {2} < {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32a"), "32-bit unsigned integer {0} = {2} < {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64a"), "64-bit unsigned integer {0} = {2} < {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("u", "8b"), "8-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16b"), "16-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32b"), "32-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64b"), "64-bit unsigned integer {0} = {1} < {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8"), "8-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "16"), "16-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "32"), "32-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "64"), "64-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("s", "8a"), "8-bit signed integer {0} = {2} < {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16a"), "16-bit signed integer {0} = {2} < {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32a"), "32-bit signed integer {0} = {2} < {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64a"), "64-bit signed integer {0} = {2} < {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8b"), "8-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16b"), "16-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32b"), "32-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64b"), "64-bit signed integer {0} = {1} < {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("f", "32"), "32-bit floating point {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "32a"), "32-bit floating point {0} = {2} < {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("f", "32b"), "32-bit floating point {0} = {1} < {2}", &.{ .register, .register, .int }),

                    .basic(.wrap("f", "64"), "64-bit floating point {0} = {1} < {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "64a"), "64-bit floating point {0} = {2} < {1}", &.{ .register, .register, .word }),
                    .basic(.wrap("f", "64b"), "64-bit floating point {0} = {1} < {2}", &.{ .register, .register, .word }),
                },
            ),
            .mnemonic("gt",
                "Performs a greater-than comparison on the provided values",
                &.{
                    .basic(.wrap("u", "8"), "8-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "16"), "16-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "32"), "32-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "64"), "64-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("u", "8a"), "8-bit unsigned integer {0} = {2} > {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16a"), "16-bit unsigned integer {0} = {2} > {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32a"), "32-bit unsigned integer {0} = {2} > {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64a"), "64-bit unsigned integer {0} = {2} > {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("u", "8b"), "8-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16b"), "16-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32b"), "32-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64b"), "64-bit unsigned integer {0} = {1} > {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8"), "8-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "16"), "16-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "32"), "32-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "64"), "64-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("s", "8a"), "8-bit signed integer {0} = {2} > {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16a"), "16-bit signed integer {0} = {2} > {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32a"), "32-bit signed integer {0} = {2} > {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64a"), "64-bit signed integer {0} = {2} > {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8b"), "8-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16b"), "16-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32b"), "32-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64b"), "64-bit signed integer {0} = {1} > {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("f", "32"), "32-bit floating point {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "32a"), "32-bit floating point {0} = {2} > {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("f", "32b"), "32-bit floating point {0} = {1} > {2}", &.{ .register, .register, .int }),

                    .basic(.wrap("f", "64"), "64-bit floating point {0} = {1} > {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "64a"), "64-bit floating point {0} = {2} > {1}", &.{ .register, .register, .word }),
                    .basic(.wrap("f", "64b"), "64-bit floating point {0} = {1} > {2}", &.{ .register, .register, .word }),
                },
            ),
            .mnemonic("le",
                "Performs a less-than-or-equal comparison on the provided values",
                &.{
                    .basic(.wrap("u", "8"), "8-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "16"), "16-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "32"), "32-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "64"), "64-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("u", "8a"), "8-bit unsigned integer {0} = {2} <= {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16a"), "16-bit unsigned integer {0} = {2} <= {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32a"), "32-bit unsigned integer {0} = {2} <= {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64a"), "64-bit unsigned integer {0} = {2} <= {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("u", "8b"), "8-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16b"), "16-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32b"), "32-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64b"), "64-bit unsigned integer {0} = {1} <= {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8"), "8-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "16"), "16-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "32"), "32-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "64"), "64-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("s", "8a"), "8-bit signed integer {0} = {2} <= {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16a"), "16-bit signed integer {0} = {2} <= {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32a"), "32-bit signed integer {0} = {2} <= {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64a"), "64-bit signed integer {0} = {2} <= {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8b"), "8-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16b"), "16-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32b"), "32-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64b"), "64-bit signed integer {0} = {1} <= {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("f", "32"), "32-bit floating point {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "32a"), "32-bit floating point {0} = {2} <= {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("f", "32b"), "32-bit floating point {0} = {1} <= {2}", &.{ .register, .register, .int }),

                    .basic(.wrap("f", "64"), "64-bit floating point {0} = {1} <= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "64a"), "64-bit floating point {0} = {2} <= {1}", &.{ .register, .register, .word }),
                    .basic(.wrap("f", "64b"), "64-bit floating point {0} = {1} <= {2}", &.{ .register, .register, .word }),
                },
            ),
            .mnemonic("ge",
                "Performs a greater-than-or-equal comparison on the provided values",
                &.{
                    .basic(.wrap("u", "8"), "8-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "16"), "16-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "32"), "32-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "64"), "64-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("u", "8a"), "8-bit unsigned integer {0} = {2} >= {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16a"), "16-bit unsigned integer {0} = {2} >= {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32a"), "32-bit unsigned integer {0} = {2} >= {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64a"), "64-bit unsigned integer {0} = {2} >= {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("u", "8b"), "8-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16b"), "16-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32b"), "32-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64b"), "64-bit unsigned integer {0} = {1} >= {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8"), "8-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "16"), "16-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "32"), "32-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "64"), "64-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("s", "8a"), "8-bit signed integer {0} = {2} >= {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16a"), "16-bit signed integer {0} = {2} >= {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32a"), "32-bit signed integer {0} = {2} >= {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64a"), "64-bit signed integer {0} = {2} >= {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8b"), "8-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16b"), "16-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32b"), "32-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64b"), "64-bit signed integer {0} = {1} >= {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("f", "32"), "32-bit floating point {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "32a"), "32-bit floating point {0} = {2} >= {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("f", "32b"), "32-bit floating point {0} = {1} >= {2}", &.{ .register, .register, .int }),

                    .basic(.wrap("f", "64"), "64-bit floating point {0} = {1} >= {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("f", "64a"), "64-bit floating point {0} = {2} >= {1}", &.{ .register, .register, .word }),
                    .basic(.wrap("f", "64b"), "64-bit floating point {0} = {1} >= {2}", &.{ .register, .register, .word }),
                },
            ),
        },
    ),

    .category("Integer arithmetic",
        \\Instructions that perform integer arithmetic operations on values.
        \\Because we use two's compliment integers, the signedness of the operands does not affect all operations. Where it does, the mnemonic will be prefixed with "u" or "s", otherwise with "i".
        \\* Where the size is < 64-bits, the least significant bits of the input value(s) are used, and the remainder of the output value is zeroed
        , &.{
            .mnemonic("i_neg",
                \\Performs integer negation on the provided value.
                , &.{
                    .basic(.override("s_neg8"), "8-bit {0} = -{1}", &.{ .register, .register }),
                    .basic(.override("s_neg16"), "16-bit {0} = -{1}", &.{ .register, .register }),
                    .basic(.override("s_neg32"), "32-bit {0} = -{1}", &.{ .register, .register }),
                    .basic(.override("s_neg64"), "64-bit {0} = -{1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("i_abs",
                "Finds the absolute value of the provided value",
                &.{
                    .basic(.override("s_abs8"), "8-bit {0} = |{1}|", &.{ .register, .register }),
                    .basic(.override("s_abs16"), "16-bit {0} = |{1}|", &.{ .register, .register }),
                    .basic(.override("s_abs32"), "32-bit {0} = |{1}|", &.{ .register, .register }),
                    .basic(.override("s_abs64"), "64-bit {0} = |{1}|", &.{ .register, .register }),
                },
            ),

            .mnemonic("i_add",
                "Performs integer addition on the provided values.",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} + {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} + {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} + {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} + {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8c"), "8-bit {0} = {1} + {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16c"), "16-bit {0} = {1} + {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} + {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} + {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("i_sub",
                "Performs integer subtraction on the provided values.",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} - {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} - {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} - {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} - {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8a"), "8-bit {0} = {2} - {1}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16a"), "16-bit {0} = {2} - {1}", &.{ .register, .register, .short }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} - {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} - {1}", &.{ .register, .register, .word }),

                    .basic(.suffix("8b"), "8-bit {0} = {1} - {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16b"), "16-bit {0} = {1} - {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} - {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} - {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("i_mul",
                "Performs integer multiplication on the provided values.",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} * {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} * {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} * {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} * {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8c"), "8-bit {0} = {1} * {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16c"), "16-bit {0} = {1} * {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} * {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} * {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("i_div",
                "Performs integer division on the provided values.",
                &.{
                    .basic(.wrap("u", "8"), "8-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "16"), "16-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "32"), "32-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "64"), "64-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("u", "8a"), "8-bit unsigned {0} = {2} / {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16a"), "16-bit unsigned {0} = {2} / {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32a"), "32-bit unsigned {0} = {2} / {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64a"), "64-bit unsigned {0} = {2} / {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("u", "8b"), "8-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16b"), "16-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32b"), "32-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64b"), "64-bit unsigned {0} = {1} / {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8"), "8-bit signed {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "16"), "16-bit signed {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "32"), "32-bit signed {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "64"), "64-bit signed {0} = {1} / {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("s", "8a"), "8-bit signed {0} = {2} / {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16a"), "16-bit signed {0} = {2} / {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32a"), "32-bit signed {0} = {2} / {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64a"), "64-bit signed {0} = {2} / {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8b"), "8-bit signed {0} = {1} / {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16b"), "16-bit signed {0} = {1} / {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32b"), "32-bit signed {0} = {1} / {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64b"), "64-bit signed {0} = {1} / {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("i_rem",
                "Gets the remainder of integer division on the provided values.",
                &.{
                    .basic(.wrap("u", "8"), "8-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "16"), "16-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "32"), "32-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("u", "64"), "64-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("u", "8a"), "8-bit unsigned {0} = {2} % {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16a"), "16-bit unsigned {0} = {2} % {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32a"), "32-bit unsigned {0} = {2} % {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64a"), "64-bit unsigned {0} = {2} % {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("u", "8b"), "8-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("u", "16b"), "16-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("u", "32b"), "32-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("u", "64b"), "64-bit unsigned {0} = {1} % {2}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8"), "8-bit signed {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "16"), "16-bit signed {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "32"), "32-bit signed {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.wrap("s", "64"), "64-bit signed {0} = {1} % {2}", &.{ .register, .register, .register }),

                    .basic(.wrap("s", "8a"), "8-bit signed {0} = {2} % {1}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16a"), "16-bit signed {0} = {2} % {1}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32a"), "32-bit signed {0} = {2} % {1}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64a"), "64-bit signed {0} = {2} % {1}", &.{ .register, .register, .word }),

                    .basic(.wrap("s", "8b"), "8-bit signed {0} = {1} % {2}", &.{ .register, .register, .byte }),
                    .basic(.wrap("s", "16b"), "16-bit signed {0} = {1} % {2}", &.{ .register, .register, .short }),
                    .basic(.wrap("s", "32b"), "32-bit signed {0} = {1} % {2}", &.{ .register, .register, .int }),
                    .basic(.wrap("s", "64b"), "64-bit signed {0} = {1} % {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("i_pow",
                "Raises a provided value to the power of the other provided value.",
                &.{
                    .basic(.suffix("8"), "8-bit {0} = {1} ** {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("16"), "16-bit {0} = {1} ** {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32"), "32-bit {0} = {1} ** {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = {1} ** {2}", &.{ .register, .register, .register }),

                    .basic(.suffix("8a"), "8-bit {0} = {2} ** {1}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16a"), "16-bit {0} = {2} ** {1}", &.{ .register, .register, .short }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} ** {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} ** {1}", &.{ .register, .register, .word }),

                    .basic(.suffix("8b"), "8-bit {0} = {1} ** {2}", &.{ .register, .register, .byte }),
                    .basic(.suffix("16b"), "16-bit {0} = {1} ** {2}", &.{ .register, .register, .short }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} ** {2}", &.{ .register, .register, .int }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} ** {2}", &.{ .register, .register, .word }),
                },
            ),
        },
    ),

    .category("Floating point arithmetic",
        \\Instructions that perform floating point arithmetic operations on values.
        \\* Where the size is < 64-bits, the least significant bits of the input value(s) are used and the remainder of the output value is zeroed
        , &.{
            .mnemonic("f_neg",
                "Performs floating point negation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = -{1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = -{1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_abs",
                "Performs a floating point absolute value operation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = |{1}|", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = |{1}|", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_sqrt",
                "Performs a square root operation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *sqrt* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *sqrt* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_floor",
                "Performs a flooring operation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *floor* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *floor* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_ceil",
                "Performs a ceiling operation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *ceiling* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *ceiling* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_round",
                "Performs a rounding operation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *round* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *round* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_trunc",
                "Performs a truncation operation on the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *truncate* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *truncate* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_man",
                "Extracts the mantissa part of the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *man* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *man* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_frac",
                "Extracts the fractional part of the provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = *frac* {1}", &.{ .register, .register }),
                    .basic(.suffix("64"), "64-bit {0} = *frac* {1}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_add",
                "Performs floating point addition on the provided values",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = {1} + {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} + {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("64"), "64-bit {0} = {1} + {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} + {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("f_sub",
                "Performs floating point subtraction on the provided values",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = {1} - {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} - {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} - {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("64"), "64-bit {0} = {1} - {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} - {1}", &.{ .register, .register, .word }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} - {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("f_mul",
                "Performs floating point multiplication on the provided values",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = {1} * {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32c"), "32-bit {0} = {1} * {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("64"), "64-bit {0} = {1} * {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64c"), "64-bit {0} = {1} * {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("f_div",
                "Performs floating point division on the provided values",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} / {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} / {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("64"), "64-bit {0} = {1} / {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} / {1}", &.{ .register, .register, .word }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} / {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("f_rem",
                "Gets the remainder of floating point division on the provided values",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} % {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} % {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("64"), "64-bit {0} = {1} % {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} % {1}", &.{ .register, .register, .word }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} % {2}", &.{ .register, .register, .word }),
                },
            ),

            .mnemonic("f_pow",
                "Raises a provided value to the power of the other provided value",
                &.{
                    .basic(.suffix("32"), "32-bit {0} = {1} ** {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("32a"), "32-bit {0} = {2} ** {1}", &.{ .register, .register, .int }),
                    .basic(.suffix("32b"), "32-bit {0} = {1} ** {2}", &.{ .register, .register, .int }),

                    .basic(.suffix("64"), "64-bit {0} = {1} ** {2}", &.{ .register, .register, .register }),
                    .basic(.suffix("64a"), "64-bit {0} = {2} ** {1}", &.{ .register, .register, .word }),
                    .basic(.suffix("64b"), "64-bit {0} = {1} ** {2}", &.{ .register, .register, .word }),
                },
            ),
        },
    ),

    .category("Value conversion",
        "Instructions that convert values between different bit representations",
        &.{
            // u_ext is not necessary since the default behavior when moving a value into a larger register is to zero extend.

            .mnemonic("s_ext",
                "Signed bit extension",
                &.{
                    .basic(.suffix("8_16"), "Sign extend 8-bits of {1} to 16-bits, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("8_32"), "Sign extend 8-bits of {1} to 32-bits, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("8_64"), "Sign extend 8-bits of {1} to 64-bits, placing the result in {0}", &.{ .register, .register }),

                    .basic(.suffix("16_32"), "Sign extend 16-bits of {1} to 32-bits, placing the result in {0}", &.{ .register, .register }),
                    .basic(.suffix("16_64"), "Sign extend 16-bits of {1} to 64-bits, placing the result in {0}", &.{ .register, .register }),

                    .basic(.suffix("32_64"), "Sign extend 32-bits of {1} to 64-bits, placing the result in {0}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_to_i",
                "Convert floats to various integer representations.",
                &.{
                    .basic(.override("f32_to_u8"), "Convert of 32-bit float in {1} to 8-bit integer; discards sign, places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f32_to_u16"), "Convert of 32-bit float in {1} to 16-bit integer; discards sign, places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f32_to_u32"), "Convert of 32-bit float in {1} to 32-bit integer; discards sign, places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f32_to_u64"), "Convert of 32-bit float in {1} to 64-bit integer; discards sign, places the result in {0}", &.{ .register, .register }),

                    .basic(.override("f32_to_s8"), "Convert of 32-bit float in {1} to 8-bit integer; keeps sign, places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f32_to_s16"), "Convert of 32-bit float in {1} to 16-bit integer; keeps sign, places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f32_to_s32"), "Convert of 32-bit float in {1} to 32-bit integer; keeps sign, places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f32_to_s64"), "Convert of 32-bit float in {1} to 64-bit integer; keeps sign, places the result in {0}", &.{ .register, .register }),
                },
            ),

            .mnemonic("i_to_f",
                \\Convert various integers to float representations.
                \\* Information loss is possible if the integer's most significant bit index is larger than the float's mantissa bit size
                , &.{
                    .basic(.override("u8_to_f32"), "Convert 8-bits in {1} to 32-bit float; discards sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("u16_to_f32"), "Convert 16-bits in {1} to 32-bit float; discards sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("u32_to_f32"), "Convert 32-bits in {1} to 32-bit float; discards sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("u64_to_f32"), "Convert 64-bits in {1} to 32-bit float; discards sign, places result in {0}", &.{ .register, .register }),

                    .basic(.override("s8_to_f32"), "Convert 8-bits in {1} to 32-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("s16_to_f32"), "Convert 16-bits in {1} to 32-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("s32_to_f32"), "Convert 32-bits in {1} to 32-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("s64_to_f32"), "Convert 64-bits in {1} to 32-bit float; keeps sign, places result in {0}", &.{ .register, .register }),

                    .basic(.override("u8_to_f64"), "Convert 8-bits in {1} to 64-bit float; discards sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("u16_to_f64"), "Convert 16-bits in {1} to 64-bit float; discards sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("u32_to_f64"), "Convert 32-bits in {1} to 64-bit float; discards sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("u64_to_f64"), "Convert 64-bits in {1} to 64-bit float; discards sign, places result in {0}", &.{ .register, .register }),

                    .basic(.override("s8_to_f64"), "Convert 8-bits in {1} to 64-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("s16_to_f64"), "Convert 16-bits in {1} to 64-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("s32_to_f64"), "Convert 32-bits in {1} to 64-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                    .basic(.override("s64_to_f64"), "Convert 64-bits in {1} to 64-bit float; keeps sign, places result in {0}", &.{ .register, .register }),
                },
            ),

            .mnemonic("f_to_f",
                "Floating point to floating point conversion",
                &.{
                    .basic(.override("f32_to_f64"), "Convert 32-bit float in {1} to 64-bit float; places the result in {0}", &.{ .register, .register }),
                    .basic(.override("f64_to_f32"), "Convert 64-bit float in {1} to 32-bit float; places the result in {0}", &.{ .register, .register }),
                },
            ),
        },
    ),
};
