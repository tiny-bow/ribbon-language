//! # binary
//! *Format-agnostic codegen tools*
//!
//! This module provides a comprehensive set of utilities for generating and manipulating binary artifacts within the Ribbon
//! toolchain. It is designed to handle the complexities of encoding machine code or bytecode where the final memory
//! addresses of functions and data are not known at compile time. The primary components are the `Encoder`, which provides
//! a high-level API for writing data; `Location`, a symbolic identifier for a position within the encoded output; and
//! `Fixup`, which represents a deferred write operation to patch an address once it becomes known. These are managed by a
//! `LocationMap` during the encoding process, allowing for flexible and robust code generation.
//!
//! The workflow centers around the `Encoder` populating a buffer while registering symbolic `Location`s and pending
//! `Fixup`s in its associated `LocationMap`. Once encoding is complete, `LocationMap.finalizeBuffer` is called to resolve
//! these fixups. It can perform both `absolute` address writes and calculate `relative` offsets, with support for patching
//! specific bit-ranges within a word for instruction encoding or tagged pointers. If a fixup refers to a location that is
//! not defined within the current buffer, it is promoted to a `LinkerFixup` and stored in a `LinkerMap`. This allows for
//! linking against other binary artifacts later in the toolchain, effectively separating intra-procedural patching from
//! inter-module linking.
const binary = @This();

const std = @import("std");
const log = std.log.scoped(.binary);

const core = @import("core");
const common = @import("common");
const Id = common.Id;
const AllocWriter = common.AllocWriter;
const RelativeAddress = AllocWriter.RelativeAddress;
const RelativeBuffer = AllocWriter.RelativeBuffer;

/// Error type shared by binary apis.
pub const Error = std.mem.Allocator.Error || error{
    /// Generic malformed binary error.
    BadEncoding,
    /// An error indicating that the current offset of the encoder is not aligned to
    /// the expected binary alignment for writing the provided data.
    UnalignedWrite,
};

/// Regions are used to scope fixup locations, allowing for multiple functions or blocks to be encoded in the same encoder.
pub const RegionId = Id.of(Location.RegionMark, core.STATIC_ID_BITS);

/// An identifier that is used to identify a location within a region in the encoded memory.
pub const OffsetId = Id.of(Location.OffsetMark, core.STATIC_ID_BITS);

/// Represents a location in the encoded memory that is referenced by a fixup, but who's relative offset is not known at the time of encoding that fixup.
pub const Location = packed struct(u64) {
    /// The region id that this location belongs to.
    region: RegionId = .fromInt(0),
    /// The  offset id within the region that this location is at.
    offset: OffsetId = .fromInt(0),

    /// Purely symbolic type for id creation (`RegionId`).
    pub const RegionMark = struct {};

    /// Purely symbolic type for id creation (`OffsetId`).
    pub const OffsetMark = struct {};

    /// Create a new `Location` from a region id and an offset id.
    /// * `region` and `id` should be of a type constructed by `common.Id`
    /// * Identity types larger than `core.STATIC_ID_BITS` bits may cause integer overflow
    pub fn from(region: anytype, id: anytype) Location {
        return Location{
            .region = region.bitcast(RegionMark, core.STATIC_ID_BITS),
            .offset = id.bitcast(OffsetMark, core.STATIC_ID_BITS),
        };
    }

    /// Create a new `Location` from a region id and an offset id.
    /// * `id` should be of a type constructed by `common.Id`
    /// * Identity types larger than `core.STATIC_ID_BITS` bits may cause integer overflow
    pub fn fromId(region: RegionId, id: anytype) Location {
        return Location{
            .region = region,
            .offset = id.bitcast(OffsetMark, core.STATIC_ID_BITS),
        };
    }
};

