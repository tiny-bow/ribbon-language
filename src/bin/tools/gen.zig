const abi = @import("abi");
const assembler = @import("assembler");
const core = @import("core");
const gen = @This();
const isa = @import("isa");
const pl = @import("platform");
const std = @import("std");

const log = std.log.scoped(.@"gen");

pub const std_options = std.Options {
    .log_level = .info,
};

const OutputTypes = enum {
    markdown,
    types,
    assembly,
    assembly_header,
    assembly_template,
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

        else => {
            log.info("Output type `{s}` is deprecated", .{@tagName(output)});
            std.process.exit(1);
        },

        // .assembly => {
        //     const file = try std.fs.cwd().createFile(args[2], .{});
        //     defer file.close();

        //     try generateHeaderAssembly(false, file.writer());
        //     try generateMainAssembly(isa.CATEGORIES, allocator, file.writer());
        // },

        // .assembly_header => {
        //     const file = try std.fs.cwd().createFile(args[2], .{});
        //     defer file.close();

        //     try generateHeaderAssembly(true, file.writer());
        // },

        // .assembly_template => {
        //     const file = try std.fs.cwd().createFile(args[2], .{});
        //     defer file.close();

        //     try generateAssemblyTemplate(isa.CATEGORIES, file.writer());
        // },
    }
}



// Assembly generation

const InstrDef = struct {
    name: []const u8,
    line_origin: usize,
    block: []const []const u8,

    fn dumpDefs(defs: *const std.StringArrayHashMap(InstrDef)) void {
        std.debug.print("defs found: {}\n", .{defs.count()});
        for (defs.values()) |def| {
            std.debug.print("    `{s}` at line {d}\n", .{ def.name, def.line_origin });
        }
    }

    fn validate(defs: *const std.StringArrayHashMap(InstrDef), categories: []const isa.Category) !void {
        var buf: [1024]u8 = undefined;
        for (categories) |*category| {
            for (category.mnemonics) |*mnemonics| {
                for (mnemonics.instructions) |*instruction| {
                    var stream = std.io.fixedBufferStream(&buf);
                    const writer = stream.writer();
                    try isa.formatInstructionName(mnemonics.name, instruction.name, writer);

                    const instrName = stream.getWritten();

                    if (!defs.contains(instrName)) {
                        std.debug.print("Error [instructions.asm]: Missing bytecode instruction `{s}`\n", .{ instrName });

                        dumpDefs(defs);

                        std.process.exit(1);
                    }
                }
            }
        }

        var opcode: u16 = 0;
        for (defs.values()) |def| {
            try def.validateTitle(opcode, categories);
            opcode += 1;
        }
    }

    fn validateTitle(self: InstrDef, opcode: u16, categories: []const isa.Category) !void {
        var buf: [1024]u8 = undefined;

        var expectedOpcode: u16 = 0;

        for (categories) |*category| {
            for (category.mnemonics) |*mnemonics| {
                for (mnemonics.instructions) |*instruction| {
                    var stream = std.io.fixedBufferStream(&buf);
                    const writer = stream.writer();

                    try isa.formatInstructionName(mnemonics.name, instruction.name, writer);

                    const instrName = stream.getWritten();

                    if (std.mem.eql(u8, self.name, instrName)) {
                        if (opcode != expectedOpcode) {
                            std.debug.print("Error [instructions.asm:{}]: Instruction `{s}` has unexpected index {d}; expected {d}\n", .{ self.line_origin, self.name, opcode, expectedOpcode });
                            std.process.exit(1);
                        }

                        return;
                    }

                    expectedOpcode += 1;
                }
            }
        }

        std.debug.print("Error [instructions.asm:{}]: Invalid bytecode instruction name `{s}`", .{ self.line_origin, self.name });
        std.process.exit(1);
    }
};


