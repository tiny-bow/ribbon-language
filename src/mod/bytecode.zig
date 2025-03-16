//! # bytecode
//! This is a namespace for the Ribbon bytecode builder.
const bytecode = @This();

const std = @import("std");
const log = std.log.scoped(.rbc);

const pl = @import("platform");
const core = @import("core");
const Id = @import("Id");
const Interner = @import("Interner");
const VirtualWriter = @import("VirtualWriter");

pub const Instruction = @import("Instruction");

test {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Builder = struct {
    /// The allocator that all memory used by intermediate structures is sourced from.
    /// * The builder is allocator-agnostic and any allocator can be used here,
    /// though resulting usage patterns may differ slightly. See `deinit`.
    allocator: std.mem.Allocator,
    /// Interned name set for the bytecode unit.
    names: NameInterner = .empty,
    /// Constant value bindings for the bytecode unit.
    constants: pl.ArrayList(*anyopaque) = .empty,
    /// Global value bindings for the bytecode unit.
    globals: pl.ArrayList(*anyopaque) = .empty,
    /// Function value bindings for the bytecode unit.
    functions: pl.ArrayList(*const Function) = .empty,
    /// Builtin function value bindings for the bytecode unit.
    builtins: pl.ArrayList(*anyopaque) = .empty,
    /// C ABI value bindings for the bytecode unit.
    foreign_addresses: pl.ArrayList(*anyopaque) = .empty,
    /// Effect type bindings for the bytecode unit.
    effects: pl.ArrayList(*anyopaque) = .empty,
    /// Effect handler set bindings for the bytecode unit.
    handler_sets: pl.ArrayList(*anyopaque) = .empty,

    /// Initialize a new bytecode unit builder.
    ///
    /// * `allocator`-agnostic, but see `deinit`
    /// * result `Builder` will own all intermediate memory allocated with the provided allocator;
    /// it can all be freed at once with `deinit`
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*const Builder {
        const self = try allocator.create(Builder);

        self.* = Builder{
            .allocator = allocator,
        };

        return self;
    }

    /// De-initialize the bytecode unit, freeing all allocated memory.
    ///
    /// This is not necessary to call if the allocator provided to the `Builder` is a `std.heap.Arena` or similar.
    pub fn deinit(b: *const Builder) void {
        const self: *Builder = @constCast(b);

        const allocator = self.allocator;
        defer allocator.destroy(self);

        defer inline for (comptime std.meta.fieldNames(Builder)[1..]) |fieldName| {
            @field(self, fieldName).deinit(allocator);
        };

        var nameIt = self.names.keyIterator();
        while (nameIt.next()) |namePtr| {
            Name.deinit(namePtr.*);
        }

        // for (self.constants.items) |constant| {
        //     allocator.free(constant);
        // }

        // for (self.globals.items) |global| {
        //     allocator.free(global);
        // }

        for (self.functions.items) |function| {
            function.deinit();
        }

        // for (self.builtins.items) |builtin| {
        //     allocator.free(builtin);
        // }

        // for (self.foreign_addresses.items) |foreign| {
        //     allocator.free(foreign);
        // }

        // for (self.effects.items) |effect| {
        //     allocator.free(effect);
        // }

        // for (self.handler_sets.items) |handlerSet| {
        //     allocator.free(handlerSet);
        // }
    }

    /// Get a `Name` from a string value.
    ///
    /// If the string has already been interned, the existing `Name` will be returned;
    /// Otherwise a new `Name` will be allocated.
    ///
    /// The `Name` that is returned will be owned by this bytecode unit.
    pub fn internName(ptr: *const Builder, value: []const u8) error{OutOfMemory}!*const Name {
        const self = @constCast(ptr);

        return (try self.names.intern(self.allocator, null, &Name{
            .rir = self,
            .id = @enumFromInt(self.names.count()),
            .value = value,
            .hash = pl.hash64(value),
        })).ptr.*;
    }

    /// Create a new `FunctionBuilder` with a given name.
    ///
    /// If a module with the same name has already been created, `error.DuplicateFunctionName` is returned.
    ///
    /// The `FunctionBuilder` that is returned will be owned by this bytecode unit.
    pub fn createFunction(ptr: *const Builder, name: *const Name) error{DuplicateFunctionName, OutOfMemory}!*const Function {
        const self = @constCast(ptr);

        for (self.functions.items) |modulePtr| {
            if (name == modulePtr.*.name) {
                return error.DuplicateFunctionName;
            }
        }

        const out = try Function.init(self, @enumFromInt(self.functions.items.len), name);

        try self.functions.append(self.allocator, out);

        return out;
    }
};

/// Provides deduplication for names in a bytecode unit.
pub const NameInterner: type = Interner.new(*const Name, struct {
    pub const DATA_FIELD = .value;

    pub fn eql(a: *const []const u8, b: *const []const u8) bool {
        return std.mem.eql(u8, a.*, b.*);
    }

    pub fn onFirstIntern(slot: **const Name, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const self = try allocator.create(Name);

        self.* = slot.*.*;

        self.value = try allocator.dupe(u8, self.value);

        slot.* = self;
    }
});

/// Various data structures in the bytecode can be given a name, for debugging and symbol resolution purposes;
/// when such a name is provided to the bytecode builder, it is interned in the builder's name set using a `Name`.
pub const Name = struct {
    /// The IR unit that owns this name.
    rir: *const Builder,
    /// The unique identifier for this name.
    id: Id.of(Name),
    /// The actual text value of this name.
    value: []const u8,
    /// A 64-bit hash of the text value of this name.
    hash: u64,

    fn deinit(ptr: *const Name) void {
        const self: *Name = @constCast(ptr);

        const allocator = self.rir.allocator;
        defer allocator.destroy(self);

        allocator.free(self.value);
    }

    pub fn onFormat(self: *const Name, formatter: anytype) !void {
        try formatter.writeAll(self.value);
    }
};


/// A `VirtualWriter` with a maximum size for the bytecode unit.
pub const Writer = VirtualWriter.new(pl.MAX_VIRTUAL_CODE_SIZE);

pub const Encoder = struct {
    /// The encoder's `VirtualWriter`
    writer: Writer,

    pub const Error = Writer.Error;

    /// Get the current offset's address with the encoded memory.
    pub fn getCurrentAddress(self: *Encoder) [*]u8 {
        return self.writer.getCurrentAddress();
    }

    /// Finalize the Encoder's writer, returning the posix pages as a read-only buffer.
    pub fn finalize(self: *Encoder) error{BadEncoding}![]align(pl.PAGE_SIZE) const u8 {
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
        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
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
        try self.writer.writeByteNTimes(0, pl.alignDelta(self.writer.cursor, alignment));
    }

    /// Composes and encodes a bytecode instruction.
    pub fn instr(self: *Encoder, code: Instruction.OpCode, data: Instruction.OpData) Writer.Error!void {
        try self.opcode(code);
        try self.operands(data);
        try self.alignTo(pl.BYTECODE_ALIGNMENT);
    }

    /// Encodes a pre-composed bytecode instruction.
    pub fn instrPre(self: *Encoder, instruction: Instruction) Writer.Error!void {
        try self.instr(instruction.code, instruction.data);
    }

    /// Encodes an opcode.
    pub fn opcode(self: *Encoder, code: Instruction.OpCode) Writer.Error!void {
        try self.writeInt(std.meta.Tag(Instruction.OpCode), @intFromEnum(code), .little);
    }

    /// Encodes instruction operands.
    pub fn operands(self: *Encoder, data: Instruction.OpData) Writer.Error!void {
        try self.writeInt(std.meta.Int(.unsigned, @bitSizeOf(Instruction.OpData)), @bitCast(data), .little);
        try self.writeByteNTimes(0, @ceil(pl.bytesFromBits(64 - (@bitSizeOf(Instruction.OpCode) + @bitSizeOf(Instruction.OpData)))));
    }
};


/// A function definition that is in-progress within the bytecode unit.
pub const Function = struct {
    /// The bytecode unit that owns this function.
    root: *const Builder,
    /// The function's unique identifier.
    id: Id.of(Function),
    /// The function's name, for symbol resolution purposes.
    name: *const Name,

    /// The function's stack window size.
    stack_size: usize = 0,
    /// The function's stack window alignment.
    stack_align: usize = 8,
    /// The function's basic blocks.
    blocks: pl.ArrayList(*const Block) = .empty,

    fn init(root: *const Builder, id: Id.of(Function), name: *const Name) !*const Function {
        const self = try root.allocator.create(Function);

        self.* = Function{
            .root = root,
            .id = id,
            .name = name,
        };

        return self;
    }

    fn deinit(ptr: *const Function) void {
        const self: *Function = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        self.blocks.deinit(allocator);
    }

    /// Create a new basic block within this function, returning a pointer to it.
    pub fn createBlock(ptr: *const Function, name: ?*const Name) error{NameCollision, TooManyBlocks, OutOfMemory}!*const Block {
        const self = @constCast(ptr);

        const index = self.blocks.items.len;

        if (index > Id.MAX_INT) {
            log.err("bytecode.Function.createBlock: Cannot create more than {d} blocks in function {s}", .{Id.MAX_INT, self.name.value});
            return error.TooManyBlocks;
        }

        const block = try Block.init(self, .fromInt(index), name);

        try self.blocks.append(self.root.allocator, block);

        return block;
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
    /// The bytecode unit that owns this block.
    root: *const Builder,
    /// The function this block belongs to.
    function: *const Function,
    /// The unique(-within-`function`) identifier for this block.
    id: Id.of(Block),
    /// The block's name, if it has one; for debugging purposes.
    name: ?*const Name,
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

    fn init(function: *const Function, id: Id.of(Block), name: ?*const Name) error{OutOfMemory}!*const Block {
        const root = function.root;
        const allocator = root.allocator;
        const self = try allocator.create(Block);

        self.* = Block{
            .root = root,
            .function = function,
            .id = id,
            .name = name,
        };

        return self;
    }

    fn deinit(ptr: *const Block) void {
        const self: *Block = @constCast(ptr);

        const allocator = self.root.allocator;
        defer allocator.destroy(self);

        self.body.deinit(allocator);
    }

    /// Append an instruction into this block, given its `OpCode` and an appropriate operand set.
    ///
    /// * `data` must be of the correct type for the instruction, or compilation errors will occur.
    /// See `Instruction.operand_sets`; each opcode has an associated type with the same name.
    /// `.{}` syntax should work.
    ///
    /// See also `instrPre`, which takes a pre-composed `Instruction` instead of individual components.
    pub fn instr(ptr: *const Block, code: Instruction.OpCode, data: anytype) error{BadEncoding, OutOfMemory}!void {
        const opFields = comptime std.meta.fieldNames(Instruction.OpCode);
        const termFields = comptime std.meta.fieldNames(Instruction.TermOpData);

        @setEvalBranchQuota(opFields.len * termFields.len * 3);

        const self: *Block = @constCast(ptr);

        if (self.terminator) |term| {
            log.err("Cannot insert instruction `{s}` into block with terminator `{s}`", .{@tagName(code), @tagName(term.code)});
            return error.BadEncoding;
        }

        const icode: u16 = @intFromEnum(code);

        inline for (opFields) |opName| {
            const isTerm = inline for (termFields) |termName| {
                if (comptime std.mem.eql(u8, opName, termName)) {
                    break true;
                }
            } else false;

            const ecode = comptime @field(Instruction.OpCode, opName);
            if (icode == comptime @intFromEnum(ecode)) {
                if (comptime isTerm) {
                    self.terminator = Instruction.Term{
                        .code = @enumFromInt(icode),
                        .data = @unionInit(Instruction.TermOpData, opName, data),
                    };
                } else {
                    try self.body.append(self.root.allocator, Instruction.Basic{
                        .code = @enumFromInt(icode),
                        .data = @unionInit(Instruction.BasicOpData, opName, data),
                    });
                }

                return;
            }
        }

        unreachable;
    }

    /// Append a pre-composed instruction into this block.
    ///
    /// * `instruction` must be properly composed, or runtime errors will occur.
    ///
    /// See also `instr`, which takes the individual components of an instruction separately.
    pub fn instrPre(ptr: *const Block, instruction: Instruction) error{BadEncoding, OutOfMemory}!void {
        const opFields = comptime std.meta.fieldNames(Instruction.OpCode);
        const termFields = comptime std.meta.fieldNames(Instruction.TermOpData);

        @setEvalBranchQuota(opFields.len * termFields.len * 3);

        const self: *Block = @constCast(ptr);

        if (self.terminator) |term| {
            log.err("Cannot insert instruction `{s}` into block with terminator `{s}`", .{@tagName(instruction.code), @tagName(term.code)});
            return error.BadEncoding;
        }

        const icode: u16 = @intFromEnum(instruction.code);

        inline for (opFields) |opName| {
            const isTerm = inline for (termFields) |termName| {
                if (comptime std.mem.eql(u8, opName, termName)) {
                    break true;
                }
            } else false;

            const ecode = comptime @field(Instruction.OpCode, opName);
            if (icode == comptime @intFromEnum(ecode)) {
                if (comptime isTerm) {
                    self.terminator = Instruction.Term{
                        .code = @enumFromInt(icode),
                        .data = @unionInit(Instruction.TermOpData, opName, @field(instruction.data, opName)),
                    };
                } else {
                    try self.body.append(self.root.allocator, Instruction.Basic{
                        .code = @enumFromInt(icode),
                        .data = @unionInit(Instruction.BasicOpData, opName, @field(instruction.data, opName)),
                    });
                }

                return;
            }
        }

        unreachable;
    }
};
