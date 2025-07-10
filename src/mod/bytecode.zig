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
const AllocWriter = @import("AllocWriter");
const RelativeAddress = AllocWriter.RelativeAddress;
const RelativeBuffer = AllocWriter.RelativeBuffer;
const Buffer = @import("Buffer");

pub const Instruction = @import("Instruction");

test {
    std.testing.refAllDecls(@This());
}

pub const Decoder = struct {
    instructions: []const core.InstructionBits = &.{},
    ip: u64 = 0,

    pub const Item = struct {
        instruction: Instruction,
        trailing: Trailing,

        /// `std.fmt` impl
        pub fn format(self: *const Item, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.print("{s}", .{@tagName(self.instruction.code)});

            inline for (comptime std.meta.fieldNames(Instruction.OpCode)) |opcode_name| {
                const code = comptime @field(Instruction.OpCode, opcode_name);

                if (code == self.instruction.code) {
                    const Set = comptime Instruction.SetType(code);
                    const operands = &@field(self.instruction.data, opcode_name);

                    inline for (comptime std.meta.fieldNames(Set)) |operand_name| {
                        const operand = @field(operands, operand_name);
                        const Operand = @TypeOf(operand);

                        switch (Operand) {
                            core.Register => try writer.print(operand_name ++ "{}", .{operand}),

                            core.UpvalueId,
                            core.GlobalId,
                            core.FunctionId,
                            core.BuiltinAddressId,
                            core.ForeignAddressId,
                            core.EffectId,
                            core.HandlerSetId,
                            core.ConstantId,
                            => |O| try std.fmt.formatInt(@intFromEnum(operand), 16, .lower, .{
                                .width = @sizeOf(O) * 2,
                                .fill = '0',
                                .alignment = .right,
                            }, writer),

                            u8 => try writer.print(operand_name ++ ":{x:0>2}", .{operand}),
                            u16 => try writer.print(operand_name ++ ":{x:0>4}", .{operand}),
                            u32 => try writer.print(operand_name ++ ":{x:0>8}", .{operand}),
                            u64 => try writer.print(operand_name ++ ":{x:0>16}", .{operand}),

                            else => @compileError("bytecode.Decoder: out of sync with ISA, encountered unexpected operand type " ++ @typeName(Operand)),
                        }
                    }

                    break;
                }
            }

            try self.trailing.format("", .{}, writer);
        }
    };

    pub const Trailing = union(enum) {
        none: void,
        call_args: []const core.Register,
        wide_imm: Imm,

        /// `std.fmt` impl
        pub fn format(self: Trailing, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .none => {},
                .call_args => |args| try writer.print(" .. {any}", .{args}),
                .wide_imm => |imm| try imm.format("", .{}, writer),
            }
        }
    };

    pub const Imm = union(enum) {
        byte: u8,
        short: u16,
        int: u32,
        word: u64,

        /// `std.fmt` impl
        pub fn format(self: Imm, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            switch (self) {
                .byte => |operand| try writer.print(" .. I:{x:0>2}", .{operand}),
                .short => |operand| try writer.print(" .. I:{x:0>4}", .{operand}),
                .int => |operand| try writer.print(" .. I:{x:0>8}", .{operand}),
                .word => |operand| try writer.print(" .. I:{x:0>16}", .{operand}),
            }
        }
    };

    pub fn init(instructions: []const core.InstructionBits) Decoder {
        return .{ .instructions = instructions };
    }

    pub fn reset(self: *Decoder) void {
        self.ip = 0;
    }

    pub fn next(self: *Decoder) error{BadEncoding}!?Item {
        if (self.ip < self.instructions.len) {
            var item = Item{
                .instruction = Instruction.fromBits(self.instructions[self.ip]),
                .trailing = Trailing.none,
            };

            self.ip += 1;

            if (item.instruction.code.isWide()) {
                if (self.ip < self.instructions.len) {
                    item.trailing.wide_imm = self.instructions[self.ip];
                    self.ip += 1;
                } else {
                    log.debug("bytecode.Decoder.next: Incomplete wide instruction at end of stream.", .{});
                    return error.BadEncoding;
                }
            } else if (utils.getExpectedCallArgumentCount(item.instruction)) |n| {
                const base: [*]core.Register = @ptrCast(self.instructions.ptr + self.ip);

                const arg_byte_count = n * @sizeOf(core.Register);
                const arg_word_count = (arg_byte_count + @sizeOf(core.InstructionBits) - 1) / @sizeOf(core.InstructionBits);

                const new_ip = self.ip + arg_word_count;

                if (new_ip > self.instructions.len) {
                    log.debug("bytecode.Decoder.next: Incomplete call instruction at end of stream.", .{});
                    return error.BadEncoding;
                }

                item.trailing.call_args = base[0..n];
                self.ip = new_ip;
            }

            return item;
        }

        return null;
    }
};