fn parseInstructionsFile(allocator: std.mem.Allocator, categories: []const isa.Category, text: []const u8) !std.StringArrayHashMap(InstrDef) {
    // split file into non-empty lines, then, in a loop:
    // find first line with no leading whitespace
    // parse first line to title by looking backwards from the end of the line;
    // ensure there is a `:` at the end of the line; if not, discard this block and continue
    // (its likely a macro we don't need in the generated code)
    // consume all lines with leading whitespace into block

    var lines = std.mem.splitScalar(u8, text, '\n');

    var defs = std.StringArrayHashMap(InstrDef).init(allocator);

    var blockLines = std.ArrayList([]const u8).init(allocator);

    var inBlock = false;

    var name: []const u8 = undefined;

    var l: usize = 0;
    while (lines.next()) |line| {
        l += 1;

        if (std.mem.eql(u8, line, "")) {
            log.debug("skipping blank line {} {s}", .{ l, if (inBlock) "(in)" else "(out)" });
            continue;
        }

        log.debug("processing line {} {s}:\n    `{s}`", .{ l, if (inBlock) "(in)" else "(out)", line });

        if (line[0] != ' ' and line[0] != '\t') {
            log.debug("top level line", .{});

            var lineEnd = for (line, 0..) |ch, i| {
                if (ch == ';') break i - 1;
            } else line.len - 1;

            while (std.ascii.isWhitespace(line[lineEnd])) {
                lineEnd -= 1;
            }

            if (line[lineEnd] != ':') {
                if (!inBlock) {
                    log.debug("discarding line {} as macro", .{ l });
                    continue;
                } else {
                    std.debug.print("Error[instructions.asm:{}]: line should end with `:`, or be indented under such a line", .{ l });
                    std.process.exit(1);
                }
            }

            log.debug("processing as instruction def", .{});

            if (inBlock) {
                log.debug("Adding InstrDef for {s}", .{ name });
                try defs.put(name, InstrDef {
                    .name = name,
                    .line_origin = l,
                    .block = try blockLines.toOwnedSlice(),
                });
            } else {
                log.debug("found first instruction {s}", .{line[0..lineEnd]});
                inBlock = true;
            }

            name = line[0..lineEnd];
        } else if (inBlock) {
            log.debug("adding line to block for {s}", .{ name });
            try blockLines.append(std.mem.trimLeft(u8, line, " \t"));
        } else {
            log.info("discarding line {} as macro", .{ l });
            continue;
        }
    } else {
        if (inBlock) {
            log.debug("Adding final InstrDef for {s}", .{ name });
            try defs.put(name, InstrDef {
                .name = name,
                .line_origin = l,
                .block = try blockLines.toOwnedSlice(),
            });
        }
    }


    if (defs.count() == 0) {
        std.debug.print(
            "Error[instructions.asm / gen.zig]: no valid instruction definitions found\nsource text was:\n{s}{s}\n\n",
            .{text[0..@min(text.len, 256)], if (text.len > 256) "\n..." else ""},
        );
        std.process.exit(1);
    }

    try InstrDef.validate(&defs, categories);

    return defs;
}

