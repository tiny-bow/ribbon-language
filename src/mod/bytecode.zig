//! # bytecode
//! This is a namespace for Ribbon bytecode data types, and the builder.
//!
//! The focal points are:
//! * `Instruction` - this is the data type representing un-encoded Ribbon bytecode instructions, as well as the namespace for both un-encoded and encoded opcodes and operand sets
//! * `TableBuilder` - the main API for creating Ribbon `Bytecode` units
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

/// A table of bytecode, containing the header, statics, and linker map.
pub const Table = struct {
    /// The map of unbound locations and their fixups.
    linker_map: LinkerMap,
    /// The bytecode unit.
    bytecode: core.Bytecode,

    /// Deinitialize the table, freeing all memory.
    pub fn deinit(self: *Table) void {
        self.bytecode.deinit(self.linker_map.gpa);
        self.linker_map.deinit();
        self.* = undefined;
    }
};

/// Disassemble a bytecode buffer, printing to the provided writer.
pub fn disas(bc: []const core.InstructionBits, options: struct {
    /// Whether to print the buffer address in the disassembly.
    buffer_address: bool = true,
    /// Whether to indent the disassembly output body.
    indent: ?[]const u8 = "    ",
    /// Instruction separator.
    separator: []const u8 = "\n",
}, writer: anytype) (error{BadEncoding} || @TypeOf(writer).Error)!void {
    var decoder = Decoder.init(bc);

    if (options.buffer_address) {
        try writer.print("[{x:0<16}]:\n", .{@intFromPtr(bc.ptr)});
    }

    const indent = if (options.indent) |s| s else "";

    while (try decoder.next()) |item| {
        try writer.print("{s}{}{s}", .{ indent, item, options.separator });
    }
}

/// Regions are used to scope fixup locations, allowing for multiple functions or blocks to be encoded in the same encoder.
pub const RegionId = Id.of(Location.RegionMark, pl.STATIC_ID_BITS);

/// An identifier that is used to identify a location within a region in the encoded memory.
pub const OffsetId = Id.of(Location.OffsetMark, pl.STATIC_ID_BITS);

