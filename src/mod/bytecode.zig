//! # bytecode
//! This is a namespace for Ribbon bytecode data types, and the builder.
//!
//! The focal points are:
//! * `Instruction` - this is the data type representing un-encoded Ribbon bytecode instructions
//! * `Builder` - the main API for creating Ribbon bytecode functions; other types in this namespace are subordinate to it.
const bytecode = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode);

const pl = @import("platform");
const core = @import("core");
const Id = @import("Id");
const Interner = @import("Interner");
const VirtualWriter = @import("VirtualWriter");

pub const Instruction = @import("Instruction");

test {
    std.testing.refAllDeclsRecursive(@This());
}

/// Disassemble a bytecode function, printing to the provided writer.
pub fn disas(vmem: pl.VirtualMemory, writer: anytype) !void {
    var ptr: core.InstructionAddr = @ptrCast(vmem);
    const end = ptr + @divExact(vmem.len, 8);

    try writer.print("[{x:0<16}]:\n", .{ @intFromPtr(ptr)});

    while (@intFromPtr(ptr) < @intFromPtr(end)) : (ptr += 1) {
        const encodedBits: u64 = @as([*]const core.InstructionBits, ptr)[0];

        const instr = Instruction.fromBits(encodedBits);

        const opcodes = comptime std.meta.fieldNames(Instruction.OpCode);
        @setEvalBranchQuota(opcodes.len * 32);

        inline for (opcodes) |instrName| {
            if (instr.code == comptime @field(Instruction.OpCode, instrName)) {
                const T = @FieldType(Instruction.OpData, instrName);
                const set = @field(instr.data, instrName);

                try writer.writeAll("    " ++ instrName);

                inline for (comptime std.meta.fieldNames(T)) |opName| {
                    const operand = @field(set, opName);

                    try writer.print(" (" ++ opName ++ " {d})", .{ @intFromEnum(operand) });
                }
            }
        }

        try writer.writeAll("\n");
    }
}

/// A `VirtualWriter` with a `platform.MAX_VIRTUAL_CODE_SIZE` memory limit.
pub const Writer = VirtualWriter.new(pl.MAX_VIRTUAL_CODE_SIZE);

