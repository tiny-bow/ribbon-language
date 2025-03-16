const abi = @import("abi");
const assembler = @import("assembler");
const core = @import("core");
const gen = @This();
const isa = @import("isa");
const pl = @import("platform");
const std = @import("std");

const log = std.log.scoped(.@"gen");

const OutputTypes = enum {
    markdown,
    types,
    assembly,
};

const OUTPUT_NAMES = std.meta.fieldNames(OutputTypes);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    if (args.len != 3) {
        std.debug.print(
            \\Usage: {s} <type> <path>
            \\* path: output file path
            \\* type: one of {s}
            , .{args[0], OUTPUT_NAMES} ,
        );
        return error.InvalidArgCount;
    }

    const output = inline for (OUTPUT_NAMES) |name| {
        if (std.mem.eql(u8, args[1], name)) {
            break @field(OutputTypes, name);
        }
    } else {
        log.err("Invalid output type `{s}`; expected one of `markdown`, `types`, `assembly`", .{ args[1] });
        return error.InvalidArg;
    };

    switch (output) {
        .markdown => {
            const file = try std.fs.cwd().createFile(args[2], .{});
            defer file.close();

            try generateMarkdown(isa.CATEGORIES, file.writer());
        },

        .types => {
            const file = try std.fs.cwd().createFile(args[2], .{});
            defer file.close();

            try generateTypes(isa.CATEGORIES, file.writer());
        },

        .assembly => {
            const file = try std.fs.cwd().createFile(args[2], .{});
            defer file.close();

            try generateHeaderAssembly(false, file.writer());
            try generateMainAssembly(isa.CATEGORIES, allocator, file.writer());
        },
    }
}


const InstrBlock = []const []const u8;

fn parseInstructionsFile(allocator: std.mem.Allocator, text: []const u8) !std.StringHashMap(InstrBlock) {
    // split file into non-empty lines, then, in a loop:
    // find first line with no leading whitespace
    // parse first line to title by looking backwards from the end of the line;
    // ensure there is a `:` at the end of the line; if not, discard this block and continue (its likely a macro we dont need in the generated code)
    // consume all lines with leading whitespace into block

    var lines = std.mem.splitScalar(u8, text, '\n');

    var blocks = std.StringHashMap(InstrBlock).init(allocator);

    var blockLines = std.ArrayList([]const u8).init(allocator);

    var inBlock = false;

    var l: usize = 0;
    while (lines.next()) |line| {
        l += 1;

        if (std.mem.eql(u8, line, "")) {
            continue;
        }

        if (line[0] != ' ' and line[0] != '\t') {
            if (!inBlock) continue;

            if (line[line.len - 1] != ':') {
                std.debug.panic("unexpected source line at {}; it should end with `:`, or be indented under such a line", .{ l });
            }

            const name = line[0..line.len - 1];

            if (inBlock) {
                const block = try blockLines.toOwnedSlice();
                try blocks.put(name, block);
            }

            inBlock = true;
        } else if (inBlock) {
            try blockLines.append(std.mem.trimLeft(u8, line, " \t"));
        } else {
            continue;
        }
    }

    return blocks;
}