/// Represents a location in the encoded memory that is referenced by a fixup, but who's relative offset is not known at the time of encoding that fixup.
pub const Location = packed struct(u64) {
    /// The region id that this location belongs to.
    region: RegionId,
    /// The  offset id within the region that this location is at.
    offset: OffsetId,

    /// Purely symbolic type for id creation (`RegionId`).
    pub const RegionMark = struct {};

    /// Purely symbolic type for id creation (`OffsetId`).
    pub const OffsetMark = struct {};

    /// Create a new `Location` from a region id and an offset id.
    /// * `id` should be of a type constructed by `common.Id`
    /// * Identity types larger than `pl.STATIC_ID_BITS` bits may cause integer overflow
    pub fn fromId(region: RegionId, id: anytype) Location {
        return Location{
            .region = region,
            .offset = id.bitcast(OffsetMark, pl.STATIC_ID_BITS),
        };
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
    relative: RelativeAddress,
    /// A location that is referenced by id, which will be resolved after encoding.
    location: Location,

    pub fn eql(a: FixupRef, b: FixupRef) bool {
        if (@as(std.meta.Tag(FixupRef), a) != @as(std.meta.Tag(FixupRef), b)) return false;

        return switch (a) {
            .relative => a.relative == b.relative,
            .location => b.location == a.location,
        };
    }

    pub fn hash(self: FixupRef, h: anytype) void {
        switch (self) {
            .relative => h.update(std.mem.asBytes(&self.relative)),
            .location => h.update(std.mem.asBytes(&self.location)),
        }
    }
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

/// Contains a fixup for an otherwise-completed artifact that has not been bound to an address yet.
/// The `LinkerMap` is used to store these fixups, and to then resolve them when provided additional artifacts.
pub const LinkerFixup = struct {
    /// Same as `Fixup.kind`.
    kind: FixupKind,
    /// Designates which operand of the fixup is the unknown location.
    basis: Basis,
    /// The other point of binding in the fixup.
    other: RelativeAddress,
    /// Same as `Fixup.bit_offset`.
    bit_offset: ?u6,

    /// In a `LinkerMap`, fixups always reference an unbound `Location`.
    /// This indicates which operand of the fixup is the unbound location.
    pub const Basis = enum {
        /// The fixup is from the location to the reference.
        from,
        /// The fixup is to the location from the reference.
        to,
    };
};

/// This is an extension of `Location`.
/// In a `LinkerMap`, a fixup is a reference to a location that has not been bound internally.
/// Many such locations are static variables, which often have a symbolic fully-qualified name
/// attached for linking and debugging purposes. Such names are included here if present, for ease of access.
pub const LinkerLocation = struct {
    /// fully qualified name of the location, if available.
    name: ?[]const u8 = null,
    /// The unresolved location itself.
    identity: Location,
    /// The set of fixups that reference this location.
    fixups: FixupSet = .empty,

    /// The type of the set used by a `LinkerLocation` insinde a `LinkerMap.FixupMap`.
    pub const FixupSet = pl.HashSet(LinkerFixup, LinkerHashContext, 80);

    /// 64-bit hash context for `LinkerFixup`.
    pub const LinkerHashContext = struct {
        pub fn eql(_: @This(), a: LinkerFixup, b: LinkerFixup) bool {
            return a.kind == b.kind and a.basis == b.basis and a.other == b.other and a.bit_offset == b.bit_offset;
        }

        pub fn hash(_: @This(), fixup: LinkerFixup) u64 {
            var hasher = std.hash.Fnv1a_64.init();

            hasher.update(std.mem.asBytes(&fixup.kind));
            hasher.update(std.mem.asBytes(&fixup.basis));
            hasher.update(std.mem.asBytes(&fixup.other));

            if (fixup.bit_offset) |bit_offset| {
                hasher.update(std.mem.asBytes(&bit_offset));
            } else {
                hasher.update("null");
            }

            return hasher.final();
        }
    };
};

/// A map of linker fixups, used to resolve addresses within an encoded artifact.
pub const LinkerMap = struct {
    /// General purpose allocator used for the linker map.
    gpa: std.mem.Allocator,
    /// Unbound locations and their fixups.
    unbound: FixupMap = .empty,

    /// A map of unbound locations and their fixups within a `LinkerMap`.
    pub const FixupMap = pl.UniqueReprArrayMap(Location, LinkerLocation, false);

    /// Create a new linker map with the provided general purpose allocator.
    pub fn init(gpa: std.mem.Allocator) LinkerMap {
        return LinkerMap{
            .gpa = gpa,
        };
    }

    /// Clear the linker map, retaining the allocator and memory.
    pub fn clear(self: *LinkerMap) void {
        for (self.unbound.values()) |*loc| loc.fixups.deinit(self.gpa);
        self.unbound.clearRetainingCapacity();
    }

    /// Deinitialize the linker map, freeing all memory it owns.
    pub fn deinit(self: *LinkerMap) void {
        for (self.unbound.values()) |*loc| loc.fixups.deinit(self.gpa);
        self.unbound.deinit(self.gpa);
        self.* = undefined;
    }

    /// Create a new linker fixup.
    pub fn bindFixup(self: *LinkerMap, kind: FixupKind, location: Location, basis: LinkerFixup.Basis, other: RelativeAddress, bit_offset: ?u6) error{OutOfMemory}!void {
        const gop = try self.unbound.getOrPut(self.gpa, location);
        if (!gop.found_existing) gop.value_ptr.* = .{ .identity = location };

        try gop.value_ptr.fixups.put(self.gpa, LinkerFixup{
            .kind = kind,
            .basis = basis,
            .other = other,
            .bit_offset = bit_offset,
        }, {});
    }

    /// Bind a name for a given location.
    pub fn bindLocationName(self: *LinkerMap, location: Location, name: []const u8) error{OutOfMemory}!void {
        const gop = try self.unbound.getOrPut(self.gpa, location);
        if (!gop.found_existing) gop.value_ptr.* = .{ .identity = location };

        gop.value_ptr.name = name;
    }

    /// Get a slice of all the locations in this linker map.
    pub fn getUnbound(self: *const LinkerMap) []LinkerLocation {
        return self.unbound.values();
    }
};

/// A location map provides relative address identification, fixup storage, and other state for fixups of encoded data.
pub const LocationMap = struct {
    /// General purpose allocator used for location map collections.
    gpa: std.mem.Allocator,
    /// The map of addresses that are referenced by id in some fixups.
    addresses: pl.UniqueReprMap(Location, ?RelativeAddress, 80) = .empty,
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
        return Location.fromId(self.region, id);
    }

    /// Register a location for a data reference.
    /// * Ref may be null if the location is not yet known.
    /// * Ref may be bound later with `bindLocation`.
    pub fn registerLocation(self: *LocationMap, location: Location, rel: ?RelativeAddress) error{ BadEncoding, OutOfMemory }!void {
        const gop = try self.addresses.getOrPut(self.gpa, location);
        if (gop.found_existing) {
            log.debug("LocationMap.registerLocation: {} already exists in map", .{location});
            return error.BadEncoding;
        }

        gop.value_ptr.* = rel;
    }

    /// Bind the location of a data reference to a specific address.
    /// * This is used to finalize the location of a data reference after it has been registered with `registerLocation`.
    pub fn bindLocation(self: *LocationMap, location: Location, rel: RelativeAddress) error{ BadEncoding, OutOfMemory }!void {
        const entry = self.addresses.getPtr(location) orelse {
            log.debug("LocationMap.bindLocation: {} does not exist in map", .{location});
            return error.BadEncoding;
        };

        if (entry.* != null) {
            log.debug("LocationMap.bindLocation: {} already bound in map", .{location});
            return error.BadEncoding;
        }

        entry.* = rel;
    }

    /// Create a new fixup.
    pub fn bindFixup(self: *LocationMap, kind: FixupKind, from: FixupRef, to: FixupRef, bit_offset: ?u6) error{OutOfMemory}!void {
        try self.fixups.append(self.gpa, Fixup{
            .kind = kind,
            .from = from,
            .to = to,
            .bit_offset = bit_offset,
        });
    }

    /// Enter a new location region.
    /// * Expected usage:
    /// ```zig
    /// const parent_region = x.enterRegion(my_region_id);
    /// defer x.leaveRegion(parent_region);
    /// ```
    /// * `region` must be a <= `pl.STATIC_ID_BITS`-bit `common.Id` type.
    pub fn enterRegion(self: *LocationMap, region: anytype) RegionId {
        const old_region = self.region;
        self.region = region.bitcast(Location.RegionMark, pl.STATIC_ID_BITS);
        return old_region;
    }

    /// Leave the current location region, restoring the previous region. See `enterRegion`.
    pub fn leaveRegion(self: *LocationMap, old_region: RegionId) void {
        self.region = old_region;
    }

    /// Get the current location region id.
    pub fn currentRegion(self: *LocationMap) RegionId {
        return self.region;
    }

    /// Use the fixup tables in the location map to finalize the encoded buffer.
    /// * Adds any unresolved location fixups to the provided `LinkerMap`
    /// * `buf` should be encoded with an `Encoder` attached to this location map
    pub fn finalizeBuffer(self: *LocationMap, linker_map: *LinkerMap, buf: []align(pl.PAGE_SIZE) u8) error{ OutOfMemory, BadEncoding }!void {
        // Resolving things like branch jumps, where a relative offset is encoded into a bit-level offset of an instruction word,
        // and things like constant values that use pointer tagging, requires a fairly robust algorithm.
        // The top level is simply iterating our accumulated the fixups, though.
        for (self.fixups.items) |fixup| {
            // first we resolve our operand references
            // `resolveFixupRef` is just a simple helper, that either unwraps a known address or looks up a location by id
            const maybe_from = try self.resolveFixupRef(fixup.from, buf);
            const maybe_to = try self.resolveFixupRef(fixup.to, buf);

            // `resolveFixupRef` returns null if the reference is not locally resolvable, which is not necessarily an error
            if (maybe_from == null or maybe_to == null) {
                if (maybe_from == null and maybe_to == null) {
                    // if both references are unresolvable, what do?
                    // not entirely sure this is a hard error condition,
                    // but let's error for now as it is a pretty odd scenario
                    log.debug("Fixup from and to references are both unresolvable", .{});
                    return error.BadEncoding;
                } else {
                    // in this condition, we need to create a linker fixup with what we resolved now
                    const basis: LinkerFixup.Basis = if (maybe_from == null) .from else .to;

                    const location = switch (basis) {
                        .from => fixup.from.location,
                        .to => fixup.to.location,
                    };

                    const other: RelativeAddress = switch (basis) {
                        .from => .fromPtr(buf, maybe_to.?),
                        .to => .fromPtr(buf, maybe_from.?),
                    };

                    try linker_map.bindFixup(
                        fixup.kind,
                        location,
                        basis,
                        other,
                        fixup.bit_offset,
                    );
                }

                continue;
            }

            const from = maybe_from.?;
            const to = maybe_to.?;

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
                    // zig fmt: off
                    comptime {
                        if (@bitSizeOf(@FieldType(Instruction.operand_sets.br, "I")) != 16
                        or  @bitSizeOf(@FieldType(Instruction.operand_sets.br_if, "Ix")) != 16
                        or  @bitSizeOf(@FieldType(Instruction.operand_sets.br_if, "Iy")) != 16
                        or  std.meta.fieldNames(Instruction.BranchOpCode).len != 2) {
                            @compileError("LocationMap: out of sync with ISA, expected 2 branch instructions with relative offsets of 16 bits");
                        }
                    }
                    // zig fmt: on

                    const relative_offset_bytes = @as(isize, @bitCast(@intFromPtr(to))) - @as(isize, @bitCast(@intFromPtr(from)));
                    const relative_offset_words: i16 = @intCast(@divExact(relative_offset_bytes, @sizeOf(core.InstructionBits)));

                    break :jump .{ @as(u16, @bitCast(relative_offset_words)), 16, std.math.maxInt(u16) };
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
                    bit_offset,
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
    /// * Returns null if the location is not found.
    pub fn resolveFixupRef(self: *LocationMap, ref: FixupRef, base: []align(pl.PAGE_SIZE) u8) error{ BadEncoding, OutOfMemory }!?*align(1) u64 {
        const rel_addr: RelativeAddress = switch (ref) {
            .relative => |known| known,
            .location => |id| (self.addresses.get(id) orelse return null) orelse return null,
        };

        const ptr = rel_addr.tryToPtrOrSentinel(base) orelse {
            log.debug("Failed to resolve fixup reference {}", .{ref});
            return error.BadEncoding;
        };

        return @ptrCast(ptr);
    }
};

/// Top-level builder for a single, linkable Ribbon bytecode unit.
/// The TableBuilder is the main entry point for the bytecode construction API.
/// It manages the memory encoder, the header, and all functions and statics.
pub const TableBuilder = struct {
    /// Allocator for all intermediate data. This is the child allocator for `TableBuilder.arena`.
    gpa: std.mem.Allocator,
    /// Allocator for non-volatile intermediate data.
    arena: std.heap.ArenaAllocator,
    /// The location map for fixups and relative addresses.
    locations: LocationMap,
    /// The header builder for the bytecode unit.
    header: HeaderBuilder = .{},
    /// Static value builders owned by this table.
    statics: StaticMap = .empty,

    /// A map of static values that are referenced by the header in a `TableBuilder`.
    pub const StaticMap = pl.UniqueReprMap(core.StaticId, Entry, 80);

    /// An entry in the `TableBuilder.statics` map, which can either be a `DataBuilder` or a `FunctionBuilder`.
    pub const Entry = struct {
        /// The location of the function in the
        location: Location,
        /// The kind of symbol this entry represents.
        kind: core.SymbolKind,
        /// Not binding a builder before encoding is an error.
        /// To indicate a linked address or a custom encoding, use `external`.
        builder: ?union(enum) {
            /// Designates an intentional lack of an attached builder.
            external: void,
            /// A builder for a function.
            function: *FunctionBuilder,
            /// A builder for a constant or global data value.
            data: *DataBuilder,

            fn deinit(self: *@This()) void {
                switch (self.*) {
                    .external => {},
                    inline else => |b| b.deinit(),
                }
            }
        },

        fn deinit(self: *Entry) void {
            if (self.builder) |*b| b.deinit();
            self.* = undefined;
        }
    };

    /// Initialize a new table builder.
    pub fn init(allocator: std.mem.Allocator) TableBuilder {
        return TableBuilder{ .gpa = allocator, .arena = .init(allocator), .locations = .init(allocator) };
    }

    /// Clear the table, retaining allocated storage where possible.
    pub fn clear(self: *TableBuilder) void {
        var static_it = self.statics.valueIterator();
        while (static_it.next()) |entry| entry.deinit();
        self.statics.clearRetainingCapacity();

        self.locations.clear();
        self.header.clear();

        self.arena.reset(.retain_capacity);
    }

    /// Deinitialize the table builder, freeing all associated memory, including the header builder.
    pub fn deinit(self: *TableBuilder) void {
        var static_it = self.statics.valueIterator();
        while (static_it.next()) |entry| entry.deinit();

        self.statics.deinit(self.gpa);
        self.locations.deinit();
        self.header.deinit(self.gpa);
        self.arena.deinit();

        self.* = undefined;
    }

    /// Create an entry for a static value in the bytecode header.
    pub fn createHeaderEntry(self: *TableBuilder, comptime kind: core.SymbolKind, name: ?[]const u8) error{ BadEncoding, OutOfMemory }!core.IdFromSymbolKind(kind) {
        // get the next static id
        const static_id = self.header.getNextId();
        const typed_id = static_id.bitcast(kind.toType(), pl.STATIC_ID_BITS);

        // create a location for the static value
        const func_loc = self.locations.localLocationId(static_id);
        const func_ref = FixupRef{ .location = func_loc };

        try self.locations.registerLocation(func_loc, null);

        // bind the location to the address table
        const bind_result = try self.header.bindAddress(self.gpa, kind, .{ .relative = func_ref });

        // sanity check: static_id should be the same as bind_result if getNextId is sound
        std.debug.assert(static_id == bind_result);

        // bind exported names in the symbol table
        if (name) |str| {
            try self.header.exportStatic(self.gpa, str, static_id);
        }

        // create type-specific static builder tracking entry
        const gop = try self.statics.getOrPut(self.gpa, static_id);

        // sanity check: id should be fresh if the address table has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        gop.value_ptr.* = .{
            .location = func_loc,
            .kind = kind,
            .builder = null,
        };

        return typed_id;
    }

    /// Bind a new `FunctionBuilder` to an id.
    /// * A fresh `id` can be created with `createHeaderEntry`.
    /// * Note that the returned pointer is owned by the `TableBuilder` and should not be deinitialized manually.
    /// * Use `getFunctionBuilder` to retrieve the pointer to the function builder by its id (available as a field of the builder).
    pub fn createFunctionBuilder(
        self: *TableBuilder,
        id: core.FunctionId,
    ) error{ BadEncoding, OutOfMemory }!*FunctionBuilder {
        // if we're not tracking this id we can't create a builder for it
        const entry = self.statics.getPtr(id.cast(anyopaque)) orelse {
            log.debug("TableBuilder.createFunctionBuilder: static:{x} does not exist", .{id});
            return error.BadEncoding;
        };

        // type check: the entry must be a function
        if (entry.kind != .function) {
            log.debug("TableBuilder.createFunctionBuilder: expected function id, got {s}:{x}", .{ @tagName(entry.kind), id });
            return error.BadEncoding;
        }

        // we support local mutations up to and including full replacement of the builder,
        // so if there was an existing builder its not an error, just deinit, and reuse the address.
        const addr = if (entry.builder) |*old_builder| existing: {
            old_builder.deinit();

            break :existing old_builder.function;
        } else try self.arena.allocator().create(FunctionBuilder);

        addr.* = FunctionBuilder.init(self.gpa, self.arena.allocator());

        addr.id = id;

        // setup and return the new builder
        entry.builder = .{ .function = addr };

        return addr;
    }

    /// Bind a new `DataBuilder` to an id.
    /// * `id` should be a `core.ConstantId` or `core.GlobalId`.
    /// * A fresh `id` can be created with `createHeaderEntry`.
    /// * Note that the returned pointer is owned by the `TableBuilder` and should not be deinitialized manually.
    /// * Use `getDataBuilder` to retrieve the pointer to the function builder by its id (available as a field of the builder).
    pub fn createDataBuilder(
        self: *TableBuilder,
        id: anytype,
    ) error{ BadEncoding, OutOfMemory }!*DataBuilder {
        const static_id = id.cast(anyopaque);

        // if we're not tracking this id we can't create a builder for it
        const entry = self.statics.getPtr(static_id) orelse {
            log.debug("TableBuilder.createFunctionBuilder: static:{x} does not exist", .{id});
            return error.BadEncoding;
        };

        // type check: the entry must be a data value
        if (entry.kind != .constant and entry.kind != .global) {
            log.debug("TableBuilder.createFunctionBuilder: expected constant or global id, got {s}:{x}", .{ @tagName(entry.kind), id });
            return error.BadEncoding;
        }

        // we support local mutations up to and including full replacement of the builder,
        // so if there was an existing builder its not an error, just deinit, and reuse the address.
        const addr = if (entry.builder) |*old_builder| existing: {
            old_builder.deinit();

            break :existing old_builder.data;
        } else try self.arena.allocator().create(DataBuilder);

        addr.* = DataBuilder.init(self.gpa, self.arena.allocator());

        addr.id = static_id;

        // setup and return the new builder
        entry.builder = .{ .data = addr };

        return addr;
    }

    /// Get a function builder by its id.
    pub fn getFunctionBuilder(self: *const TableBuilder, id: core.FunctionId) ?*FunctionBuilder {
        const entry = self.statics.getPtr(id) orelse return null;
        if (entry.kind != .function) return null;
        return if (entry.builder) |*builder| &builder.function else null;
    }

    /// Get a data builder by its id.
    /// * `id` should be a `core.ConstantId` or `core.GlobalId`
    pub fn getDataBuilder(self: *const TableBuilder, id: anytype) ?*DataBuilder {
        const entry = self.statics.getPtr(id) orelse return null;
        if (entry.kind != .constant and entry.kind != .global) return null;
        return if (entry.builder) |*builder| &builder.data else null;
    }

    /// Get the location of a static by its id.
    pub fn getStaticLocation(self: *const TableBuilder, id: core.StaticId) ?Location {
        const entry = self.statics.get(id) orelse return null;
        return entry.location;
    }

    /// Encode the current state of the Table.
    /// * `allocator` is used for the final `Table`.
    pub fn encode(self: *TableBuilder, allocator: std.mem.Allocator) Encoder.Error!Table {
        // Create the encoder with the provided allocator
        var encoder = try Encoder.init(self.gpa, allocator, &self.locations);
        defer encoder.deinit();

        // Encode the header first
        const header_rel = try self.header.encode(&encoder);

        // Encode the statics the header references, tracking how much data we append
        // to the encoder, so we can finalize the header with the correct size.
        const size_start = encoder.getEncodedSize();

        var static_it = self.statics.valueIterator();
        while (static_it.next()) |entry| {
            if (entry.builder) |builder| {
                switch (builder) {
                    .external => {},
                    .function => |function_builder| try function_builder.encode(&encoder),
                    .data => |data_builder| try data_builder.encode(&encoder),
                }
            }
        }

        const size_end = encoder.getEncodedSize();

        const statics_size = size_end - size_start;

        // Finalize the encoder and get the bytecode
        const buf = try encoder.finalize();
        errdefer allocator.free(buf);

        // Perform local linking of addresses
        var linker_map = LinkerMap.init(allocator);
        errdefer linker_map.deinit();

        // Run location map finalization on the buffer to fixup all addresses
        try self.locations.finalizeBuffer(&linker_map, buf);

        // sanity check: For core.deinit to work, the header must be the base pointer of the buffer
        std.debug.assert(header_rel.isBase());

        const header = header_rel.toTypedPtr(*core.Header, buf);

        header.size += statics_size;

        // Wrap the encoded header in a `core.Bytecode` structure, and that in a `Table` with the linker
        return Table{
            .linker_map = linker_map,
            .bytecode = core.Bytecode{ .header = header },
        };
    }
};

/// Builder for bytecode headers. See `core.Header`.
/// * This is a lower-level utility api used by the `TableBuilder`.
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
    ) error{ BadEncoding, OutOfMemory }!core.StaticId {
        return self.address_table.bind(allocator, kind, address);
    }

    /// Bind a name to an address in the header by id, exporting the static value to the symbol table.
    pub fn exportStatic(
        self: *HeaderBuilder,
        allocator: std.mem.Allocator,
        name: []const u8,
        static_id: core.StaticId,
    ) error{ BadEncoding, OutOfMemory }!void {
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

        const symbol_table = try self.symbol_table.encode(encoder);
        const address_table = try self.address_table.encode(encoder);

        const end_size = encoder.getEncodedSize();

        const header = encoder.relativeToPointer(*core.Header, header_rel);
        header.size = end_size - start_size;

        try symbol_table.write(encoder, header_rel.applyOffset(@intCast(@offsetOf(core.Header, "symbol_table"))));
        try address_table.write(encoder, header_rel.applyOffset(@intCast(@offsetOf(core.Header, "address_table"))));

        return header_rel;
    }
};

