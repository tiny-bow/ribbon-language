//! # bytecode
//! This is a namespace for Ribbon bytecode data types, and the builder.
//!
//! The focal points are:
//! * `Instruction` - this is the data type representing un-encoded Ribbon bytecode instructions, as well as the namespace for both un-encoded and encoded opcodes and operand sets
//! * `Table` - the main API for creating Ribbon `Bytecode` units
//! * `Builder` - the main API for creating Ribbon bytecode functions
const bytecode = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode);

const pl = @import("platform");
const core = @import("core");
const Id = @import("Id");
const Interner = @import("Interner");
const VirtualWriter = @import("VirtualWriter");
const Buffer = @import("Buffer");

pub const Instruction = @import("Instruction");

test {
    std.testing.refAllDecls(@This());
}

/// Disassemble a bytecode function, printing to the provided writer.
pub fn disas(vmem: pl.VirtualMemory, writer: anytype) !void {
    var ptr: core.InstructionAddr = @ptrCast(vmem);
    const end = ptr + @divExact(vmem.len, 8);

    try writer.print("[{x:0<16}]:\n", .{@intFromPtr(ptr)});

    while (@intFromPtr(ptr) < @intFromPtr(end)) : (ptr += 1) {
        const encodedBits: u64 = @as([*]const core.InstructionBits, ptr)[0];

        const instr = Instruction.fromBits(encodedBits);

        const opcodes = comptime std.meta.fieldNames(Instruction.OpCode);
        @setEvalBranchQuota(opcodes.len * 32);

        inline for (opcodes) |instrName| {
            const comptime_code = comptime @field(Instruction.OpCode, instrName);
            if (instr.code == comptime @field(Instruction.OpCode, instrName)) {
                const T = @FieldType(Instruction.OpData, instrName);
                const set = @field(instr.data, instrName);

                try writer.writeAll("    " ++ instrName);

                inline for (comptime std.meta.fieldNames(T)) |opName| {
                    const F = @FieldType(T, opName);
                    const field = @field(set, opName);

                    switch (F) {
                        core.Register => try writer.print(" {}", .{field}),
                        core.UpvalueId => try writer.print(" U:{x}", .{field.toInt()}),
                        core.GlobalId => try writer.print(" G:{x}", .{field.toInt()}),
                        core.FunctionId => try writer.print(" F:{x}", .{field.toInt()}),
                        core.BuiltinAddressId => try writer.print(" B:{x}", .{field.toInt()}),
                        core.ForeignAddressId => try writer.print(" X:{x}", .{field.toInt()}),
                        core.EffectId => try writer.print(" E:{x}", .{field.toInt()}),
                        core.HandlerSetId => try writer.print(" H:{x}", .{field.toInt()}),
                        core.ConstantId => try writer.print(" C:{x}", .{field.toInt()}),
                        u8 => try writer.print(" i8:{x}", .{field}),
                        u16 => try writer.print(" i16:{x}", .{field}),
                        u32 => try writer.print(" i32:{x}", .{field}),
                        u64 => try writer.print(" i64:{x}", .{field}),
                        else => @compileError("Disassembler is out of sync with ISA: Unexpected operand type " ++ @typeName(F)),
                    }
                }

                if (comptime Instruction.isCall(comptime_code)) {
                    const arg_count = set.I;
                    if (arg_count > 0) {
                        try writer.writeAll(" args:");
                        const arg_ptr: [*]const core.Register = @ptrCast(ptr + 1);
                        for (0..arg_count) |i| {
                            try writer.print(" {}", .{arg_ptr[i]});
                        }
                        // Advance ptr to the end of the argument list. The main loop will
                        // then increment it to the next instruction.
                        const arg_bytes = arg_count * @sizeOf(core.Register);
                        // Integer division ceiling to find how many 8-byte words are needed.
                        const arg_words = (arg_bytes + pl.BYTECODE_ALIGNMENT - 1) / pl.BYTECODE_ALIGNMENT;
                        ptr += arg_words;
                    }
                } else if (comptime Instruction.isWide(comptime_code)) {
                    ptr += 1; // Advance past the main instruction word
                    const imm64: u64 = @as([*]const u64, @ptrCast(ptr))[0];
                    try writer.print(" i64:{x}", .{imm64});
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

    pub const Error = Writer.Error || error{
        /// Generic malformed bytecode error.
        BadEncoding,
        /// An error indicating that the current offset of the encoder is not aligned to the expected bytecode alignment for writing the provided data.
        UnalignedWrite,
    };

    /// Initialize a new Encoder with a `VirtualWriter`.
    pub fn init() error{OutOfMemory}!Encoder {
        const writer = try Writer.init();
        return Encoder{
            .writer = writer,
        };
    }

    /// Deinitialize the Encoder, freeing any memory it owns.
    pub fn deinit(self: *Encoder) void {
        self.writer.deinit();
    }

    /// Finalize the Encoder's writer, returning the posix pages as a read-only buffer.
    pub fn finalize(self: *Encoder) error{BadEncoding}!pl.VirtualMemory {
        return self.writer.finalize(.read_only);
    }

    /// Get the current offset's address with the encoded memory.
    pub fn getCurrentAddress(self: *Encoder) [*]u8 {
        return self.writer.getCurrentAddress();
    }

    /// Returns the size of the uncommitted region of memory.
    pub fn uncommittedRegion(self: *Encoder) usize {
        return self.writer.uncommittedRegion();
    }

    /// Returns the available capacity in the current page.
    pub fn availableCapacity(self: *Encoder) []u8 {
        return self.writer.availableCapacity();
    }

    /// Same as `std.mem.Allocator.create`, but allocates from the virtual address space of the writer.
    pub fn create(self: *Encoder, comptime T: type) Error!*T {
        return self.writer.create(T);
    }

    /// Same as `std.mem.Allocator.alloc`, but allocates from the virtual address space of the writer.
    pub fn alloc(self: *Encoder, comptime T: type, len: usize) Error![]T {
        return self.writer.alloc(T, len);
    }

    /// Same as `std.mem.Allocator.dupe`, but copies a slice into the virtual address space of the writer.
    pub fn dupe(self: *Encoder, comptime T: type, slice: []const T) Error![]T {
        return self.writer.dupe(T, slice);
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
        comptime T: type,
        value: T,
        comptime _: enum { little }, // allows backward compat with zig's writer interface; but only in provably compatible use-cases
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

    /// Asserts that the current offset of the encoder is instruction-aligned.
    pub fn ensureAligned(self: *Encoder) Error!void {
        if (pl.alignDelta(self.writer.cursor, pl.BYTECODE_ALIGNMENT) != 0) {
            return error.UnalignedWrite;
        }
    }

    /// Composes and encodes a bytecode instruction.
    ///
    /// This function is used internally by `instr` and `instrPre`.
    /// It can be called directly, though it should be noted that it does not
    /// type-check the `data` argument, whereas `instr` does.
    pub fn instrCompose(self: *Encoder, code: Instruction.OpCode, data: anytype) Error!void {
        try self.ensureAligned();

        try self.opcode(code);
        try self.operands(code, Instruction.OpData.fromBits(data));

        if (comptime pl.RUNTIME_SAFETY) try self.ensureAligned();
    }

    /// Composes and encodes a bytecode instruction.
    pub fn instr(self: *Encoder, comptime code: Instruction.OpCode, data: Instruction.SetType(code)) Error!void {
        return self.instrCompose(code, data);
    }

    /// Encodes a pre-composed bytecode instruction.
    pub fn instrPre(self: *Encoder, instruction: Instruction) Error!void {
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

    /// A fixup is a placeholder for an instruction that will have an operand filled later.
    pub const Fixup = struct {
        /// The instruction bits that will be modified later.
        instr: *core.InstructionBits,
        /// The bit-offset of the operand within the instruction bits.
        bit_position: u64,
    };

    /// Encodes a branch instruction with a placeholder value and returns the address of the placeholder.
    pub fn instrBr(self: *Encoder, comptime code: Instruction.OpCode, data: Instruction.SetType(code)) Error!Fixup {
        if (comptime !Instruction.isBranch(code)) {
            @compileError("instrBr can only be used with branch-family opcodes.");
        }

        const base: *core.InstructionBits = @ptrCast(self.getCurrentAddress());

        try self.instr(code, data);

        const bit_position = @bitSizeOf(Instruction.OpCode) + @bitOffsetOf(Instruction.SetType(code), "I");

        return .{
            .instr = base,
            .bit_position = bit_position,
        };
    }

    /// Encodes a call-family instruction followed by its argument registers.
    /// This handles writing the instruction word, the argument registers, and any
    /// necessary padding to re-align the instruction stream.
    pub fn instrCall(
        self: *Encoder,
        comptime code: Instruction.OpCode,
        data: Instruction.SetType(code),
        args: []const core.Register,
    ) Error!void {
        // 1. Compile-time check: Ensure this is a call-family instruction.
        comptime {
            const is_call = switch (code) {
                .call, .call_c, .f_call, .f_call_c, .prompt => true,
                else => false,
            };
            if (!is_call) {
                @compileError("instrCall can only be used with call-family opcodes.");
            }
            const T = Instruction.SetType(code);
            if (!@hasField(T, "I")) {
                @compileError("instrCall opcode must have an argument count operand 'I'.");
            }
        }

        // 2. Runtime check: Ensure argument count matches.
        if (args.len != data.I) {
            std.debug.panic("Argument count mismatch for {s}: expected {d}, got {d}", .{
                @tagName(code), data.I, args.len,
            });
        }

        // 3. Encode the main instruction word.
        try self.instr(code, data);

        // 4. Encode the argument registers.
        try self.writeAll(std.mem.sliceAsBytes(args));

        // 5. Align for the next instruction.
        try self.alignTo(pl.BYTECODE_ALIGNMENT);
    }

    /// Encodes an instruction that is followed by a 64-bit immediate value.
    pub fn instrWithImm64(
        self: *Encoder,
        comptime code: Instruction.OpCode,
        data: Instruction.SetType(code),
        imm64: u64,
    ) Error!void {
        if (comptime !Instruction.isWide(code)) @compileError("instrWithImm64 used with an incompatible opcode.");

        try self.instr(code, data);

        try self.ensureAligned();
        try self.writeValue(imm64);
    }
};

/// A simple builder API for bytecode functions.
pub const Builder = struct {
    /// The allocator used by this function.
    allocator: std.mem.Allocator,
    /// The function's unique identifier.
    id: core.FunctionId,
    /// The function's stack window size.
    stack_size: usize = 0,
    /// The function's stack window alignment.
    stack_align: usize = 8,
    /// The function's basic blocks.
    blocks: pl.ArrayList(*const Block) = .empty,

    /// Initialize a new builder for a bytecode function.
    pub fn init(allocator: std.mem.Allocator, id: core.FunctionId) !*const Builder {
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
    pub fn createBlock(ptr: *const Builder) !*const Block {
        const self = @constCast(ptr);

        const index = self.blocks.items.len;

        if (index > BlockId.MAX_INT) {
            log.debug("bytecode.Builder.createBlock: Cannot create more than {d} blocks in function {}", .{ BlockId.MAX_INT, self.id });
            return error.OutOfMemory;
        }

        const block = try Block.init(self, .fromInt(index));

        try self.blocks.append(self.allocator, block);

        return block;
    }

    pub const BlockMap = pl.UniqueReprMap(BlockId, core.MutInstructionAddr, 80);

    pub fn encode(ptr: *const Builder, encoder: *Encoder) Encoder.Error!void {
        const self = @constCast(ptr);

        if (self.blocks.items.len == 0) {
            log.debug("bytecode.Builder.finalize: Cannot finalize a function with no blocks", .{});
            return error.BadEncoding;
        }

        var fixups = Block.FixupMap{};
        defer fixups.deinit(self.allocator);

        var blocks = BlockMap{};
        defer blocks.deinit(self.allocator);

        for (self.blocks.items) |block| {
            const addr = encoder.getCurrentAddress();

            try blocks.put(self.allocator, block.id, @alignCast(@ptrCast(addr)));

            try block.encode(encoder, &fixups);
        }

        var fixup_it = fixups.iterator();

        while (fixup_it.next()) |entry| {
            const dest_block_id = entry.key_ptr.*;
            const dest_entry = blocks.get(dest_block_id) orelse {
                log.debug("bytecode.Builder.finalize: Block {} not found in fixup map", .{dest_block_id});
                return error.BadEncoding;
            };

            const fixup_set = entry.value_ptr.items;
            for (fixup_set) |fixup| {
                const original_bits = fixup.instr.*;
                const block_relative_offset = @as(i32, @intCast(@intFromPtr(dest_entry))) - @as(i32, @intCast(@intFromPtr(fixup.instr)));

                // we now need to erase the existing 32 bits at `fixup.bit_position`
                const mask = @as(u64, 0xFFFF_FFFF) << @intCast(fixup.bit_position);
                const cleared = original_bits & ~mask; // clear the 32-bit region
                const inserted = @as(u32, @bitCast(block_relative_offset)) << @intCast(fixup.bit_position);
                // insert the new operand
                const new_instr = cleared | inserted;

                fixup.instr.* = new_instr;
            }
        }
    }
};

pub const BlockId = Id.of(Block, 16);

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
    id: BlockId,
    /// The instructions making up the body of this block, in un-encoded form.
    body: pl.ArrayList(Proto) = .empty,
    /// The instruction that terminates this block.
    /// * Adding any instruction when this is non-`null` is a `BadEncoding` error
    /// * For all other purposes, `null` is semantically equivalent to `unreachable`
    ///
    /// This is intended for convenience. For example, when calling an effect
    /// handler *that is known to always cancel*, we can treat the `prompt` as
    /// terminal in higher-level code.
    terminator: ?Instruction.Term = null,

    /// Simple intermediate for storing instructions in a block stream.
    pub const Proto = struct {
        inner: Instruction.Basic,
        additional: AdditionalInfo = .none,

        pub const AdditionalInfo = union(enum) {
            none,
            wide_imm: u64,
            call_args: Buffer.fixed(core.Register, pl.MAX_REGISTERS),
            branch_target: BlockId,
        };
    };

    fn init(function: *const Builder, id: BlockId) error{OutOfMemory}!*const Block {
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

    pub const FixupMap = pl.UniqueReprMap(BlockId, pl.ArrayList(Encoder.Fixup), 80);

    /// Write this block's instructions into the provided bytecode encoder.
    pub fn encode(ptr: *const Block, encoder: *Encoder, fixups: *FixupMap) Encoder.Error!void {
        const self: *Block = @constCast(ptr);

        for (self.body.items) |proto| {
            const full_code = proto.inner.code.upcast();

            @setEvalBranchQuota(10_000); // a lot of comptime work ahead

            // We need to switch over the instruction code to find the proper function to call.
            inline for (comptime std.meta.fieldNames(Instruction.BasicOpCode)) |field_name| {
                const comptime_code = @field(Instruction.OpCode, field_name);

                if (comptime_code == full_code) {
                    if (comptime Instruction.isCall(comptime_code)) {
                        try encoder.instrCall(comptime_code, @field(proto.inner.data, field_name), proto.additional.call_args.asSlice());
                    } else if (comptime Instruction.isWide(comptime_code)) {
                        try encoder.instrWithImm64(comptime_code, @field(proto.inner.data, field_name), proto.additional.wide_imm);
                    } else if (comptime Instruction.isBranch(comptime_code)) {
                        const fixup = try encoder.instrBr(comptime_code, @field(proto.inner.data, field_name));

                        const gop = try fixups.getOrPut(self.function.allocator, proto.additional.branch_target);

                        if (!gop.found_existing) gop.value_ptr.* = .{};

                        try gop.value_ptr.append(self.function.allocator, fixup);
                    } else {
                        try encoder.instrPre(proto.inner.upcast());
                    }

                    break;
                }
            }
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
    pub fn composeInstr(ptr: *const Block, code: Instruction.OpCode, data: anytype) error{ BadEncoding, OutOfMemory }!void {
        const self: *Block = @constCast(ptr);

        if (self.terminator) |term| {
            log.debug("Cannot insert instruction `{s}` into block with terminator `{s}`", .{ @tagName(code), @tagName(term.code) });
            return error.BadEncoding;
        }

        switch (code.downcast()) {
            .basic => |b| {
                try self.body.append(self.function.allocator, Proto{ .inner = Instruction.Basic{
                    .code = b,
                    .data = Instruction.BasicOpData.fromBits(data),
                } });
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
    pub fn instr(ptr: *const Block, comptime code: Instruction.OpCode, data: Instruction.SetType(code)) error{ BadEncoding, OutOfMemory }!void {
        return ptr.composeInstr(code, data);
    }

    /// Append a pre-composed instruction into this block.
    ///
    /// * `instruction` must be properly composed, or runtime errors will occur.
    ///
    /// See also `instr`, which takes the individual components of an instruction separately.
    pub fn instrPre(ptr: *const Block, instruction: Instruction) error{ BadEncoding, OutOfMemory }!void {
        return ptr.composeInstr(instruction.code, instruction.data);
    }

    /// Encodes a branch instruction with a placeholder value and returns the address of the placeholder.
    pub fn instrBr(
        ptr: *const Block,
        comptime code: Instruction.BasicOpCode,
        data: Instruction.SetType(code),
    ) !Encoder.Fixup {
        const self: *Block = @constCast(ptr);

        if (comptime !Instruction.isBranch(code.upcast())) @compileError("instrBr can only be used with branch-family opcodes.");

        try self.body.append(self.function.allocator, Proto{
            .inner = Instruction.Basic{
                .code = code,
                .data = Instruction.BasicOpData.fromBits(data),
            },
            .additional = .{ .branch_target = BlockId.fromInt(0) }, // Placeholder for the target block
        });
    }

    /// Encodes a call-family instruction followed by its argument registers.
    /// This handles writing the instruction word, the argument registers, and any
    /// necessary padding to re-align the instruction stream.
    pub fn instrCall(
        ptr: *const Block,
        comptime code: Instruction.BasicOpCode,
        data: Instruction.SetType(code.upcast()),
        args: []const core.Register,
    ) !void {
        const self: *Block = @constCast(ptr);

        if (comptime !Instruction.isCall(code.upcast())) @compileError("instrCall can only be used with call-family opcodes.");

        try self.body.append(self.function.allocator, Proto{
            .inner = Instruction.Basic{
                .code = code,
                .data = Instruction.BasicOpData.fromBits(data),
            },
            .additional = .{ .call_args = .fromSlice(args) },
        });
    }

    /// Encodes an instruction that is followed by a 64-bit immediate value.
    pub fn instrWithImm64(
        ptr: *const Block,
        comptime code: Instruction.BasicOpCode,
        data: Instruction.SetType(code.upcast()),
        imm64: u64,
    ) !void {
        const self: *Block = @constCast(ptr);

        if (comptime !Instruction.isWide(code.upcast())) @compileError("instrWithImm64 used with an incompatible opcode.");

        try self.body.append(self.function.allocator, Proto{
            .inner = Instruction.Basic{
                .code = code,
                .data = Instruction.BasicOpData.fromBits(data),
            },
            .additional = .{ .wide_imm = imm64 },
        });
    }
};

/// Unified SymbolTable + AddressTable.
pub const Table = struct {
    /// Binds *fully-qualified* names to AddressTable ids
    symbol_table: SymbolTable = .{},
    /// Binds bytecode ids to addresses for the function being compiled
    address_table: AddressTable = .{},

    /// Clear the symbol and address table entries, retaining the current memory capacity.
    pub fn clear(self: *Table) void {
        self.symbol_table.clear();
        self.address_table.clear();
    }

    /// Deinitialize the symbol and address table, freeing all memory.
    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.symbol_table.deinit(allocator);
        self.address_table.deinit(allocator);
    }

    /// Bind a fully qualified name to an address, returning the address table id of the static.
    pub fn bind(
        self: *Table,
        allocator: std.mem.Allocator,
        name: []const u8,
        address: anytype,
    ) !core.StaticId {
        const PtrT = @TypeOf(address);
        const PtrT_info = @typeInfo(PtrT);
        if (comptime PtrT_info != .pointer or PtrT_info.pointer.size != .one) {
            @compileError("bytecode.Table.bind: Address must be a single value pointer type, got " ++ @typeName(PtrT));
        }

        const T = PtrT_info.pointer.child;
        const kind = comptime core.SymbolKind.fromType(T);

        const id = try self.address_table.bind(allocator, kind, @ptrCast(address));

        try self.symbol_table.bind(allocator, name, id);

        return id;
    }

    /// Copies the current state of this table into the provided buffer and returns a `core.Bytecode` wrapping the copy.
    pub fn encode(self: *const Table) !core.Bytecode {
        var encoder = Encoder{
            .writer = try Writer.init(),
        };

        const header = try encoder.create(core.Header);

        const start = encoder.getCurrentAddress();

        const symbol_table = try self.symbol_table.encode(&encoder);
        const address_table = try self.address_table.encode(&encoder);

        const end = encoder.getCurrentAddress();

        const size = @intFromPtr(end) - @intFromPtr(start);

        header.* = .{
            .size = size,
            .symbol_table = symbol_table,
            .address_table = address_table,
        };

        _ = try encoder.finalize();

        return .{ .header = header };
    }
};

/// A mirror of `core.SymbolTable` that is extensible.
pub const SymbolTable = struct {
    /// Binds fully-qualified names to AddressTable ids
    map: pl.StringArrayMap(core.StaticId) = .empty,

    /// Bind a fully qualified name to an address table id of a constant.
    pub fn bind(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: core.StaticId) !void {
        try self.map.put(allocator, name, id);
    }

    /// Get the address table id associated with the given fully qualified name.
    pub fn get(self: *const SymbolTable, name: []const u8) ?core.StaticId {
        return self.map.get(name);
    }

    /// Clears all entries in the symbol table, retaining the current memory capacity.
    pub fn clear(self: *SymbolTable) void {
        self.map.clearRetainingCapacity();
    }

    /// Writes the current state of this address table into the provided encoder,
    /// returning a new `core.SymbolTable` referencing the new buffers.
    pub fn encode(self: *const SymbolTable, encoder: *Encoder) !core.SymbolTable {
        const new_keys = try encoder.alloc(core.SymbolTable.Key, self.map.count());
        const new_values = try encoder.alloc(core.StaticId, self.map.count());

        var i: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const new_name = try encoder.dupe(u8, entry.key_ptr.*);

            new_keys[i] = .{
                .hash = pl.hash64(new_name),
                .name = .fromSlice(new_name),
            };

            new_values[i] = entry.value_ptr.*;

            i += 1;
        }

        return .{
            .keys = .fromSlice(new_keys),
            .values = .fromSlice(new_values),
        };
    }

    /// Deinitializes the symbol table, freeing all memory.
    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }
};

/// A mirror of `core.AddressTable` that is extensible.
pub const AddressTable = struct {
    data: pl.MultiArrayList(struct {
        kind: core.SymbolKind,
        address: *const anyopaque,
    }) = .empty,

    /// Clear all entries in the address table, retaining the current memory capacity.
    pub fn clear(self: *AddressTable) void {
        self.data.clearRetainingCapacity();
    }

    /// Deinitialize the address table, freeing all memory it owns.
    pub fn deinit(self: *AddressTable, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
    }

    /// Get the SymbolKind of an address by its id.
    pub fn getKind(self: *const AddressTable, id: core.StaticId) ?core.SymbolKind {
        const index = id.toInt();

        if (index < self.data.len) {
            return self.data.items(.kind)[index];
        } else {
            return null;
        }
    }

    /// Get the address of a static value by its id.
    pub fn getAddress(self: *const AddressTable, id: core.StaticId) ?*const anyopaque {
        const index = id.toInt();

        if (index < self.data.len) {
            return self.data.items(.address)[index];
        } else {
            return null;
        }
    }

    /// Get the address of a typed static by its id.
    pub fn get(self: *const AddressTable, id: anytype) ?*const core.StaticTypeFromId(id) {
        const T = @TypeOf(id);

        const addr = self.getAddress(id) orelse return null;

        if (comptime T == core.StaticId) {
            return addr;
        } else {
            const kind = self.getKind(id).?;
            const id_kind = comptime core.symbolKindFromId(T);

            std.debug.assert(kind == id_kind);

            return @ptrCast(@alignCast(addr));
        }
    }

    /// Bind an address to a static id with the given kind.
    pub fn bind(self: *AddressTable, allocator: std.mem.Allocator, kind: core.SymbolKind, address: *const anyopaque) !core.StaticId {
        const index = self.data.len;

        if (index > core.StaticId.MAX_INT) {
            log.debug("bytecode.AddressTable.bind: Cannot bind more than {d} symbols", .{core.StaticId.MAX_INT});
            return error.OutOfMemory;
        }

        try self.data.append(allocator, .{
            .kind = kind,
            .address = address,
        });

        return .fromInt(index);
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validateSymbol(self: *const AddressTable, id: core.StaticId) bool {
        return self.data.len > id.toInt();
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validateSymbolKind(self: *const AddressTable, kind: core.SymbolKind, id: core.StaticId) bool {
        const index = id.toInt();

        if (index < self.data.len) {
            return self.data.items(.kind)[index] == kind;
        } else {
            return false;
        }
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validate(self: *const AddressTable, id: anytype) bool {
        const T = @TypeOf(id);

        if (comptime T == core.StaticId) {
            return self.validateSymbol(id);
        } else {
            return self.validateSymbolKind(comptime core.symbolKindFromId(T), id);
        }
    }

    /// Writes the current state of this address table into the provided encoder,
    /// returning a new `core.AddressTable` referencing the new buffers.
    pub fn encode(self: *const AddressTable, encoder: *Encoder) !core.AddressTable {
        const new_kinds = try encoder.alloc(core.SymbolKind, self.data.len);
        const new_addresses = try encoder.alloc(*const anyopaque, self.data.len);

        const old_kinds = self.data.items(.kind);
        const old_addresses = self.data.items(.address);

        @memcpy(new_kinds, old_kinds);

        // Perform a deep copy of the data.
        for (0..self.data.len) |i| {
            const kind = old_kinds[i];
            const old_address: [*]const u8 = @ptrCast(old_addresses[i]);
            const data_size = core.sizeOfStaticFromKind(kind);
            const data_alignment = core.alignOfStaticFromKind(kind);

            try encoder.alignTo(data_alignment);
            const new_data_ptr = try encoder.alloc(u8, data_size);
            @memcpy(new_data_ptr, old_address[0..data_size]);
            new_addresses[i] = new_data_ptr.ptr;
        }

        return .{
            .kinds = .fromSlice(new_kinds),
            .addresses = .fromSlice(new_addresses),
        };
    }
};

test "BasicInstructionEncoding" {
    var encoder = try Encoder.init();
    defer encoder.deinit();

    try encoder.instr(.nop, .{});
    try encoder.instr(.halt, .{});
    try encoder.instr(.trap, .{});

    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    try disas(vmem, output_buf.writer());

    const output_str = output_buf.items;
    const first_newline = std.mem.indexOfScalar(u8, output_str, '\n') orelse return error.TestFailed;
    const actual = output_str[first_newline + 1 ..];

    const expected =
        \\    nop
        \\    halt
        \\    trap
        \\
    ;

    // We must use `splitScalar` and `join` to normalize the line endings,
    // as the heredoc might have different endings depending on the editor.
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');

    while (expected_lines.next()) |expected_line| {
        const actual_line = actual_lines.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected_line, actual_line);
    }
    if (actual_lines.next() != null) return error.TestFailed;
}

test "InstructionWithOperandsEncoding" {
    var encoder = try Encoder.init();
    defer encoder.deinit();

    try encoder.instr(.push_set, .{ .H = .fromInt(0x1234) });
    try encoder.instr(.br_if, .{ .R = .r(1), .I = 0xDEADBEEF });
    // Use the new helper to correctly encode a multi-word call instruction.
    const call_args = [_]core.Register{ .r(10), .r(11) };
    try encoder.instrCall(.call_c, .{ .R = .r(2), .F = .fromInt(0xABCD), .I = 2 }, &call_args);
    try encoder.instr(.addr_l, .{ .R = .r(4), .I = 0xCAFEBABE });

    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    try disas(vmem, output_buf.writer());

    const output_str = output_buf.items;
    const first_newline = std.mem.indexOfScalar(u8, output_str, '\n') orelse return error.TestFailed;
    const actual = output_str[first_newline + 1 ..];

    const expected =
        \\    push_set H:1234
        \\    br_if r1 i32:deadbeef
        \\    call_c r2 F:abcd i8:2 args: r10 r11
        \\    addr_l r4 i32:cafebabe
        \\
    ;

    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');

    while (expected_lines.next()) |expected_line| {
        const actual_line = actual_lines.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected_line, actual_line);
    }
    if (actual_lines.next() != null) return error.TestFailed;
}

test "BuilderApiEncoding" {
    const allocator = std.testing.allocator;

    const builder = try Builder.init(allocator, .fromInt(1));
    defer builder.deinit();

    const block1 = try builder.createBlock();
    try block1.instr(.bit_copy8c, .{ .R = .r(1), .I = 0x42 });
    try block1.instr(.br, .{ .I = 0 }); // Jump to next instruction/block start

    const block2 = try builder.createBlock();
    try block2.instr(.i_add8c, .{ .Rx = .r(1), .Ry = .r(1), .I = 1 });
    try block2.instr(.@"return", .{ .R = .r(1) });

    var encoder = try Encoder.init();
    defer encoder.deinit();

    try builder.encode(&encoder);

    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    var output_buf = std.ArrayList(u8).init(allocator);
    defer output_buf.deinit();

    try disas(vmem, output_buf.writer());

    const output_str = output_buf.items;
    const first_newline = std.mem.indexOfScalar(u8, output_str, '\n') orelse return error.TestFailed;
    const actual = output_str[first_newline + 1 ..];

    const expected =
        \\    bit_copy8c r1 i8:42
        \\    br i32:0
        \\    i_add8c r1 r1 i8:1
        \\    return r1
        \\
    ;

    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');

    while (expected_lines.next()) |expected_line| {
        const actual_line = actual_lines.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected_line, actual_line);
    }
    if (actual_lines.next() != null) return error.TestFailed;
}

test "BuilderEmptyTerminator" {
    const allocator = std.testing.allocator;

    const builder = try Builder.init(allocator, .fromInt(1));
    defer builder.deinit();

    const block = try builder.createBlock();
    try block.instr(.nop, .{});
    // No terminator set, should default to unreachable

    var encoder = try Encoder.init();
    defer encoder.deinit();

    try builder.encode(&encoder);

    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    var output_buf = std.ArrayList(u8).init(allocator);
    defer output_buf.deinit();

    try disas(vmem, output_buf.writer());

    const output_str = output_buf.items;
    const first_newline = std.mem.indexOfScalar(u8, output_str, '\n') orelse return error.TestFailed;
    const actual = output_str[first_newline + 1 ..];

    const expected =
        \\    nop
        \\    unreachable
        \\
    ;

    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');

    while (expected_lines.next()) |expected_line| {
        const actual_line = actual_lines.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected_line, actual_line);
    }
    if (actual_lines.next() != null) return error.TestFailed;
}

test "AddressTableEncoding" {
    const allocator = std.testing.allocator;
    var at = AddressTable{};
    defer at.deinit(allocator);

    // Create a dummy variable on the stack to get a valid, non-null pointer from.
    var dummy_instr: u64 = 0;
    const dummy_addr: [*]const core.InstructionBits = @ptrCast(&dummy_instr);

    // Create data on the stack for the pointers to point to.
    const my_func = core.Function{
        .header = core.EMPTY_HEADER,
        // Point the extents to the valid dummy address.
        .extents = .{ .base = dummy_addr, .upper = dummy_addr },
        .stack_size = 16,
    };
    const my_const_data = "test_const";
    const my_const = core.Constant.fromSlice(my_const_data);

    // Bind pointers to the real data.
    const addr1: *const anyopaque = &my_func;
    const addr2: *const anyopaque = &my_const;

    const id1 = try at.bind(allocator, .function, addr1);
    const id2 = try at.bind(allocator, .constant, addr2);

    try std.testing.expectEqual(@as(u32, 0), id1.toInt());
    try std.testing.expectEqual(@as(u32, 1), id2.toInt());

    var encoder = try Encoder.init();
    defer encoder.deinit();

    // The encode function will now be able to safely read from addr1 and addr2.
    const core_at = try at.encode(&encoder);
    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    try std.testing.expectEqual(@as(usize, 2), core_at.kinds.len);
    try std.testing.expectEqual(@as(usize, 2), core_at.addresses.len);
    try std.testing.expectEqual(core.SymbolKind.function, core_at.kinds.asSlice()[0]);
    try std.testing.expectEqual(core.SymbolKind.constant, core_at.kinds.asSlice()[1]);

    // We can also verify the copied data in the new buffer.
    const new_func_ptr: *const core.Function = @ptrCast(@alignCast(core_at.addresses.asSlice()[0]));
    try std.testing.expectEqual(@as(u16, 16), new_func_ptr.stack_size);
    // Verify the extents were also copied correctly.
    try std.testing.expect(@intFromPtr(new_func_ptr.extents.base) != 0);

    const new_const_ptr: *const core.Constant = @ptrCast(@alignCast(core_at.addresses.asSlice()[1]));
    try std.testing.expectEqualSlices(u8, "test_const", new_const_ptr.asSlice());
}

test "SymbolTableEncoding" {
    const allocator = std.testing.allocator;
    var st = SymbolTable{};
    defer st.deinit(allocator);

    try st.bind(allocator, "foo", .fromInt(1));
    try st.bind(allocator, "bar.baz", .fromInt(2));

    var encoder = try Encoder.init();
    defer encoder.deinit();

    const core_st = try st.encode(&encoder);
    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    try std.testing.expectEqual(@as(usize, 2), core_st.values.len);

    var found_foo = false;
    var found_bar_baz = false;

    for (0..core_st.values.len) |i| {
        const entry = .{ .key = core_st.keys.asSlice()[i], .value = core_st.values.asSlice()[i] };

        if (std.mem.eql(u8, entry.key.name.asSlice(), "foo")) {
            try std.testing.expectEqual(false, found_foo);
            found_foo = true;
            try std.testing.expectEqual(@as(u32, 1), entry.value.toInt());
        } else if (std.mem.eql(u8, entry.key.name.asSlice(), "bar.baz")) {
            try std.testing.expectEqual(false, found_bar_baz);
            found_bar_baz = true;
            try std.testing.expectEqual(@as(u32, 2), entry.value.toInt());
        } else {
            return error.TestFailed; // Found unexpected key
        }
    }

    try std.testing.expect(found_foo);
    try std.testing.expect(found_bar_baz);
}

test "Block: adding instruction after terminator fails" {
    const allocator = std.testing.allocator;

    const builder = try Builder.init(allocator, .fromInt(1));
    defer builder.deinit();

    const block = try builder.createBlock();
    try block.instr(.@"return", .{ .R = .r(0) }); // Set the terminator

    // Attempting to add another instruction should now fail.
    try std.testing.expectError(error.BadEncoding, block.instr(.nop, .{}));
}

test "Builder: encoding function with no blocks fails" {
    const allocator = std.testing.allocator;
    const builder = try Builder.init(allocator, .fromInt(1));
    defer builder.deinit();

    var encoder = try Encoder.init();
    defer encoder.deinit();

    // Encoding a builder with no blocks should return an error.
    try std.testing.expectError(error.BadEncoding, builder.encode(&encoder));
}

test "Disassembler: all operand types" {
    var encoder = try Encoder.init();
    defer encoder.deinit();

    // Test each operand type supported by the disassembler using a real instruction.

    // core.HandlerSetId
    try encoder.instr(.push_set, .{ .H = .fromInt(0xAAAA) });
    // core.UpvalueId
    try encoder.instr(.addr_u, .{ .R = .r(1), .U = .fromInt(0xBB) });
    // core.GlobalId
    try encoder.instr(.addr_g, .{ .R = .r(2), .G = .fromInt(0xCCCC) });
    // core.FunctionId
    try encoder.instrCall(.call_c, .{ .R = .r(3), .F = .fromInt(0xDDDD), .I = 0 }, &.{});
    // core.BuiltinAddressId
    try encoder.instr(.addr_b, .{ .R = .r(4), .B = .fromInt(0x1111) });
    // core.ForeignAddressId
    try encoder.instr(.addr_x, .{ .R = .r(5), .X = .fromInt(0x2222) });
    // core.EffectId
    try encoder.instrCall(.prompt, .{ .R = .r(6), .E = .fromInt(0x3333), .I = 0 }, &.{});
    // core.ConstantId
    try encoder.instr(.addr_c, .{ .R = .r(7), .C = .fromInt(0x5555) });
    // u8
    try encoder.instr(.bit_copy8c, .{ .R = .r(8), .I = 0x42 });
    // u16
    try encoder.instr(.bit_copy16c, .{ .R = .r(9), .I = 0x6789 });
    // u32
    try encoder.instr(.bit_copy32c, .{ .R = .r(10), .I = 0xABCDEF01 });
    // u64
    try encoder.instrWithImm64(.f_add64c, .{ .Rx = .r(11), .Ry = .r(12) }, 0x1122334455667788);

    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    var output_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer output_buf.deinit();

    try disas(vmem, output_buf.writer());

    const output_str = output_buf.items;
    const first_newline = std.mem.indexOfScalar(u8, output_str, '\n') orelse return error.TestFailed;
    const actual = output_str[first_newline + 1 ..];

    const expected =
        \\    push_set H:aaaa
        \\    addr_u r1 U:bb
        \\    addr_g r2 G:cccc
        \\    call_c r3 F:dddd i8:0
        \\    addr_b r4 B:1111
        \\    addr_x r5 X:2222
        \\    prompt r6 E:3333 i8:0
        \\    addr_c r7 C:5555
        \\    bit_copy8c r8 i8:42
        \\    bit_copy16c r9 i16:6789
        \\    bit_copy32c r10 i32:abcdef01
        \\    f_add64c r11 r12 i64:1122334455667788
        \\
    ;

    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');

    while (expected_lines.next()) |expected_line| {
        const actual_line = actual_lines.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected_line, actual_line);
    }
    if (actual_lines.next() != null) return error.TestFailed;
}

test "Multi-word instruction encoding" {
    const allocator = std.testing.allocator;
    var encoder = try Encoder.init();
    defer encoder.deinit();

    // Test a call with arguments
    const call_args = [_]core.Register{ .r(10), .r(11), .r(12) };
    try encoder.instrCall(.call, .{ .Rx = .r(0), .Ry = .r(1), .I = 3 }, &call_args);

    // Test a multi-word immediate instruction
    try encoder.instrWithImm64(.i_add64c, .{ .Rx = .r(2), .Ry = .r(3) }, 0xDEADBEEF_CAFEBABE);

    // A simple instruction to ensure we aligned correctly
    try encoder.instr(.nop, .{});

    const vmem = try encoder.finalize();
    defer std.posix.munmap(@alignCast(vmem));

    var output_buf = std.ArrayList(u8).init(allocator);
    defer output_buf.deinit();

    // This now requires the updated `disas` function
    try disas(vmem, output_buf.writer());

    const output_str = output_buf.items;
    const first_newline = std.mem.indexOfScalar(u8, output_str, '\n') orelse return error.TestFailed;
    const actual = output_str[first_newline + 1 ..];

    const expected =
        \\    call r0 r1 i8:3 args: r10 r11 r12
        \\    i_add64c r2 r3 i64:deadbeefcafebabe
        \\    nop
        \\
    ;

    // Line-by-line comparison...
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');

    while (expected_lines.next()) |expected_line| {
        const actual_line = actual_lines.next() orelse return error.TestFailed;
        try std.testing.expectEqualStrings(expected_line, actual_line);
    }
    if (actual_lines.next() != null) return error.TestFailed;
}

test "Misaligned instruction encoding panics" {
    var encoder = try Encoder.init();
    defer encoder.deinit();

    try encoder.writeByte(0xFF); // Deliberately misalign the stream

    const x = encoder.instr(.nop, .{});

    try std.testing.expectError(error.UnalignedWrite, x);
}

test "Table.encode full lifecycle" {
    const allocator = std.heap.page_allocator;
    var table = Table{};
    defer table.deinit(allocator);

    // Create a dummy variable on the stack to get a valid, non-null pointer from.
    var dummy_instr: u64 = 0;
    const dummy_addr: [*]const core.InstructionBits = @ptrCast(&dummy_instr);

    // Create data on the stack for the pointers to point to.
    const my_func = core.Function{
        .header = core.EMPTY_HEADER,
        // Point the extents to the valid dummy address.
        .extents = .{ .base = dummy_addr, .upper = dummy_addr },
        .stack_size = 16,
    };
    const my_const_data = "test_const";
    const my_const = core.Constant.fromSlice(my_const_data);

    const func_id = try table.bind(allocator, "my_main", &my_func);
    const const_id = try table.bind(allocator, "my_greeting", &my_const);

    try std.testing.expectEqual(@as(u32, 0), func_id.toInt());
    try std.testing.expectEqual(@as(u32, 1), const_id.toInt());

    // 2. Encode the table into a self-contained bytecode unit.
    const bytecode_unit = try table.encode();
    defer bytecode_unit.deinit();

    // 3. Inspect the resulting core.Bytecode object.
    const header = bytecode_unit.header;
    try std.testing.expectEqual(@as(usize, 2), header.address_table.addresses.len);

    // 4. Look up the symbols by name in the encoded structure.
    const func_addr_info = header.lookupAddress("my_main") orelse return error.TestFailed;
    try std.testing.expectEqual(core.SymbolKind.function, func_addr_info[0]);
    const func_ptr: *const core.Function = @ptrCast(@alignCast(func_addr_info[1]));
    // Check against the original data to ensure the copy was successful.
    try std.testing.expectEqual(@as(u16, 16), func_ptr.stack_size);

    const const_addr_info = header.lookupAddress("my_greeting") orelse return error.TestFailed;
    try std.testing.expectEqual(core.SymbolKind.constant, const_addr_info[0]);
    const const_ptr: *const core.Constant = @ptrCast(@alignCast(const_addr_info[1]));
    try std.testing.expectEqualSlices(u8, my_const_data, const_ptr.asSlice());
}
