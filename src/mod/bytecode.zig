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
                    const operandBytes = std.mem.asBytes(&@field(set, opName));

                    try writer.print(" (" ++ opName ++ " {x})", .{ operandBytes });
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



/// Unified SymbolTable + AddressTable.
pub const Table = struct {
    /// Binds *fully-qualified* names to AddressTable ids
    symbol_table: SymbolTable = .{},
    /// Binds bytecode ids to addresses for the function being compiled
    address_table: AddressTable = .{},

    /// Get an id and symbol kind for a given name, if it is bound in this table.
    pub fn getGenericId(self: *const Table, name: []const u8) ?core.SymbolTable.Value {
        return self.symbol_table.getGeneric(name);
    }

    /// Get a constant id for a given name, if it is bound in this table.
    pub fn getConstantId(self: *const Table, name: []const u8) ?Id.of(core.Constant) {
        return self.symbol_table.getConstant(name);
    }

    /// Get a global id for a given name, if it is bound in this table.
    pub fn getGlobalId(self: *const Table, name: []const u8) ?Id.of(core.Global) {
        return self.symbol_table.getGlobal(name);
    }

    /// Get a function id for a given name, if it is bound in this table.
    pub fn getFunctionId(self: *const Table, name: []const u8) ?Id.of(core.Function) {
        return self.symbol_table.getFunction(name);
    }

    /// Get a builtin address id for a given name, if it is bound in this table.
    pub fn getBuiltinAddressId(self: *const Table, name: []const u8) ?Id.of(core.BuiltinAddress) {
        return self.symbol_table.getBuiltinAddress(name);
    }

    /// Get a foreign address id for a given name, if it is bound in this table.
    pub fn getForeignAddressId(self: *const Table, name: []const u8) ?Id.of(core.ForeignAddress) {
        return self.symbol_table.getForeignAddress(name);
    }

    /// Get a handler set id for a given name, if it is bound in this table.
    pub fn getHandlerSetId(self: *const Table, name: []const u8) ?Id.of(core.HandlerSet) {
        return self.symbol_table.getHandlerSet(name);
    }

    /// Get an effect id for a given name, if it is bound in this table.
    pub fn getEffectId(self: *const Table, name: []const u8) ?Id.of(core.Effect) {
        return self.symbol_table.getEffect(name);
    }

    /// Get a constant by id.
    /// * only checked in safe mode
    pub fn getConstantById(self: *const Table, id: Id.of(core.Constant)) *const core.Constant {
        return self.address_table.getConstant(id);
    }

    /// Get a global by id.
    /// * only checked in safe mode
    pub fn getGlobalById(self: *const Table, id: Id.of(core.Global)) *const core.Global {
        return self.address_table.getGlobal(id);
    }

    /// Get a function by id.
    /// * only checked in safe mode
    pub fn getFunctionById(self: *const Table, id: Id.of(core.Function)) *const core.Function {
        return self.address_table.getFunction(id);
    }

    /// Get a builtin address by id.
    /// * only checked in safe mode
    pub fn getBuiltinAddressById(self: *const Table, id: Id.of(core.BuiltinAddress)) *const core.BuiltinAddress {
        return self.address_table.getBuiltinAddress(id);
    }

    /// Get a foreign address by id.
    /// * only checked in safe mode
    pub fn getForeignAddressById(self: *const Table, id: Id.of(core.ForeignAddress)) *const core.ForeignAddress {
        return self.address_table.getForeignAddress(id);
    }

    /// Get a handler set by id.
    /// * only checked in safe mode
    pub fn getHandlerSetById(self: *const Table, id: Id.of(core.HandlerSet)) *const core.HandlerSet {
        return self.address_table.getHandlerSet(id);
    }

    /// Get an effect by id.
    /// * only checked in safe mode
    pub fn getEffectById(self: *const Table, id: Id.of(core.Effect)) *const core.Effect {
        return self.address_table.getEffect(id);
    }

    /// Get a constant by name.
    pub fn getConstantByName(self: *const Table, name: []const u8) ?*const core.Constant {
        return if (self.symbol_table.getConstant(name)) |v| self.address_table.getConstant(v) else null;
    }

    /// Get a global by name.
    pub fn getGlobalByName(self: *const Table, name: []const u8) ?*const core.Global {
        return if (self.symbol_table.getGlobal(name)) |v| self.address_table.getGlobal(v) else null;
    }

    /// Get a function by name.
    pub fn getFunctionByName(self: *const Table, name: []const u8) ?*const core.Function {
        return if (self.symbol_table.getFunction(name)) |v| self.address_table.getFunction(v) else null;
    }

    /// Get a builtin address by name.
    pub fn getBuiltinAddressByName(self: *const Table, name: []const u8) ?*const core.BuiltinAddress {
        return if (self.symbol_table.getBuiltinAddress(name)) |v| self.address_table.getBuiltinAddress(v) else null;
    }

    /// Get a foreign address by name.
    pub fn getForeignAddressByName(self: *const Table, name: []const u8) ?*const core.ForeignAddress {
        return if (self.symbol_table.getForeignAddress(name)) |v| self.address_table.getForeignAddress(v) else null;
    }

    /// Get a handler set by name.
    pub fn getHandlerSetByName(self: *const Table, name: []const u8) ?*const core.HandlerSet {
        return if (self.symbol_table.getHandlerSet(name)) |v| self.address_table.getHandlerSet(v) else null;
    }

    /// Get an effect by name.
    pub fn getEffectByName(self: *const Table, name: []const u8) ?*const core.Effect {
        return if (self.symbol_table.getEffect(name)) |v| self.address_table.getEffect(v) else null;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided constant, within this table.
    pub fn bindConstant(self: *Table, allocator: std.mem.Allocator, name: []const u8, constant: *const core.Constant) !Id.of(core.Constant) {
        if (self.validateConstantName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindConstant(allocator, constant);
        try self.symbol_table.bindConstant(allocator, name, id);
        return id;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided global, within this table.
    pub fn bindGlobal(self: *Table, allocator: std.mem.Allocator, name: []const u8, global: *const core.Global) !Id.of(core.Global) {
        if (self.validateGlobalName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindGlobal(allocator, global);
        try self.symbol_table.bindGlobal(allocator, name, id);
        return id;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided function, within this table.
    pub fn bindFunction(self: *Table, allocator: std.mem.Allocator, name: []const u8, function: *const core.Function) !Id.of(core.Function) {
        if (self.validateFunctionName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindFunction(allocator, function);
        try self.symbol_table.bindFunction(allocator, name, id);
        return id;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided builtin address, within this table.
    pub fn bindBuiltinAddress(self: *Table, allocator: std.mem.Allocator, name: []const u8, builtin_address: *const core.BuiltinAddress) !Id.of(core.BuiltinAddress) {
        if (self.validateBuiltinAddressName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindBuiltinAddress(allocator, builtin_address);
        try self.symbol_table.bindBuiltinAddress(allocator, name, id);
        return id;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided foreign address, within this table.
    pub fn bindForeignAddress(self: *Table, allocator: std.mem.Allocator, name: []const u8, foreign_address: *const core.ForeignAddress) !Id.of(core.ForeignAddress) {
        if (self.validateForeignAddressName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindForeignAddress(allocator, foreign_address);
        try self.symbol_table.bindForeignAddress(allocator, name, id);
        return id;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided handler set, within this table.
    pub fn bindHandlerSet(self: *Table, allocator: std.mem.Allocator, name: []const u8, handler_set: *const core.HandlerSet) !Id.of(core.HandlerSet) {
        if (self.validateHandlerSetName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindHandlerSet(allocator, handler_set);
        try self.symbol_table.bindHandlerSet(allocator, name, id);
        return id;
    }

    /// Bind the provided fully qualified name to a newly-created id and the provided effect, within this table.
    pub fn bindEffect(self: *Table, allocator: std.mem.Allocator, name: []const u8, effect: *const core.Effect) !Id.of(core.Effect) {
        if (self.validateEffectName(name)) return error.DuplicateBinding;

        const id = try self.address_table.bindEffect(allocator, effect);
        try self.symbol_table.bindEffect(allocator, name, id);
        return id;
    }

    /// Validate that the given name binds some value.
    pub fn validateGenericName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.getGeneric(name) != null;
    }

    /// Validate that the given name binds a constant id.
    pub fn validateConstantName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateConstant(name);
    }

    /// Validate that the given name binds a global id.
    pub fn validateGlobalName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateGlobal(name);
    }

    /// Validate that the given name binds a function id.
    pub fn validateFunctionName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateFunction(name);
    }

    /// Validate that the given name binds a builtin address id.
    pub fn validateBuiltinAddressName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateBuiltinAddress(name);
    }

    /// Validate that the given name binds a foreign address id.
    pub fn validateForeignAddressName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateForeignAddress(name);
    }

    /// Validate that the given name binds a handler set id.
    pub fn validateHandlerSetName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateHandlerSet(name);
    }

    /// Validate that the given name binds an effect id.
    pub fn validateEffectName(self: *const Table, name: []const u8) bool {
        return self.symbol_table.validateEffect(name);
    }

    /// Ensure that a given constant id is valid.
    pub fn validateConstantId(self: *const Table, id: Id.of(core.Constant)) bool {
        return self.address_table.validateConstant(id);
    }

    /// Ensure that a given global id is valid.
    pub fn validateGlobalId(self: *const Table, id: Id.of(core.Global)) bool {
        return self.address_table.validateGlobal(id);
    }

    /// Ensure that a given function id is valid.
    pub fn validateFunctionId(self: *const Table, id: Id.of(core.Function)) bool {
        return self.address_table.validateFunction(id);
    }

    /// Ensure that a given builtin address id is valid.
    pub fn validateBuiltinAddressId(self: *const Table, id: Id.of(core.BuiltinAddress)) bool {
        return self.address_table.validateBuiltinAddress(id);
    }

    /// Ensure that a given foreign address id is valid.
    pub fn validateForeignAddressId(self: *const Table, id: Id.of(core.ForeignAddress)) bool {
        return self.address_table.validateForeignAddress(id);
    }

    /// Ensure that a given handler set id is valid.
    pub fn validateHandlerSetId(self: *const Table, id: Id.of(core.HandlerSet)) bool {
        return self.address_table.validateHandlerSet(id);
    }

    /// Ensure that a given effect id is valid.
    pub fn validateEffectId(self: *const Table, id: Id.of(core.Effect)) bool {
        return self.address_table.validateEffect(id);
    }

    /// Clear the symbol and address table entries, retaining the current memory capacity.
    pub fn clear(self: *Table) void {
        self.symbol_table.clear();
        self.address_table.clear();
    }

    /// Copies the current state of this table into the provided buffer and returns a `core.Header` wrapping the copy.
    pub fn write(self: *const Table, buf: []u8, out: *core.Header) usize { // TODO: use an encoder pattern like other modules
        var offset = self.symbol_table.write(buf, &out.symbols);
        offset += self.address_table.write(buf[offset..], &out.addresses);
        return offset;
    }

    /// Deinitialize the symbol and address table, freeing all memory.
    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.symbol_table.deinit(allocator);
        self.address_table.deinit(allocator);
    }
};

/// A mirror of `core.SymbolTable` that is extensible.
pub const SymbolTable = struct {
    /// Binds *fully-qualified* names to AddressTable ids
    map: std.StringArrayHashMapUnmanaged(core.SymbolTable.Value) = .empty, // TODO why is this not in pl?


    /// Bind a fully qualified name to an address table id of a constant.
    pub fn bindConstant(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.Constant)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .constant, .id = id.cast(anyopaque) });
    }

    /// Bind a fully qualified name to an address table id of a global.
    pub fn bindGlobal(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.Global)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .global, .id = id.cast(anyopaque) });
    }

    /// Bind a fully qualified name to an address table id of a function.
    pub fn bindFunction(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.Function)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .function, .id = id.cast(anyopaque) });
    }

    /// Bind a fully qualified name to an address table id of a builtin address.
    pub fn bindBuiltinAddress(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.BuiltinAddress)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .builtin, .id = id.cast(anyopaque) });
    }

    /// Bind a fully qualified name to an address table id of a foreign address.
    pub fn bindForeignAddress(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.ForeignAddress)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .foreign_address, .id = id.cast(anyopaque) });
    }

    /// Bind a fully qualified name to an address table id of a handler set.
    pub fn bindHandlerSet(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.HandlerSet)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .handler_set, .id = id.cast(anyopaque) });
    }

    /// Bind a fully qualified name to an address table id of an effect.
    pub fn bindEffect(self: *SymbolTable, allocator: std.mem.Allocator, name: []const u8, id: Id.of(core.Effect)) !void {
        try self.map.putNoClobber(allocator, name, .{ .kind = .effect, .id = id.cast(anyopaque) });
    }

    /// Get the address table id associated with the given fully qualified name.
    pub fn getGeneric(self: *const SymbolTable, name: []const u8) ?core.SymbolTable.Value {
        return self.map.get(name);
    }

    /// Get the address table constant id associated with the given fully qualified name.
    pub fn getConstant(self: *const SymbolTable, name: []const u8) ?Id.of(core.Constant) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .constant) {
                return v.id.cast(core.Constant);
            }
        }

        return null;
    }

    /// Get the address table global id associated with the given fully qualified name.
    pub fn getGlobal(self: *const SymbolTable, name: []const u8) ?Id.of(core.Global) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .global) {
                return v.id.cast(core.Global);
            }
        }

        return null;
    }

    /// Get the address table function id associated with the given fully qualified name.
    pub fn getFunction(self: *const SymbolTable, name: []const u8) ?Id.of(core.Function) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .function) {
                return v.id.cast(core.Function);
            }
        }

        return null;
    }

    /// Get the address table builtin address id associated with the given fully qualified name.
    pub fn getBuiltinAddress(self: *const SymbolTable, name: []const u8) ?Id.of(core.BuiltinAddress) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .builtin) {
                return v.id.cast(core.BuiltinAddress);
            }
        }

        return null;
    }

    /// Get the address table foreign address id associated with the given fully qualified name.
    pub fn getForeignAddress(self: *const SymbolTable, name: []const u8) ?Id.of(core.ForeignAddress) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .foreign_address) {
                return v.id.cast(core.ForeignAddress);
            }
        }

        return null;
    }

    /// Get the address table handler set id associated with the given fully qualified name.
    pub fn getHandlerSet(self: *const SymbolTable, name: []const u8) ?Id.of(core.HandlerSet) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .handler_set) {
                return v.id.cast(core.HandlerSet);
            }
        }

        return null;
    }

    /// Get the address table effect id associated with the given fully qualified name.
    pub fn getEffect(self: *const SymbolTable, name: []const u8) ?Id.of(core.Effect) {
        const entry = self.map.get(name);

        if (entry) |v| {
            if (v.kind == .effect) {
                return v.id.cast(core.Effect);
            }
        }

        return null;
    }

    /// Ensure that a given name binds some value, returning the type if it does.
    pub fn validateGeneric(self: *const SymbolTable, name: []const u8) ?core.SymbolKind {
        const entry = self.map.get(name);
        if (entry) |v| return v.kind;
        return null;
    }

    /// Validate that the given name binds a constant id.
    pub fn validateConstant(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .constant else false;
    }

    /// Validate that the given name binds a global id.
    pub fn validateGlobal(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .global else false;
    }

    /// Validate that the given name binds a function id.
    pub fn validateFunction(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .function else false;
    }

    /// Validate that the given name binds a builtin address id.
    pub fn validateBuiltinAddress(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .builtin else false;
    }

    /// Validate that the given name binds a foreign address id.
    pub fn validateForeignAddress(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .foreign_address else false;
    }

    /// Validate that the given name binds a handler set id.
    pub fn validateHandlerSet(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .handler_set else false;
    }

    /// Validate that the given name binds an effect id.
    pub fn validateEffect(self: *const SymbolTable, name: []const u8) bool {
        const entry = self.map.get(name);
        return if (entry) |e| e.kind == .effect else false;
    }

    /// Clears all entries in the symbol table, retaining the current memory capacity.
    pub fn clear(self: *SymbolTable) void {
        self.map.clearRetainingCapacity();
    }

    /// Copies the current state of this table into the provided buffer and returns a `core.SymbolTable` wrapping the copy.
    pub fn write(self: *const SymbolTable, buf: []u8, out: *core.SymbolTable) usize { // TODO: use an encoder pattern like other modules
        const key_size = comptime @sizeOf(core.SymbolTable.Key);
        const val_size = comptime @sizeOf(core.SymbolTable.Value);

        var bytes_len: usize = 0;
        for (self.map.keys()) |key_ptr| {
            bytes_len += key_ptr.len;
        }

        const total_len = bytes_len + (key_size + val_size) * self.map.count();
        std.debug.assert(buf.len >= total_len);

        var bytes_offset: usize = 0;

        const key_buf: []core.SymbolTable.Key = @alignCast(std.mem.bytesAsSlice(core.SymbolTable.Key, buf[bytes_len..bytes_len + key_size * self.map.count()]));
        const val_buf: []core.SymbolTable.Value = @alignCast(std.mem.bytesAsSlice(core.SymbolTable.Value, buf[bytes_len + key_size * self.map.count()..total_len]));

        var it = self.map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            const key_copy = buf[bytes_offset..bytes_offset + entry.key_ptr.len];
            bytes_offset += entry.key_ptr.len;
            @memcpy(key_copy, entry.key_ptr.*);

            key_buf[i] = core.SymbolTable.Key{
                .hash = pl.hash64(entry.key_ptr.*),
                .name = .fromSlice(key_copy),
            };

            val_buf[i] = entry.value_ptr.*;

            i += 1;
        }

        out.* = core.SymbolTable{
            .keys = .fromSlice(key_buf),
            .values = .fromSlice(val_buf),
        };

        return total_len;
    }

    /// Deinitializes the symbol table, freeing all memory.
    pub fn deinit(self: *SymbolTable, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
    }
};