/// Builder for bytecode symbol tables. See `core.SymbolTable`.
/// This is used to bind fully qualified names to static ids, which are then used in the `AddressTableBuilder` to bind addresses to those ids.
/// The symbol table is used to resolve names to addresses in the bytecode, which is a core part of capabilities like dynamic linking and debug symbol reference.
/// * This is a lower-level utility api used by the `HeaderBuilder`.
pub const SymbolTableBuilder = struct {
    /// Binds fully-qualified names to AddressTable ids
    map: pl.StringArrayMap(core.StaticId) = .empty,

    /// Deinitializes the symbol table, freeing all memory.
    pub fn deinit(self: *SymbolTableBuilder, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.* = undefined;
    }

    /// Bind a fully qualified name to an address table id of a constant.
    pub fn bind(self: *SymbolTableBuilder, allocator: std.mem.Allocator, name: []const u8, id: core.StaticId) error{ BadEncoding, OutOfMemory }!void {
        if (name.len == 0) {
            log.debug("SymbolTableBuilder.bind: Failed to export {}; Name string cannot be empty", .{id});
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

    /// Simple intermediate representing a `core.SymbolTable` whos rows have already been encoded.
    /// * This is a temporary intermediate type produced and consumed during the building/encoding process
    /// * See `SymbolTableBuilder` and `HeaderBuilder` for usage
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
        pub fn write(self: *const ProtoSymbolTable, encoder: *Encoder, table_rel: RelativeAddress) Encoder.Error!void {
            const table = encoder.relativeToPointer(*core.SymbolTable, table_rel);

            table.len = self.len;

            try encoder.bindFixup(
                .absolute,
                .{ .relative = table_rel.applyOffset(@intCast(@offsetOf(core.SymbolTable, "keys"))) },
                .{ .relative = self.keys },
                null,
            );

            try encoder.bindFixup(
                .absolute,
                .{ .relative = table_rel.applyOffset(@intCast(@offsetOf(core.SymbolTable, "values"))) },
                .{ .relative = self.values },
                null,
            );

            comptime {
                if (std.meta.fieldNames(core.SymbolTable).len != 3) {
                    @compileError("ProtoSymbolTable: out of sync with core.SymbolTable, missing fields");
                }
            }
        }
    };

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
            .len = @intCast(self.map.count()),
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
/// * This is a lower-level utility api used by the `HeaderBuilder`.
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
    pub fn getNextId(self: *AddressTableBuilder) core.StaticId {
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
            log.debug("AddressTable.bind: Cannot bind more than {d} symbols", .{core.StaticId.MAX_INT});
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

    /// Simple intermediate representing a `core.AddressTable` whos rows have already been encoded.
    /// * This is a temporary intermediate type produced and consumed during the building/encoding process
    /// * See `AddressTableBuilder` and `HeaderBuilder` for usage
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

            try encoder.bindFixup(
                .absolute,
                .{ .relative = table_rel.applyOffset(@intCast(@offsetOf(core.AddressTable, "kinds"))) },
                .{ .relative = self.kinds },
                null,
            );

            try encoder.bindFixup(
                .absolute,
                .{ .relative = table_rel.applyOffset(@intCast(@offsetOf(core.AddressTable, "addresses"))) },
                .{ .relative = self.addresses },
                null,
            );

            comptime {
                if (std.meta.fieldNames(core.AddressTable).len != 3) {
                    @compileError("ProtoAddressTable: out of sync with core.AddressTable, missing fields");
                }
            }
        }
    };

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
                    const from_rel = new_addresses_rel.applyOffset(@intCast(i * @sizeOf(*const anyopaque)));

                    try encoder.bindFixup(.absolute, .{ .relative = from_rel }, to_rel, null);
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

                    new_addresses[i] = new_mem.ptr;
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

/// Builder for static data blobs like constants and globals.
pub const DataBuilder = struct {
    /// General-purpose allocator for collections and temporary data.
    gpa: std.mem.Allocator,
    /// Arena allocator for user data.
    arena: std.mem.Allocator,
    /// The writer for the data builder's buffer.
    writer: AllocWriter,
    /// The id of the data builder, used to reference it in the bytecode header.
    /// * This must either be a `core.ConstantId` or a `core.GlobalId`.
    id: core.StaticId = .fromInt(0),
    /// The alignment to give the final data buffer. A value <=1 indicates no preference.
    alignment: pl.Alignment = 0,
    /// A map of data locations to their references.
    /// * This is used to track locations in the data builder's memory that are yet to be determined.
    /// * The map is keyed by `DataLocation`, which is a symbolic type for locations in the data builder's memory.
    /// * The values are `DataRef`, which can either be a reference to the data builder's own memory or a standard `FixupRef`.
    locations: pl.UniqueReprMap(DataLocation, ?DataRef, 80) = .empty,
    /// A list of data fixups that need to be resolved when the data is encoded.
    /// * This is used to track fixups that reference data within the data builder's own memory.
    fixups: pl.ArrayList(DataFixup) = .empty,

    /// Purely symbolic type for id creation (`DataBuilder.DataLocation`).
    pub const DLoc = struct {};

    /// Represents a location in the data builder's memory that is yet to be determined when the location is initially referenced.
    pub const DataLocation = Id.of(DLoc, pl.STATIC_ID_BITS);

    /// Data fixups are distinct from standard fixups in that:
    /// * `from` is always an offset into their own temporary memory, rather than an Encoder's working buffer
    /// * `to` is a `DataRef`, which can either be a reference into the data builder's own memory, or a standard `FixupRef`
    pub const DataFixup = struct {
        /// Same as `Fixup.kind`.
        kind: FixupKind,
        /// The offset into the data builder's memory where the fixup is applied.
        from: u64,
        /// A reference to the data builder's own memory or a standard fixup reference.
        to: DataRef,
        /// The bit offset within the data builder's memory where the fixup is applied.
        bit_offset: ?u6,
    };

    /// A fixup reference for data fixups. Extends `FixupRef` to allow for data-specific references.
    pub const DataRef = union(enum) {
        /// A reference to a data builder's own memory.
        /// * This is used for fixups that reference data within the same data builder
        internal: union(enum) {
            /// A relative address within the data builder's memory.
            relative: RelativeAddress,
            /// A location in the data builder's memory that is yet to be determined.
            location: DataLocation,
        },
        /// A reference to a standard fixup.
        /// * This is used for fixups that reference data outside the data builder
        standard: FixupRef,
    };

    /// Initialize a new data builder for a static data value.
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) DataBuilder {
        return .{
            .gpa = gpa,
            .arena = arena,
            .writer = AllocWriter.init(gpa),
        };
    }

    /// Clear the data builder, retaining the current memory capacity.
    pub fn clear(self: *DataBuilder) void {
        self.writer.clear();
        self.locations.clearRetainingCapacity();
        self.fixups.clearRetainingCapacity();
        self.id = .fromInt(0);
    }

    /// Deinitialize the data builder, freeing all memory it owns.
    pub fn deinit(self: *DataBuilder) void {
        self.writer.deinit();
        self.locations.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.* = undefined;
    }

    /// Register a location for a data reference.
    /// * Ref may be null if the location is not yet known.
    /// * Ref may be bound later with `bindLocation`.
    pub fn registerLocation(self: *DataBuilder, location: DataLocation, ref: ?DataRef) error{ BadEncoding, OutOfMemory }!void {
        const gop = try self.locations.getOrPut(self.gpa, location);

        if (gop.found_existing) {
            log.debug("DataBuilder.registerLocation: Location {} already exists in data builder", .{location});
            return error.BadEncoding;
        }

        gop.value_ptr.* = ref;
    }

    /// Bind the location of a data reference to a specific address.
    /// * This is used to finalize the location of a data reference after it has been registered with `registerLocation`.
    pub fn bindLocation(self: *DataBuilder, location: DataLocation, ref: DataRef) error{ BadEncoding, OutOfMemory }!void {
        const entry = self.locations.getPtr(location) orelse {
            log.debug("DataBuilder.bindLocation: Location {} does not exist in data builder", .{location});
            return error.BadEncoding;
        };

        if (entry.* != null) {
            log.debug("DataBuilder.bindLocation: Location {} already bound in data builder", .{location});
            return error.BadEncoding;
        }

        entry.* = ref;
    }

    /// Create a new fixup entry for the data. `from` must be a currently-valid relative address into the data buffer or to its end.
    pub fn bindFixup(self: *DataBuilder, kind: FixupKind, from: RelativeAddress, to: DataRef, bit_offset: ?u6) error{ BadEncoding, OutOfMemory }!void {
        if (from.toInt() > self.writer.getWrittenSize()) {
            log.debug("DataBuilder.bindFixup: Invalid 'from' offset {} for data builder", .{from});
            return error.BadEncoding;
        }

        try self.fixups.append(self.gpa, .{
            .kind = kind,
            .from = from.toInt(),
            .to = to,
            .bit_offset = bit_offset,
        });
    }

    /// Encode the data and fixups into the provided encoder.
    pub fn encode(self: *const DataBuilder, encoder: *Encoder) Encoder.Error!void {
        // get the final data buffer
        const data_buf = self.writer.getWrittenRegion();

        // get the address of our header entry in the final buffer
        const entry_addr: *core.Constant = try encoder.clone(
            // we can use a `core.Constant` layout for the header entry,
            // since globals and constants share the same layout and simply provide different access semantics
            core.Constant.fromLayout(.{
                .size = data_buf.len,
                .alignment = @max(self.alignment, 1),
            }),
        );

        // bind the location for our ID
        const entry_rel_addr = encoder.addressToRelative(entry_addr);
        const location = encoder.localLocationId(self.id);
        try encoder.bindLocation(location, entry_rel_addr);

        // ensure our data is aligned to its specified alignment
        try encoder.alignTo(@max(self.alignment, 1));
        // get the relative address of the data buffer
        const data_rel_addr = encoder.getRelativeAddress();

        // sanity check: core.Constant and this algorithm should agree on the start offset
        std.debug.assert(encoder.relativeToAddress(data_rel_addr) == encoder.relativeToPointer(*const core.Constant, entry_rel_addr).asPtr());

        // write our data buffer to the main encoder
        try encoder.writeAll(data_buf);

        // finally, process our local fixups and register them
        for (self.fixups.items) |local_fixup| {
            // calculate the 'from' address of the fixup in the global context
            const from_rel_addr = data_rel_addr.applyOffset(@intCast(local_fixup.from));

            try encoder.bindFixup(
                local_fixup.kind,
                .{ .relative = from_rel_addr },
                self.resolveRef(data_rel_addr, local_fixup.to, encoder),
                local_fixup.bit_offset,
            );
        }
    }

    /// Resolves a `DataRef` into a final `FixupRef` for the main encoder.
    /// This function is the bridge between the `DataBuilder`'s isolated memory space
    /// and the global encoding context.
    ///
    /// - `data_rel_addr` is the base relative address where this `DataBuilder`'s
    ///   content has been written into the main encoder.
    /// - `ref` is the internal data reference to resolve.
    /// - `encoder` is the main bytecode encoder.
    ///
    /// This function handles three cases for a `DataRef`:
    /// 1. `.standard`: A reference that is already global. It is passed through unchanged.
    /// 2. `.internal.relative`: A reference to a known offset within this `DataBuilder`.
    ///    It is resolved to a global `FixupRef.relative` by adding `data_rel_addr`.
    /// 3. `.internal.location`: A symbolic reference within this `DataBuilder`.
    ///    - If the location has already been bound internally, it is resolved recursively.
    ///    - **If the location is unbound, it is "promoted" to a global `Location`**.
    ///      This is a key mechanism that allows data blobs to contain forward-references
    ///      to other functions or data that have not yet been encoded. The `DataLocation`
    ///      is combined with the encoder's current region ID to form a unique global
    ///      `Location` that the linker can resolve later.
    pub fn resolveRef(
        self: *const DataBuilder,
        data_rel_addr: AllocWriter.RelativeAddress,
        ref: DataRef,
        encoder: *Encoder,
    ) FixupRef {
        return switch (ref) {
            .internal => |internal_ref| switch (internal_ref) {
                .relative => |rel| FixupRef{ .relative = data_rel_addr.applyOffset(@intCast(rel.toInt())) },
                .location => |loc| {
                    if (self.locations.get(loc)) |entry| {
                        if (entry) |binding| {
                            return self.resolveRef(data_rel_addr, binding, encoder);
                        }
                    }

                    // promote unbound data locations to global locations
                    return FixupRef{ .location = encoder.localLocationId(loc) };
                },
            },
            .standard => |standard_ref| standard_ref,
        };
    }

    // writer api wrapper //

    pub const Error = bytecode.Error;

    /// Get the current length of the written region of the data builder.
    pub fn getWrittenSize(self: *const DataBuilder) u64 {
        return self.writer.getWrittenSize();
    }

    /// Returns the size of the region of allocated of memory that is unused.
    pub fn getAvailableCapacity(self: *const DataBuilder) u64 {
        return self.writer.getAvailableCapacity();
    }

    /// Get the current written region of the data builder.
    pub fn getWrittenRegion(self: *const DataBuilder) []align(pl.PAGE_SIZE) u8 {
        return self.writer.getWrittenRegion();
    }

    /// Returns the region of memory that is allocated but has not been written to.
    pub fn getAvailableRegion(self: *const DataBuilder) []u8 {
        return self.writer.getAvailableRegion();
    }

    /// Returns the current address of the data builder's cursor.
    /// * This address is not guaranteed to be stable throughout the write; use `getRelativeAddress` for stable references.
    pub fn getCurrentAddress(self: *DataBuilder) [*]u8 {
        return self.writer.getCurrentAddress();
    }

    /// Returns the current cursor position. See also `getCurrentAddress`.
    /// * This can be used to get an address into the final buffer after write completion.
    pub fn getRelativeAddress(self: *const DataBuilder) RelativeAddress {
        return self.writer.getRelativeAddress();
    }

    /// Convert an unstable address in the data builder, such as those acquired through `alloc`, into a stable relative address.
    pub fn addressToRelative(self: *const DataBuilder, address: anytype) AllocWriter.RelativeAddress {
        return self.writer.addressToRelative(address);
    }

    /// Convert a stable relative address in the data builder into an unstable absolute address.
    pub fn relativeToAddress(self: *const DataBuilder, relative: RelativeAddress) [*]u8 {
        return self.writer.relativeToAddress(relative);
    }

    /// Convert a stable relative address in the data builder into an unstable, typed pointer.
    pub fn relativeToPointer(self: *const DataBuilder, comptime T: type, relative: RelativeAddress) T {
        return self.writer.relativeToPointer(T, relative);
    }

    /// Reallocate the data builder's memory as necessary to support the given capacity.
    pub fn ensureCapacity(self: *DataBuilder, cap: u64) AllocWriter.Error!void {
        return self.writer.ensureCapacity(cap);
    }

    /// Reallocate the data builder's memory as necessary to support the given additional capacity.
    pub fn ensureAdditionalCapacity(self: *DataBuilder, additional: u64) AllocWriter.Error!void {
        return self.writer.ensureAdditionalCapacity(additional);
    }

    /// Allocates an aligned byte buffer from the address space of the data builder.
    pub fn alignedAlloc(self: *DataBuilder, alignment: pl.Alignment, len: usize) AllocWriter.Error![]u8 {
        return self.writer.alignedAlloc(alignment, len);
    }

    /// Same as `std.mem.Allocator.alloc`, but allocates from the address space of the data builder.
    pub fn alloc(self: *DataBuilder, comptime T: type, len: usize) AllocWriter.Error![]T {
        return self.writer.alloc(T, len);
    }

    /// Same as `alloc`, but returns a RelativeAddress instead of a pointer.
    pub fn allocRel(self: *DataBuilder, comptime T: type, len: usize) AllocWriter.Error!AllocWriter.RelativeAddress {
        return self.writer.allocRel(T, len);
    }

    /// Same as `std.mem.Allocator.dupe`, but copies a slice into the address space of the data builder.
    pub fn dupe(self: *DataBuilder, comptime T: type, slice: []const T) AllocWriter.Error![]T {
        return self.writer.dupe(T, slice);
    }

    /// Same as `dupe`, but returns a RelativeAddress instead of a pointer.
    pub fn dupeRel(self: *DataBuilder, comptime T: type, slice: []const T) AllocWriter.Error!AllocWriter.RelativeAddress {
        return self.writer.dupeRel(T, slice);
    }

    /// Same as `std.mem.Allocator.create`, but allocates from the address space of the data builder.
    pub fn create(self: *DataBuilder, comptime T: type) AllocWriter.Error!*T {
        return self.writer.create(T);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn createRel(self: *DataBuilder, comptime T: type) AllocWriter.Error!AllocWriter.RelativeAddress {
        return self.writer.createRel(T);
    }

    /// Same as `create`, but takes an initializer.
    pub fn clone(self: *DataBuilder, value: anytype) AllocWriter.Error!*@TypeOf(value) {
        return self.writer.clone(value);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn cloneRel(self: *DataBuilder, value: anytype) AllocWriter.Error!AllocWriter.RelativeAddress {
        return self.writer.cloneRel(value);
    }

    /// Writes as much of a slice of bytes to the data builder as will fit without an allocation.
    /// Returns the number of bytes written.
    pub fn write(self: *DataBuilder, noalias bytes: []const u8) AllocWriter.Error!usize {
        return self.writer.write(bytes);
    }

    /// Writes all bytes from a slice to the data builder.
    pub fn writeAll(self: *DataBuilder, bytes: []const u8) AllocWriter.Error!void {
        return self.writer.writeAll(bytes);
    }

    /// Writes a single byte to the data builder.
    pub fn writeByte(self: *DataBuilder, byte: u8) AllocWriter.Error!void {
        return self.writer.writeByte(byte);
    }

    /// Writes a byte to the data builder `n` times.
    pub fn writeByteNTimes(self: *DataBuilder, byte: u8, n: usize) AllocWriter.Error!void {
        return self.writer.writeByteNTimes(byte, n);
    }

    /// Writes a slice of bytes to the data builder `n` times.
    pub fn writeBytesNTimes(self: *DataBuilder, bytes: []const u8, n: usize) AllocWriter.Error!void {
        return self.writer.writeBytesNTimes(bytes, n);
    }

    /// Writes an integer to the data builder.
    /// * This function is provided for backward compatibility with Zig's writer interface. Prefer `writeValue` instead.
    pub fn writeInt(
        self: *DataBuilder,
        comptime T: type,
        value: T,
        comptime _: enum { little }, // allows backward compat with writer api; but only in provably compatible use-cases
    ) AllocWriter.Error!void {
        return self.writer.writeInt(T, value, .little);
    }

    /// Generalized version of `writeInt`;
    /// Works for any value with a unique representation.
    /// * Does not consider or provide value alignment
    /// * See `std.meta.hasUniqueRepresentation`
    pub fn writeValue(
        self: *DataBuilder,
        value: anytype,
    ) AllocWriter.Error!void {
        const T = @TypeOf(value);

        if (comptime !std.meta.hasUniqueRepresentation(T)) {
            @compileError("DataBuilder.writeValue: Type `" ++ @typeName(T) ++ "` does not have a unique representation");
        }

        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
    }

    /// Pushes zero bytes (if necessary) to align the current offset of the builder to the provided alignment value.
    pub fn alignTo(self: *DataBuilder, alignment: pl.Alignment) AllocWriter.Error!void {
        const delta = pl.alignDelta(self.writer.cursor, alignment);
        try self.writer.writeByteNTimes(0, delta);
    }

    /// Asserts that the current offset of the builder is aligned to the given value.
    pub fn ensureAligned(self: *DataBuilder, alignment: pl.Alignment) DataBuilder.Error!void {
        if (pl.alignDelta(self.writer.cursor, alignment) != 0) {
            return error.UnalignedWrite;
        }
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
    blocks: pl.UniqueReprMap(BlockId, *BlockBuilder, 80) = .empty,

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
        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

        self.blocks.deinit(self.gpa);

        self.* = undefined;
    }

    /// Create a new basic block within this function, returning a pointer to it.
    /// * Note that the returned pointer is owned by the function builder and should not be deinitialized manually.
    /// * Use `getBlock` to retrieve the pointer to the block builder by its id (available as a field of the builder).
    pub fn createBlock(self: *FunctionBuilder) error{OutOfMemory}!*BlockBuilder {
        const index = self.blocks.count();

        if (index > core.StaticId.MAX_INT) {
            log.debug("FunctionBuilder.createBlock: Cannot create more than {d} blocks", .{core.StaticId.MAX_INT});
            return error.OutOfMemory;
        }

        const block_id = BlockId.fromInt(index);
        const addr = try self.arena.create(BlockBuilder);

        const gop = try self.blocks.getOrPut(self.gpa, block_id);

        // sanity check: block_id should be fresh if the map has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        addr.* = BlockBuilder.init(self.gpa, self.arena);
        addr.id = block_id;
        addr.function = self.id;

        gop.value_ptr.* = addr;

        return addr;
    }

    /// Get a pointer to a block builder by its block id.
    pub fn getBlock(self: *const FunctionBuilder, id: BlockId) ?*BlockBuilder {
        return self.blocks.get(id);
    }

    /// Encode the function and all blocks into the provided encoder, inserting a fixup location for the function itself into the current region.
    pub fn encode(self: *FunctionBuilder, encoder: *Encoder) Encoder.Error!void {
        // set up the visitor and queue for block encoding
        var visitor: BlockVisitor = .init(encoder.temp_allocator);
        defer visitor.deinit();

        var queue: BlockVisitorQueue = .init(encoder.temp_allocator);
        defer queue.deinit();

        // create our header entry
        const entry_addr_rel = try encoder.createRel(core.Function);

        // bind its location to the function id
        const location = encoder.localLocationId(self.id);
        try encoder.bindLocation(location, entry_addr_rel);

        const region_token = encoder.enterRegion(RegionId.fromInt(self.id.toInt() + 1));
        defer encoder.leaveRegion(region_token);

        // write the function body

        // ensure the function's instructions are aligned
        try encoder.alignTo(@alignOf(core.InstructionBits));

        const base_rel = encoder.getRelativeAddress();

        try queue.add(BlockBuilder.entry_point_id);

        while (queue.visit()) |block_id| {
            if (try visitor.visit(block_id)) continue;

            const block = self.blocks.get(block_id).?;

            try block.encode(&queue, encoder);
        }

        const upper_rel = encoder.getRelativeAddress();

        // write the function header
        const header = encoder.relativeToPointer(*core.Function, entry_addr_rel);

        header.kind = .bytecode;
        header.stack_size = @intCast(pl.alignTo(self.stack_size, self.stack_align));

        // Add a fixup for the function's header reference
        try encoder.bindFixup(
            .absolute,
            .{ .relative = entry_addr_rel.applyOffset(@intCast(@offsetOf(core.Function, "header"))) },
            .{ .relative = .base },
            null,
        );

        // Add fixups for the function's extents references
        const extents_rel = entry_addr_rel.applyOffset(@intCast(@offsetOf(core.Function, "extents")));
        try encoder.bindFixup(
            .absolute,
            .{ .relative = extents_rel.applyOffset(@intCast(@offsetOf(core.Extents, "base"))) },
            .{ .relative = base_rel },
            null,
        );
        try encoder.bindFixup(
            .absolute,
            .{ .relative = extents_rel.applyOffset(@intCast(@offsetOf(core.Extents, "upper"))) },
            .{ .relative = upper_rel },
            null,
        );
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
    pub fn init(gpa: std.mem.Allocator) SequenceBuilder {
        return .{ .gpa = gpa };
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
        if (pi.instruction.code.isTerm() or pi.instruction.code.isBranch()) {
            log.err("SequenceBuilder cannot contain terminator or branch instructions", .{});
            return error.BadEncoding;
        }

        if (pi.instruction.code.isCall()) {
            if (pi.additional != .call_args or pi.additional.call_args.len != pi.instruction.getExpectedCallArgumentCount().?) {
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
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .none,
        });
    }

    /// Append a two-word instruction to the sequence.
    pub fn instrWide(self: *SequenceBuilder, comptime code: Instruction.WideOpCode, data: Instruction.SetType(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .{ .wide_imm = wide_operand },
        });
    }

    /// Append a call instruction to the sequence.
    pub fn instrCall(self: *SequenceBuilder, comptime code: Instruction.CallOpCode, data: Instruction.SetType(code.upcast()), args: Buffer.fixed(core.Register, pl.MAX_REGISTERS)) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
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
            .additional = .{ .branch_target = .{ target, null } },
        };
    }

    /// Set the block terminator to a conditional branch instruction.
    pub fn instrBrIf(self: *BlockBuilder, condition: core.Register, then_id: BlockId, else_id: BlockId) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = .br_if,
                .data = .{ .br_if = .{ .R = condition } },
            },
            .additional = .{ .branch_target = .{ then_id, else_id } },
        };
    }

    /// Set the block terminator.
    pub fn instrTerm(self: *BlockBuilder, comptime code: Instruction.TermOpCode, data: Instruction.SetType(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .none,
        };
    }

    /// Encode the block into the provided encoder, including the body instructions and the terminator.
    /// * The block's entry point is encoded as a location in the bytecode header, using the current region id and the block's id as the offset
    /// * Other blocks' ids that are referenced by instructions are added to the provided queue in order of use
    pub fn encode(self: *BlockBuilder, queue: *BlockVisitorQueue, encoder: *Encoder) Encoder.Error!void {
        // we can encode the current location as the block entry point
        try encoder.registerLocation(encoder.localLocationId(self.id), encoder.getRelativeAddress());

        // first we emit all the body instructions by encoding the inner sequence
        try self.body.encode(queue, encoder);

        // now the terminator instruction, if any; same as body instructions, but can queue block ids
        if (self.terminator) |*proto| {
            try proto.encode(queue, encoder);
        } else {
            // simply write the scaled opcode for `unreachable`, since it has no operands
            try encoder.writeValue(Instruction.OpCode.@"unreachable".toBits());
        }
    }

    fn ensureUnterminated(self: *BlockBuilder) Encoder.Error!void {
        if (self.terminator) |_| {
            log.debug("BlockBuilder.ensureUnterminated: Block {x} is already terminated; cannot append additional instructions", .{self.id.toInt()});
            return error.BadEncoding;
        }
    }

    comptime {
        const br_instr_names = std.meta.fieldNames(Instruction.BranchOpCode);

        if (br_instr_names.len != 2) {
            @compileError("BlockBuilder: out of sync with ISA, unhandled branch opcodes");
        }

        if (pl.indexOfBuf(u8, br_instr_names, "br") == null or pl.indexOfBuf(u8, br_instr_names, "br_if") == null) {
            @compileError("BlockBuilder: out of sync with ISA, branch opcode names changed");
        }
    }
};