/// Determines the kind of fixup to perform.
pub const FixupKind = enum {
    /// Copy the resolve address of `.to`, into the location at the resolved address of `.from`.
    absolute,
    /// Resolve the address of `.to`, and `.from`, then calculate the relative offset between them,
    /// overwriting the bits at `.bit_offset` in the instruction at `.from`.
    relative_words,
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
    pub const FixupSet = common.HashSet(LinkerFixup, LinkerHashContext);

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
    pub const FixupMap = common.UniqueReprArrayMap(Location, LinkerLocation);

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
    addresses: common.UniqueReprMap(Location, ?RelativeAddress) = .empty,
    /// The map of addresses that need to be fixed up after encoding.
    fixups: common.ArrayList(Fixup) = .empty,
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
        self.region = region.bitcast(Location.RegionMark, core.STATIC_ID_BITS);
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
    pub fn finalizeBuffer(self: *LocationMap, linker_map: *LinkerMap, buf: []align(core.PAGE_SIZE) u8) error{ OutOfMemory, BadEncoding }!void {
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
                .relative_words => jump: {
                    const relative_offset_bytes = @as(isize, @bitCast(@intFromPtr(to))) - @as(isize, @bitCast(@intFromPtr(from)));
                    const relative_offset_words: i16 = @intCast(@divExact(relative_offset_bytes, @sizeOf(*u64)));

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
    pub fn resolveFixupRef(self: *LocationMap, ref: FixupRef, base: []align(core.PAGE_SIZE) u8) error{ BadEncoding, OutOfMemory }!?*align(1) u64 {
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

/// Wrapper over `AllocWriter` that provides a location-fixup API via `LocationMap`.
pub const Encoder = struct {
    /// General purpose allocator for intermediate user operations.
    temp_allocator: std.mem.Allocator,
    /// The encoder's `AllocWriter`
    writer: AllocWriter,
    /// Location map providing relative address identification, fixup storage, and other state for fixups.
    locations: *LocationMap,
    /// Generic location visitor state for resolving out-of-order encodes.
    visited_locations: common.UniqueReprSet(Location) = .empty,

    pub const Error = binary.Error;

    /// Initialize a new Encoder with a `AllocWriter`.
    pub fn init(temp_allocator: std.mem.Allocator, writer_allocator: std.mem.Allocator, locations: *LocationMap) error{OutOfMemory}!Encoder {
        const writer = try AllocWriter.initCapacity(writer_allocator);
        return Encoder{
            .temp_allocator = temp_allocator,
            .writer = writer,
            .locations = locations,
        };
    }

    /// Clear the Encoder, retaining the allocator and writer, along with the writer buffer memory and visitor set storage.
    /// * Note this does not clear the `locations` map as the encoder does not own it
    pub fn clear(self: *Encoder) void {
        self.writer.clear();
        self.visited_locations.clearRetainingCapacity();
    }

    /// Deinitialize the Encoder, freeing any memory it owns.
    pub fn deinit(self: *Encoder) void {
        self.writer.deinit();
        self.visited_locations.deinit(self.temp_allocator);
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

    /// Poll the visitor set to see if a value should be visited.
    /// * Returns `true` if the value has not yet been visited, and puts it into the set.
    pub fn visitLocation(self: *Encoder, location: Location) !bool {
        const gop = try self.visited_locations.getOrPut(self.temp_allocator, location);
        return !gop.found_existing;
    }

    /// Poll the visitor set to see if a value has been visited.
    /// * Returns `true` if the value has been visited, and does not put it into the set.
    pub fn hasVisitedLocation(self: *Encoder, location: Location) bool {
        return self.visited_locations.contains(location);
    }

    /// Finalize the Encoder's writer, returning the memory.
    ///
    /// After calling this function, the encoder will be in its default-initialized state.
    /// In other words, it is safe but not necessary to call `deinit` on it.
    /// It does not need to be re-initializd before reuse, as the allocator is retained.
    pub fn finalize(self: *Encoder) Encoder.Error![]align(core.PAGE_SIZE) u8 {
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
    pub fn alignedAlloc(self: *Encoder, alignment: core.Alignment, len: usize) AllocWriter.Error![]u8 {
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
    pub fn alignTo(self: *Encoder, alignment: core.Alignment) AllocWriter.Error!void {
        const delta = common.alignDelta(self.writer.cursor, alignment);
        try self.writer.writeByteNTimes(0, delta);
    }

    /// Asserts that the current offset of the encoder is aligned to the given value.
    pub fn ensureAligned(self: *Encoder, alignment: core.Alignment) Encoder.Error!void {
        if (common.alignDelta(self.writer.cursor, alignment) != 0) {
            return error.UnalignedWrite;
        }
    }
};

const testing = std.testing;

test "linker map locations and fixups" {
    const gpa = std.testing.allocator;

    var linker_map = LinkerMap.init(gpa);
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

test "location map regions and locations" {
    const gpa = std.testing.allocator;
    var map = LocationMap.init(gpa);
    defer map.deinit();

    const region_id1 = Id.of(u8, 8).fromInt(1);
    const parent_region = map.enterRegion(region_id1);
    try testing.expectEqual(RegionId.fromInt(0), parent_region);
    try testing.expectEqual(region_id1.bitcast(Location.RegionMark, core.STATIC_ID_BITS), map.currentRegion());

    const offset_id1 = Id.of(u16, 16).fromInt(10);
    const loc1 = map.localLocationId(offset_id1);
    try testing.expectEqual(region_id1.bitcast(Location.RegionMark, core.STATIC_ID_BITS), loc1.region);

    try map.registerLocation(loc1, null);
    try testing.expect(map.addresses.get(loc1).? == null);

    const rel_addr = RelativeAddress.fromInt(42);
    try map.bindLocation(loc1, rel_addr);
    try testing.expect(map.addresses.get(loc1).?.? == rel_addr);

    map.leaveRegion(parent_region);
    try testing.expectEqual(RegionId.fromInt(0), map.currentRegion());
}

test "finalize buffer with resolvable fixups" {
    const gpa = std.testing.allocator;
    var map = LocationMap.init(gpa);
    defer map.deinit();

    var linker_map = LinkerMap.init(gpa);
    defer linker_map.deinit();

    var encoder = try Encoder.init(gpa, gpa, &map);
    defer encoder.deinit();

    // Word 0: Will contain the absolute address of Word 2.
    const from_abs_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0));
    const from_abs_loc = encoder.localLocationId(OffsetId.fromInt(1));
    try encoder.registerLocation(from_abs_loc, from_abs_rel);

    // Word 1: Will contain a relative jump to Word 3. The low 16 bits will be patched.
    const from_rel_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xFFFFFFFFFFFF0000));
    const from_rel_loc = encoder.localLocationId(OffsetId.fromInt(2));
    try encoder.registerLocation(from_rel_loc, from_rel_rel);

    // Word 2: The target for the absolute fixup.
    const to_abs_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xAAAAAAAAAAAAAAA));
    const to_abs_loc = encoder.localLocationId(OffsetId.fromInt(3));
    try encoder.registerLocation(to_abs_loc, to_abs_rel);

    // Word 3: The target for the relative fixup.
    const to_rel_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xBBBBBBBBBBBBBBBB));
    const to_rel_loc = encoder.localLocationId(OffsetId.fromInt(4));
    try encoder.registerLocation(to_rel_loc, to_rel_rel);

    // Bind fixups
    try encoder.bindFixup(.absolute, .{ .location = from_abs_loc }, .{ .location = to_abs_loc }, null);
    try encoder.bindFixup(.relative, .{ .location = from_rel_loc }, .{ .location = to_rel_loc }, 0);

    const buf = try encoder.finalize();
    defer gpa.free(buf);

    // Finalize the buffer by applying fixups
    try map.finalizeBuffer(&linker_map, buf);

    // Check results
    const words: [*]const u64 = @ptrCast(buf.ptr);

    // Absolute fixup: words[0] should now hold the address of words[2]
    const expected_abs_addr = @intFromPtr(&words[2]);
    try testing.expectEqual(expected_abs_addr, words[0]);

    // Relative fixup: words[1] should contain a relative offset.
    // The jump is from words[1] to words[3], which is 2 words forward (16 bytes).
    const expected_relative_val: u16 = 2;
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFF0000 | expected_relative_val), words[1]);

    try testing.expectEqual(@as(u64, 0xAAAAAAAAAAAAAAA), words[2]);
    try testing.expectEqual(@as(u64, 0xBBBBBBBBBBBBBBBB), words[3]);
}