fn generateHeaderAssembly(includePlaceholders: bool, writer: anytype) !void {
    try writer.print("%define OP_SIZE 0x{x}\n\n", .{ pl.OPCODE_SIZE });

    inline for (comptime std.meta.fieldNames(core.mem.FiberHeader)) |fieldName| {
        const baseOffset = @offsetOf(core.mem.FiberHeader, fieldName);

        // Because the `Stack` structure has its top_ptr at the beginning of its data,
        // we can just use the stack's offset as the top_ptr offset, which is all we need.
        try writer.print("%define Fiber.{s} 0x{x}\n", .{ fieldName, baseOffset });

        const T: type = @FieldType(core.mem.FiberHeader, fieldName);

        if (comptime pl.hasDecl(T, .IS_RIBBON_STACK)) {
            try writer.print("%define Fiber.{s}.base 0x{x}\n", .{ fieldName, baseOffset + @offsetOf(T, "base") });
            try writer.print("%define Fiber.{s}.limit 0x{x}\n", .{ fieldName, baseOffset + @offsetOf(T, "limit") });
        }
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.CallFrame)) |fieldName| {
        const baseOffset = @offsetOf(core.CallFrame, fieldName);

        try writer.print("%define CallFrame.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.SetFrame)) |fieldName| {
        const baseOffset = @offsetOf(core.SetFrame, fieldName);

        try writer.print("%define SetFrame.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.Evidence)) |fieldName| {
        const baseOffset = @offsetOf(core.Evidence, fieldName);

        try writer.print("%define Evidence.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.BuiltinSignal)) |fieldName| {
        const d = @field(core.BuiltinSignal, fieldName);

        try writer.print("%define BuiltinSignal.{s} 0x{x}\n", .{ fieldName, @as(u64, @bitCast(@intFromEnum(d))) });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.Function)) |fieldName| {
        const baseOffset = @offsetOf(core.Function, fieldName);

        try writer.print("%define Function.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.Header)) |fieldName| {
        const baseOffset = @offsetOf(core.Header, fieldName);

        try writer.print("%define Header.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.Extents)) |fieldName| {
        const baseOffset = @offsetOf(core.Extents, fieldName);

        try writer.print("%define Extents.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.AddressTable)) |fieldName| {
        const baseOffset = @offsetOf(core.AddressTable, fieldName);

        try writer.print("%define AddressTable.{s} 0x{x}\n", .{ fieldName, baseOffset });
    }

    try writer.writeAll("\n");

    inline for (comptime std.meta.fieldNames(core.HandlerSet)) |fieldName| {
        const baseOffset = @offsetOf(core.HandlerSet, fieldName);

        try writer.print("%define HandlerSet.{s} 0x{x}\n", .{ fieldName, baseOffset });
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

    if (includePlaceholders) {
        try writer.writeAll(
            \\
            \\%ifndef R_JUMP_TABLE
            \\%define R_JUMP_TABLE 0
            \\%define R_JUMP_TABLE_LENGTH 0
            \\%define R_EXIT_OKAY 0
            \\%define R_EXIT_HALT 0
            \\%define R_TRAP_REQUESTED 0
            \\%define R_TRAP_BAD_ENCODING 0
            \\%define R_TRAP_OVERFLOW 0
            \\%define R_TRAP_UNDERFLOW 0
            \\%define R_TRAP_REQUESTED 0
            \\%define R_DECODE 0
            \\%define R_DISPATCH 0
            \\%define R_BREAKPOINT 0
            \\%endif
            \\
        );
    }
}

fn generateMainAssembly(categories: []const isa.Category, allocator: std.mem.Allocator, writer: anytype) !void {
    try generateAssemblyJumpTable(categories, writer);
    try generateAssemblyIntro(writer);

    const impls = try parseInstructionsFile(allocator, categories, @embedFile("instructions.asm"));
    try generateAssemblyBody(categories, &impls, writer);
}

fn generateAssemblyIntro(writer: anytype) !void {
    var entries = std.io.fixedBufferStream(@embedFile("entry_points.asm"));

    const reader = entries.reader();

    var buf: [1024]u8 = undefined;

    while (true) {
        const line = try reader.readUntilDelimiter(&buf, '\n');

        if (std.mem.eql(u8, line, "section .text")) {
            try writer.writeAll("\n\nsection .text\n\n");
            break;
        }
    }

    try pl.stream(reader, writer);
}

fn generateAssemblyBody(categories: []const isa.Category, impls: *const std.StringArrayHashMap(InstrDef), writer: anytype) !void {
    try writer.writeAll("\nsection .text\n\n");

    var opcode: u16 = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                try writer.writeAll("\n");

                try writer.writeAll("R_");
                var nameBuf: [256]u8 = undefined;
                var stream = std.io.fixedBufferStream(&nameBuf);
                const nameWriter = stream.writer();
                try isa.formatInstructionName(mnemonic.name, instruction.name, nameWriter);
                const name = stream.getWritten();

                if (impls.get(name)) |instr| {
                    try writer.print("{s}:\n", .{ name });
                    for (instr.block) |line| {
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
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
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

fn generateAssemblyTemplate(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\%include "ribbon.h.asm"
        \\
    );

    var opcode: u16 = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                try writer.writeAll("\n\n");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll(": ; ");
                try formatOpcodeLiteral(opcode, writer);
                try writer.writeAll(" ");
                try formatInstructionOperands(" ", " + ", instruction, writer);
                try writer.writeAll(" ");
                try formatInstructionDescription("", " ", instruction.description, instruction.operands, writer);
                try writer.writeAll("\n    TODO\n");

                opcode += 1;
            }

            try writer.writeAll("\n");
        }

        try writer.writeAll("\n");
    }
}



// Types generation

fn generateTypes(categories: []const isa.Category, writer: anytype) !void {
    try generateTypesIntro(writer);

    try writer.writeAll(
        \\    /// Downcast full instruction -> basic instruction | term instruction
        \\    pub fn downcast(self: Instruction) union(enum) { basic: Basic, term: Term } {
        \\        switch (self.code.downcast()) {
        \\            .basic => |b| return .{ .basic = .{ .code = b, .data = @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(BasicOpData)), @truncate(@as(std.meta.Int(.unsigned, @bitSizeOf(OpData)), @bitCast(self.data))))) } },
        \\            .term => |t| return .{ .term = .{ .code = t, .data = @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(TermOpData)), @truncate(@as(std.meta.Int(.unsigned, @bitSizeOf(OpData)), @bitCast(self.data))))) } },
        \\        }
        \\    }
        \\
        \\    /// discriminator for instruction identity
        \\    code: OpCode,
        \\    /// operand set for the instruction
        \\    data: OpData,
        \\
    );

    try generateTypesCodes(categories, writer);
    try generateTypesData(categories, writer);
    try generateTypesUnion(categories, writer);
    try generateTypesBasicAndTerm(categories, writer);
}