/// Simple intermediate representing complete, possibly multiword instructions.
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
        /// The destination(s) of branch instructions.
        branch_target: struct { BlockId, ?BlockId },
    };

    /// Encode this instruction into the provided encoder at the current relative address.
    /// * This method is used by the `BlockBuilder` to encode instructions into the
    /// * It is not intended to be used directly; instead, use the `BlockBuilder` methods to append instructions.
    /// * Also available are convenience methods in `Encoder` for appending instructions directly.
    /// * The `queue` is used to track branch targets and ensure they are visited in the correct order.
    pub fn encode(self: *const ProtoInstr, queue: *BlockVisitorQueue, encoder: *Encoder) Encoder.Error!void {
        try encoder.ensureAligned(pl.BYTECODE_ALIGNMENT);

        const rel_addr = encoder.getRelativeAddress();
        try encoder.writeValue(self.instruction.toBits());

        switch (self.additional) {
            .none => {},
            .wide_imm => |bits| try encoder.writeValue(bits),
            .call_args => |args| try encoder.writeAll(std.mem.sliceAsBytes(args.asSlice())),
            .branch_target => |ids| {
                const then_id, const maybe_else_id = ids;
                const then_dest = encoder.localLocationId(then_id);

                switch (self.instruction.code) {
                    .br => {
                        if (maybe_else_id) |_| {
                            log.err("BlockBuilder.encode: Branch instruction `br` cannot have an else target", .{});
                            return error.BadEncoding;
                        }

                        const then_bit_offset = @bitOffsetOf(Instruction.operand_sets.br, "I") + @bitSizeOf(Instruction.OpCode);

                        try encoder.bindFixup(
                            .relative,
                            .{ .relative = rel_addr },
                            .{ .location = then_dest },
                            then_bit_offset,
                        );

                        try queue.add(then_id);
                    },
                    .br_if => {
                        if (maybe_else_id) |else_id| {
                            const else_dest = encoder.localLocationId(else_id);

                            const then_bit_offset = @bitOffsetOf(Instruction.operand_sets.br_if, "Ix") + @bitSizeOf(Instruction.OpCode);
                            const else_bit_offset = @bitOffsetOf(Instruction.operand_sets.br_if, "Iy") + @bitSizeOf(Instruction.OpCode);

                            try encoder.bindFixup(
                                .relative,
                                .{ .relative = rel_addr },
                                .{ .location = then_dest },
                                then_bit_offset,
                            );

                            try encoder.bindFixup(
                                .relative,
                                .{ .relative = rel_addr },
                                .{ .location = else_dest },
                                else_bit_offset,
                            );

                            try queue.add(then_id);
                            try queue.add(else_id);
                        } else {
                            log.err("BlockBuilder.encode: Branch instruction `br_if` must have an else target", .{});
                            return error.BadEncoding;
                        }
                    },
                    else => |code| {
                        log.err("BlockBuilder.encode: `{s}` is not an expected branch instruction ", .{@tagName(code)});
                        return error.BadEncoding;
                    },
                }
            },
        }

        try encoder.alignTo(pl.BYTECODE_ALIGNMENT);
    }
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
                            core.Register => try writer.print(" {}", .{operand}),

                            core.UpvalueId,
                            core.GlobalId,
                            core.FunctionId,
                            core.BuiltinAddressId,
                            core.ForeignAddressId,
                            core.EffectId,
                            core.HandlerSetId,
                            core.ConstantId,
                            => |Static| {
                                try writer.writeAll(" " ++ operand_name ++ ":");

                                if (operand == .null) {
                                    try writer.writeAll("null");
                                } else {
                                    try std.fmt.formatInt(operand.toInt(), 16, .lower, .{
                                        .width = @sizeOf(Static) * 2,
                                        .fill = '0',
                                        .alignment = .right,
                                    }, writer);
                                }
                            },

                            u8 => try writer.print(" " ++ operand_name ++ ":{x:0>2}", .{operand}),
                            u16 => try writer.print(" " ++ operand_name ++ ":{x:0>4}", .{operand}),
                            u32 => try writer.print(" " ++ operand_name ++ ":{x:0>8}", .{operand}),
                            u64 => try writer.print(" " ++ operand_name ++ ":{x:0>16}", .{operand}),

                            else => @compileError("Decoder: out of sync with ISA, encountered unexpected operand type " ++ @typeName(Operand)),
                        }
                    }

                    try self.trailing.show(code, writer);

                    return;
                }
            }

            unreachable;
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

        fn show(self: Trailing, code: Instruction.OpCode, writer: anytype) !void {
            switch (self) {
                .none => {},
                .call_args => |args| {
                    try writer.writeAll(" .. (");

                    for (args, 0..) |arg, i| {
                        try writer.print("{}", .{arg});

                        if (i < args.len - 1) {
                            try writer.writeAll(" ");
                        }
                    }

                    try writer.writeAll(")");
                },
                .wide_imm => |imm| try imm.show(code, writer),
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

        fn show(self: Imm, code: Instruction.OpCode, writer: anytype) !void {
            const name = code.wideOperandName() orelse "UnexpectedImm";
            switch (self) {
                .byte => |operand| try writer.print(" .. {s}:{x:0>2}", .{ name, operand }),
                .short => |operand| try writer.print(" .. {s}:{x:0>4}", .{ name, operand }),
                .int => |operand| try writer.print(" .. {s}:{x:0>8}", .{ name, operand }),
                .word => |operand| try writer.print(" .. {s}:{x:0>16}", .{ name, operand }),
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
                    item.trailing = .{ .wide_imm = switch (item.instruction.code.wideOperandType().?) {
                        .byte => .{ .byte = @truncate(self.instructions[self.ip]) },
                        .short => .{ .short = @truncate(self.instructions[self.ip]) },
                        .int => .{ .int = @truncate(self.instructions[self.ip]) },
                        .word => .{ .word = self.instructions[self.ip] },
                    } };
                    self.ip += 1;
                } else {
                    log.debug("Decoder.next: Incomplete wide instruction at end of stream.", .{});
                    return error.BadEncoding;
                }
            } else if (item.instruction.getExpectedCallArgumentCount()) |n| {
                // this case needs to create a view of a variable number of *bytes* in the word stream
                const base: [*]const core.Register = @ptrCast(self.instructions.ptr + self.ip);

                // we need to get the byte count, then round up to the nearest word size
                const arg_byte_count = n * @sizeOf(core.Register);
                const arg_word_count = (arg_byte_count + @sizeOf(core.InstructionBits) - 1) / @sizeOf(core.InstructionBits);

                // check the new instruction pointer before incrementing
                const new_ip = self.ip + arg_word_count;
                if (new_ip > self.instructions.len) {
                    log.debug("Decoder.next: Incomplete call instruction at end of stream.", .{});
                    return error.BadEncoding;
                }

                // setup trailing operands
                item.trailing = .{ .call_args = base[0..n] };
                self.ip = new_ip;
            }

            return item;
        }

        return null;
    }
};