/// Wrapper over `VirtualWriter` that provides a bytecode instruction specific API.
pub const Encoder = struct {
    /// The encoder's `VirtualWriter`
    writer: Writer,

    pub const Error = Writer.Error;

    /// Get the current offset's address with the encoded memory.
    pub fn getCurrentAddress(self: *Encoder) [*]u8 {
        return self.writer.getCurrentAddress();
    }

    /// Finalize the Encoder's writer, returning the posix pages as a read-only buffer.
    pub fn finalize(self: *Encoder) error{BadEncoding}!pl.VirtualMemory {
        return self.writer.finalize(.read_only);
    }

    /// Returns the size of the uncommitted region of memory.
    pub fn uncommittedRegion(self: *Encoder) usize {
        return self.writer.uncommittedRegion();
    }

    /// Returns the available capacity in the current page.
    pub fn availableCapacity(self: *Encoder) []u8 {
        return self.writer.availableCapacity();
    }

    /// Writes as much of a slice of bytes to the encoder as will fit without an allocation.
    /// Returns the number of bytes written.
    pub fn write(self: *Encoder, noalias bytes: []const u8) Writer.Error!usize {
        return self.writer.write(bytes);
    }

    /// Writes all bytes from a slice to the encoder.
    pub fn writeAll(self: *Encoder, bytes: []const u8) Writer.Error!void {
        return self.writer.writeAll(bytes);
    }

    /// Writes a single byte to the encoder.
    pub fn writeByte(self: *Encoder, byte: u8) Writer.Error!void {
        return self.writer.writeByte(byte);
    }

    /// Writes a byte to the encoder `n` times.
    pub fn writeByteNTimes(self: *Encoder, byte: u8, n: usize) Writer.Error!void {
        return self.writer.writeByteNTimes(byte, n);
    }

    /// Writes a slice of bytes to the encoder `n` times.
    pub fn writeBytesNTimes(self: *Encoder, bytes: []const u8, n: usize) Writer.Error!void {
        return self.writer.writeBytesNTimes(bytes, n);
    }

    /// Writes an integer to the encoder.
    pub fn writeInt(
        self: *Encoder,
        comptime T: type, value: T,
        comptime _: enum {little}, // allows backward compat with zig's writer interface; but only in provably compatible use-cases
    ) Writer.Error!void {
        try self.writer.writeInt(T, value, .little);
    }

    /// Generalized version of `writeInt` for little-endian only;
    /// Works for any value with a unique representation.
    ///
    /// See `std.meta.hasUniqueRepresentation`.
    pub fn writeValue(
        self: *Encoder,
        value: anytype,
    ) Writer.Error!void {
        const T = @TypeOf(value);

        if (comptime !std.meta.hasUniqueRepresentation(T)) {
            @compileError("bytecode.Encoder.writeValue: Type `" ++ @typeName(T) ++ "` does not have a unique representation");
        }

        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
    }

    /// Pushes zero bytes (if necessary) to align the current offset of the encoder to the provided alignment value.
    pub fn alignTo(self: *Encoder, alignment: pl.Alignment) Writer.Error!void {
        const delta = pl.alignDelta(self.writer.cursor, alignment);
        try self.writer.writeByteNTimes(0, delta);
    }

    /// Composes and encodes a bytecode instruction.
    ///
    /// This function is used internally by `instr` and `instrPre`.
    /// It can be called directly, though it should be noted that it does not
    /// type-check the `data` argument, whereas `instr` does.
    ///
    /// ### Panics
    /// If the starting offset of the encoder is not aligned to `pl.BYTECODE_ALIGNMENT`.
    pub fn instrCompose(self: *Encoder, code: Instruction.OpCode, data: anytype) Writer.Error!void {
        const delta = pl.alignDelta(self.writer.cursor, pl.BYTECODE_ALIGNMENT);

        if (delta != 0) {
            std.debug.panic(
                "VirtualWriter cursor is at {}, but must be aligned to {} for bytecode instructions; off by {} bytes",
                .{ self.writer.cursor, pl.BYTECODE_ALIGNMENT, delta },
            );
        }

        try self.opcode(code);
        try self.operands(code, Instruction.OpData.fromBits(data));

        std.debug.assert(pl.alignDelta(self.writer.cursor, pl.BYTECODE_ALIGNMENT) == 0);
    }

    /// Composes and encodes a bytecode instruction.
    pub fn instr(self: *Encoder, comptime code: Instruction.OpCode, data: Instruction.SetType(code)) Writer.Error!void {
        return self.instrCompose(code, data);
    }

    /// Encodes a pre-composed bytecode instruction.
    pub fn instrPre(self: *Encoder, instruction: Instruction) Writer.Error!void {
        return self.instrCompose(instruction.code, instruction.data);
    }

    /// Encodes an opcode.
    pub fn opcode(self: *Encoder, code: Instruction.OpCode) Writer.Error!void {
        try self.writeInt(u16, @intFromEnum(code), .little);
    }

    /// Encodes instruction operands.
    pub fn operands(self: *Encoder, code: Instruction.OpCode, data: Instruction.OpData) Writer.Error!void {
        try self.writeInt(u48, data.toBits(code), .little);
    }
};


/// A simple builder API for bytecode functions.
pub const Builder = struct {
    /// The allocator used by this function.
    allocator: std.mem.Allocator,
    /// The function's unique identifier.
    id: Id.of(core.Function),
    /// The function's stack window size.
    stack_size: usize = 0,
    /// The function's stack window alignment.
    stack_align: usize = 8,
    /// The function's basic blocks.
    blocks: pl.ArrayList(*const Block) = .empty,

    /// Initialize a new builder for a bytecode function.
    pub fn init(allocator: std.mem.Allocator, id: Id.of(core.Function)) !*const Builder {
        const self = try allocator.create(Builder);

        self.* = Builder{
            .allocator = allocator,
            .id = id,
        };

        return self;
    }

    /// Deinitialize the builder, freeing all memory associated with it.
    pub fn deinit(ptr: *const Builder) void {
        const self: *Builder = @constCast(ptr);

        const allocator = self.allocator;
        defer allocator.destroy(ptr);

        for (self.blocks.items) |block| {
            block.deinit();
        }

        self.blocks.deinit(allocator);
    }

    /// Create a new basic block within this function, returning a pointer to it.
    pub fn createBlock(ptr: *const Builder) error{NameCollision, TooManyBlocks, OutOfMemory}!*const Block {
        const self = @constCast(ptr);

        const index = self.blocks.items.len;

        if (index > Id.MAX_INT) {
            log.err("bytecode.Builder.createBlock: Cannot create more than {d} blocks in function {}", .{Id.MAX_INT, self.id});
            return error.TooManyBlocks;
        }

        const block = try Block.init(self, .fromInt(index));

        try self.blocks.append(self.allocator, block);

        return block;
    }

    pub fn encode(ptr: *const Builder, encoder: *Encoder) error{BadEncoding, OutOfMemory}!void {
        const self = @constCast(ptr);

        if (self.blocks.items.len == 0) {
            log.err("bytecode.Builder.finalize: Cannot finalize a function with no blocks", .{});
            return error.BadEncoding;
        }

        for (self.blocks.items) |block| {
            try block.encode(encoder);
        }
    }
};