// Assembly generation
fn generateHeaderAssembly(includeStandins: bool, writer: anytype) !void {
    try writer.print("%define OP_SIZE 0x{x}\n", .{ pl.OPCODE_SIZE });

    inline for (comptime std.meta.fieldNames(core.mem.FiberHeader)) |fieldName| {
        const baseOffset = @offsetOf(core.mem.FiberHeader, fieldName);

        // Because the `Stack` structure has its top_ptr at the beginning of its data,
        // we can just use the stack's offset as the top_ptr offset, which is all we need.
        try writer.print("%define Fiber.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.CallFrame)) |fieldName| {
        const baseOffset = @offsetOf(core.CallFrame, fieldName);

        try writer.print("%define CallFrame.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.BuiltinSignal)) |fieldName| {
        const d = @field(core.BuiltinSignal, fieldName);

        try writer.print("%define BuiltinSignal.{s} 0x{x}\n", .{ fieldName, @as(u64, @bitCast(@intFromEnum(d))) });
    }

    try writer.writeAll("\n");

    const registers = comptime std.meta.declarations(abi);

    inline for (registers, 0..) |decl, i| {
        const d = @field(abi, decl.name);
        const T = @TypeOf(d);

        if (comptime T == assembler.Register) {
            try writer.print("%define {s} {s}\n", .{ decl.name, @tagName(d) });

            inline for (comptime &.{.{"int", 32}, .{"short", 16}, .{"byte", 8}}) |sub| {
                try writer.print("%define {s}_{s} {s}\n", .{ decl.name, sub[0], @tagName(d.toBitSize(sub[1])) });
            }
        } else {
            continue;
        }

        if (i < registers.len - 1) {
            try writer.writeAll("\n");
        }
    }


    try writer.writeAll(
        \\
        \\%define BUILTIN_SIGNAL rax
        \\
        \\%macro PRELUDE 1
        \\    mov FIBER, AUX1
        \\    mov VREG, [FIBER + Fiber.registers]
        \\    mov FRAME, [FIBER + Fiber.calls]
        \\    mov qword [FIBER + Fiber.loop], %1
        \\    mov IP, [FRAME + CallFrame.ip]
        \\%endmacro
        \\
        \\%macro ENTRY_POINT 2
        \\section .text
        \\global %1
        \\
        \\%1:
        \\    PRELUDE %2
        \\    jmp R_DECODE
        \\%endmacro
        \\
        \\%macro EXIT 1
        \\    mov BUILTIN_SIGNAL, %1
        \\    ret
        \\%endmacro
        \\
        \\%define TODO EXIT BuiltinSignal.request_trap
        \\
        \\%macro mem2mem 2
        \\    mov ACC, %2
        \\    mov %1, ACC
        \\%endmacro
        \\
        \\%define DISPATCH jmp qword [FIBER + Fiber.loop]
        \\
    );

    if (includeStandins) {
        try writer.writeAll(
            \\
            \\%ifndef R_JUMP_TABLE
            \\%define R_JUMP_TABLE rax
            \\%define R_JUMP_TABLE_LENGTH rax
            \\%define R_EXIT_OKAY rax
            \\%define R_EXIT_HALT rax
            \\%define R_TRAP_BAD_ENCODING rax
            \\%define R_TRAP_OVERFLOW rax
            \\%define R_TRAP_REQUESTED rax
            \\%define R_DECODE rax
            \\%define R_DISPATCH rax
            \\%endif
            \\
        );
    }
}

fn generateMainAssembly(categories: []const isa.Category, allocator: std.mem.Allocator, writer: anytype) !void {
    try generateAssemblyJumpTable(categories, writer);
    try generateAssemblyIntro(writer);

    const implsSrc = try std.fs.cwd().readFileAlloc(allocator, "src/gen-base/x64/instructions.asm", std.math.maxInt(usize));
    const impls = try parseInstructionsFile(allocator, implsSrc);
    try generateAssemblyBody(categories, &impls, writer);
}

fn generateAssemblyIntro(writer: anytype) !void {
    const entries = try std.fs.cwd().openFile("src/gen-base/x64/entry_points.asm", .{});
    defer entries.close();

    const reader = entries.reader();

    try pl.stream(reader, writer);
}

fn generateAssemblyBody(categories: []const isa.Category, impls: *const std.StringHashMap(InstrBlock), writer: anytype) !void {
    try writer.writeAll("\nsection .text\n\n");

    var opcode: u16 = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                try writer.writeAll("\n");

                try writer.writeAll("R_");
                var nameBuf: [256]u8 = undefined;
                var stream = std.io.fixedBufferStream(&nameBuf);
                const nameWriter = stream.writer();
                try isa.formatInstructionName(mnemonic.name, instruction.name, nameWriter);
                const name = stream.getWritten();

                if (impls.get(name)) |block| {
                    try writer.print("{s}:\n", .{ name });
                    for (block) |line| {
                        try writer.writeAll(line);
                        try writer.writeAll("\n");
                    }
                    try writer.writeAll("\n\n");
                } else {
                    try writer.print("{s}: TODO\n\n", .{name});
                }

                opcode += 1;
            }
        }
    }

    try writer.writeAll("\n\n\n");
}