/// Wrapper over `AllocWriter` that provides a bytecode instruction specific API.
pub const Encoder = struct {
    /// General purpose allocator for intermediate user operations.
    temp_allocator: std.mem.Allocator,
    /// The encoder's `AllocWriter`
    writer: AllocWriter,
    /// Location map providing relative address identification, fixup storage, and other state for fixups.
    locations: *LocationMap,

    pub const Error = bytecode.Error;

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
    /// * Note this does not clear the `locations` map as the encoder does not own it
    pub fn clear(self: *Encoder) void {
        self.writer.clear();
    }

    /// Deinitialize the Encoder, freeing any memory it owns.
    pub fn deinit(self: *Encoder) void {
        self.writer.deinit();
        self.* = undefined;
    }

    /// Enter a new location region.
    /// * Expected usage:
    /// ```zig
    /// const parent_region = x.enterRegion(my_region_id);
    /// defer x.leaveRegion(parent_region);
    /// ```
    /// * `region` must be a <= `pl.STATIC_ID_BITS`-bit `common.Id` type.
    pub fn enterRegion(self: *Encoder, region: anytype) RegionId {
        return self.locations.enterRegion(region);
    }

    /// Leave the current location region, restoring the previous region. See `enterRegion`.
    pub fn leaveRegion(self: *Encoder, old_region: RegionId) void {
        return self.locations.leaveRegion(old_region);
    }

    /// Get the current location region id.
    pub fn currentRegion(self: *Encoder) RegionId {
        return self.locations.currentRegion();
    }

    /// Finalize the Encoder's writer, returning the memory.
    ///
    /// After calling this function, the encoder will be in its default-initialized state.
    /// In other words, it is safe but not necessary to call `deinit` on it.
    /// It does not need to be re-initializd before reuse, as the allocator is retained.
    pub fn finalize(self: *Encoder) Encoder.Error![]align(pl.PAGE_SIZE) u8 {
        const buf = try self.writer.finalize();

        self.clear();

        return buf;
    }

    /// Create a new fixup.
    pub fn bindFixup(self: *Encoder, kind: FixupKind, from: FixupRef, to: FixupRef, bit_offset: ?u6) error{OutOfMemory}!void {
        try self.locations.bindFixup(kind, from, to, bit_offset);
    }

    /// Register a new location for fixups to reference.
    /// * relative address may be null if the location is not yet known
    /// * relative address may be bound later with `bindLocation`
    pub fn registerLocation(self: *Encoder, id: Location, rel_addr: ?RelativeAddress) error{ BadEncoding, OutOfMemory }!void {
        try self.locations.registerLocation(id, rel_addr);
    }

    /// Store the address of a location for fixups to reference.
    /// * this is used to finalize the location of a reference after it has been registered with `registerLocation`
    pub fn bindLocation(self: *Encoder, id: Location, rel_addr: RelativeAddress) error{ BadEncoding, OutOfMemory }!void {
        try self.locations.bindLocation(id, rel_addr);
    }

    // writer api wrapper //

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
    pub fn getAvailableCapacity(self: *Encoder) u64 {
        return self.writer.getAvailableCapacity();
    }

    /// Ensure the total available capacity in the encoder memory.
    pub fn ensureCapacity(self: *Encoder, cap: u64) AllocWriter.Error!void {
        return self.writer.ensureCapacity(cap);
    }

    /// Ensure additional available capacity in the encoder memory.
    pub fn ensureAdditionalCapacity(self: *Encoder, additional: u64) AllocWriter.Error!void {
        return self.writer.ensureAdditionalCapacity(additional);
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

    /// Generalized version of `writeInt`;
    /// Works for any value with a unique representation.
    /// * Does not consider or provide value alignment
    /// * See `std.meta.hasUniqueRepresentation`
    pub fn writeValue(
        self: *Encoder,
        value: anytype,
    ) AllocWriter.Error!void {
        const T = @TypeOf(value);

        if (comptime !std.meta.hasUniqueRepresentation(T)) {
            @compileError("Encoder.writeValue: Type `" ++ @typeName(T) ++ "` does not have a unique representation");
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

const testing = std.testing;

/// A helper struct to reduce boilerplate in tests.
fn TestBed(comptime test_name: []const u8) type {
    return struct {
        gpa: std.mem.Allocator,
        builder: TableBuilder,

        fn init() !TestBed(test_name) {
            var self: TestBed(test_name) = undefined;
            self.gpa = std.testing.allocator;
            self.builder = TableBuilder.init(self.gpa);
            testing.log_level = .debug;
            return self;
        }

        fn deinit(self: *TestBed(test_name)) void {
            self.builder.deinit();
        }
    };
}

test "linker map locations and fixups" {
    var tb = try TestBed("linker map locations and fixups").init();
    defer tb.deinit();

    var linker_map = LinkerMap.init(tb.gpa);
    defer linker_map.deinit();

    const region1 = RegionId.fromInt(1);
    const offset1 = OffsetId.fromInt(10);
    const loc1 = Location{ .region = region1, .offset = offset1 };

    const region2 = RegionId.fromInt(2);
    const offset2 = OffsetId.fromInt(20);
    const loc2 = Location{ .region = region2, .offset = offset2 };

    const other_ref = RelativeAddress.fromInt(1234);

    try linker_map.bindFixup(.absolute, loc1, .from, other_ref, null);
    try linker_map.bindLocationName(loc1, "my.cool.symbol");

    try linker_map.bindFixup(.relative, loc2, .to, other_ref, 32);

    const unbound = linker_map.getUnbound();
    try testing.expectEqual(@as(usize, 2), unbound.len);

    const l_loc1 = linker_map.unbound.get(loc1).?;
    try testing.expectEqualStrings("my.cool.symbol", l_loc1.name.?);
    try testing.expectEqual(@as(usize, 1), l_loc1.fixups.count());

    var it1 = l_loc1.fixups.iterator();
    const fixup1 = it1.next().?.key_ptr;
    try testing.expect(fixup1.kind == .absolute);
    try testing.expect(fixup1.basis == .from);
    try testing.expect(fixup1.other == other_ref);

    const l_loc2 = linker_map.unbound.get(loc2).?;
    try testing.expect(l_loc2.name == null);
    try testing.expectEqual(@as(usize, 1), l_loc2.fixups.count());

    var it2 = l_loc2.fixups.iterator();
    const fixup2 = it2.next().?.key_ptr;
    try testing.expect(fixup2.kind == .relative);
    try testing.expect(fixup2.basis == .to);

    linker_map.clear();
    try testing.expectEqual(@as(usize, 0), linker_map.getUnbound().len);
}

test "encode simple function with wide instruction" {
    var tb = try TestBed("encode simple function with wide instruction").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 0x1234);
    try entry_block.instr(.i_add64, .{ .Rx = .r0, .Ry = .r1, .Rz = .r1 });
    try entry_block.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();

    const main_func = table.bytecode.header.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    const expected =
        \\    bit_copy64c r1 .. I:0000000000001234
        \\    i_add64 r0 r1 r1
        \\    return r0
        \\
    ;
    try testing.expectEqualStrings(expected, disas_buf.items);
}

test "encode function with branch and dead code" {
    var tb = try TestBed("encode function with branch and dead code").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    var exit_block = try main_fn.createBlock();
    var dead_block = try main_fn.createBlock(); // Should not be encoded

    try entry_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 1);
    try entry_block.instrBr(exit_block.id);

    try dead_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 999);
    try dead_block.instrTerm(.halt, .{});

    try exit_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 2);
    try exit_block.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();

    const main_func = table.bytecode.header.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    const expected =
        \\    bit_copy64c r0 .. I:0000000000000001
        \\    br I:0001
        \\    bit_copy64c r0 .. I:0000000000000002
        \\    return r0
        \\
    ;
    try testing.expectEqualStrings(expected, disas_buf.items);
}