pub const utils = struct {
    pub fn getExpectedCallArgumentCount(instr: Instruction) ?u8 {
        if (!instr.code.isCall()) return null;

        return switch (@as(Instruction.CallOpCode, @enumFromInt(@intFromEnum(instr.code)))) {
            .call => instr.data.call.I,
            .call_c => instr.data.call_c.I,
            .f_call => instr.data.f_call.I,
            .f_call_c => instr.data.f_call_c.I,
            .prompt => instr.data.prompt.I,
        };
    }
};

/// Disassemble a bytecode buffer, printing to the provided writer.
pub fn disas(bc: []const core.InstructionBits, writer: anytype) (error{BadEncoding} || @TypeOf(writer).Error)!void {
    var decoder = Decoder.init(bc);

    try writer.print("[{x:0<16}]:\n", .{@intFromPtr(bc.ptr)});

    while (try decoder.next()) |item| {
        try writer.print("    {}", .{item});
    }
}

/// An id of a location in the encoded memory that is referenced by a fixup, but who's relative offset is not known at the time of encoding.
pub const LocationId = packed struct(u64) {
    region: RegionId,
    offset: OffsetId,
};

const Region = struct {};
pub const RegionId = Id.of(bytecode.Region, 32);

const Offset = struct {};
pub const OffsetId = Id.of(bytecode.Offset, 32);

/// A map of relative addresses, used to store the addresses of locations that need to be fixed up by id after encoding.
pub const LocationMap = pl.UniqueReprMap(LocationId, RelativeAddress, 80);

/// Determines the kind of fixup to perform.
pub const FixupKind = enum {
    /// Copy the resolve address of `.to`, into the location at the resolved address of `.from`.
    absolute,
    /// Resolve the address of `.to`, and `.from`, then calculate the relative offset between them,
    /// overwriting the bits at `.bit_offset` in the instruction at `.from`.
    relative,
};

/// A reference to an encoded memory location that needs to be fixed up.
pub const FixupRef = union(enum) {
    known: RelativeAddress,
    by_id: LocationId,
};

/// A fixup is a reference from one location in the encoded memory to another; these need to be "fixed up" after the encoding is complete,
/// as the addresses of the locations may not be known at the time of encoding, or the addresses may change due to reallocation etc.
pub const Fixup = struct {
    /// The kind of fixup to perform.
    kind: FixupKind,
    /// The location that needs an address written to it.
    from: FixupRef,
    /// The location whose address will be written to `from`.
    to: FixupRef,
    /// A bit position in the word at `from` that will be overwritten with the address or relative offset of `to`.
    bit_offset: ?u6,
};

