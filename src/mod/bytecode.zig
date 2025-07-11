//! # bytecode
//! This is a namespace for Ribbon bytecode data types, and the builder.
//!
//! The focal points are:
//! * `Instruction` - this is the data type representing un-encoded Ribbon bytecode instructions, as well as the namespace for both un-encoded and encoded opcodes and operand sets
//! * `Table` - the main API for creating Ribbon `Bytecode` units
//! * `FunctionBuilder` - the main API for creating Ribbon bytecode functions
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
    // ensure all module decls are semantically analyzed
    std.testing.refAllDecls(@This());
}

/// Error type shared by bytecode apis.
pub const Error = std.mem.Allocator.Error || error{
    /// Generic malformed bytecode error.
    BadEncoding,
    /// An error indicating that the current offset of the encoder is not aligned to
    /// the expected bytecode alignment for writing the provided data.
    UnalignedWrite,
};

/// Simple decoder iterator for bytecode instructions.
/// * Likely not suitable for interpreters due to performance; intended for reflection.
pub const Decoder = struct {
    /// The instruction stream for the decoder to read from.
    instructions: []const core.InstructionBits = &.{},
    /// Current decoding position in the instruction stream.
    ip: u64 = 0,

    /// A decoded instruction with its trailing operands.
    pub const Item = struct {
        /// The actual decoded instruction.
        instruction: Instruction,
        /// Any trailing operands that are not part of the instruction's main word.
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
                            => |Static| try std.fmt.formatInt(@intFromEnum(operand), 16, .lower, .{
                                .width = @sizeOf(Static) * 2,
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

    /// Trailing operands for instructions that have more than one word of data, used in `Decoder.Item` for multi-word instructions' data.
    pub const Trailing = union(enum) {
        /// No trailing operands.
        none: void,
        /// Trailing operands were call arguments, decoded as slice of `core.Register`.
        call_args: []const core.Register,
        /// Trailing operand is a wide immediate value, decoded as `Decoder.Imm`.
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

    /// Wrapper for all bytecode immediate operands, used in `Decoder.Trailing` for 2-word instructions' trailing operand.
    pub const Imm = union(enum) {
        /// 8 bits of the immediate word were used by the trailing operand.
        byte: u8,
        /// 16 bits of the immediate word were used by the trailing operand.
        short: u16,
        /// 32 bits of the immediate word were used by the trailing operand.
        int: u32,
        /// 64 bits of the immediate word were used by the trailing operand.
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

    /// Initialize a new Decoder with the provided instruction bit buffer.
    pub fn init(instructions: []const core.InstructionBits) Decoder {
        return .{ .instructions = instructions };
    }

    /// Clear the decoder instruction pointer.
    pub fn clear(self: *Decoder) void {
        self.ip = 0;
    }

    /// Iterator method. Get the next instruction from the decoder.
    pub fn next(self: *Decoder) error{BadEncoding}!?Item {
        if (self.ip < self.instructions.len) {
            // create the item that will be returned this iteration
            var item = Item{
                .instruction = Instruction.fromBits(self.instructions[self.ip]),
                .trailing = Trailing.none,
            };

            // we have consumed the main instruction word
            self.ip += 1;

            // check if the instruction is a wide instruction or a call instruction
            if (item.instruction.code.isWide()) {
                if (self.ip < self.instructions.len) {
                    // simple case, just copy it over and increment ip
                    item.trailing.wide_imm = self.instructions[self.ip];
                    self.ip += 1;
                } else {
                    log.debug("bytecode.Decoder.next: Incomplete wide instruction at end of stream.", .{});
                    return error.BadEncoding;
                }
            } else if (utils.getExpectedCallArgumentCount(item.instruction)) |n| {
                // this case needs to create a view of a variable number of *bytes* in the word stream
                const base: [*]core.Register = @ptrCast(self.instructions.ptr + self.ip);

                // we need to get the byte count, then round up to the nearest word size
                const arg_byte_count = n * @sizeOf(core.Register);
                const arg_word_count = (arg_byte_count + @sizeOf(core.InstructionBits) - 1) / @sizeOf(core.InstructionBits);

                // check the new instruction pointer before incrementing
                const new_ip = self.ip + arg_word_count;
                if (new_ip > self.instructions.len) {
                    log.debug("bytecode.Decoder.next: Incomplete call instruction at end of stream.", .{});
                    return error.BadEncoding;
                }

                // setup trailing operands
                item.trailing.call_args = base[0..n];
                self.ip = new_ip;
            }

            return item;
        }

        return null;
    }
};

/// Generic bytecode utilities.
pub const utils = struct {
    /// Purely symbolic type for id creation (`RegionId`).
    const Region = struct {};

    /// Purely symbolic type for id creation (`OffsetId`).
    const Offset = struct {};

    /// Given an instruction, determine how many call-argument register operands it expects to be passed.
    /// * Returns null if the instruction is not a call instruction
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

/// Represents a location in the encoded memory that is referenced by a fixup, but who's relative offset is not known at the time of encoding that fixup.
pub const Location = packed struct(u64) {
    /// The region id that this location belongs to.
    region: RegionId,
    /// The  offset id within the region that this location is at.
    offset: OffsetId,
};

/// Regions are used to scope fixup locations, allowing for multiple functions or blocks to be encoded in the same encoder.
pub const RegionId = Id.of(utils.Region, pl.STATIC_ID_BITS);

/// An identifier that is used to identify a location within a region in the encoded memory.
pub const OffsetId = Id.of(utils.Offset, pl.STATIC_ID_BITS);

/// A location map provides relative address identification, fixup storage, and other state for fixups of encoded data.
pub const LocationMap = struct {
    /// General purpose allocator used for location map collections.
    gpa: std.mem.Allocator,
    /// The map of addresses that are referenced by id in some fixups.
    addresses: pl.UniqueReprMap(Location, RelativeAddress, 80) = .empty,
    /// The map of addresses that need to be fixed up after encoding.
    fixups: pl.ArrayList(Fixup) = .empty,
    /// State variable indicating the region the location map currently operates in.
    region: RegionId = .fromInt(0),

    /// Initialize a new location map with the provided general purpose allocator.
    pub fn init(gpa: std.mem.Allocator) LocationMap {
        return LocationMap{
            .gpa = gpa,
        };
    }

    /// Clear the location map, retaining the allocator and memory.
    pub fn clear(self: *LocationMap) void {
        self.addresses.clearRetainingCapacity();
        self.fixups.clearRetainingCapacity();
        self.region = .fromInt(0);
    }

    /// Deinitialize the location map, freeing all memory it owns.
    pub fn deinit(self: *LocationMap) void {
        self.addresses.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.* = undefined;
    }

    /// Create a location identifier.
    /// * `id` should be of a type constructed by `common.Id`.
    /// * Identity types larger than pl.STATIC_ID_BITS bits may cause integer overflow.
    pub fn localLocationId(self: *LocationMap, id: anytype) Location {
        return Location{
            .region = self.region,
            .offset = id.bitcast(utils.Offset, pl.STATIC_ID_BITS),
        };
    }

    /// Bind a location identifier to a relative address.
    /// * If the location is already bound, this will overwrite the existing binding.
    pub fn bindLocation(self: *LocationMap, id: Location, rel_addr: RelativeAddress) error{OutOfMemory}!*void {
        return self.addresses.put(self.gpa, id, rel_addr);
    }

    /// Create a new fixup.
    pub fn bindFixup(self: *Encoder, kind: FixupKind, from: FixupRef, to: FixupRef, bit_offset: ?u6) error{OutOfMemory}!void {
        try self.fixups.append(self.temp_allocator, Fixup{
            .kind = kind,
            .from = from,
            .to = to,
            .bit_offset = bit_offset,
        });
    }

    /// Use the fixup tables in the location map to finalize the encoded buffer.
    /// * `temp_allocator` is used for the visitor that tracks safety of fixups
    pub fn finalizeBuffer(self: *LocationMap, temp_allocator: std.mem.Allocator, buf: []align(pl.PAGE_SIZE) u8) error{ OutOfMemory, BadEncoding }!void {
        // visitor to track safety
        var visitor = try pl.Visitor(*align(1) u64).init(temp_allocator);
        defer visitor.deinit();

        // Resolving things like branch jumps, where a relative offset is encoded into a bit-level offset of an instruction word,
        // and things like constant values that use pointer tagging, requires a fairly robust algorithm.
        // The top level is simply iterating our accumulated the fixups, though.
        for (self.fixups.items) |fixup| {
            // first we resolve our operand references
            // `resolveFixupRef` is just a simple helper, that either unwraps a known address or looks up a location by id
            const from = try self.resolveFixupRef(fixup.from, buf);
            const to = try self.resolveFixupRef(fixup.to, buf);

            // prevent writing to the same location multiple times in the event of a bad encoding
            if (!try visitor.visit(from)) {
                log.debug("Fixup location already visited", .{});
                return error.BadEncoding;
            }

            // we now have *align(1) u64 for both the pointee and the pointer,
            // in order to resolve the fixup we special case operations based on
            // whether we are doing an absolute or relative address fixup,
            // and whether this fixup requires a bitwise offset into the destination "pointer" word

            const is_bit_offset = fixup.bit_offset != null;
            const bit_offset = fixup.bit_offset orelse 0;

            const bits: u64, const bit_size: u64, const base_mask: u64 = switch (fixup.kind) {
                // we allow bit offsets for absolutes, to cover things like constant pointer tagging
                // however, if there is no bit offset we use the full 64 bits of the pointer to enable a simpler write operation
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
                // relative offsets are more complex, but here we just need to calculate the offset between the two pointers
                .relative => jump: {
                    if (comptime @bitSizeOf(Instruction.operand_sets.br.I) != 32 or @bitSizeOf(Instruction.operand_sets.br_if.I) != 32 or std.meta.fieldNames(Instruction.BranchOpCode).len != 2) {
                        @compileError("bytecode.LocationMap: out of sync with ISA, expected 2 branch instructions with relative offsets of 32 bits");
                    }

                    const relative_offset_bytes = @as(isize, @bitCast(@intFromPtr(to))) - @as(isize, @bitCast(@intFromPtr(from)));
                    const relative_offset_words: i32 = @intCast(@divExact(relative_offset_bytes, @sizeOf(core.InstructionBits)));

                    break :jump .{ @as(u32, @bitCast(relative_offset_words)), 32, std.math.maxInt(u32) };
                },
            };

            // simple case for absolute fixups with no bit offset
            if (bit_size == 64 and bit_offset == 0) {
                from.* = bits;
                continue;
            }

            // we have a bit offset, or our destination is smaller than 64 bits,
            // we must perform bit manipulation on the existing value in the destination word

            // check that this fixup is requesting a valid bit manipulation
            const padding = @as(u8, 64) - bit_size;
            if (bit_offset > padding) {
                log.debug("Fixup bit offset {d} exceeds available space 64-{d}={d} for destination word", .{
                    fixup.bit_offset,
                    bit_size,
                    padding,
                });
                return error.BadEncoding;
            }

            // now, we can perform the manipulation; load the bits
            const original_bits = from.*;

            // base_mask is just the max int of our sub-word; it needs to be moved into position in the word
            const mask = base_mask << @intCast(bit_offset);

            // use the inverse of the mask to clear the old destination bits
            const cleared = original_bits & ~mask;

            // bits needs to be shifted into position in the word
            const inserted = bits << @intCast(bit_offset);

            // finally, we can write the cleared old bits and our new bits together into the destination word
            from.* = cleared | inserted;
        }
    }

    /// Get an unaligned word address within a buffer, by resolving a `FixupRef` referencing it.
    pub fn resolveFixupRef(self: *Encoder, ref: FixupRef, base: []align(pl.PAGE_SIZE) u8) error{BadEncoding}!*align(1) u64 {
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
};

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
    /// A known relative address that can be resolved immediately.
    known: RelativeAddress,
    /// A location that is referenced by id, which will be resolved after encoding.
    by_id: Location,
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
    /// General purpose allocator for intermediate user operations.
    temp_allocator: std.mem.Allocator,
    /// The encoder's `AllocWriter`
    writer: AllocWriter,
    /// Location map providing relative address identification, fixup storage, and other state for fixups.
    locations: *LocationMap,

    pub const Error = AllocWriter.Error || bytecode.Error;

    /// Initialize a new Encoder with a `AllocWriter`.
    pub fn init(temp_allocator: std.mem.Allocator, writer_allocator: std.mem.Allocator, locations: *LocationMap) error{OutOfMemory}!Encoder {
        const writer = try AllocWriter.initCapacity(writer_allocator);
        return Encoder{
            .temp_allocator = temp_allocator,
            .writer = writer,
            .locations = locations,
        };
    }

    /// Clear the Encoder, retaining the allocator and writer, along with the writer buffer memory.
    pub fn clear(self: *Encoder) void {
        self.writer.clear();
        self.fixups.clearRetainingCapacity();
        self.locations.clearRetainingCapacity();
        self.region = .fromInt(0);
    }

    /// Deinitialize the Encoder, freeing any memory it owns.
    pub fn deinit(self: *Encoder) void {
        self.writer.deinit();
        self.fixups.deinit(self.temp_allocator);
        self.locations.deinit(self.temp_allocator);
        self.* = undefined;
    }

    /// Enter a new encoding region.
    /// * Expected usage:
    /// ```zig
    /// const parent_region = encoder.enterRegion(my_region_id);
    /// defer encoder.leaveRegion(parent_region);
    /// ```
    /// * `region` must be a <= `pl.STATIC_ID_BITS`-bit enum type.
    pub fn enterRegion(self: *Encoder, region: anytype) RegionId {
        const old_region = self.region;
        self.region = @enumFromInt(@intFromEnum(region));
        return old_region;
    }

    /// Leave the current encoding region, restoring the previous region. See `enterRegion`.
    pub fn leaveRegion(self: *Encoder, old_region: RegionId) void {
        self.region = old_region;
    }

    /// Get the current encoding region id.
    pub fn currentRegion(self: *Encoder) RegionId {
        return self.region;
    }

    /// Finalize the Encoder's writer, returning the memory.
    ///
    /// After calling this function, the encoder will be in its default-initialized state.
    /// In other words, it is safe but not necessary to call `deinit` on it.
    /// It does not need to be re-initializd before reuse, as the allocator is retained.
    pub fn finalize(self: *Encoder) Encoder.Error![]align(pl.PAGE_SIZE) u8 {
        defer self.clear();

        return self.writer.finalize();
    }

    /// Create a new fixup.
    pub fn bindFixup(self: *Encoder, kind: FixupKind, from: FixupRef, to: FixupRef, bit_offset: ?u6) error{OutOfMemory}!void {
        try self.locations.bindFixup(self, kind, from, to, bit_offset);
    }

    /// Create a new location for fixups to reference.
    pub fn bindLocation(self: *Encoder, rel_addr: RelativeAddress, id: Location) error{OutOfMemory}!void {
        try self.locations.bindLocation(id, rel_addr);
    }

    /// `addLocation` with the current relative address and region of the encoder.
    /// * `id` should be of a type constructed by `common.Id`.
    /// * Identity types larger than 32 bits may cause integer overflow.
    pub fn bindCurrentLocation(self: *Encoder, id: anytype) error{OutOfMemory}!void {
        return self.bindLocation(self.getRelativeAddress(), self.localLocationId(id));
    }

    /// Create a new `LocationId` for a location in the encoded memory, using the current region of the encoder.
    /// * `id` should be of a type constructed by `common.Id`.
    /// * Identity types larger than 32 bits may cause integer overflow.
    pub fn localLocationId(self: *Encoder, offset: anytype) Location {
        return self.locations.localLocationId(offset);
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
    pub fn alignedAlloc(self: *Encoder, alignment: pl.Alignment, len: usize) AllocWriter.Error![]u8 {
        return self.writer.alignedAlloc(alignment, len);
    }

    /// Same as `std.mem.Allocator.alloc`, but allocates from the virtual address space of the encoder.
    pub fn alloc(self: *Encoder, comptime T: type, len: usize) AllocWriter.Error![]T {
        return self.writer.alloc(T, len);
    }

    /// Same as `alloc`, but returns a RelativeAddress instead of a pointer.
    pub fn allocRel(self: *Encoder, comptime T: type, len: usize) AllocWriter.Error!RelativeAddress {
        return self.writer.allocRel(T, len);
    }

    /// Same as `std.mem.Allocator.dupe`, but copies a slice into the virtual address space of the encoder.
    pub fn dupe(self: *Encoder, comptime T: type, slice: []const T) AllocWriter.Error![]T {
        return self.writer.dupe(T, slice);
    }

    /// Same as `dupe`, but returns a RelativeAddress instead of a pointer.
    pub fn dupeRel(self: *Encoder, comptime T: type, slice: []const T) AllocWriter.Error!RelativeAddress {
        return self.writer.dupeRel(T, slice);
    }

    /// Same as `std.mem.Allocator.create`, but allocates from the virtual address space of the encoder.
    pub fn create(self: *Encoder, comptime T: type) AllocWriter.Error!*T {
        return self.writer.create(T);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn createRel(self: *Encoder, comptime T: type) AllocWriter.Error!RelativeAddress {
        return self.writer.createRel(T);
    }

    /// Same as `create`, but takes an initializer.
    pub fn clone(self: *Encoder, value: anytype) AllocWriter.Error!*@TypeOf(value) {
        return self.writer.clone(value);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn cloneRel(self: *Encoder, value: anytype) AllocWriter.Error!RelativeAddress {
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
    /// * This function is provided for backward compatibility with Zig's writer interface. Prefer `writeValue` instead.
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
    /// * Does not consider or provide value alignment
    /// * See `std.meta.hasUniqueRepresentation`
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
    pub fn ensureAligned(self: *Encoder, alignment: pl.Alignment) Encoder.Error!void {
        if (pl.alignDelta(self.writer.cursor, alignment) != 0) {
            return error.UnalignedWrite;
        }
    }
};

/// Top-level builder for a single, linkable Ribbon bytecode unit.
/// The Table is the main entry point for the bytecode construction API.
/// It manages the memory encoder, the header, and all functions and statics.
pub const Table = struct {
    /// Allocator for all intermediate data. This is the child allocator for `Table.arena`.
    gpa: std.mem.Allocator,
    /// Allocator for non-volatile intermediate data.
    arena: std.heap.ArenaAllocator,
    /// The location map for fixups and relative addresses.
    locations: LocationMap,
    /// The header builder for the bytecode unit.
    header: HeaderBuilder = .{},
    /// FunctionBuilders owned by this table.
    functions: pl.UniqueReprMap(core.FunctionId, FunctionEntry, 80) = .empty,

    /// An entry in the `Table.functions` map, which can either be a `FunctionBuilder` or a user-encoded function.
    pub const FunctionEntry = struct {
        /// The location of the function in the bytecode.
        location: Location,
        /// The builder for this function. Not all functions require a builder, some may be user-encoded.
        /// A null state does not necessarily indicate the function entry is unfinished.
        builder: ?FunctionBuilder = null,

        fn deinit(self: *FunctionEntry) void {
            if (self.builder) |b| b.deinit();
        }
    };

    /// Initialize a new table.
    pub fn init(allocator: std.mem.Allocator) Table {
        return Table{ .gpa = allocator, .arena = .init(allocator), .locations = .init(allocator) };
    }

    /// Clear the table, retaining allocated storage where possible.
    pub fn clear(self: *Table) void {
        var function_it = self.functions.valueIterator();
        while (function_it.next()) |entry| entry.deinit();
        self.functions.clearRetainingCapacity();

        self.locations.clear();
        self.header.clear();

        self.arena.reset(.retain_capacity);
    }

    /// Deinitialize the table, freeing all associated memory, including the header builder.
    pub fn deinit(self: *Table) void {
        self.functions.deinit(self.gpa);
        self.locations.deinit(self.gpa);
        self.header.deinit(self.gpa);
        self.arena.deinit();

        self.* = undefined;
    }

    /// Create an entry for a static value in the bytecode header.
    pub fn createHeaderEntry(self: *Table, comptime kind: core.SymbolKind, name: ?[]const u8) error{OutOfMemory}!core.IdFromSymbolKind(kind) {
        // get the next static id
        const static_id = self.header.getNextId();
        const typed_id = static_id.bitcast(kind.toType(), pl.STATIC_ID_BITS);

        // create a location for the static value
        const func_loc = self.locations.localLocationId(static_id);
        const func_ref = FixupRef{ .by_id = func_loc };

        // bind the location to the address table
        const bind_result = try self.header.bindAddress(self.gpa, .kind, .{ .relative = func_ref });

        // sanity check: static_id should be the same as bind_result if getNextId is sound
        std.debug.assert(static_id == bind_result);

        // bind exported names in the symbol table
        if (name) |str| {
            try self.header.exportStatic(self.gpa, str, static_id);
        }

        // create type-specific static builder tracking entry
        switch (kind) {
            .function => {
                const gop = try self.functions.getOrPut(self.gpa, typed_id);

                // sanity check: id should be fresh if the address table has been mutated in append-only fashion
                std.debug.assert(!gop.found_existing);

                gop.value_ptr.* = FunctionEntry{
                    .location = func_loc,
                    .binding = .user_encoded,
                };
            },
            else => pl.todo(noreturn, "table support for static kind " ++ @tagName(kind) ++ " not yet implemented"),
        }

        return typed_id;
    }

    /// Bind a new `FunctionBuilder` to an id.
    /// * A fresh `id` can be created with `createHeaderEntry`.
    /// * Note that the returned pointer is unstable; creation of additional functions may invalidate it.
    /// * Use `getFunctionBuilder` to retrieve the latest pointer to the function builder by its id (available as a field of the builder).
    pub fn createFunctionBuilder(
        self: *Table,
        id: core.FunctionId,
    ) error{OutOfMemory}!*FunctionBuilder {
        // if we're not tracking this id we can't create a builder for it
        const entry = self.functions.getPtr(self.gpa, id) orelse {
            log.debug("bytecode.Table.createFunctionBuilder: Function id {d} does not exist in the tracked portion of the header", .{id});
            return error.BadEncoding;
        };

        // we support local mutations up to and including full replacement of the builder,
        // so if there was an existing builder its not an error, just deinit
        if (entry.builder) |*old_builder| old_builder.deinit();

        // setup and return the new builder
        entry.builder = FunctionBuilder.init(self.gpa, self.arena, id);

        return &entry.binding.?.builder;
    }

    /// Get a function builder by its id.
    pub fn getFunctionBuilder(self: *const Table, id: core.FunctionId) ?*FunctionBuilder {
        const entry = self.functions.getPtr(id) orelse return null;
        return if (entry.builder) |*builder| builder else null;
    }

    /// Get the location of a function by its id.
    pub fn getFunctionLocation(self: *const Table, id: core.FunctionId) ?Location {
        const entry = self.functions.get(id) orelse return null;
        return entry.location;
    }

    /// Encode the current state of the table into a `core.Bytecode` unit.
    pub fn encode(self: *const Table, allocator: std.mem.Allocator) Encoder.Error!core.Bytecode {
        // Create the encoder with the provided allocator
        const encoder = try Encoder.init(self.gpa, allocator, &self.locations);
        defer encoder.deinit();

        // Encode the header first
        const header_rel = try self.header.encode(&encoder);

        // Encode the statics the header references
        var function_it = self.functions.valueIterator();
        while (function_it.next()) |entry| {
            if (entry.builder) |*builder| try builder.encode(&encoder);
        }

        // Finalize the encoder and get the bytecode
        const buf = try encoder.finalize();

        // Run location map finalization on the buffer to fixup all addresses
        try self.locations.finalizeBuffer(encoder.temp_allocator, buf);

        // For core.Bytecode.deinit to work, the header must be the base pointer of the buffer.
        std.debug.assert(header_rel.isBase());

        // Wrap the encoded header in a `core.Bytecode` structure
        return core.Bytecode{
            .header = header_rel.toTypedPtr(core.Header, buf),
        };
    }
};

/// Builder for bytecode headers. See `core.Header`.
/// * This is a lower-level utility api used by the `bytecode.Table`.
pub const HeaderBuilder = struct {
    /// Binds *fully-qualified* names to AddressTable ids
    symbol_table: SymbolTableBuilder = .{},
    /// Binds bytecode ids to addresses for the function being compiled
    address_table: AddressTableBuilder = .{},

    /// Get the id the next address table entry will be bound to.
    pub fn getNextId(self: *HeaderBuilder) core.StaticId {
        return self.address_table.getNextId();
    }

    /// Clear the symbol and address table entries, retaining the current memory capacity.
    pub fn clear(self: *HeaderBuilder) void {
        self.symbol_table.clear();
        self.address_table.clear();
    }

    /// Deinitialize the symbol and address table, freeing all memory.
    pub fn deinit(self: *HeaderBuilder, allocator: std.mem.Allocator) void {
        self.symbol_table.deinit(allocator);
        self.address_table.deinit(allocator);

        self.* = undefined;
    }

    /// Bind a new id without a name, returning the address table id of the static.
    pub fn bindAddress(
        self: *HeaderBuilder,
        allocator: std.mem.Allocator,
        kind: core.SymbolKind,
        address: AddressTableBuilder.Entry,
    ) error{OutOfMemory}!core.StaticId {
        return self.address_table.bind(allocator, kind, address);
    }

    /// Bind a name to an address in the header by id, exporting the static value to the symbol table.
    pub fn exportStatic(
        self: *HeaderBuilder,
        allocator: std.mem.Allocator,
        name: []const u8,
        static_id: core.StaticId,
    ) error{OutOfMemory}!void {
        return self.symbol_table.bind(allocator, name, static_id);
    }

    /// Bind a fully qualified name to an address, returning the address table id of the static.
    pub fn bindExportAddress(
        self: *HeaderBuilder,
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: core.SymbolKind,
        address: AddressTableBuilder.Entry,
    ) error{OutOfMemory}!core.StaticId {
        const id = try self.bindAddress(allocator, kind, address);
        try self.exportStatic(allocator, name, id);
        return id;
    }

    /// Encode the current state of the table into a `core.Header` structure, returning its relative address.
    pub fn encode(self: *const HeaderBuilder, encoder: *Encoder) Encoder.Error!RelativeAddress {
        const header_rel = try encoder.createRel(core.Header);

        const start_size = encoder.getEncodedSize();

        const symbol_table = try self.symbol_table.encode(&encoder);
        const address_table = try self.address_table.encode(&encoder);

        const end_size = encoder.getEncodedSize();

        const header = encoder.relativeToPointer(*const core.Header, header_rel);
        header.size = end_size - start_size;

        try symbol_table.write(encoder, header_rel.applyOffset(@offsetOf(core.Header, "symbol_table")));
        try address_table.write(encoder, header_rel.applyOffset(@offsetOf(core.Header, "address_table")));

        return header_rel;
    }
};

/// Builder for bytecode symbol tables. See `core.SymbolTable`.
/// This is used to bind fully qualified names to static ids, which are then used in the `AddressTableBuilder` to bind addresses to those ids.
/// The symbol table is used to resolve names to addresses in the bytecode, which is a core part of capabilities like dynamic linking and debug symbol reference.
/// * This is a lower-level utility api used by the `bytecode.HeaderBuilder`.
pub const SymbolTableBuilder = struct {
    /// Binds fully-qualified names to AddressTable ids
    map: pl.StringArrayMap(core.StaticId) = .empty,

    /// Deinitializes the symbol table, freeing all memory.
    pub fn deinit(self: *SymbolTableBuilder, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }

    /// Bind a fully qualified name to an address table id of a constant.
    pub fn bind(self: *SymbolTableBuilder, allocator: std.mem.Allocator, name: []const u8, id: core.StaticId) error{OutOfMemory}!void {
        if (name.len == 0) {
            log.debug("bytecode.SymbolTableBuilder.bind: Failed to export StaticId:{x}; Name string cannot be empty", .{@intFromEnum(id)});
            return error.BadEncoding;
        }

        try self.map.put(allocator, name, id);
    }

    /// Get the address table id associated with the given fully qualified name.
    pub fn get(self: *const SymbolTableBuilder, name: []const u8) ?core.StaticId {
        return self.map.get(name);
    }

    /// Clears all entries in the symbol table, retaining the current memory capacity.
    pub fn clear(self: *SymbolTableBuilder) void {
        self.map.clearRetainingCapacity();
    }

    /// Writes the current state of this address table into the provided encoder,
    /// returning a new `core.SymbolTable` referencing the new buffers. See `ProtoSymbolTable.write`.
    pub fn encode(self: *const SymbolTableBuilder, encoder: *Encoder) Encoder.Error!ProtoSymbolTable {
        const new_keys_rel = try encoder.allocRel(core.SymbolTable.Key, self.map.count());
        const new_values_rel = try encoder.allocRel(core.StaticId, self.map.count());

        var i: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const new_keys = encoder.relativeToPointer([*]core.SymbolTable.Key, new_keys_rel);
            const new_values = encoder.relativeToPointer([*]core.StaticId, new_values_rel);

            const new_name = try encoder.dupe(u8, entry.key_ptr.*);

            new_keys[i] = .{
                .hash = pl.hash64(new_name),
                .name = .fromSlice(new_name),
            };

            new_values[i] = entry.value_ptr.*;

            i += 1;
        }

        return ProtoSymbolTable{
            .len = self.map.count(),
            .keys = new_keys_rel,
            .values = new_values_rel,
        };
    }
};

/// A builder for bytecode address tables. See `core.AddressTable`.
/// This is used to bind static ids to addresses of constants, functions, and other static values.
/// The address table is a core part of the bytecode, as it allows the bytecode to reference static values by id,
/// which can then be resolved to addresses at runtime or during linking.
/// The address table builder supports both relative and absolute addresses, as well as inlined data for static values that are not directly addressable.
/// Like the rest of the `bytecode` module infrastructure, this supports fixups, which are used to resolve addresses that are not known at the time of encoding.
/// * This is a lower-level utility api used by the `bytecode.HeaderBuilder`.
pub const AddressTableBuilder = struct {
    data: pl.MultiArrayList(struct {
        kind: core.SymbolKind,
        address: Entry,
    }) = .empty,

    /// A to-be-encoded binding in an address table builder.
    pub const Entry = union(enum) {
        relative: FixupRef,
        absolute: *const anyopaque,
        inlined: struct {
            bytes: []const u8,
            alignment: pl.Alignment,
        },
    };

    /// Get the id the next address table entry will be bound to.
    pub fn getNextId(self: *HeaderBuilder) core.StaticId {
        return .fromInt(self.count());
    }

    /// Get the number of entries in the address table.
    pub fn count(self: *const AddressTableBuilder) usize {
        return self.data.len;
    }

    /// Clear all entries in the address table, retaining the current memory capacity.
    pub fn clear(self: *AddressTableBuilder) void {
        self.data.clearRetainingCapacity();
    }

    /// Deinitialize the address table, freeing all memory it owns.
    pub fn deinit(self: *AddressTableBuilder, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = undefined;
    }

    /// Get the SymbolKind of an address by its id.
    pub fn getKind(self: *const AddressTableBuilder, id: core.StaticId) ?core.SymbolKind {
        const index = id.toInt();

        if (index < self.count()) {
            return self.data.items(.kind)[index];
        } else {
            return null;
        }
    }

    /// Get the address of a static value by its id.
    pub fn getAddress(self: *const AddressTableBuilder, id: core.StaticId) ?Entry {
        const index = id.toInt();

        if (index < self.count()) {
            return self.data.items(.address)[index];
        } else {
            return null;
        }
    }

    /// Get the address of a typed static by its id.
    pub fn get(self: *const AddressTableBuilder, id: anytype) ?Entry {
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
    pub fn bind(self: *AddressTableBuilder, allocator: std.mem.Allocator, kind: core.SymbolKind, address: Entry) error{OutOfMemory}!core.StaticId {
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
    pub fn validateSymbol(self: *const AddressTableBuilder, id: core.StaticId) bool {
        return self.data.len > id.toInt();
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validateSymbolKind(self: *const AddressTableBuilder, kind: core.SymbolKind, id: core.StaticId) bool {
        const index = id.toInt();

        if (index < self.data.len) {
            return self.data.items(.kind)[index] == kind;
        } else {
            return false;
        }
    }

    /// Determine if the provided id exists and has the given kind.
    pub fn validate(self: *const AddressTableBuilder, id: anytype) bool {
        const T = @TypeOf(id);

        if (comptime T == core.StaticId) {
            return self.validateSymbol(id);
        } else {
            return self.validateSymbolKind(comptime core.symbolKindFromId(T), id);
        }
    }

    /// Writes the current state of this address table into the provided encoder,
    /// returning a new `ProtoAddressTable` referencing the new buffers. See `ProtoAddressTable.write`.
    pub fn encode(self: *const AddressTableBuilder, encoder: *Encoder) Encoder.Error!ProtoAddressTable {
        const kinds = self.data.items(.kind);
        const addresses = self.data.items(.address);

        const new_kinds_rel = try encoder.dupeRel(core.SymbolKind, kinds);
        const new_addresses_rel = try encoder.allocRel(*const anyopaque, self.data.len);

        for (0..self.count()) |i| {
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
    /// The general allocator used by this function for collections.
    gpa: std.mem.Allocator,
    /// The arena allocator used by this function for non-volatile data.
    arena: std.mem.Allocator,
    /// The function's unique identifier.
    id: core.FunctionId = .fromInt(0),
    /// The function's stack window size.
    stack_size: usize = 0,
    /// The function's stack window alignment.
    stack_align: usize = 8,
    /// The function's basic blocks, unordered.
    blocks: pl.UniqueReprMap(BlockId, BlockBuilder, 80) = .empty,

    /// Initialize a new builder for a bytecode function.
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) FunctionBuilder {
        return FunctionBuilder{
            .gpa = gpa,
            .arena = arena,
        };
    }

    /// Clear the function builder, retaining the current memory capacity.
    pub fn clear(self: *FunctionBuilder) void {
        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();
        self.blocks.clearRetainingCapacity();

        self.id = .fromInt(0);
        self.stack_size = 0;
        self.stack_align = 8;
    }

    /// Deinitialize the builder, freeing all memory associated with it.
    pub fn deinit(self: *FunctionBuilder) void {
        const allocator = self.gpa;
        defer allocator.destroy(self);

        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

        self.blocks.deinit(allocator);

        self.* = undefined;
    }

    /// Create a new basic block within this function, returning a pointer to it.
    /// * Note that the returned pointer is unstable; creation of additional blocks may invalidate it.
    /// * Use `getBlock` to retrieve the latest pointer to the block builder by its id (available as a field of the builder).
    pub fn createBlock(self: *FunctionBuilder) error{OutOfMemory}!*BlockBuilder {
        const index = self.blocks.count();

        if (index > core.StaticId.MAX_INT) {
            log.debug("bytecode.FunctionBuilder.createBlock: Cannot create more than {d} blocks", .{BlockBuilder.MAX_BLOCKS});
            return error.OutOfMemory;
        }

        const block_id = BlockId.fromInt(index);

        const gop = try self.blocks.getOrPut(self.gpa, block_id);

        // sanity check: block_id should be fresh if the map has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        gop.value_ptr.* = BlockBuilder.init(self.gpa, self.arena);
        gop.value_ptr.id = block_id;
        gop.value_ptr.function = self.id;

        return gop.value_ptr;
    }

    /// Get a pointer to a block builder by its block id.
    pub fn getBlock(self: *const FunctionBuilder, id: BlockId) ?*BlockBuilder {
        return self.blocks.get(id);
    }

    /// Encode the function and all blocks into the provided encoder, inserting a fixup location for the function itself into the current region.
    pub fn encode(self: *FunctionBuilder, encoder: *Encoder) Encoder.Error!void {
        var visitor: BlockVisitor = try .init(encoder.temp_allocator);
        defer visitor.deinit();

        var queue: BlockVisitorQueue = try .init(encoder.temp_allocator);
        defer queue.deinit();

        const rel_addr = encoder.getRelativeAddress();
        const location = encoder.localLocationId(self.id);
        try encoder.addLocation(rel_addr, location);

        const region_token = encoder.enterRegion(self.id);
        defer encoder.leaveRegion(region_token);

        try queue.add(BlockBuilder.entry_point_id);

        while (queue.visit()) |block_id| {
            if (!try visitor.visit(block_id)) continue;

            const block = self.blocks.get(block_id).?;

            try block.encode(queue, encoder);
        }
    }
};

/// A builder for creating a linear sequence of bytecode instructions.
/// This builder does not support terminators or branch instructions and is
/// intended for generating straight-line code fragments for specialized use cases
/// like JIT compilers or code generators.
pub const SequenceBuilder = struct {
    /// The general allocator used by this sequence builder for collections.
    gpa: std.mem.Allocator,
    /// The collection of instructions in this sequence, in un-encoded form.
    body: pl.ArrayList(ProtoInstr) = .empty,

    /// Initialize a new sequence builder with the given allocator.
    pub fn init(allocator: std.mem.Allocator) SequenceBuilder {
        return .{ .allocator = allocator };
    }

    /// Clear the sequence builder, retaining the current memory capacity.
    pub fn clear(self: *SequenceBuilder) void {
        self.body.clearRetainingCapacity();
    }

    /// Deinitialize the sequence builder, freeing all memory associated with it.
    pub fn deinit(self: *SequenceBuilder) void {
        self.body.deinit(self.gpa);
        self.* = undefined;
    }

    /// Append a pre-composed `ProtoInstr` to the sequence.
    /// * Violating sequence invariants will result in a `BadEncoding` error.
    pub fn proto(self: *SequenceBuilder, pi: ProtoInstr) Error!void {
        if (pi.instruction.isTerm() or pi.instruction.isBranch()) {
            log.err("SequenceBuilder cannot contain terminator or branch instructions", .{});
            return error.BadEncoding;
        }

        if (pi.instruction.isCall()) {
            if (pi.additional != .call_args or pi.additional.call_args.len != utils.getExpectedCallArgumentCount(pi.instruction)) {
                log.err("SequenceBuilder cannot contain call instructions with non-standard argument counts", .{});
                return error.BadEncoding;
            }
        }

        try self.body.append(self.gpa, pi);
    }

    /// Append a non-terminating one-word instruction to the sequence.
    pub fn instr(self: *SequenceBuilder, comptime code: Instruction.BasicOpCode, data: Instruction.SetType(code.upcast())) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .none,
        });
    }

    /// Append a two-word instruction to the sequence.
    pub fn instrWide(self: *SequenceBuilder, comptime code: Instruction.WideOpCode, data: Instruction.SetType(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .{ .wide_imm = wide_operand },
        });
    }

    /// Append a call instruction to the sequence.
    pub fn instrCall(self: *SequenceBuilder, comptime code: Instruction.CallOpCode, data: Instruction.SetType(code.upcast()), args: Buffer.fixed(core.Register, pl.MAX_REGISTERS)) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .{ .call_args = args },
        });
    }

    /// Encodes the instruction sequence into the provided encoder.
    /// Does not encode a terminator; execution will fall through.
    pub fn encode(self: *const SequenceBuilder, queue: *BlockVisitorQueue, encoder: *Encoder) Encoder.Error!void {
        for (self.body.items) |*pi| {
            try pi.encode(queue, encoder);
        }
    }
};

/// A unique identifier for a bytecode block, used to reference blocks in a function builder.
pub const BlockId = Id.of(BlockBuilder, 16);

/// A visitor for bytecode blocks, used to track which blocks have been visited during encoding.
pub const BlockVisitor = pl.Visitor(BlockId);

/// A queue of bytecode blocks to visit, used by the Block encoder to queue references to jump targets.
pub const BlockVisitorQueue = pl.VisitorQueue(BlockId);

/// A bytecode basic block in unencoded form.
///
/// A basic block is a straight-line sequence of instructions with no *local*
/// control flow, terminated by a branch or similar instruction. It is built upon
/// a `SequenceBuilder` for its body, adding support for terminators and branching.
pub const BlockBuilder = struct {
    /// The arena allocator used for this block's body.
    arena: std.mem.Allocator,
    /// The instructions making up the body of this block, in un-encoded form.
    body: SequenceBuilder,
    /// The unique(-within-`function`) identifier for this block.
    id: BlockId = .fromInt(0),
    /// The function this block belongs to.
    function: core.FunctionId = .fromInt(0),
    /// The instruction that terminates this block.
    /// * Adding any instruction when this is non-`null` is a `BadEncoding` error
    /// * For all other purposes, `null` is semantically equivalent to `unreachable`
    terminator: ?ProtoInstr = null,

    /// ID of all functions' entry point block.
    pub const entry_point_id = BlockId.fromInt(0);

    /// Initialize a new block builder for the given function and block ids.
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) BlockBuilder {
        return BlockBuilder{
            .arena = arena,
            .body = .init(gpa),
        };
    }

    /// Clear the block builder, retaining the current memory capacity.
    pub fn clear(self: *BlockBuilder) void {
        self.body.clear();

        self.id = .fromInt(0);
        self.function = .fromInt(0);
        self.terminator = null;
    }

    /// Deinitialize the block builder, freeing all memory associated with it.
    pub fn deinit(self: *BlockBuilder) void {
        self.body.deinit();
        self.* = undefined;
    }

    /// Get the total count of instructions in this block, including the terminator (even if implicit).
    pub fn count(self: *const BlockBuilder) u64 {
        return self.body.body.items.len + 1;
    }

    /// Append a pre-composed
    /// Append a non-terminating one-word instruction to the block body.
    pub fn instr(self: *BlockBuilder, comptime code: Instruction.BasicOpCode, data: Instruction.SetType(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instr(code, data);
    }

    /// Append a two-word instruction to the block body.
    pub fn instrWide(self: *BlockBuilder, comptime code: Instruction.WideOpCode, data: Instruction.SetType(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instrWide(code, data, wide_operand);
    }

    /// Append a call instruction to the block body.
    pub fn instrCall(self: *BlockBuilder, comptime code: Instruction.CallOpCode, data: Instruction.SetType(code.upcast()), args: Buffer.fixed(core.Register, pl.MAX_REGISTERS)) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instrCall(code, data, args);
    }

    /// Set the block terminator to a branch instruction.
    pub fn instrBr(self: *BlockBuilder, target: BlockId) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = .br,
                .data = .{ .br = .{} },
            },
            .additional = .{ .branch_target = target },
        };
    }

    /// Set the block terminator to a conditional branch instruction.
    pub fn instrBrIf(self: *BlockBuilder, condition: core.Register, target: BlockId) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = .br_if,
                .data = .{ .br_if = .{ .R = condition } },
            },
            .additional = .{ .branch_target = target },
        };
    }

    /// Set the block terminator.
    pub fn instrTerm(self: *BlockBuilder, comptime code: Instruction.TermOpCode, data: Instruction.SetType(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = code.upcast(),
                .data = data,
            },
            .additional = .none,
        };
    }

    /// Encode the block into the provided encoder, including the body instructions and the terminator.
    /// * The block's entry point is encoded as a location in the bytecode header, using the current region id and the block's id as the offset
    /// * Other blocks' ids that are referenced by instructions are added to the provided queue in order of use
    pub fn encode(self: *BlockBuilder, queue: *BlockVisitorQueue, encoder: *Encoder) Encoder.Error!void {
        // we can encode the current location as the block entry point
        try encoder.addLocation(encoder.getRelativeAddress(), Location{
            .region = encoder.currentRegion(),
            .offset = self.id.bitcast(bytecode.Offset, 32),
        });

        // first we emit all the body instructions by encoding the inner sequence
        try self.body.encode(queue, encoder);

        // now the terminator instruction, if any; same as body instructions, but can queue block ids
        if (self.terminator) |*proto| {
            try proto.encode(queue, encoder);
        } else {
            // simply write the scaled opcode for `unreachable`, since it has no operands
            try encoder.writeValue(@as(core.InstructionBits, @intFromEnum(Instruction.OpCode.@"unreachable")));
        }
    }

    fn ensureUnterminated(self: *BlockBuilder) Encoder.Error!void {
        if (self.terminator) |_| {
            log.debug("bytecode.BlockBuilder.ensureUnterminated: Block {x} is already terminated; cannot append additional instructions", .{self.id.toInt()});
            return error.BadEncoding;
        }
    }

    comptime {
        const br_instr_names = std.meta.fieldNames(Instruction.BranchOpCode);

        if (br_instr_names.len != 2) {
            @compileError("bytecode.BlockBuilder: out of sync with ISA, unhandled branch opcodes");
        }

        if (pl.indexOfBuf(u8, br_instr_names, "br") == null or pl.indexOfBuf(u8, br_instr_names, "br_if") == null) {
            @compileError("bytecode.BlockBuilder: out of sync with ISA, branch opcode names changed");
        }
    }
};