test "encode function call" {
    var tb = try TestBed("encode function call").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const add_id = try tb.builder.createHeaderEntry(.function, "add");

    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var add_fn = try tb.builder.createFunctionBuilder(add_id);

    // main function
    var main_entry = try main_fn.createBlock();
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 10);
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r2 }, 20);
    try main_entry.instrCall(.call_c, .{ .R = .r0, .F = add_id, .I = 2 }, .fromSlice(&.{ .r1, .r2 }));
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // add function
    var add_entry = try add_fn.createBlock();
    try add_entry.instr(.i_add64, .{ .Rx = .r0, .Ry = .r0, .Rz = .r1 });
    try add_entry.instrTerm(.@"return", .{ .R = .r0 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Disassemble and check main
    {
        var disas_buf = std.ArrayList(u8).init(tb.gpa);
        defer disas_buf.deinit();
        const main_func = table.bytecode.header.get(main_id);
        const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
        try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

        const expected_main =
            \\    bit_copy64c r1 .. I:000000000000000a
            \\    bit_copy64c r2 .. I:0000000000000014
            \\    call_c r0 F:00000001 I:02 .. (r1 r2)
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_main, disas_buf.items);
    }

    // Disassemble and check add
    {
        var disas_buf = std.ArrayList(u8).init(tb.gpa);
        defer disas_buf.deinit();
        const add_func = table.bytecode.header.get(add_id);
        const code_slice = add_func.extents.base[0..@divExact(@intFromPtr(add_func.extents.upper) - @intFromPtr(add_func.extents.base), @sizeOf(core.InstructionBits))];
        try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

        const expected_add =
            \\    i_add64 r0 r0 r1
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_add, disas_buf.items);
    }
}

