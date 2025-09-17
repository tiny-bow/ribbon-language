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

pub const RelativeAddress = common.AllocWriter.RelativeAddress;
pub const RelativeBuffer = common.AllocWriter.RelativeBuffer;

test {
    // std.debug.print("semantic analysis for binary\n", .{});
    std.testing.refAllDecls(@This());
}

/// Error type shared by binary apis.
pub const Error = std.mem.Allocator.Error || error{
    /// Generic malformed binary error.
    BadEncoding,
    /// An error indicating that the current offset of the encoder is not aligned to
    /// the expected binary alignment for writing the provided data.
    UnalignedWrite,
};

/// An identifier that is used to identify a region in the encoded memory.
pub const RegionId = common.Id.of(Region, core.STATIC_ID_BITS);

/// Regions are used to scope fixup locations, allowing for multiple functions or blocks to be encoded in the same encoder.
pub const Region = struct {
    type_name: []const u8,
    id: RegionId,

    /// * `id` should be of a type constructed by `common.Id`
    /// * id types larger than `core.STATIC_ID_BITS` bits may cause (safe mode checked) integer overflow
    pub fn from(id: anytype) Region {
        const T = @TypeOf(id);
        if (T == Region) return id;

        return Region{
            .type_name = @typeName(T.Value),
            .id = id.bitcast(Region, core.STATIC_ID_BITS),
        };
    }
};

/// An identifier that is used to identify an offset within a region in the encoded memory.
pub const OffsetId = common.Id.of(Offset, core.STATIC_ID_BITS);

/// Offsets are like a sub-region, attached to a location along with a region to give more specific identification.
pub const Offset = struct {
    type_name: []const u8,
    id: OffsetId,

    /// * `id` should be of a type constructed by `common.Id`
    /// * id types larger than `core.STATIC_ID_BITS` bits may cause (safe mode checked) integer overflow
    pub fn from(id: anytype) Offset {
        const T = @TypeOf(id);
        if (T == Offset) return id;

        return Offset{
            .type_name = @typeName(T.Value),
            .id = id.bitcast(Offset, core.STATIC_ID_BITS),
        };
    }
};