/// Wrapper over `AllocWriter` that provides a bytecode instruction specific API.
pub const Encoder = struct {
    /// Allocator for the fixup maps and user operations.
    temp_allocator: std.mem.Allocator,
    /// The encoder's `AllocWriter`
    writer: AllocWriter,
    /// The map of addresses that need to be fixed up after encoding.
    fixups: pl.ArrayList(Fixup) = .{},
    /// The map of relative addresses that are referenced by id in some fixups.
    locations: LocationMap = .{},
    /// A 32-bit contextual identifier to prepend to scoped fixup locations.
    region: RegionId = .fromInt(0),

    pub const Error = AllocWriter.Error || error{
        /// Generic malformed bytecode error.
        BadEncoding,
        /// An error indicating that the current offset of the encoder is not aligned to
        /// the expected bytecode alignment for writing the provided data.
        UnalignedWrite,
    };

    /// Initialize a new Encoder with a `AllocWriter`.
    pub fn init(temp_allocator: std.mem.Allocator, writer_allocator: std.mem.Allocator) error{OutOfMemory}!Encoder {
        const writer = try AllocWriter.initCapacity(writer_allocator);
        return Encoder{
            .temp_allocator = temp_allocator,
            .writer = writer,
        };
    }

    /// Clear the Encoder, retaining the allocator and writer, along with the writer buffer memory.
    pub fn clear(self: *Encoder) void {
        self.fixups.clearRetainingCapacity();
        self.locations.clearRetainingCapacity();
        self.writer.clear();
    }

    /// Deinitialize the Encoder, freeing any memory it owns.
    pub fn deinit(self: *Encoder) void {
        self.fixups.deinit(self.temp_allocator);
        self.locations.deinit(self.temp_allocator);
        self.writer.deinit();
    }

    /// * `region` must be a < 32-bit enum type.
    pub fn enterRegion(self: *Encoder, region: anytype) RegionId {
        const old_region = self.region;
        self.region = @enumFromInt(@intFromEnum(region));
        return old_region;
    }

    pub fn leaveRegion(self: *Encoder, old_region: RegionId) void {
        self.region = old_region;
    }

    pub fn currentRegion(self: *Encoder) RegionId {
        return self.region;
    }

    /// Finalize the Encoder's writer, returning the memory.
    ///
    /// After calling this function, the encoder will be in its default-initialized state.
    /// In other words, it is safe but not necessary to call `deinit` on it.
    /// It does not need to be re-initializd before reuse, as the allocator is retained.
    pub fn finalize(self: *Encoder) Error![]align(pl.PAGE_SIZE) u8 {
        const buf = try self.writer.finalize();

        var visitor = try pl.Visitor(*align(1) u64).init(self.temp_allocator);
        defer visitor.deinit();

        for (self.fixups.items) |fixup| {
            const from = try self.resolveFixupRef(fixup.from, buf);

            if (!try visitor.visit(from)) {
                log.debug("Fixup location already visited", .{});
                return error.BadEncoding;
            }

            const to = try self.resolveFixupRef(fixup.to, buf);
            const is_bit_offset = fixup.bit_offset != null;
            const bit_offset = fixup.bit_offset orelse 0;

            const bits: u64, const bit_size: u64, const base_mask: u64 = switch (fixup.kind) {
                .absolute => link: {
                    break :link if (is_bit_offset) .{
                        @as(u48, @intCast(@intFromPtr(to))),
                        48,
                        std.math.maxInt(u48),
                    } else .{
                        @intFromPtr(to),
                        64,
                        std.math.maxInt(u64),
                    };
                },
                .relative => jump: {
                    const relative_offset_bytes = @as(isize, @bitCast(@intFromPtr(to))) - @as(isize, @bitCast(@intFromPtr(from)));
                    const relative_offset_words: i32 = @intCast(@divExact(relative_offset_bytes, @sizeOf(core.InstructionBits)));

                    break :jump .{ @as(u32, @bitCast(relative_offset_words)), 32, std.math.maxInt(u32) };
                },
            };

            const padding = @as(u8, 64) - bit_size;
            if (bit_offset > padding) {
                log.debug("Fixup bit offset {d} exceeds available space 64-{d}={d} for destination word", .{
                    fixup.bit_offset,
                    bit_size,
                    padding,
                });
                return error.BadEncoding;
            }

            if (bit_size == 64) {
                from.* = bits;
                continue;
            }

            const original_bits = from.*;

            const mask = base_mask << @intCast(bit_offset);
            const cleared = original_bits & ~mask;
            const inserted = bits << @intCast(bit_offset);

            from.* = cleared | inserted;
        }

        return buf;
    }

    fn resolveFixupRef(self: *Encoder, ref: FixupRef, base: []align(pl.PAGE_SIZE) u8) !*align(1) u64 {
        resolve: {
            const rel_addr = switch (ref) {
                .known => |known| known,
                .by_id => |id| self.locations.get(id) orelse break :resolve,
            };

            return @ptrCast(rel_addr.tryToPtrOrSentinel(base) orelse break :resolve);
        }

        log.debug("Failed to resolve fixup reference {}", .{ref});
        return error.BadEncoding;
    }

    /// Create a new fixup.
    pub fn addFixup(self: *Encoder, kind: FixupKind, from: FixupRef, to: FixupRef, bit_offset: ?u6) Error!void {
        try self.fixups.append(self.temp_allocator, Fixup{
            .kind = kind,
            .from = from,
            .to = to,
            .bit_offset = bit_offset,
        });
    }

    /// Create a new location for fixups to reference.
    pub fn addLocation(self: *Encoder, rel_addr: RelativeAddress, id: LocationId) Error!void {
        try self.locations.put(self.temp_allocator, id, rel_addr);
    }

    /// `addLocation` with the current relative address of the encoder.
    pub fn addCurrentLocation(self: *Encoder, id: LocationId) Error!void {
        return self.addLocation(self.getRelativeAddress(), id);
    }

    /// Get the current length of the encoded region of the encoder.
    pub fn getEncodedSize(self: *Encoder) u64 {
        return self.writer.getWrittenSize();
    }

    /// Get the current encoded region of the encoder.
    pub fn getEncodedRegion(self: *Encoder) u64 {
        return self.writer.getWrittenRegion();
    }

    /// Get the current offset address with the encoded memory.
    /// * This address is not guaranteed to be stable throughout the encode; use `getRelativeAddress` for stable references.
    pub fn getCurrentAddress(self: *Encoder) [*]u8 {
        return self.writer.getCurrentAddress();
    }

    /// Convert an unstable address in the encoder, such as those acquired through `alloc`, into a stable relative address.
    pub fn addressToRelative(self: *Encoder, address: anytype) RelativeAddress {
        return self.writer.addressToRelative(address);
    }

    /// Convert a stable relative address in the encoder into an unstable absolute address.
    pub fn relativeToAddress(self: *Encoder, relative: RelativeAddress) [*]u8 {
        return self.writer.relativeToAddress(relative);
    }

    /// Convert a stable relative address in the encoder into an unstable, typed pointer.
    pub fn relativeToPointer(self: *Encoder, comptime T: type, relative: RelativeAddress) T {
        return self.writer.relativeToPointer(T, relative);
    }

    /// Get the current offset relative address with the encoded memory. See also `getCurrentAddress`.
    /// * This can be used to get an address into the final buffer after encode completion.
    pub fn getRelativeAddress(self: *Encoder) RelativeAddress {
        return self.writer.getRelativeAddress();
    }

    /// Create a new `LocationId` for a location in the encoded memory, using the current region of the encoder.
    pub fn localLocationId(self: *Encoder, offset: anytype) LocationId {
        return LocationId{
            .region = self.region,
            .offset = offset.bitcast(Offset, 32),
        };
    }

    /// Returns the available capacity in the encoder memory.
    pub fn availableCapacity(self: *Encoder) []u8 {
        return self.writer.availableCapacity();
    }

    /// Ensure the total available capacity in the encoder memory.
    pub fn ensureCapacity(self: *Encoder) []u8 {
        return self.writer.ensureCapacity();
    }

    /// Ensure additional available capacity in the encoder memory.
    pub fn ensureAdditionalCapacity(self: *Encoder) []u8 {
        return self.writer.ensureAdditionalCapacity();
    }

    /// Allocates an aligned byte buffer from the address space of the encoder.
    pub fn alignedAlloc(self: *Encoder, alignment: pl.Alignment, len: usize) Error![]u8 {
        return self.writer.alignedAlloc(alignment, len);
    }

    /// Same as `std.mem.Allocator.alloc`, but allocates from the virtual address space of the encoder.
    pub fn alloc(self: *Encoder, comptime T: type, len: usize) Error![]T {
        return self.writer.alloc(T, len);
    }

    /// Same as `alloc`, but returns a RelativeAddress instead of a pointer.
    pub fn allocRel(self: *Encoder, comptime T: type, len: usize) Error!RelativeAddress {
        return self.writer.allocRel(T, len);
    }

    /// Same as `std.mem.Allocator.dupe`, but copies a slice into the virtual address space of the encoder.
    pub fn dupe(self: *Encoder, comptime T: type, slice: []const T) Error![]T {
        return self.writer.dupe(T, slice);
    }

    /// Same as `dupe`, but returns a RelativeAddress instead of a pointer.
    pub fn dupeRel(self: *Encoder, comptime T: type, slice: []const T) Error!RelativeAddress {
        return self.writer.dupeRel(T, slice);
    }

    /// Same as `std.mem.Allocator.create`, but allocates from the virtual address space of the encoder.
    pub fn create(self: *Encoder, comptime T: type) Error!*T {
        return self.writer.create(T);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn createRel(self: *Encoder, comptime T: type) Error!RelativeAddress {
        return self.writer.createRel(T);
    }

    /// Same as `create`, but takes an initializer.
    pub fn clone(self: *Encoder, value: anytype) Error!*@TypeOf(value) {
        return self.writer.clone(value);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn cloneRel(self: *Encoder, value: anytype) Error!RelativeAddress {
        return self.writer.cloneRel(value);
    }

    /// Writes as much of a slice of bytes to the encoder as will fit without an allocation.
    /// Returns the number of bytes written.
    pub fn write(self: *Encoder, noalias bytes: []const u8) AllocWriter.Error!usize {
        return self.writer.write(bytes);
    }

    /// Writes all bytes from a slice to the encoder.
    pub fn writeAll(self: *Encoder, bytes: []const u8) AllocWriter.Error!void {
        return self.writer.writeAll(bytes);
    }

    /// Writes a single byte to the encoder.
    pub fn writeByte(self: *Encoder, byte: u8) AllocWriter.Error!void {
        return self.writer.writeByte(byte);
    }

    /// Writes a byte to the encoder `n` times.
    pub fn writeByteNTimes(self: *Encoder, byte: u8, n: usize) AllocWriter.Error!void {
        return self.writer.writeByteNTimes(byte, n);
    }

    /// Writes a slice of bytes to the encoder `n` times.
    pub fn writeBytesNTimes(self: *Encoder, bytes: []const u8, n: usize) AllocWriter.Error!void {
        return self.writer.writeBytesNTimes(bytes, n);
    }

    /// Writes an integer to the encoder.
    pub fn writeInt(
        self: *Encoder,
        comptime T: type,
        value: T,
        comptime _: enum { little }, // allows backward compat with zig's writer interface; but only in provably compatible use-cases
    ) AllocWriter.Error!void {
        try self.writer.writeInt(T, value, .little);
    }

    /// Generalized version of `writeInt` for little-endian only;
    /// Works for any value with a unique representation.
    ///
    /// See `std.meta.hasUniqueRepresentation`.
    pub fn writeValue(
        self: *Encoder,
        value: anytype,
    ) AllocWriter.Error!void {
        const T = @TypeOf(value);

        if (comptime !std.meta.hasUniqueRepresentation(T)) {
            @compileError("bytecode.Encoder.writeValue: Type `" ++ @typeName(T) ++ "` does not have a unique representation");
        }

        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
    }

    /// Pushes zero bytes (if necessary) to align the current offset of the encoder to the provided alignment value.
    pub fn alignTo(self: *Encoder, alignment: pl.Alignment) AllocWriter.Error!void {
        const delta = pl.alignDelta(self.writer.cursor, alignment);
        try self.writer.writeByteNTimes(0, delta);
    }

    /// Asserts that the current offset of the encoder is aligned to the given value.
    pub fn ensureAligned(self: *Encoder, alignment: pl.Alignment) Error!void {
        if (pl.alignDelta(self.writer.cursor, alignment) != 0) {
            return error.UnalignedWrite;
        }
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
        self.symbol_table = .{};
        self.address_table.deinit(allocator);
        self.address_table = .{};
    }

    /// Bind a fully qualified name to an address, returning the address table id of the static.
    pub fn bind(
        self: *Table,
        allocator: std.mem.Allocator,
        name: []const u8,
        address: AddressTable.Entry,
    ) !core.StaticId {
        const PtrT = @TypeOf(address);
        const PtrT_info = @typeInfo(PtrT);
        if (comptime PtrT_info != .pointer or PtrT_info.pointer.size != .one) {
            @compileError("bytecode.Table.bind: Address must be a single value pointer type, got " ++ @typeName(PtrT));
        }

        const T = PtrT_info.pointer.child;
        const kind = comptime core.SymbolKind.fromType(T);

        const id = try self.address_table.bind(allocator, kind, address);

        try self.symbol_table.bind(allocator, name, id);

        return id;
    }

    pub fn finalize(self: *const Table, encoder: *Encoder) !RelativeAddress {
        const header_rel = try encoder.createRel(core.Header);

        const start_size = encoder.getEncodedSize();

        const symbol_table = try self.symbol_table.encode(&encoder);
        const address_table = try self.address_table.finalize(&encoder);

        const end_size = encoder.getEncodedSize();

        const header = encoder.relativeToPointer(*const core.Header);

        header.* = .{
            .size = end_size - start_size,
            .symbol_table = symbol_table,
            .address_table = address_table,
        };

        self.deinit();

        return header_rel;
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
        address: Entry,
    }) = .empty,

    pub const Entry = union(enum) {
        relative: FixupRef,
        absolute: *const anyopaque,
        inlined: struct {
            bytes: []const u8,
            alignment: pl.Alignment,
        },
    };

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
    pub fn getAddress(self: *const AddressTable, id: core.StaticId) ?Entry {
        const index = id.toInt();

        if (index < self.data.len) {
            return self.data.items(.address)[index];
        } else {
            return null;
        }
    }

    /// Get the address of a typed static by its id.
    pub fn get(self: *const AddressTable, id: anytype) ?Entry {
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
    pub fn bind(self: *AddressTable, allocator: std.mem.Allocator, kind: core.SymbolKind, address: Entry) !core.StaticId {
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
    /// returning a new `ProtoAddressTable` referencing the new buffers.
    pub fn encode(self: *const AddressTable, encoder: *Encoder) !ProtoAddressTable {
        const kinds = self.data.items(.kind);
        const addresses = self.data.items(.address);

        const new_kinds_rel = try encoder.dupeRel(core.SymbolKind, kinds);
        const new_addresses_rel = try encoder.allocRel(*const anyopaque, self.data.len);

        for (0..self.data.len) |i| {
            switch (addresses[i]) {
                .relative => |to_rel| {
                    const from_rel = new_addresses_rel.applyOffset(@intCast(i));

                    try encoder.addFixup(.absolute, .{ .known = from_rel }, to_rel, null);
                },
                .absolute => |abs_ptr| {
                    const new_addresses = encoder.relativeToPointer([*]*const anyopaque, new_addresses_rel);

                    new_addresses[i] = abs_ptr;
                },
                .inlined => |inlined| {
                    try encoder.alignTo(inlined.alignment);
                    const new_mem = try encoder.alloc(u8, inlined.bytes.len);
                    @memcpy(new_mem, inlined.bytes);

                    const new_addresses = encoder.relativeToPointer([*]*const anyopaque, new_addresses_rel);

                    new_addresses[i] = new_mem;
                },
            }
        }

        return ProtoAddressTable{
            .addresses = new_addresses_rel,
            .kinds = new_kinds_rel,
            .len = @intCast(self.data.len),
        };
    }
};

/// A simple builder API for bytecode functions.
pub const FunctionBuilder = struct {
    /// The allocator used by this function.
    allocator: std.mem.Allocator,
    /// The function's unique identifier.
    id: core.FunctionId,
    /// The function's stack window size.
    stack_size: usize = 0,
    /// The function's stack window alignment.
    stack_align: usize = 8,
    /// The function's basic blocks, unordered.
    blocks: pl.UniqueReprMap(BlockId, *const BlockBuilder, 80) = .empty,
    /// State variable for creating function-unique block ids.
    fresh_id: BlockId = BlockBuilder.entry_point_id,

    /// Initialize a new builder for a bytecode function.
    pub fn init(allocator: std.mem.Allocator, id: core.FunctionId) !*const FunctionBuilder {
        const self = try allocator.create(FunctionBuilder);
        errdefer allocator.destroy(self);

        self.* = FunctionBuilder{
            .allocator = allocator,
            .id = id,
        };

        _ = try self.createBlock();

        return self;
    }

    /// Deinitialize the builder, freeing all memory associated with it.
    pub fn deinit(self: *FunctionBuilder) void {
        const allocator = self.allocator;
        defer allocator.destroy(self);

        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

        self.blocks.deinit(allocator);
    }

    /// Encode the function and all blocks into the provided encoder.
    pub fn encode(self: *FunctionBuilder, encoder: *Encoder) Encoder.Error!void {
        var visitor = try BlockVisitor.init(encoder.temp_allocator);

        const region_token = encoder.enterRegion(self.id);
        defer encoder.leaveRegion(region_token);

        try self.visitBlock(&visitor, encoder, BlockBuilder.entry_point_id);
    }

    fn visitBlock(self: *FunctionBuilder, visitor: *BlockVisitor, encoder: *Encoder, block_id: BlockId) !void {
        if (!try visitor.visit(block_id)) return;

        const block = self.blocks.get(block_id).?;

        log.debug("FunctionBuilder.finalize: Visiting block {d}", .{block_id.toInt()});

        try block.finalize(visitor, encoder);
    }

    /// Create a new basic block within this function, returning a pointer to it.
    pub fn createBlock(self: *FunctionBuilder) !*const BlockBuilder {
        const id = self.fresh_id.next();

        const block = try BlockBuilder.init(self, id);
        errdefer block.deinit();

        try self.blocks.put(self.allocator, id, block);

        return block;
    }
};

/// A unique identifier for a bytecode block, used to reference blocks in a function builder.
pub const BlockId = Id.of(BlockBuilder, 16);

/// A visitor for bytecode blocks, used to track which blocks have been visited during encoding.
pub const BlockVisitor = pl.Visitor(BlockId);

/// A queue of bytecode blocks to visit, used by the Block encoder to queue references to jump targets.
pub const BlockVisitorQueue = pl.VisitorQueue(BlockId);

/// Simple intermediate representing a `core.AddressTable` whos rows have already been encoded.
pub const ProtoAddressTable = struct {
    addresses: RelativeAddress,
    kinds: RelativeAddress,
    len: u32,

    fn encode(self: *const ProtoAddressTable, encoder: *Encoder) Encoder.Error!void {
        const table = try encoder.create(core.AddressTable);
        const table_rel = encoder.addressToRelative(table);

        table.len = self.len;

        try encoder.addFixup(
            .absolute,
            .{ .known = table_rel.applyOffset(@intCast(@offsetOf(core.AddressTable, "kinds"))) },
            .{ .known = self.kinds },
            null,
        );

        try encoder.addFixup(
            .absolute,
            .{ .known = table_rel.applyOffset(@intCast(@offsetOf(core.AddressTable, "addresses"))) },
            .{ .known = self.addresses },
            null,
        );
    }
};

/// Simple intermediate for storing instructions in a block stream.
pub const ProtoInstr = struct {
    inner: Instruction,
    additional: AdditionalInfo,

    pub const AdditionalInfo = union(enum) {
        none,
        wide_imm: u64,
        call_args: Buffer.fixed(core.Register, pl.MAX_REGISTERS),
        branch_target: BlockId,
    };

    fn encode(self: *const ProtoInstr, queue: *BlockVisitorQueue, encoder: *Encoder) Encoder.Error!void {
        try encoder.ensureAligned(pl.BYTECODE_ALIGNMENT);

        const code_bits: core.InstructionBits = @intFromEnum(self.inner.code);
        const data_bits: core.InstructionBits = @intFromEnum(self.inner.data);

        const rel_addr = encoder.getRelativeAddress();
        try encoder.writeValue(code_bits | (data_bits << @bitSizeOf(Instruction.OpCode)));

        switch (self.additional) {
            .none => {},
            .wide_imm => |bits| try encoder.writeValue(bits),
            .call_args => |args| {
                try encoder.writeAll(std.mem.sliceAsBytes(args.toSlice()));
                try encoder.alignTo(pl.BYTECODE_ALIGNMENT);
            },
            .branch_target => |id| {
                const dest = encoder.localLocationId(id);

                try encoder.addFixup(
                    .relative,
                    .{ .known = rel_addr },
                    .{ .by_id = dest },
                    0,
                );

                try queue.add(id);
            },
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
pub const BlockBuilder = struct {
    /// The function this block belongs to.
    function: *const FunctionBuilder,
    /// The unique(-within-`function`) identifier for this block.
    id: BlockId,
    /// The instructions making up the body of this block, in un-encoded form.
    body: pl.ArrayList(ProtoInstr) = .empty,
    /// The instruction that terminates this block.
    /// * Adding any instruction when this is non-`null` is a `BadEncoding` error
    /// * For all other purposes, `null` is semantically equivalent to `unreachable`
    ///
    /// This is intended for convenience. For example, when calling an effect
    /// handler *that is known to always cancel*, we can treat the `prompt` as
    /// terminal in higher-level code.
    terminator: ?ProtoInstr = null,

    /// ID of all functions' entry point block.
    pub const entry_point_id = BlockId.fromInt(1);

    /// Get the total count of instructions in this block, including the terminator (even if implicit).
    pub fn count(self: *const BlockBuilder) u64 {
        return self.body.len + 1;
    }

    /// Append a prebuilt `ProtoInstr` to the block.
    /// * This is the most general way to append an instruction to the block;
    ///   the other forms, `instr`, `instrWide`, `instrCall`, `instrBranch`, and `instrTerm`,
    ///   are all safer wrappers around this and should be preferred where possible
    /// * It is the caller's responsibility to ensure that the instruction is well-formed
    /// * If the instruction is a terminator, it will be set as the block terminator
    pub fn instrProto(
        self: *BlockBuilder,
        proto: ProtoInstr,
    ) Encoder.Error!void {
        try self.ensureUnterminated();

        if (proto.inner.isTerm() or proto.inner.isBranch()) {
            self.terminator = proto;
        } else {
            try self.body.append(self.function.allocator, proto);
        }
    }

    /// Append a non-terminating one-word instruction to the block body.
    /// * See `instrCall`, `instrWide`, `instrBranch`, `instrTerm` for other instruction types
    /// * The unsafe method `instrProto` accepts prebuilt-`ProtoInstr` where these are not sufficient
    pub fn instr(self: *BlockBuilder, comptime code: Instruction.BasicOpCode, data: Instruction.SetType(code.upcast())) Encoder.Error!void {
        try self.instrProto(.{
            .inner = Instruction{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .none,
        });
    }

    /// Append a two-word instruction to the block body.
    /// * See `instrCall`, `instr`, `instrBranch`, `instrTerm` for other instruction types
    /// * The unsafe method `instrProto` accepts prebuilt-`ProtoInstr` where these are not sufficient
    pub fn instrWide(self: *BlockBuilder, comptime code: Instruction.WideOpCode, data: Instruction.SetType(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Encoder.Error!void {
        try self.instrProto(.{
            .inner = Instruction{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .{ .wide_imm = wide_operand },
        });
    }

    /// Append a call instruction to the block body.
    /// * See `instr`, `instrWide`, `instrBranch`, `instrTerm` for other instruction types
    /// * The unsafe method `instrProto` accepts prebuilt-`ProtoInstr` where these are not sufficient
    pub fn instrCall(
        self: *BlockBuilder,
        comptime code: Instruction.CallOpCode,
        data: Instruction.SetType(code.upcast()),
        args: Buffer.fixed(core.Register, pl.MAX_REGISTERS),
    ) Encoder.Error!void {
        try self.instrProto(.{
            .inner = Instruction{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .{ .call_args = args },
        });
    }

    /// Set the block terminator to a branch instruction.
    /// * See `instrCall`, `instrWide`, `instr`, `instrTerm` for other instruction types
    /// * The unsafe method `instrProto` accepts prebuilt-`ProtoInstr` where these are not sufficient
    pub fn instrBranch(
        self: *BlockBuilder,
        comptime code: Instruction.BranchOpCode,
        data: Instruction.SetType(code.upcast()),
        target: BlockId,
    ) Encoder.Error!void {
        try self.instrProto(.{
            .inner = Instruction{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .{ .branch_target = target },
        });
    }

    /// Set the block terminator.
    /// * See `instrCall`, `instrWide`, `instrBranch`, `instr` for other instruction types
    /// * The unsafe method `instrProto` accepts prebuilt-`ProtoInstr` where these are not sufficient
    pub fn instrTerm(self: *BlockBuilder, comptime code: Instruction.TermOpCode, data: Instruction.SetType(code.upcast())) Encoder.Error!void {
        try self.instrProto(.{
            .inner = Instruction{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .none,
        });
    }

    fn init(function: *const FunctionBuilder, id: BlockId) error{OutOfMemory}!*const BlockBuilder {
        const allocator = function.allocator;
        const self = try allocator.create(BlockBuilder);

        self.* = BlockBuilder{
            .function = function,
            .id = id,
        };

        return self;
    }

    fn deinit(self: *BlockBuilder) void {
        const allocator = self.function.allocator;
        defer allocator.destroy(self);

        self.body.deinit(allocator);
    }

    fn encode(self: *BlockBuilder, visitor: *BlockVisitor, encoder: *Encoder) Encoder.Error!void {
        // queue any references to other blocks for visiting after ours
        var queue = BlockVisitorQueue.init(encoder.temp_allocator);
        defer queue.deinit();

        // we can encode the current location as the block entry point
        try encoder.addLocation(encoder.getRelativeAddress(), LocationId{
            .region = encoder.currentRegion(),
            .offset = self.id.bitcast(bytecode.Offset, 32),
        });

        // first we emit all the body instructions, in order; body instructions don't queue block ids
        for (self.body.items) |*proto| {
            try proto.encode(&queue, encoder);
        }

        // now the terminator instruction, if any; same as body instructions, but can queue block ids
        if (self.terminator) |*proto| {
            try proto.encode(&queue, encoder);
        } else {
            // simply write the scaled opcode for `unreachable`, since it has no operands
            try encoder.writeInt(@as(pl.InstructionBits, @intFromEnum(Instruction.OpCode.@"unreachable")));
        }

        // now we visit all the blocks that were queued, in order
        while (queue.visit()) |block_id| {
            try self.function.visitBlock(visitor, encoder, block_id);
        }
    }

    fn ensureUnterminated(self: *BlockBuilder) Encoder.Error!void {
        if (self.terminator) |_| {
            log.debug("bytecode.BlockBuilder.ensureUnterminated: Block {x} is already terminated; cannot append additional instructions", .{self.id.toInt()});
            return error.BadEncoding;
        }
    }
};