test "encode static data reference" {
    var tb = try TestBed("encode static data reference").init();
    defer tb.deinit();

    // Create and build a constant data static
    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "my_const");
    const data_builder = try tb.builder.createDataBuilder(const_id);
    data_builder.alignment = @alignOf(u64);
    try data_builder.writeValue(@as(u64, 0xCAFEBABE_DECAF_BAD));

    // Create a function that references the constant
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    try entry_block.instr(.addr_c, .{ .R = .r0, .C = const_id });
    try entry_block.instr(.load64, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    try entry_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Check that the loaded constant is correct
    const data: *const core.Constant = table.bytecode.header.get(const_id);
    const data_ptr: *const u64 = @alignCast(@ptrCast(data.asPtr()));
    try testing.expectEqual(@as(u64, 0xCAFEBABE_DECAF_BAD), data_ptr.*);

    // Check disassembly
    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();
    const main_func = table.bytecode.header.get(main_id);
    const main_len = @divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits));
    try disas(main_func.extents.base[0..main_len], .{ .buffer_address = false }, disas_buf.writer());

    const expected_disas =
        \\    addr_c r0 C:00000000
        \\    load64 r1 r0 I:00000000
        \\    return r1
        \\
    ;
    try testing.expectEqualStrings(expected_disas, disas_buf.items);
}

test "encode external reference creates linker fixup" {
    var tb = try TestBed("encode external reference creates linker fixup").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const external_id = try tb.builder.createHeaderEntry(.function, "my.external.func");

    // Create builder for main, but not for the external function
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();
    try entry_block.instrCall(.call_c, .{ .R = .r0, .F = external_id, .I = 0 }, .{});
    try entry_block.instrTerm(.halt, .{});

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // We expect one unbound location: the external function
    try testing.expectEqual(@as(usize, 1), table.linker_map.unbound.count());

    const external_loc_id = tb.builder.locations.localLocationId(external_id);
    const linker_loc = table.linker_map.unbound.get(external_loc_id).?;

    // It should have one fixup associated with it (from the address table entry)
    try testing.expectEqual(@as(usize, 1), linker_loc.fixups.count());

    var fixup_it = linker_loc.fixups.iterator();
    const fixup = fixup_it.next().?.key_ptr;

    // The fixup should be to resolve the absolute address of the external function
    // and write it into the address table.
    try testing.expectEqual(FixupKind.absolute, fixup.kind);
    try testing.expectEqual(LinkerFixup.Basis.to, fixup.basis);
    try testing.expect(fixup.bit_offset == null);
}