/// A bytecode basic block in unencoded form.
///
/// A basic block is a straight-line sequence of instructions with no *local*
/// control flow, terminated by a branch or similar instruction. Emphasis is placed
/// on *local*, because a basic block can still call functions; it simply assumes
/// they always return. (See docs for the field `terminator` for some details about
/// this.)
///
/// This definition of basic block was chosen for convenience of interface. We could track
/// termination of functional control flow; but it would require more complex data structures
/// and API. The current design allows for a simple, linear representation of the bytecode
/// function's control flow, which is sufficient for the intended use cases of the `Builder`.
pub const Block = struct {
    /// The function this block belongs to.
    function: *const Builder,
    /// The unique(-within-`function`) identifier for this block.
    id: Id.of(Block),
    /// The instructions making up the body of this block, in un-encoded form.
    body: pl.ArrayList(Instruction.Basic) = .empty,
    /// The instruction that terminates this block.
    /// * Adding any instruction when this is non-`null` is a `BadEncoding` error
    /// * For all other purposes, `null` is semantically equivalent to `unreachable`
    ///
    /// This is intended for convenience. For example, when calling an effect
    /// handler *that is known to always cancel*, we can treat the `prompt` as
    /// terminal in higher-level code.
    terminator: ?Instruction.Term = null,

    fn init(function: *const Builder, id: Id.of(Block)) error{OutOfMemory}!*const Block {
        const allocator = function.allocator;
        const self = try allocator.create(Block);

        self.* = Block{
            .function = function,
            .id = id,
        };

        return self;
    }

    fn deinit(ptr: *const Block) void {
        const self: *Block = @constCast(ptr);

        const allocator = self.function.allocator;
        defer allocator.destroy(self);

        self.body.deinit(allocator);
    }

    /// Write this block's instructions into the provided bytecode encoder.
    pub fn encode(ptr: *const Block, encoder: *Encoder) error{BadEncoding, OutOfMemory}!void {
        const self: *Block = @constCast(ptr);

        for (self.body.items) |basic| {
            try encoder.instrPre(basic.upcast());
        }

        if (self.terminator) |term| {
            try encoder.instrPre(term.upcast());
        } else {
            try encoder.instr(.@"unreachable", .{});
        }
    }

    /// Append an instruction into this block, given its `OpCode` and an appropriate operand set.
    ///
    /// * `data` must be of the correct shape for the instruction, or undefined behavior will occur.
    /// See `Instruction.operand_sets`; each opcode has an associated type with the same name.
    /// You can also use `OpData` directly.
    ///
    /// This function is used internally by `instr` and `instrPre`.
    /// It can be called directly, though it should be noted that it does not
    /// type-check the `data` argument, whereas `instr` does.
    pub fn composeInstr(ptr: *const Block, code: Instruction.OpCode, data: anytype) error{BadEncoding, OutOfMemory}!void {
        const self: *Block = @constCast(ptr);

        if (self.terminator) |term| {
            log.err("Cannot insert instruction `{s}` into block with terminator `{s}`", .{@tagName(code), @tagName(term.code)});
            return error.BadEncoding;
        }

        switch (code.downcast()) {
            .basic => |b| {
                try self.body.append(self.function.allocator, Instruction.Basic{
                    .code = b,
                    .data = Instruction.BasicOpData.fromBits(data),
                });
            },
            .term => |t| {
                self.terminator = Instruction.Term{
                    .code = t,
                    .data = Instruction.TermOpData.fromBits(data),
                };
            },
        }
    }

    /// Append an instruction into this block, given its `OpCode` and an appropriate operand set.
    ///
    /// * `data` must be of the correct type for the instruction, or compilation errors will occur.
    /// See `Instruction.operand_sets`; each opcode has an associated type with the same name.
    /// `.{}` syntax should work.
    ///
    /// See also `instrPre`, which takes a pre-composed `Instruction` instead of individual components.
    pub fn instr(ptr: *const Block, comptime code: Instruction.OpCode, data: Instruction.SetType(code)) error{BadEncoding, OutOfMemory}!void {
        return ptr.composeInstr(code, data);
    }

    /// Append a pre-composed instruction into this block.
    ///
    /// * `instruction` must be properly composed, or runtime errors will occur.
    ///
    /// See also `instr`, which takes the individual components of an instruction separately.
    pub fn instrPre(ptr: *const Block, instruction: Instruction) error{BadEncoding, OutOfMemory}!void {
        return ptr.composeInstr(instruction.code, instruction.data);
    }
};