fn generateTypesIntro(writer: anytype) !void {
    try paste("generateTypes", "", "//", "//", "Instruction_intro.zig", writer);
}

fn generateTypesCodes(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Enumeration identifying each instruction.
        \\pub const OpCode = enum(u16) {
        \\    /// Downcast full opcode -> basic opcode | term opcode
        \\    pub fn downcast(self: OpCode) union(enum) { basic: BasicOpCode, term: TermOpCode } {
        \\        @setEvalBranchQuota(std.meta.fieldNames(OpCode).len * 4);
        \\
        \\        inline for (comptime std.meta.fieldNames(BasicOpCode)) |fieldName| {
        \\            if (self == comptime @field(BasicOpCode, fieldName).upcast()) {
        \\                 return .{ .basic = @enumFromInt(@intFromEnum(self)) };
        \\            }
        \\        }
        \\
        \\        inline for (comptime std.meta.fieldNames(TermOpCode)) |fieldName| {
        \\            if (self == comptime @field(TermOpCode, fieldName).upcast()) {
        \\                 return .{ .term = @enumFromInt(@intFromEnum(self)) };
        \\            }
        \\        }
        \\
        \\        unreachable;
        \\    }
        \\
    );

    var opcode: u16 = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                try generateTypesZigDoc(opcode, instruction, writer);

                try writer.writeAll("    @\"");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("\" = 0x");
                try formatOpcodeLiteral(opcode, writer);
                try writer.writeAll(",\n");

                opcode += 1;
            }
        }
    }

    try writer.writeAll("};\n\n");
}

fn generateTypesZigDoc(opcode: u16, instr: *const isa.Instruction, writer: anytype) !void {
    try writer.writeAll("    /// `");
    try formatOpcodeLiteral(opcode, writer);
    try writer.writeAll("`\n");

    try formatInstructionDescription("    /// ", null, instr.description, instr.operands, writer);
    try writer.writeAll("; `");
    try formatOpcodeSequence(opcode, " ", writer);
    try writer.writeAll(" ");
    try formatInstructionOperands(" ", " + ", instr, writer);
    try writer.writeAll("`\n");
}