/// Simple intermediate for storing instructions in a block stream.
/// * This is a temporary intermediate type produced and consumed during the building/encoding process
/// * Used as an input to various builders' and encoder methods, to represent full instructions; necessary to store multi-word instructions, before encoding
pub const ProtoInstr = struct {
    /// The instruction itself, containing the opcode and data.
    instruction: Instruction,
    /// Additional information for the instruction, such as wide immediate values or call arguments.
    additional: AdditionalInfo,

    /// Additional information for `ProtoInstr`, capturing data that does not fit into an instruction word.
    pub const AdditionalInfo = union(enum) {
        /// No additional information, basic instruction.
        none,
        /// The immediate value half of a 2-word instruction.
        wide_imm: u64,
        /// The arguments of variable-width call instructions.
        call_args: Buffer.fixed(core.Register, pl.MAX_REGISTERS),
        /// The destination of branch instructions.
        branch_target: BlockId,
    };

    /// Encode this instruction into the provided encoder at the current relative address.
    /// * This method is used by the `BlockBuilder` to encode instructions into the bytecode.
    /// * It is not intended to be used directly; instead, use the `BlockBuilder` methods to append instructions.
    /// * Also available are convenience methods in `Encoder` for appending instructions directly.
    /// * The `queue` is used to track branch targets and ensure they are visited in the correct order.
    pub fn encode(self: *const ProtoInstr, queue: *BlockVisitorQueue, encoder: *Encoder) Encoder.Error!void {
        try encoder.ensureAligned(pl.BYTECODE_ALIGNMENT);

        const code_bits: core.InstructionBits = @intFromEnum(self.instruction.code);
        const data_bits: core.InstructionBits = @intFromEnum(self.instruction.data);

        const rel_addr = encoder.getRelativeAddress();
        try encoder.writeValue(code_bits | (data_bits << @bitSizeOf(Instruction.OpCode)));

        switch (self.additional) {
            .none => {},
            .wide_imm => |bits| try encoder.writeValue(bits),
            .call_args => |args| try encoder.writeAll(std.mem.sliceAsBytes(args.toSlice())),
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

        try encoder.alignTo(pl.BYTECODE_ALIGNMENT);
    }
};

/// Simple intermediate representing a `core.SymbolTable` whos rows have already been encoded.
/// * This is a temporary intermediate type produced and consumed during the building/encoding process
/// * See `bytecode.SymbolTableBuilder` and `bytecode.HeaderBuilder` for usage
pub const ProtoSymbolTable = struct {
    keys: RelativeAddress,
    values: RelativeAddress,
    len: u32,

    /// Helper function
    /// Expected usage:
    /// 1. Reserve bytecode header space at the start of encoding region.
    /// 2. Generate the address table with `SymbolTableBuilder.encode`, returning this structure.
    /// 3. Offset the header address with `rel_addr.applyOffset(@offsetOf(core.Header), "symbol_table")`.
    /// 4. Pass the offset relative address to this method.
    /// 5. Finalize the encoder with `Encoder.finalize` in order for fixups added by this function to complete patching of the header.
    pub fn write(self: *const ProtoSymbolTable, encoder: *Encoder) Encoder.Error!void {
        const table = encoder.relativeToPointer(core.SymbolTable, self);

        table.len = self.len;

        try encoder.addFixup(
            .absolute,
            .{ .known = @offsetOf(core.SymbolTable, "keys") },
            .{ .known = self.keys },
            null,
        );

        try encoder.addFixup(
            .absolute,
            .{ .known = @offsetOf(core.SymbolTable, "values") },
            .{ .known = self.values },
            null,
        );

        comptime {
            if (std.meta.fieldNames(core.SymbolTable).len != 3) {
                @compileError("bytecode.ProtoSymbolTable: out of sync with core.SymbolTable, missing fields");
            }
        }
    }
};

/// Simple intermediate representing a `core.AddressTable` whos rows have already been encoded.
/// * This is a temporary intermediate type produced and consumed during the building/encoding process
/// * See `bytecode.AddressTableBuilder` and `bytecode.HeaderBuilder` for usage
pub const ProtoAddressTable = struct {
    addresses: RelativeAddress,
    kinds: RelativeAddress,
    len: u32,

    /// Helper function
    /// Expected usage:
    /// 1. Reserve bytecode header space at the start of encoding region.
    /// 2. Generate the address table with `AddressTableBuilder.encode`, returning this structure.
    /// 3. Offset the header address with `rel_addr.applyOffset(@offsetOf(core.Header), "address_table")`.
    /// 4. Pass the offset relative address to this method.
    /// 5. Finalize the encoder with `Encoder.finalize` in order for fixups added by this function to complete patching of the header.
    pub fn write(self: *const ProtoAddressTable, encoder: *Encoder, table_rel: RelativeAddress) Encoder.Error!void {
        const table = encoder.relativeToPointer(*core.AddressTable, table_rel);

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

        comptime {
            if (std.meta.fieldNames(core.AddressTable).len != 3) {
                @compileError("bytecode.ProtoAddressTable: out of sync with core.AddressTable, missing fields");
            }
        }
    }
};