fn generateAssemblyJumpTable(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\%define R_JUMP_TABLE rvm_interpreter_jump_table
        \\%define R_JUMP_TABLE_LENGTH rvm_interpreter_jump_table_length
        \\
        \\section .rodata
        \\align 8
        \\global R_JUMP_TABLE
        \\global R_JUMP_TABLE_LENGTH
        \\R_JUMP_TABLE: dq
    );

    var opcode: u16 = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                if (opcode != 0) {
                    try writer.writeAll(", ");
                } else {
                    try writer.writeAll(" ");
                }

                try writer.writeAll("R_");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);

                opcode += 1;
            }
        }
    }

    try writer.print("\nR_JUMP_TABLE_LENGTH equ 0x{x} ; {d}\n\n\n", .{opcode, opcode});
}



// Types generation

fn generateTypes(categories: []const isa.Category, writer: anytype) !void {
    try generateTypesIntro(writer);

    try writer.writeAll(
        \\    /// discriminator for instruction identity
        \\    code: OpCode,
        \\    /// operand set for the instruction
        \\    data: OpData,
        \\
        \\
    );

    try generateTypesCodes(categories, writer);
    try generateTypesData(categories, writer);
    try generateTypesUnion(categories, writer);
    try generateTypesBasicAndTerm(categories, writer);
}

fn generateTypesIntro(writer: anytype) !void {
    try paste("generateTypes", "", "//", "//", "src/gen-base/zig/Instruction_intro.zig", writer);
}

fn generateTypesCodes(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Enumeration identifying each instruction.
        \\pub const OpCode = enum(u16) {
        \\
    );

    var opcode: u16 = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                try writer.writeAll("    @\"");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("\" = 0x");
                try formatOpcode(opcode, writer);
                try writer.writeAll(",\n");

                opcode += 1;
            }
        }
    }

    try writer.writeAll("};\n\n");
}

fn generateTypesZigDoc(mnemonic: []const u8, opcode: u16, instr: isa.Instruction, writer: anytype) !void {
    try writer.writeAll("    /// `");
    try formatOpcode(opcode, writer);
    try writer.writeAll("`\n");

    try formatInstructionDescription("    /// ", false, instr.description, instr.operands, writer);
    try writer.writeAll("; `");
    try formatOpcode(opcode, writer);
    try formatInstructionOperands(mnemonic, instr.name, instr.operands, writer);
    try writer.writeAll("`\n");
}

fn generateTypesData(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Like `Instruction`, but specialized to instructions that can occur inside a basic block.
        \\pub const Basic = struct {
        \\    /// discriminator for instruction identity
        \\    code: BasicOpCode,
        \\    /// operand set for the instruction
        \\    data: BasicOpData,
        \\};
        \\
        \\/// Like `Instruction`, but specialized to instructions that can terminate a basic block.
        \\pub const Term = struct {
        \\    /// discriminator for instruction identity
        \\    code: TermOpCode,
        \\    /// operand set for the instruction
        \\    data: TermOpData,
        \\};
        \\
        \\
    );

    try writer.writeAll(
        \\/// Namespace of operand set types for each instruction.
        \\pub const operand_sets = struct {
        \\
    );

    var opcode: u16 = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                try writer.writeAll("    pub const @\"");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("\" = packed struct { ");

                for (instruction.operands, 0..) |operand, i| {
                    _ = try isa.formatOperand(i, instruction.operands, writer);
                    try writer.writeAll(": ");
                    try writer.writeAll(switch (operand) {
                        .register => "core.Register",
                        .constant => "Id.of(core.Constant)",
                        .function => "Id.of(core.Function)",
                        .global => "Id.of(core.Global)",
                        .upvalue => "Id.of(core.Upvalue)",
                        .handler_set => "Id.of(core.HandlerSet)",
                        .builtin => "Id.of(core.BuiltinAddress)",
                        .effect => "Id.of(core.Effect)",
                        .foreign => "Id.of(core.ForeignAddress)",
                    });
                    try writer.writeAll(", ");
                }

                try writer.writeAll("};\n\n");

                opcode += 1;
            }
        }
    }
    try writer.writeAll("};\n\n");
}

fn generateTypesUnion(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Untagged union of all `operand_sets` types.
        \\pub const OpData = packed union {
        \\
    );

    var opcode: u16 = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                try writer.writeAll("    @\"");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("\": operand_sets.@\"");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("\",\n");

                opcode += 1;
            }
        }
    }
    try writer.writeAll("};\n\n");
}