/// Represents a location in the encoded memory that is referenced by a fixup, but who's relative offset is not known at the time of encoding that fixup.
pub const Location = struct {
    /// The region id that this location belongs to.
    region: Region,
    /// The  offset id within the region that this location is at.
    offset: Offset,

    /// Create a new `Location` from a region id and an offset id.
    /// * `region` and `id` should be of a type constructed by `common.Id`
    /// * Identity types larger than `core.STATIC_ID_BITS` (safe mode checked) bits may cause integer overflow
    pub fn from(region: anytype, id: anytype) Location {
        return Location{
            .region = .from(region),
            .offset = .from(id),
        };
    }

    pub fn eql(a: Location, b: Location) bool {
        return a.region.id == b.region.id and a.offset.id == b.offset.id and std.mem.eql(u8, a.region.type_name, b.region.type_name) and std.mem.eql(u8, a.offset.type_name, b.offset.type_name);
    }

    pub fn hash(self: Location, h: anytype) void {
        h.update(std.mem.asBytes(&self.region.id));
        h.update(std.mem.asBytes(&self.offset.id));
        h.update(std.mem.asBytes(&self.region.type_name));
        h.update(std.mem.asBytes(&self.offset.type_name));
    }

    pub fn format(self: Location, writer: *std.io.Writer) !void {
        try writer.print("{s}:{x}/{s}:{x}", .{
            self.region.type_name,
            self.region.id.toInt(),
            self.offset.type_name,
            self.offset.id.toInt(),
        });
    }

    pub fn HashContext(comptime T: type) type {
        return struct {
            const Ctx = @This();

            pub const eql = switch (T) {
                u32 => struct {
                    pub fn eql(_: Ctx, a: Location, b: Location, _: usize) bool {
                        return a.eql(b);
                    }
                }.eql,
                u64, u128 => struct {
                    pub fn eql(_: Ctx, a: Location, b: Location) bool {
                        return a.eql(b);
                    }
                }.eql,
                else => @compileError("Unsupported hash type " ++ @typeName(T) ++ " expected u32, u64 or u128"),
            };

            pub fn hash(_: Ctx, loc: Location) T {
                var hasher = switch (T) {
                    u32 => std.hash.Fnv1a_32.init(),
                    u64 => std.hash.Fnv1a_64.init(),
                    u128 => std.hash.Fnv1a_128.init(),
                    else => @compileError("Unsupported hash type " ++ @typeName(T) ++ " expected u32, u64, or u128"),
                };

                hasher.update(std.mem.asBytes(&loc.region.type_name));
                hasher.update(std.mem.asBytes(&loc.region.id));
                hasher.update(std.mem.asBytes(&loc.offset.type_name));
                hasher.update(std.mem.asBytes(&loc.offset.id));
                return hasher.final();
            }
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
    pub const FixupMap = common.ArrayMap(Location, LinkerLocation, Location.HashContext(u32));

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
    addresses: common.HashMap(Location, ?RelativeAddress, Location.HashContext(u64)) = .empty,
    /// The map of addresses that need to be fixed up after encoding.
    fixups: common.ArrayList(Fixup) = .empty,
    /// State variable indicating the region the location map currently operates in.
    region: Region,
    /// The base Region this LocationMap was initialized with.
    base_region: Region,

    /// Initialize a new location map with the provided general purpose allocator.
    /// * `id` should be of a type constructed by `common.Id`
    /// * Identity types larger than `core.STATIC_ID_BITS` bits may cause integer overflow
    pub fn init(gpa: std.mem.Allocator, id: anytype) LocationMap {
        const region = Region.from(id);
        return LocationMap{
            .gpa = gpa,
            .region = region,
            .base_region = region,
        };
    }

    /// Clear the location map, retaining the allocator and memory.
    pub fn clear(self: *LocationMap) void {
        self.addresses.clearRetainingCapacity();
        self.fixups.clearRetainingCapacity();
        self.region = self.base_region;
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
        return Location.from(self.region, id);
    }

    /// Register a location for a data reference.
    /// * Ref may be null if the location is not yet known.
    /// * Ref may be bound later with `bindLocation`.
    pub fn registerLocation(self: *LocationMap, location: Location) error{ BadEncoding, OutOfMemory }!void {
        const gop = try self.addresses.getOrPut(self.gpa, location);
        if (gop.found_existing) {
            log.debug("LocationMap.registerLocation: {f} already exists in map", .{location});
            return error.BadEncoding;
        } else {
            gop.value_ptr.* = null;
            log.debug("LocationMap.registerLocation: {f} registered in map", .{location});
        }
    }

    /// Bind the location of a data reference to a specific address.
    /// * This is used to finalize the location of a data reference after it has been registered with `registerLocation`.
    pub fn bindLocation(self: *LocationMap, location: Location, rel: RelativeAddress) error{ BadEncoding, OutOfMemory }!void {
        const entry = self.addresses.getPtr(location) orelse {
            log.debug("LocationMap.bindLocation: {f} does not exist in map", .{location});
            return error.BadEncoding;
        };

        if (entry.* != null) {
            log.debug("LocationMap.bindLocation: {f} already bound in map", .{location});
            return error.BadEncoding;
        }

        entry.* = rel;

        log.debug("LocationMap.bindLocation: {f} bound to @{x} in map", .{ location, rel.toInt() });
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
    pub fn enterRegion(self: *LocationMap, id: anytype) Region {
        const old_region = self.region;
        self.region = .from(id);
        return old_region;
    }

    /// Leave the current location region, restoring the previous region. See `enterRegion`.
    pub fn leaveRegion(self: *LocationMap, old_region: Region) void {
        self.region = old_region;
    }

    /// Get the current location region id.
    pub fn currentRegion(self: *LocationMap) Region {
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

/// Wrapper over `common.AllocWriter` that provides a location-fixup API via `LocationMap`.
pub const Encoder = struct {
    /// General purpose allocator for intermediate user operations.
    temp_allocator: std.mem.Allocator,
    /// The encoder's `common.AllocWriter`
    writer: common.AllocWriter,
    /// Location map providing relative address identification, fixup storage, and other state for fixups.
    locations: *LocationMap,
    /// Generic location visitor state for resolving out-of-order encodes.
    visited_locations: common.HashSet(Location, Location.HashContext(u64)) = .empty,
    /// Generic locations visitor state for marking skipped locations.
    /// * This is to validate that locations that have to be skipped are visited later.
    skipped_locations: common.HashSet(Location, Location.HashContext(u64)) = .empty,

    pub const Error = binary.Error;

    /// Initialize a new Encoder with a `common.AllocWriter`.
    pub fn init(temp_allocator: std.mem.Allocator, writer_allocator: std.mem.Allocator, locations: *LocationMap) error{OutOfMemory}!Encoder {
        const writer = try common.AllocWriter.initCapacity(writer_allocator);
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
        self.skipped_locations.clearRetainingCapacity();
    }

    /// Deinitialize the Encoder, freeing any memory it owns.
    pub fn deinit(self: *Encoder) void {
        self.writer.deinit();
        self.visited_locations.deinit(self.temp_allocator);
        self.skipped_locations.deinit(self.temp_allocator);
        self.* = undefined;
    }

    /// Enter a new location region.
    /// * Expected usage:
    /// ```zig
    /// const parent_region = x.enterRegion(my_region_id);
    /// defer x.leaveRegion(parent_region);
    /// ```
    /// * `region` must be a <= `pl.STATIC_ID_BITS`-bit `common.Id` type.
    pub fn enterRegion(self: *Encoder, id: anytype) Region {
        return self.locations.enterRegion(id);
    }

    /// Leave the current location region, restoring the previous region. See `enterRegion`.
    pub fn leaveRegion(self: *Encoder, old_region: Region) void {
        return self.locations.leaveRegion(old_region);
    }

    /// Get the current location region id.
    pub fn currentRegion(self: *Encoder) Region {
        return self.locations.currentRegion();
    }

    /// Poll the visitor set to see if a value should be visited.
    /// * Returns `true` if the value has not yet been visited, and puts it into the set
    pub fn visitLocation(self: *Encoder, location: Location) error{OutOfMemory}!bool {
        const gop = try self.visited_locations.getOrPut(self.temp_allocator, location);
        const new = !gop.found_existing;

        if (new) {
            log.debug("Encoder.visitLocation: {f} has not been visited, adding to visitor set", .{location});
        } else {
            log.debug("Encoder.visitLocation: {f} has already been visited", .{location});
        }

        return new;
    }

    /// Append a marker in the visitor set to indicate a location has been skipped and should be validated later.
    pub fn skipLocation(self: *Encoder, location: Location) error{OutOfMemory}!void {
        log.debug("Encoder.skipLocation: marking {f} as skipped", .{location});

        try self.skipped_locations.put(self.temp_allocator, location, {});
    }

    /// Validate that all skipped locations have been visited.
    pub fn validateSkippedLocations(self: *Encoder) error{BadEncoding}!void {
        var it = self.skipped_locations.keyIterator();
        while (it.next()) |location| {
            if (self.visited_locations.get(location.*) == null) {
                log.debug("Encoder.validateSkippedLocations: {f} was skipped but not re-visited later", .{location.*});
                return error.BadEncoding;
            }
        }
    }

    /// Poll the visitor set to see if a value has been visited.
    /// * Returns `true` if the value has been visited, and does not put it into the set.
    pub fn hasVisitedLocation(self: *Encoder, location: Location) bool {
        return self.visited_locations.contains(location);
    }

    /// Poll the visitor set to see if a value has been skipped.
    pub fn hasSkippedLocation(self: *Encoder, location: Location) bool {
        return self.skipped_locations.contains(location);
    }

    /// Finalize the Encoder's writer, returning the memory.
    ///
    /// After calling this function, the encoder will be in its default-initialized state.
    /// In other words, it is safe but not necessary to call `deinit` on it.
    /// It does not need to be re-initializd before reuse, as the allocator is retained.
    pub fn finalize(self: *Encoder) Encoder.Error![]align(core.PAGE_SIZE) u8 {
        try self.validateSkippedLocations();

        const buf = try self.writer.finalize();

        self.clear();

        return buf;
    }

    /// Create a new fixup.
    pub fn bindFixup(self: *Encoder, kind: FixupKind, from: FixupRef, to: FixupRef, bit_offset: ?u6) error{OutOfMemory}!void {
        try self.locations.bindFixup(kind, from, to, bit_offset);
    }

    /// Register a new location for fixups to reference.
    /// * relative address may be bound later with `bindLocation`
    pub fn registerLocation(self: *Encoder, id: Location) error{ BadEncoding, OutOfMemory }!void {
        try self.locations.registerLocation(id);
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
    pub fn ensureCapacity(self: *Encoder, cap: u64) common.AllocWriter.Error!void {
        return self.writer.ensureCapacity(cap);
    }

    /// Ensure additional available capacity in the encoder memory.
    pub fn ensureAdditionalCapacity(self: *Encoder, additional: u64) common.AllocWriter.Error!void {
        return self.writer.ensureAdditionalCapacity(additional);
    }

    /// Allocates an aligned byte buffer from the address space of the encoder.
    pub fn alignedAlloc(self: *Encoder, alignment: core.Alignment, len: usize) common.AllocWriter.Error![]u8 {
        return self.writer.alignedAlloc(alignment, len);
    }

    /// Same as `std.mem.Allocator.alloc`, but allocates from the virtual address space of the encoder.
    pub fn alloc(self: *Encoder, comptime T: type, len: usize) common.AllocWriter.Error![]T {
        return self.writer.alloc(T, len);
    }

    /// Same as `alloc`, but returns a RelativeAddress instead of a pointer.
    pub fn allocRel(self: *Encoder, comptime T: type, len: usize) common.AllocWriter.Error!RelativeAddress {
        return self.writer.allocRel(T, len);
    }

    /// Same as `std.mem.Allocator.dupe`, but copies a slice into the virtual address space of the encoder.
    pub fn dupe(self: *Encoder, comptime T: type, slice: []const T) common.AllocWriter.Error![]T {
        return self.writer.dupe(T, slice);
    }

    /// Same as `dupe`, but returns a RelativeAddress instead of a pointer.
    pub fn dupeRel(self: *Encoder, comptime T: type, slice: []const T) common.AllocWriter.Error!RelativeAddress {
        return self.writer.dupeRel(T, slice);
    }

    /// Same as `std.mem.Allocator.create`, but allocates from the virtual address space of the encoder.
    pub fn create(self: *Encoder, comptime T: type) common.AllocWriter.Error!*T {
        return self.writer.create(T);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn createRel(self: *Encoder, comptime T: type) common.AllocWriter.Error!RelativeAddress {
        return self.writer.createRel(T);
    }

    /// Same as `create`, but takes an initializer.
    pub fn clone(self: *Encoder, value: anytype) common.AllocWriter.Error!*@TypeOf(value) {
        return self.writer.clone(value);
    }

    /// Same as `create`, but returns a RelativeAddress instead of a pointer.
    pub fn cloneRel(self: *Encoder, value: anytype) common.AllocWriter.Error!RelativeAddress {
        return self.writer.cloneRel(value);
    }

    /// Writes as much of a slice of bytes to the encoder as will fit without an allocation.
    /// Returns the number of bytes written.
    pub fn write(self: *Encoder, noalias bytes: []const u8) common.AllocWriter.Error!usize {
        return self.writer.write(bytes);
    }

    /// Writes all bytes from a slice to the encoder.
    pub fn writeAll(self: *Encoder, bytes: []const u8) common.AllocWriter.Error!void {
        return self.writer.writeAll(bytes);
    }

    /// Writes a single byte to the encoder.
    pub fn writeByte(self: *Encoder, byte: u8) common.AllocWriter.Error!void {
        return self.writer.writeByte(byte);
    }

    /// Writes a byte to the encoder `n` times.
    pub fn writeByteNTimes(self: *Encoder, byte: u8, n: usize) common.AllocWriter.Error!void {
        return self.writer.writeByteNTimes(byte, n);
    }

    /// Writes a slice of bytes to the encoder `n` times.
    pub fn writeBytesNTimes(self: *Encoder, bytes: []const u8, n: usize) common.AllocWriter.Error!void {
        return self.writer.writeBytesNTimes(bytes, n);
    }

    /// Writes an integer to the encoder.
    /// * This function is provided for backward compatibility with Zig's writer interface. Prefer `writeValue` instead.
    pub fn writeInt(
        self: *Encoder,
        comptime T: type,
        value: T,
        comptime _: enum { little }, // allows backward compat with zig's writer interface; but only in provably compatible use-cases
    ) common.AllocWriter.Error!void {
        try self.writer.writeInt(T, value, .little);
    }

    /// Generalized version of `writeInt`;
    /// Works for any value with a unique representation.
    /// * Does not consider or provide value alignment
    /// * See `std.meta.hasUniqueRepresentation`
    pub fn writeValue(
        self: *Encoder,
        value: anytype,
    ) common.AllocWriter.Error!void {
        const T = @TypeOf(value);

        if (comptime !std.meta.hasUniqueRepresentation(T)) {
            @compileError("Encoder.writeValue: Type `" ++ @typeName(T) ++ "` does not have a unique representation");
        }

        const bytes = std.mem.asBytes(&value);
        try self.writeAll(bytes);
    }

    /// Pushes zero bytes (if necessary) to align the current offset of the encoder to the provided alignment value.
    pub fn alignTo(self: *Encoder, alignment: core.Alignment) common.AllocWriter.Error!void {
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
