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

pub const Instruction = @import("Instruction");

test {
    std.testing.refAllDeclsRecursive(@This());
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
            if (instr.code == comptime @field(Instruction.OpCode, instrName)) {
                const T = @FieldType(Instruction.OpData, instrName);
                const set = @field(instr.data, instrName);

                try writer.writeAll("    " ++ instrName);

                inline for (comptime std.meta.fieldNames(T)) |opName| {
                    const operandBytes = std.mem.asBytes(&@field(set, opName));

                    try writer.print(" (" ++ opName ++ " {x})", .{operandBytes});
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
            log.err("bytecode.Builder.createBlock: Cannot create more than {d} blocks in function {}", .{ BlockId.MAX_INT, self.id });
            return error.OutOfMemory;
        }

        const block = try Block.init(self, .fromInt(index));

        try self.blocks.append(self.allocator, block);

        return block;
    }

    pub fn encode(ptr: *const Builder, encoder: *Encoder) error{ BadEncoding, OutOfMemory }!void {
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
    body: pl.ArrayList(Instruction.Basic) = .empty,
    /// The instruction that terminates this block.
    /// * Adding any instruction when this is non-`null` is a `BadEncoding` error
    /// * For all other purposes, `null` is semantically equivalent to `unreachable`
    ///
    /// This is intended for convenience. For example, when calling an effect
    /// handler *that is known to always cancel*, we can treat the `prompt` as
    /// terminal in higher-level code.
    terminator: ?Instruction.Term = null,

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

    /// Write this block's instructions into the provided bytecode encoder.
    pub fn encode(ptr: *const Block, encoder: *Encoder) error{ BadEncoding, OutOfMemory }!void {
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
    pub fn composeInstr(ptr: *const Block, code: Instruction.OpCode, data: anytype) error{ BadEncoding, OutOfMemory }!void {
        const self: *Block = @constCast(ptr);

        if (self.terminator) |term| {
            log.err("Cannot insert instruction `{s}` into block with terminator `{s}`", .{ @tagName(code), @tagName(term.code) });
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
        const kind = comptime core.symbolKindFromId(T);

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
            log.err("bytecode.AddressTable.bind: Cannot bind more than {d} symbols", .{core.StaticId.MAX_INT});
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
        @memcpy(new_addresses, old_addresses);

        return .{
            .kinds = .fromSlice(new_kinds),
            .addresses = .fromSlice(new_addresses),
        };
    }
};