fn generateTypesBasicAndTerm(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Enumeration identifying each instruction that can appear inside a basic block.
        \\pub const BasicOpCode = enum(u16) {
        \\
    );

    var opcode: u16 = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                if (!instruction.terminal) {
                    try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                    try writer.writeAll("    @\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\" = 0x");
                    try formatOpcode(opcode, writer);
                    try writer.writeAll(",\n");
                }

                opcode += 1;
            }
        }
    }

    try writer.writeAll("};\n\n");

    try writer.writeAll(
        \\/// Enumeration identifying each instruction that can terminate a basic block.
        \\pub const TermOpCode = enum(u16) {
        \\
    );

    opcode = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                if (instruction.terminal) {
                    try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                    try writer.writeAll("    @\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\" = 0x");
                    try formatOpcode(opcode, writer);
                    try writer.writeAll(",\n");
                }

                opcode += 1;
            }
        }
    }

    try writer.writeAll("};\n\n");

    try writer.writeAll(
        \\/// Untagged union of all `operand_sets` types that can appear in a basic block.
        \\pub const BasicOpData = packed union {
        \\
    );

    opcode = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                if (!instruction.terminal) {
                    try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                    try writer.writeAll("    @\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\": operand_sets.@\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\",\n");
                }

                opcode += 1;
            }
        }
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll(
        \\/// Untagged union of all `operand_sets` types that can terminate a basic block.
        \\pub const TermOpData = packed union {
        \\
    );

    opcode = 0;
    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            for (mnemonic.instructions) |instruction| {
                if (instruction.terminal) {
                    try generateTypesZigDoc(mnemonic.name, opcode, instruction, writer);

                    try writer.writeAll("    @\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\": operand_sets.@\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\",\n");
                }

                opcode += 1;
            }
        }
    }
    try writer.writeAll("};\n\n");
}

// Markdown generation

fn generateMarkdown(categories: []const isa.Category, writer: anytype) !void {
    try generateMarkdownIntro(writer);
    try generateMarkdownSyntax(writer);
    try generateMarkdownBody(categories, writer);
}