fn generateTypesData(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Like `Instruction`, but specialized to instructions that can occur inside a basic block.
        \\pub const Basic = struct {
        \\    /// Discriminator for instruction identity.
        \\    code: BasicOpCode,
        \\    /// Operand set for the instruction.
        \\    data: BasicOpData,
        \\    /// Convert basic -> full instruction.
        \\    pub fn upcast(self: Basic) Instruction { return .{ .code = self.code.upcast(), .data = self.data.upcast() }; }
        \\};
        \\
        \\/// Like `Instruction`, but specialized to instructions that can terminate a basic block.
        \\pub const Term = struct {
        \\    /// Discriminator for instruction identity.
        \\    code: TermOpCode,
        \\    /// Operand set for the instruction.
        \\    data: TermOpData,
        \\    /// Convert terminator -> full instruction.
        \\    pub fn upcast(self: Term) Instruction { return .{ .code = self.code.upcast(), .data = self.data.upcast() }; }
        \\};
        \\
        \\/// Derive a type from `operand_sets` using the provided opcode.
        \\pub fn SetType(comptime code: OpCode) type {
        \\    return @FieldType(OpData, @tagName(code));
        \\}
        \\
        \\/// Determine if a type is from `operand_sets`.
        \\pub fn isSetType(comptime T: type) bool {
        \\    comptime {
        \\        for (std.meta.declarations(operand_sets)) |typeDecl| {
        \\            const F = @field(operand_sets, typeDecl.name);
        \\            if (T == F) return true;
        \\        }
        \\        return false;
        \\    }
        \\}
        \\
        \\/// Masks out the operands from encoded instruction bits, leaving only the opcode.
        \\pub const OPCODE_MASK = @as(core.InstructionBits, std.math.maxInt(std.meta.Int(.unsigned, @bitSizeOf(Instruction.OpCode))));
        \\
        \\/// Split an encoded instruction word into its opcode and operand data, and return it as an `Instruction`.
        \\pub fn fromBits(encodedBits: core.InstructionBits) Instruction {
        \\    const opcode: std.meta.Int(.unsigned, @bitSizeOf(Instruction.OpCode)) = @truncate(encodedBits & Instruction.OPCODE_MASK);
        \\    const data: std.meta.Int(.unsigned, @bitSizeOf(Instruction.OpData)) = @truncate(encodedBits >> @bitSizeOf(Instruction.OpCode));
        \\
        \\    return Instruction{
        \\        .code = @enumFromInt(opcode),
        \\        .data = @bitCast(data),
        \\    };
        \\}
        \\
        \\
    );

    try writer.writeAll(
        \\/// Namespace of operand set types for each instruction.
        \\pub const operand_sets = struct {
        \\
    );

    var opcode: u16 = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                try generateTypesZigDoc(opcode, instruction, writer);

                try writer.writeAll("    pub const @\"");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("\" = packed struct { ");


                var size: usize = 0;
                var wordOffset: usize = 2;

                for (instruction.operands, 0..) |operand, i| {
                    const operandSize = operand.sizeOf();
                    const remSize = isa.Operand.totalSizeNoPadding(instruction.operands[i + 1..]);

                    if (isa.wordBoundaryHeuristic(operand, remSize, wordOffset)) {
                        break;
                    }

                    _ = try isa.formatOperand(i, instruction.operands, writer);
                    try writer.writeAll(": ");

                    try writer.writeAll(switch (operand) {
                        .register => "core.Register",
                        .upvalue => "Id.of(core.Upvalue)",
                        .global => "Id.of(core.Global)",
                        .function => "Id.of(core.Function)",
                        .builtin => "Id.of(core.BuiltinAddress)",
                        .foreign => "Id.of(core.ForeignAddress)",
                        .effect => "Id.of(core.Effect)",
                        .handler_set => "Id.of(core.HandlerSet)",
                        .constant => "Id.of(core.Constant)",
                        .byte => "u8",
                        .short => "u16",
                        .int => "u32",
                        .word => unreachable,
                    });

                    try writer.writeAll(", ");

                    wordOffset += operandSize;
                    size += operandSize;
                }


                try writer.writeAll("};\n\n");

                opcode += 1;
            }
        }
    }
    try writer.writeAll("};\n\n");

    try writer.writeAll(
        \\
        \\comptime {
        \\    for (std.meta.declarations(operand_sets)) |typeDecl| {
        \\        const bits = @bitSizeOf(@field(operand_sets, typeDecl.name));
        \\        if (bits > 48) {
        \\            @compileLog(std.fmt.comptimePrint("Operand set type " ++ @typeName(@field(operand_sets, typeDecl.name)) ++ " is too large to fit in an instruction word; it is {} bits", .{  bits }));
        \\        }
        \\    }
        \\}
        \\
    );
}