test "finalize buffer with unresolvable fixups" {
    const gpa = std.testing.allocator;
    var map = LocationMap.init(gpa);
    defer map.deinit();

    var linker_map = LinkerMap.init(gpa);
    defer linker_map.deinit();

    var encoder = try Encoder.init(gpa, gpa, &map);
    defer encoder.deinit();

    // A known location that needs a fixup from an unknown one.
    const from_known_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0)); // Placeholder for absolute address
    const from_known_loc = encoder.localLocationId(OffsetId.fromInt(1));
    try encoder.registerLocation(from_known_loc, from_known_rel);

    // An unknown location that will be resolved by the linker.
    const to_unknown_region = RegionId.fromInt(99);
    const to_unknown_offset = OffsetId.fromInt(100);
    const to_unknown_loc = Location{ .region = to_unknown_region, .offset = to_unknown_offset };
    try encoder.registerLocation(to_unknown_loc, null); // Register as known but never bind

    // Bind a fixup from the known location to the unknown one.
    try encoder.bindFixup(.absolute, .{ .location = from_known_loc }, .{ .location = to_unknown_loc }, null);

    const buf = try encoder.finalize();
    defer gpa.free(buf);

    // Finalize. This should move the unresolved fixup to the linker_map.
    try map.finalizeBuffer(&linker_map, buf);

    try testing.expectEqual(@as(usize, 1), linker_map.unbound.count());

    const unbound_loc = linker_map.unbound.get(to_unknown_loc).?;
    try testing.expectEqual(to_unknown_loc, unbound_loc.identity);
    try testing.expectEqual(@as(usize, 1), unbound_loc.fixups.count());

    var it = unbound_loc.fixups.iterator();
    const fixup = it.next().?.key_ptr;

    try testing.expect(fixup.kind == .absolute);
    try testing.expect(fixup.basis == .to); // The 'to' part was unknown
    const expected_other_addr = RelativeAddress.fromPtr(buf, &buf[from_known_rel.toInt()]);
    try testing.expect(fixup.other == expected_other_addr);
}