fn generateMarkdownIntro(writer: anytype) !void {
    var headerBuf: [1024]u8 = undefined;

    var stream = std.io.fixedBufferStream(&headerBuf);

    const headerWriter = stream.writer();

    try headerWriter.print(
        \\# Ribbon ISA v{}.{}.{}
        , .{ isa.VERSION.major, isa.VERSION.minor, isa.VERSION.patch },
    );


    if (isa.VERSION.pre) |pre| {
        try headerWriter.print(" <sub><code>{s}</code></sub>", .{ pre });

        if (isa.VERSION.build) |build| {
            try headerWriter.print("\n<sub>build</sub> <code>{s}</code>", .{ build });
        }
    }

    try headerWriter.writeAll(
        \\
        \\- [Syntax](#syntax)
        \\- [Instructions](#instructions)
        \\
    );

    try paste("generateMarkdown", stream.getWritten(), "<!--", "-->", "src/gen-base/markdown/Isa_intro.md", writer);
}

fn generateMarkdownInstructionToc(categories: []const isa.Category, writer: anytype) !void {
    for (categories) |category| {
        try writer.writeAll("- ");
        try writeLink(category.name, writer);
        try writer.writeAll("\n");
        for (category.mnemonics) |mnemonic| {
            try writer.writeAll("    + ");
            try writeLink(mnemonic.name, writer);
            try writer.writeAll("\n");
        }
    }

    try writer.writeAll("\n\n\n");
}

fn generateMarkdownSyntax(writer: anytype) !void {
    try writer.writeAll(
        \\
        \\
        \\#### Operand Types
        \\| Type | Shortcode | Size |
        \\|-|-|-|
        \\
    );

    inline for (comptime std.meta.fieldNames(isa.Operand)) |fieldName| {
        const operand = @field(isa.Operand, fieldName);

        try writer.writeAll("| ");
        try operand.writeContextualReference(writer);
        try writer.writeAll(" | `");
        try operand.writeShortcode(writer);
        try writer.print("` | {d} bits |\n", .{ operand.sizeOf() * 8 });
    }

    try writer.writeAll("\n\n\n");
}

fn averageMnemonicInstructions(categories: []const isa.Category) f64 {
    var total: f64 = 0;
    var mnemonicsCount: f64 = 0;

    for (categories) |category| {
        mnemonicsCount += @floatFromInt(category.mnemonics.len);

        for (category.mnemonics) |mnemonic| {
            total += @floatFromInt(mnemonic.instructions.len);
        }
    }

    return total / mnemonicsCount;
}

fn countInstructions(categories: []const isa.Category) usize {
    var count: usize = 0;

    for (categories) |category| {
        for (category.mnemonics) |mnemonic| {
            count += mnemonic.instructions.len;
        }
    }

    return count;
}

fn countMnemonics(categories: []const isa.Category) usize {
    var count: usize = 0;

    for (categories) |category| {
        count += category.mnemonics.len;
    }

    return count;
}

fn generateMarkdownBody(categories: []const isa.Category, writer: anytype) !void {
    try writer.print(
        \\## Instructions
        \\There are `{d}` categories.
        \\Separated into those categories, there are a total of `{}` mnemonics.
        \\With an average of `{d}` instructions per mnemonic,
        \\we have a grand total of `{}` unique instructions.
        \\
        \\
        , .{ categories.len, countMnemonics(categories), averageMnemonicInstructions(categories), countInstructions(categories) },
    );

    try generateMarkdownInstructionToc(categories, writer);

    var opcode: u16 = 0;
    for (categories) |category| {
        try writer.print("### {s}\n\n", .{ category.name });

        try formatMnemonicDescription(null, false, category.description, writer);

        for (category.mnemonics) |mnemonic| {
            try writer.print("#### {s}\n\n", .{ mnemonic.name });

            try formatMnemonicDescription(null, false, mnemonic.description, writer);

            try writer.writeAll("| Name | Encoding | Description |\n|-|-|-|\n");

            for (mnemonic.instructions) |instruction| {
                try writer.writeAll("| ");

                if (instruction.jit_only) {
                    try writer.writeAll("<em style=\"float: right\">jit</em><br>");
                }

                try writer.writeByte('`');
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeByte('`');

                try writer.writeAll(" | `");
                try formatOpcode(opcode, writer);
                try formatInstructionOperands(mnemonic.name, instruction.name, instruction.operands, writer);
                try writer.writeAll("` | ");

                try formatInstructionDescription(null, true, instruction.description, instruction.operands, writer);

                try writer.writeAll(" |\n");

                opcode += 1;
            }

            try writer.writeAll("\n");
        }
    }
}

// Generalized isa formatting

fn formatOpcode(code: u16, writer: anytype) !void {
    try std.fmt.formatInt(code, 16, .lower, .{ .alignment = .right, .width = 4, .fill = '0' }, writer);
}

fn formatInstructionArgument(argument: []const u8, operands: []const isa.Operand, writer: anytype) !bool {
    if (try formatMnemonicArgument(argument, writer)) {
        return true;
    }

    if (std.fmt.parseInt(usize, argument, 10)) |operandIndex| {
        if (operandIndex > operands.len) {
            return error.InvalidOperandIndex;
        }


        try writer.writeByte('`');
        _ = try isa.formatOperand(operandIndex, operands, writer);
        try writer.writeByte('`');

        return true;
    } else |_| {
        return false;
    }
}

fn formatInstructionOperands(mnemonic: []const u8, instr: isa.InstructionName, operands: []const isa.Operand, writer: anytype) !void {
    var size: usize = 2;

    for (operands) |operand| {
        size += operand.sizeOf();
    }

    if (size > 8) {
        log.warn("Instruction {s}/{} is {} bytes in size", .{ mnemonic, instr, size });
    }

    if (operands.len != 0) {
        for (operands, 0..) |operand, i| {
            const requiredChars = operand.sizeOf() * 2;
            const writtenChars = try isa.formatOperand(i, operands, writer);

            if (requiredChars > writtenChars) {
                try writer.writeBytesNTimes("_", requiredChars - writtenChars);
            }
        }
    }

    // try writer.writeBytesNTimes("00", 8 - size);
}

fn formatMnemonicArgument(argument: []const u8, writer: anytype) !bool {
    if (std.mem.startsWith(u8, argument, ".")) {
        const arg = argument[1..];

        inline for (comptime std.meta.fieldNames(isa.Operand)) |fieldName| {
            if (std.mem.eql(u8, arg, fieldName)) {
                try @field(isa.Operand, fieldName).writeContextualReference(writer);

                return true;
            }
        }

        if (@inComptime()) {
            @compileLog("unknown arg", argument);
        } else {
            log.err("unknown arg: `{s}`", .{ argument });
        }

        return error.InvalidMnemonicArg;
    } else {
        return false;
    }
}

fn formatMnemonicDescription(linePrefix: ?[]const u8, sanitizeBreak: bool, formatString: []const u8, writer: anytype) !void {
    try formatDescriptionWith(linePrefix, sanitizeBreak, formatString, writer, struct {
        pub const formatArgument = formatMnemonicArgument;
    });

    try writer.writeAll("\n\n");
}

fn formatInstructionDescription(linePrefix: ?[]const u8, sanitizeBreak: bool, description: []const u8, operands: []const isa.Operand, writer: anytype) !void {
    const Ctx = struct {
        operands: []const isa.Operand,

        pub fn formatArgument(self: @This(), argument: []const u8, f: anytype) !bool {
            return formatInstructionArgument(argument, self.operands, f);
        }
    };

    return formatDescriptionWith(linePrefix, sanitizeBreak, description, writer, Ctx { .operands = operands });
}

fn formatDescriptionWith(linePrefix: ?[]const u8, sanitizeBreak: bool, formatString: []const u8, writer: anytype, ctx: anytype) !void {
    var i: usize = 0;

    if (linePrefix) |pfx| {
        try writer.writeAll(pfx);
    }

    while (i < formatString.len) {
        const ch = formatString[i];

        i += 1;

        if (ch == '{') {
            const argStart = i;

            const argEnd = while (i < formatString.len) {
                const ch2 = formatString[i];
                if (ch2 == '}') {
                    break i;
                }
                i += 1;
            } else {
                if (@inComptime()) {
                    @compileLog("UnclosedFormatArgument", formatString, argStart);
                } else {
                    log.err("Unclosed format argument `{s}` in `{s}`", .{ formatString[argStart..], formatString });
                }
                return error.UnclosedFormatArgument;
            };

            const arg: []const u8 = formatString[argStart..argEnd];

            if (try ctx.formatArgument(arg, writer)) {
                i += 1; // Move past the closing brace
                continue;
            } else {
                if (@inComptime()) {
                    @compileLog("unknown arg", arg, argStart, argEnd);
                } else {
                    log.err("unknown arg: `{s}`", .{ arg });
                }
                return error.UnknownArg;
            }
        } else if (ch == '\n') {
            if (sanitizeBreak) {
                try writer.writeAll("<br>");
            } else {
                try writer.writeByte('\n');
            }

            if (linePrefix) |pfx| {
                try writer.writeAll(pfx);
            }
        } else if (ch == '|') {
            try writer.writeAll("\\|");
        } else {
            try writer.writeByte(ch);
        }
    }
}

// utility text functions

fn writeKebab(name: []const u8, writer: anytype) !void {
    var i: usize = 0;
    while (i < name.len) {
        const ch = name[i];
        if (ch == ' ') {
            try writer.writeByte('-');
        } else {
            try writer.writeByte(std.ascii.toLower(ch));
        }
        i += 1;
    }
}

fn writeLink(name: []const u8, writer: anytype) !void {
    try writer.print("[{s}](#", .{ name });
    try writeKebab(name, writer);
    try writer.writeByte(')');
}

fn paste(generatorName: []const u8, header: []const u8, commentPre: []const u8, commentPost: []const u8, path: []const u8, writer: anytype) !void {
    const genBase = try std.fs.cwd().openFile(path, .{});
    defer genBase.close();

    const reader = genBase.reader();

    try writer.print(
        \\{s} This file is generated by `bin/tools/codegen.zig`, do not edit {s}
        \\{s} See `{s}` for the template; `codegen.zig/#{s}` for the generator {s}
        \\
        \\{s}
        , .{
            commentPre,
            commentPost,
            commentPre,
            path,
            generatorName,
            commentPost,
            header,
        },
    );

    // the templates have a small disclaimer comment at the top, skip it.
    for (0..3) |_| try reader.skipUntilDelimiterOrEof('\n');

    try pl.stream(reader, writer);

    try writer.writeAll("\n");
}