fn generateTypesUnion(categories: []const isa.Category, writer: anytype) !void {
    try writer.writeAll(
        \\/// Untagged union of all `operand_sets` types.
        \\pub const OpData = packed union {
        \\    /// Extract the operand set for a given opcode.
        \\    pub fn extractSet(self: OpData, comptime code: OpCode) SetType(code) {
        \\        inline for (comptime std.meta.fieldNames(OpCode)) |fieldName| {
        \\            if (code == comptime @field(OpCode, fieldName).upcast()) {
        \\                return @field(self, fieldName);
        \\            }
        \\        }
        \\
        \\        unreachable;
        \\    }
        \\
        \\    /// Create an operand data union from the bits of one of its variants
        \\    pub fn fromBits(set: anytype) OpData {
        \\        return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(OpData)), @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(set))), @bitCast(set))));
        \\    }
        \\
        \\    /// Create a 48-bit integer from an `OpData` value.
        \\    /// * **NOTE**: Previously, this was done with a bitcast.
        \\    /// However, that can sometimes lead to undefined bytes in encoded bytecode streams;
        \\    /// So now, this uses compile-time reflection to extract the fields of the union,
        \\    /// and copies them into a 48-bit integer.
        \\    /// This new process requires an `OpCode` to discriminate the union.
        \\    pub fn toBits(self: OpData, code: OpCode) u48 {
        \\        var i: usize = 0;
        \\        var out: u48 = 0;
        \\        const bytes = std.mem.asBytes(&out);
        \\
        \\        const opcodes = comptime std.meta.fieldNames(Instruction.OpCode);
        \\        @setEvalBranchQuota(opcodes.len * 32);
        \\
        \\        inline for (opcodes) |instrName| {
        \\            if (code == comptime @field(Instruction.OpCode, instrName)) {
        \\                const T = @FieldType(Instruction.OpData, instrName);
        \\                const set = @field(self, instrName);
        \\
        \\                inline for (comptime std.meta.fieldNames(T)) |opName| {
        \\                    const operand = @field(set, opName);
        \\                    const size = @sizeOf(@FieldType(T, opName));
        \\                    @memcpy(bytes[i..i + size], std.mem.asBytes(&operand));
        \\                    i += size;
        \\                }
        \\
        \\                return out;
        \\            }
        \\        } else unreachable;
        \\    }
        \\
        \\
    );

    var opcode: u16 = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                try generateTypesZigDoc(opcode, instruction, writer);

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
        \\    /// convert basic opcode -> full opcode
        \\    pub fn upcast(self: BasicOpCode) OpCode { return @enumFromInt(@intFromEnum(self)); }
        \\
    );

    var opcode: u16 = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                if (!instruction.terminal) {
                    try generateTypesZigDoc(opcode, instruction, writer);

                    try writer.writeAll("    @\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\" = 0x");
                    try formatOpcodeLiteral(opcode, writer);
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
        \\    /// convert term opcode -> full opcode
        \\    pub fn upcast(self: TermOpCode) OpCode { return @enumFromInt(@intFromEnum(self)); }
        \\
    );

    opcode = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                if (instruction.terminal) {
                    try generateTypesZigDoc(opcode, instruction, writer);

                    try writer.writeAll("    @\"");
                    try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                    try writer.writeAll("\" = 0x");
                    try formatOpcodeLiteral(opcode, writer);
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
        \\    /// convert basic operand data -> full operand data
        \\    pub fn upcast(self: BasicOpData) OpData { return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(OpData)), @as(std.meta.Int(.unsigned, @bitSizeOf(BasicOpData)), @bitCast(self)))); }
        \\
        \\    /// Create an operand data union from the bits of one of its variants
        \\    pub fn fromBits(set: anytype) BasicOpData {
        \\        return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(BasicOpData)), @intCast(@as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(set))), @bitCast(set)))));
        \\    }
        \\
    );

    opcode = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                if (!instruction.terminal) {
                    try generateTypesZigDoc(opcode, instruction, writer);

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
        \\    /// convert term operand set -> full operand set
        \\    pub fn upcast(self: TermOpData) OpData { return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(OpData)), @as(std.meta.Int(.unsigned, @bitSizeOf(TermOpData)), @bitCast(self)))); }
        \\
        \\    /// Create an operand data union from the bits of one of its variants
        \\    pub fn fromBits(set: anytype) TermOpData {
        \\        return @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(TermOpData)), @intCast(@as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(set))), @bitCast(set)))));
        \\    }
        \\
    );

    opcode = 0;
    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            for (mnemonic.instructions) |*instruction| {
                if (instruction.terminal) {
                    try generateTypesZigDoc(opcode, instruction, writer);

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
        \\- [Overview](#overview)
        \\- [Instructions](#instructions)
        \\
    );

    try paste("generateMarkdown", stream.getWritten(), "<!--", "-->", "Isa_intro.md", writer);
}

fn generateMarkdownInstructionToc(categories: []const isa.Category, writer: anytype) !void {
    for (categories) |*category| {
        try writer.writeAll("- ");
        try writeLink(category.name, writer);
        try writer.writeAll("\n");
        for (category.mnemonics) |*mnemonic| {
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

    for (categories) |*category| {
        mnemonicsCount += @floatFromInt(category.mnemonics.len);

        for (category.mnemonics) |*mnemonic| {
            total += @floatFromInt(mnemonic.instructions.len);
        }
    }

    return total / mnemonicsCount;
}

fn countInstructions(categories: []const isa.Category) usize {
    var count: usize = 0;

    for (categories) |*category| {
        for (category.mnemonics) |*mnemonic| {
            count += mnemonic.instructions.len;
        }
    }

    return count;
}

fn countMnemonics(categories: []const isa.Category) usize {
    var count: usize = 0;

    for (categories) |*category| {
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
    for (categories) |*category| {
        try writer.print("### {s}\n\n", .{ category.name });

        try formatMnemonicDescription(null, null, category.description, writer);

        for (category.mnemonics) |*mnemonic| {
            try writer.print("#### {s}\n\n", .{ mnemonic.name });

            try formatMnemonicDescription(null, null, mnemonic.description, writer);

            try writer.writeAll("| Name | Encoding | Description |\n|-|-|-|\n");

            for (mnemonic.instructions) |*instruction| {
                try writer.writeAll("| ");

                if (instruction.jit_only) {
                    try writer.writeAll("<em>jit</em><br>");
                }

                try writer.writeAll("`");
                try isa.formatInstructionName(mnemonic.name, instruction.name, writer);
                try writer.writeAll("` | `");

                try formatOpcodeSequence(opcode, "`&nbsp;`", writer);
                try writer.writeAll("`&nbsp;");

                try writer.writeAll("`");
                try formatInstructionOperands("`&nbsp;`", "`<br>`", instruction, writer);
                try writer.writeAll("` | ");

                try formatInstructionDescription(null, "<br>", instruction.description, instruction.operands, writer);

                try writer.writeAll(" |\n");

                opcode += 1;
            }

            try writer.writeAll("\n");
        }
    }
}

// Generalized isa formatting

fn formatOpcodeLiteral(code: u16, writer: anytype) !void {
    try std.fmt.formatInt(code, 16, .lower, .{ .alignment = .right, .width = 4, .fill = '0' }, writer);
}

fn formatOpcodeSequence(code: u16, space: []const u8, writer: anytype) !void {
    const opcodeBytes: *const [2]u8 = @ptrCast(&if (comptime @import("builtin").target.cpu.arch.endian() == .big) @byteSwap(code) else code);

    try writer.print("{x:0>2}{s}{x:0>2}", .{ opcodeBytes[0], space, opcodeBytes[1] });
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

fn formatInstructionOperands(space: []const u8, tail: []const u8, instruction: *const isa.Instruction, writer: anytype) !void {
    var size: usize = 0;
    var wordOffset: usize = 2;

    for (instruction.operands, 0..) |operand, i| {
        const operandSize = operand.sizeOf();
        const remSize = isa.Operand.totalSizeNoPadding(instruction.operands[i + 1..]);

        if (isa.wordBoundaryHeuristic(operand, remSize, wordOffset)) {
            if (wordOffset < 8) {
                for (0..(8 - wordOffset)) |_| {
                    try writer.writeAll(space);
                    try writer.writeAll("__");
                }
            }

            try writer.writeAll(tail);

            wordOffset = 0;
        } else if (i > 0) {
            try writer.writeAll(space);
        }

        const requiredChars = operand.sizeOf() * 2;
        var writtenChars = try isa.formatOperand(i, instruction.operands, writer);

        if (writtenChars == 1) {
            try writer.writeByte('.');
            writtenChars += 1;
        }

        if (requiredChars > writtenChars) {
            for (0..((requiredChars - writtenChars) / 2)) |_| {
                try writer.writeAll(space);
                try writer.writeAll("..");
            }
        }

        wordOffset += operandSize;
        size += operandSize;
    }

    if (wordOffset != 0 and wordOffset != 8) {
        if (instruction.operands.len > 0) {
            try writer.writeAll(space);
        }

        for (0..(8 - wordOffset)) |i| {
            if (i > 0) try writer.writeAll(space);
            try writer.writeAll("__");
        }
    }

    if (instruction.variable_length) {
        try writer.writeAll(tail);
        try writer.writeAll("...");
    }
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

fn formatMnemonicDescription(linePrefix: ?[]const u8, sanitizeBreak: ?[]const u8, formatString: []const u8, writer: anytype) !void {
    try formatDescriptionWith(linePrefix, sanitizeBreak, formatString, writer, struct {
        pub const formatArgument = formatMnemonicArgument;
    });

    try writer.writeAll("\n\n");
}

fn formatInstructionDescription(linePrefix: ?[]const u8, sanitizeBreak: ?[]const u8, description: []const u8, operands: []const isa.Operand, writer: anytype) !void {
    const Ctx = struct {
        operands: []const isa.Operand,

        pub fn formatArgument(self: @This(), argument: []const u8, f: anytype) !bool {
            return formatInstructionArgument(argument, self.operands, f);
        }
    };

    return formatDescriptionWith(linePrefix, sanitizeBreak, description, writer, Ctx { .operands = operands });
}

fn formatDescriptionWith(linePrefix: ?[]const u8, sanitizeBreak: ?[]const u8, formatString: []const u8, writer: anytype, ctx: anytype) !void {
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
            if (sanitizeBreak) |san| {
                try writer.writeAll(san);
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

fn paste(generatorName: []const u8, header: []const u8, commentPre: []const u8, commentPost: []const u8, comptime path: []const u8, writer: anytype) !void {
    var genBase = std.io.fixedBufferStream(@embedFile(path));

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
