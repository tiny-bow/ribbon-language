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
pub const NameInterner = Interner.new(*const Name, struct {
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


pub const PseudoInstr = union(enum) {
    no_fixup: Instruction,
    label: *const Name,
    branch: struct {
        opcode: Instruction.OpCode,
        condition: ?core.Register,
        target: *const Name,
    },
    static_addr: struct {
        opcode: Instruction.OpCode,
        target: *const Name,
        result: core.Register,
    },
    static_call: struct {
        name: *const Name,
        opcode: Instruction.OpCode,
        arguments: pl.ArrayList(core.Register),
        result: ?core.Register,
    },
};

pub const Writer = VirtualWriter.new(pl.MAX_VIRTUAL_CODE_SIZE);

pub const Encoder = struct {
    writer: Writer,

    pub const Error = Writer.Error;

    pub fn getCurrentAddress(self: *Encoder) [*]u8 {
        return self.writer.getCurrentAddress();
    }

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

/// A map of symbol references for a linker to resolve.
pub const LinkerFixups = pl.StringMap(pl.ArrayList(LinkerFixup));

/// A symbol reference for a linker to resolve.
pub const LinkerFixup = struct {
    addr: *align(1) u16,
    expected: core.SymbolKind,

    /// Create a new `LinkerFixup` with the given address and expected symbol kind.
    pub fn init(addr: *align(1) u16, expected: core.SymbolKind) LinkerFixup {
        return LinkerFixup{
            .addr = addr,
            .expected = expected,
        };
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
    stack_size: pl.uword = 0,
    /// The function's stack window alignment.
    stack_align: pl.uword = 8,
    /// The function's instructions.
    instructions: pl.ArrayList(PseudoInstr) = .empty,


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

        self.instructions.deinit(allocator);
    }

    pub fn addInstruction(ptr: *const Function, instruction: PseudoInstr) error{OutOfMemory}!void {
        const self: *Function = @constCast(ptr);
        try self.instructions.append(self.root.allocator, instruction);
    }

    // FIXME: constantInterner
    pub fn generate(self: *const Function, constantInterner: anytype, linkerAllocator: std.mem.Allocator, out: *core.Function, instructionEncoder: *Encoder) error{BadEncoding, OutOfMemory}!LinkerFixups {
        log.info("Generating bytecode for function `{}`", .{self.name});

        const address: core.InstructionAddr(.mutable) = @ptrCast(@alignCast(instructionEncoder.getCurrentAddress()));

        out.id = @enumFromInt(@intFromEnum(self.id));
        out.extents = .{ .base = address, .upper = undefined };
        out.stack_size = self.stack_size;

        var labelMap: pl.UniqueReprMap(*const Name, core.InstructionAddr(.mutable), 80) = .empty;
        defer labelMap.deinit(self.root.allocator);

        var localFixUps: pl.ArrayList(struct {core.InstructionAddr(.mutable), *const Name}) = .empty;
        defer localFixUps.deinit(self.root.allocator);

        var linkerFixups: LinkerFixups = .empty;
        errdefer linkerFixups.deinit(linkerAllocator);

        for (self.instructions.items) |*instr| {
            switch (instr.*) {
                .no_fixup => |no_fixup| try instructionEncoder.instrPre(no_fixup),

                .label => |label| try labelMap.put(self.root.allocator, label, address),

                .branch => |*branchProto| {
                    try localFixUps.append(self.root.allocator, .{address, branchProto.target});

                    try instructionEncoder.instr(branchProto.opcode, switch (branchProto.opcode) {
                        .br => undefined,
                        .br_if => .{ .br_if = .{ .R = branchProto.condition.?, .C = undefined } },
                        else => return error.BadEncoding,
                    });
                },

                .static_addr => |*addrProto| {
                    try instructionEncoder.opcode(addrProto.opcode);

                    const name = try linkerAllocator.dupe(u8, addrProto.target.value);

                    const fixupEntry = try linkerFixups.getOrPut(linkerAllocator, name);
                    if (!fixupEntry.found_existing) fixupEntry.value_ptr.* = .empty;

                    switch (addrProto.opcode) {
                        .@"addr_l" => {
                            // TODO: add local variable offset tracker and use it here with constantInterner
                        },
                        .@"addr_u" => {
                            // TODO: we still dont have a story for binding and accessing upvalues
                        },
                        .@"addr_g" => {
                            try instructionEncoder.writeValue(addrProto.result);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(addrProto.result, .global));
                            try instructionEncoder.writeValue(core.GlobalId.null);
                        },
                        .@"addr_f" => {
                            try instructionEncoder.writeValue(addrProto.result);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(addrProto.result, .function));
                            try instructionEncoder.writeValue(core.FunctionId.null);
                        },
                        .@"addr_b" => {
                            try instructionEncoder.writeValue(addrProto.result);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(addrProto.result, .builtin));
                            try instructionEncoder.writeValue(core.BuiltinAddressId.null);
                        },
                        .@"addr_x" => {
                            try instructionEncoder.writeValue(addrProto.result);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(addrProto.result, .foreign));
                            try instructionEncoder.writeValue(core.ForeignAddressId.null);
                        },
                        .@"addr_c" => {
                            try instructionEncoder.writeValue(addrProto.result);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(addrProto.result, .constant));
                            try instructionEncoder.writeValue(core.ConstantId.null);
                        },
                        else => return error.BadEncoding,
                    }

                    try instructionEncoder.alignTo(@alignOf(Instruction.OpCode));
                },

                .static_call => |*callProto| {
                    try instructionEncoder.opcode(callProto.opcode);

                    const name = try linkerAllocator.dupe(u8, callProto.name.value);

                    const fixupEntry = try linkerFixups.getOrPut(linkerAllocator, name);
                    if (!fixupEntry.found_existing) fixupEntry.value_ptr.* = .empty;

                    const args = args: switch (callProto.opcode) {
                        .@"call_c" => {
                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .function));
                            try instructionEncoder.writeValue(core.FunctionId.null);

                            break :args callProto.arguments.items;
                        },
                        .@"call_c_v" => {
                            try instructionEncoder.writeValue(callProto.arguments.items[0]);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .function));
                            try instructionEncoder.writeValue(core.FunctionId.null);

                            break :args callProto.arguments.items[1..];
                        },
                        .@"call_builtinc" => {
                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .builtin));
                            try instructionEncoder.writeValue(core.BuiltinAddressId.null);

                            break :args callProto.arguments.items;
                        },
                        .@"call_builtinc_v" => {
                            try instructionEncoder.writeValue(callProto.arguments.items[0]);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .builtin));
                            try instructionEncoder.writeValue(core.BuiltinAddressId.null);

                            break :args callProto.arguments.items[1..];
                        },
                        .@"call_foreignc" => {
                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .foreign));
                            try instructionEncoder.writeValue(core.ForeignAddressId.null);

                            break :args callProto.arguments.items;
                        },
                        .@"call_foreignc_v" => {
                            try instructionEncoder.writeValue(callProto.arguments.items[0]);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .foreign));
                            try instructionEncoder.writeValue(core.ForeignAddressId.null);

                            break :args callProto.arguments.items[1..];
                        },
                        .@"prompt" => {
                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .effect));
                            try instructionEncoder.writeValue(core.EffectId.null);

                            break :args callProto.arguments.items;
                        },
                        .@"prompt_v" => {
                            try instructionEncoder.writeValue(callProto.arguments.items[0]);

                            try fixupEntry.value_ptr.append(linkerAllocator, LinkerFixup.init(@ptrCast(address), .effect));
                            try instructionEncoder.writeValue(core.EffectId.null);

                            break :args callProto.arguments.items[1..];
                        },

                        else => return error.BadEncoding,
                    };

                    const argCount = try constantInterner.internNative(&callProto.arguments.items.len);
                    try instructionEncoder.writeValue(argCount.id);

                    for (args) |arg| try instructionEncoder.writeValue(arg);

                    try instructionEncoder.alignTo(@alignOf(Instruction.OpCode));
                },
            }
        }

        return linkerFixups;
    }
};