test "finalize buffer with absolute fixup and bit offset" {
    const gpa = std.testing.allocator;
    var map = LocationMap.init(gpa);
    defer map.deinit();

    var linker_map = LinkerMap.init(gpa);
    defer linker_map.deinit();

    var encoder = try Encoder.init(gpa, gpa, &map);
    defer encoder.deinit();

    // A pointer location with some pre-existing tag data in the low bits
    const from_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0b101)); // Initial value with tag
    const from_loc = encoder.localLocationId(OffsetId.fromInt(1));
    try encoder.registerLocation(from_loc, from_rel);

    // Pad to a different address
    try encoder.writeValue(@as(u64, 0));

    // The target data
    const to_rel = encoder.getRelativeAddress();
    try encoder.writeValue(@as(u64, 0xCAFE));
    const to_loc = encoder.localLocationId(OffsetId.fromInt(2));
    try encoder.registerLocation(to_loc, to_rel);

    // Bind a fixup for a 48-bit pointer, at bit offset 16.
    try encoder.bindFixup(.absolute, .{ .location = from_loc }, .{ .location = to_loc }, 16);

    const buf = try encoder.finalize();
    defer gpa.free(buf);

    try map.finalizeBuffer(&linker_map, buf);

    const words: [*]const u64 = @ptrCast(buf.ptr);
    const to_ptr_addr = @intFromPtr(&words[2]);
    const addr_48bit = @as(u48, @truncate(to_ptr_addr));

    const expected_val = (@as(u64, addr_48bit) << 16) | 0b101;

    try testing.expectEqual(expected_val, words[0]);
}