/// A mirror of `core.AddressTable` that is extensible.
pub const AddressTable = struct {
    /// Constant value bindings section.
    constants: pl.ArrayList(*const core.Constant) = .empty,
    /// Global value bindings section.
    globals: pl.ArrayList(*const core.Global) = .empty,
    /// Function value bindings section.
    functions: pl.ArrayList(*const core.Function) = .empty,
    /// Builtin function value bindings section.
    builtin_addresses: pl.ArrayList(*const core.BuiltinAddress) = .empty,
    /// C ABI value bindings section.
    foreign_addresses: pl.ArrayList(*const core.ForeignAddress) = .empty,
    /// Effect handler set bindings section.
    handler_sets: pl.ArrayList(*const core.HandlerSet) = .empty,
    /// Effect identity bindings section.
    effects: pl.ArrayList(*const core.Effect) = .empty,

    /// Bind a constant pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindConstant(self: *AddressTable, allocator: std.mem.Allocator, constant: *const core.Constant) !Id.of(core.Constant) {
        const idx = self.constants.items.len;
        try self.constants.append(allocator, constant);
        return Id.of(core.Constant).fromInt(idx);
    }

    /// Bind a global pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindGlobal(self: *AddressTable, allocator: std.mem.Allocator, global: *const core.Global) !Id.of(core.Global) {
        const idx = self.globals.items.len;
        try self.globals.append(allocator, global);
        return Id.of(core.Global).fromInt(idx);
    }

    /// Bind a function pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindFunction(self: *AddressTable, allocator: std.mem.Allocator, function: *const core.Function) !Id.of(core.Function) {
        const idx = self.functions.items.len;
        try self.functions.append(allocator, function);
        return Id.of(core.Function).fromInt(idx);
    }

    /// Bind a builtin address pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindBuiltinAddress(self: *AddressTable, allocator: std.mem.Allocator, builtin_address: *const core.BuiltinAddress) !Id.of(core.BuiltinAddress) {
        const idx = self.builtin_addresses.items.len;
        try self.builtin_addresses.append(allocator, builtin_address);
        return Id.of(core.BuiltinAddress).fromInt(idx);
    }

    /// Bind a foreign address pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindForeignAddress(self: *AddressTable, allocator: std.mem.Allocator, foreign_address: *const core.ForeignAddress) !Id.of(core.ForeignAddress) {
        const idx = self.foreign_addresses.items.len;
        try self.foreign_addresses.append(allocator, foreign_address);
        return Id.of(core.ForeignAddress).fromInt(idx);
    }

    /// Bind a handler set pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindHandlerSet(self: *AddressTable, allocator: std.mem.Allocator, handler_set: *const core.HandlerSet) !Id.of(core.HandlerSet) {
        const idx = self.handler_sets.items.len;
        try self.handler_sets.append(allocator, handler_set);
        return Id.of(core.HandlerSet).fromInt(idx);
    }

    /// Bind a effect pointer into this address table, yielding an id to refer to it by in future.
    /// * Id returned is unique to this address table and any `core.AddressTable` produced with it; it cannot be used with others.
    pub fn bindEffect(self: *AddressTable, allocator: std.mem.Allocator, effect: *const core.Effect) !Id.of(core.Effect) {
        const idx = self.effects.items.len;
        try self.effects.append(allocator, effect);
        return Id.of(core.Effect).fromInt(idx);
    }

    /// Get the constant pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getConstant(self: *const AddressTable, id: Id.of(core.Constant)) *const core.Constant {
        return self.constants.items[id.toInt()];
    }

    /// Get the global pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getGlobal(self: *const AddressTable, id: Id.of(core.Global)) *const core.Global {
        return self.globals.items[id.toInt()];
    }

    /// Get the function pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getFunction(self: *const AddressTable, id: Id.of(core.Function)) *const core.Function {
        return self.functions.items[id.toInt()];
    }

    /// Get the builtin address pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getBuiltinAddress(self: *const AddressTable, id: Id.of(core.BuiltinAddress)) *const core.BuiltinAddress {
        return self.builtin_addresses.items[id.toInt()];
    }

    /// Get the foreign address pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getForeignAddress(self: *const AddressTable, id: Id.of(core.ForeignAddress)) *const core.ForeignAddress {
        return self.foreign_addresses.items[id.toInt()];
    }

    /// Get the handler set pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getHandlerSet(self: *const AddressTable, id: Id.of(core.HandlerSet)) *const core.HandlerSet {
        return self.handler_sets.items[id.toInt()];
    }

    /// Get the effect pointer associated with the given id.
    /// * only checked in safe mode
    pub fn getEffect(self: *const AddressTable, id: Id.of(core.Effect)) *const core.Effect {
        return self.effects.items[id.toInt()];
    }

    /// Ensure that a given constant id is valid.
    pub fn validateConstant(self: *const AddressTable, id: Id.of(core.Constant)) bool {
        return id.toInt() < self.constants.items.len;
    }

    /// Ensure that a given global id is valid.
    pub fn validateGlobal(self: *const AddressTable, id: Id.of(core.Global)) bool {
        return id.toInt() < self.globals.items.len;
    }

    /// Ensure that a given function id is valid.
    pub fn validateFunction(self: *const AddressTable, id: Id.of(core.Function)) bool {
        return id.toInt() < self.functions.items.len;
    }

    /// Ensure that a given builtin address id is valid.
    pub fn validateBuiltinAddress(self: *const AddressTable, id: Id.of(core.BuiltinAddress)) bool {
        return id.toInt() < self.builtin_addresses.items.len;
    }

    /// Ensure that a given foreign address id is valid.
    pub fn validateForeignAddress(self: *const AddressTable, id: Id.of(core.ForeignAddress)) bool {
        return id.toInt() < self.foreign_addresses.items.len;
    }

    /// Ensure that a given handler set id is valid.
    pub fn validateHandlerSet(self: *const AddressTable, id: Id.of(core.HandlerSet)) bool {
        return id.toInt() < self.handler_sets.items.len;
    }

    /// Ensure that a given effect id is valid.
    pub fn validateEffect(self: *const AddressTable, id: Id.of(core.Effect)) bool {
        return id.toInt() < self.effects.items.len;
    }

    /// Clears all sections of the address table, retaining the current memory capacity.
    pub fn clear(self: *AddressTable) void {
        self.constants.clearRetainingCapacity();
        self.globals.clearRetainingCapacity();
        self.functions.clearRetainingCapacity();
        self.builtin_addresses.clearRetainingCapacity();
        self.foreign_addresses.clearRetainingCapacity();
        self.handler_sets.clearRetainingCapacity();
        self.effects.clearRetainingCapacity();
    }

    /// Deinitializes the address table, freeing all memory.
    pub fn deinit(self: *AddressTable, allocator: std.mem.Allocator) void {
        self.constants.deinit(allocator);
        self.globals.deinit(allocator);
        self.functions.deinit(allocator);
        self.builtin_addresses.deinit(allocator);
        self.foreign_addresses.deinit(allocator);
        self.handler_sets.deinit(allocator);
        self.effects.deinit(allocator);
    }

    /// Copies the current state of this table into the provided buffer and returns a `core.AddressTable` wrapping the copy.
    pub fn write(self: *const AddressTable, buf: []u8, out: *core.AddressTable) usize { // TODO: use an encoder pattern like other modules
        const ptr_size = @sizeOf(*anyopaque);

        const constant_bytes = self.constants.items.len * ptr_size;
        const global_bytes = self.globals.items.len * ptr_size;
        const function_bytes = self.functions.items.len * ptr_size;
        const builtin_bytes = self.builtin_addresses.items.len * ptr_size;
        const foreign_bytes = self.foreign_addresses.items.len * ptr_size;
        const handler_bytes = self.handler_sets.items.len * ptr_size;
        const effect_bytes = self.effects.items.len * ptr_size;

        const offset = constant_bytes + global_bytes + function_bytes + builtin_bytes + foreign_bytes + handler_bytes + effect_bytes;

        std.debug.assert(buf.len >= offset);

        const constants = buf[0..constant_bytes];
        const globals = buf[constant_bytes..constant_bytes + global_bytes];
        const functions = buf[constant_bytes + global_bytes..constant_bytes + global_bytes + function_bytes];
        const builtin_addresses = buf[constant_bytes + global_bytes + function_bytes..constant_bytes + global_bytes + function_bytes + builtin_bytes];
        const foreign_addresses = buf[constant_bytes + global_bytes + function_bytes + builtin_bytes..constant_bytes + global_bytes + function_bytes + builtin_bytes + foreign_bytes];
        const handler_sets = buf[constant_bytes + global_bytes + function_bytes + builtin_bytes + foreign_bytes..constant_bytes + global_bytes + function_bytes + builtin_bytes + foreign_bytes + handler_bytes];
        const effects = buf[constant_bytes + global_bytes + function_bytes + builtin_bytes + foreign_bytes + handler_bytes..constant_bytes + global_bytes + function_bytes + builtin_bytes + foreign_bytes + handler_bytes + effect_bytes];

        @memcpy(constants, std.mem.sliceAsBytes(self.constants.items));
        @memcpy(globals, std.mem.sliceAsBytes(self.globals.items));
        @memcpy(functions, std.mem.sliceAsBytes(self.functions.items));
        @memcpy(builtin_addresses, std.mem.sliceAsBytes(self.builtin_addresses.items));
        @memcpy(foreign_addresses, std.mem.sliceAsBytes(self.foreign_addresses.items));
        @memcpy(handler_sets, std.mem.sliceAsBytes(self.handler_sets.items));
        @memcpy(effects, std.mem.sliceAsBytes(self.effects.items));

        out.* = .{
            .constants = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.Constant, constants))),
            .globals = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.Global, globals))),
            .functions = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.Function, functions))),
            .builtin_addresses = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.BuiltinAddress, builtin_addresses))),
            .foreign_addresses = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.ForeignAddress, foreign_addresses))),
            .handler_sets = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.HandlerSet, handler_sets))),
            .effects = .fromSlice(@alignCast(std.mem.bytesAsSlice(*const core.Effect, effects))),
        };

        return offset;
    }

    // validate mirror
    comptime {
        outer: for (std.meta.fieldNames(core.AddressTable)) |core_field| {
            for (std.meta.fieldNames(AddressTable)) |comp_field| {
                if (std.mem.eql(u8, core_field, comp_field)) continue :outer;
            } else {
                @compileError("missing field " ++ core_field ++ " in ir2bc.AddressTable");
            }
        }

        outer: for (std.meta.fieldNames(AddressTable)) |comp_field| {
            for (std.meta.fieldNames(core.AddressTable)) |core_field| {
                if (std.mem.eql(u8, core_field, comp_field)) continue :outer;
            } else {
                @compileError("extra field " ++ comp_field ++ " in ir2bc.AddressTable");
            }
        }

        for (std.meta.fieldNames(AddressTable)) |field| {
            const our_type = @typeInfo(@FieldType(@FieldType(AddressTable, field), "items")).pointer.child;
            const core_type = @FieldType(core.AddressTable, field).ValueType;

            if (our_type != core_type) {
                @compileError("type mismatch for field " ++ field ++ ": expected " ++ @typeName(core_type) ++ ", got " ++ @typeName(our_type));
            }
        }
    }
};
