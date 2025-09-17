//! Builder for static data blobs like constants and globals.
const DataBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_data_builder);

const core = @import("core");
const binary = @import("binary");

const common = @import("common");

const bytecode = @import("../bytecode.zig");

test {
    // std.debug.print("semantic analysis for bytecode DataBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

/// General-purpose allocator for collections and temporary data.
gpa: std.mem.Allocator,
/// Arena allocator for user data.
arena: std.mem.Allocator,
/// The writer for the data builder's buffer.
writer: common.AllocWriter,
/// The id of the data builder, used to reference it in the bytecode header.
/// * This must either be a `core.ConstantId` or a `core.GlobalId`.
id: core.StaticId = .fromInt(0),
/// The alignment to give the final data buffer. A value <=1 indicates no preference.
alignment: core.Alignment = 0,
/// A map of data locations to their references.
/// * This is used to track locations in the data builder's memory that are yet to be determined.
/// * The map is keyed by `DataLocation`, which is a symbolic type for locations in the data builder's memory.
/// * The values are `DataRef`, which can either be a reference to the data builder's own memory or a standard `binary.FixupRef`.
locations: common.UniqueReprMap(DataLocation, ?DataRef) = .empty,
/// A list of data fixups that need to be resolved when the data is encoded.
/// * This is used to track fixups that reference data within the data builder's own memory.
fixups: common.ArrayList(DataFixup) = .empty,
/// The symbol kind of the data builder.
/// * This is used to determine how the data builder's id should be interpreted.
/// * It should be either `core.SymbolKind.constant` or `core.SymbolKind.global`.
symbol_kind: core.SymbolKind = .constant,

/// Purely symbolic type for id creation (`DataBuilder.DataLocation`).
pub const DLoc = struct {};

/// Represents a location in the data builder's memory that is yet to be determined when the location is initially referenced.
pub const DataLocation = common.Id.of(DLoc, core.STATIC_ID_BITS);

/// Data fixups are distinct from standard fixups in that:
/// * `from` is always an binary.Offset into their own temporary memory, rather than an binary.Encoder's working buffer
/// * `to` is a `DataRef`, which can either be a reference into the data builder's own memory, or a standard `binary.FixupRef`
pub const DataFixup = struct {
    /// Same as `binary.Fixup.kind`.
    kind: binary.FixupKind,
    /// The binary.Offset into the data builder's memory where the binary.Fixup is applied.
    from: u64,
    /// A reference to the data builder's own memory or a standard binary.Fixup reference.
    to: DataRef,
    /// The bit binary.Offset within the data builder's memory where the binary.Fixup is applied.
    bit_offset: ?u6,
};

/// A binary.Fixup reference for data fixups. Extends `binary.FixupRef` to allow for data-specific references.
pub const DataRef = union(enum) {
    /// A reference to a data builder's own memory.
    /// * This is used for fixups that reference data within the same data builder
    internal: union(enum) {
        /// A relative address within the data builder's memory.
        relative: binary.RelativeAddress,
        /// A location in the data builder's memory that is yet to be determined.
        location: DataLocation,
    },
    /// A reference to a standard binary.Fixup.
    /// * This is used for fixups that reference data outside the data builder
    standard: binary.FixupRef,
};

/// Initialize a new data builder for a static data value.
pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) DataBuilder {
    return .{
        .gpa = gpa,
        .arena = arena,
        .writer = common.AllocWriter.init(gpa),
    };
}

/// Clear the data builder, retaining the current memory capacity.
pub fn clear(self: *DataBuilder) void {
    self.writer.clear();
    self.locations.clearRetainingCapacity();
    self.fixups.clearRetainingCapacity();
    self.id = .fromInt(0);
    self.alignment = 0;
    self.symbol_kind = .constant;
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
        log.debug("DataBuilder.registerLocation: binary.Location {f} already exists in data builder", .{location});
        return error.BadEncoding;
    }

    gop.value_ptr.* = ref;
}

/// Bind the location of a data reference to a specific address.
/// * This is used to finalize the location of a data reference after it has been registered with `registerLocation`.
pub fn bindLocation(self: *DataBuilder, location: DataLocation, ref: DataRef) error{ BadEncoding, OutOfMemory }!void {
    const entry = self.locations.getPtr(location) orelse {
        log.debug("DataBuilder.bindLocation: binary.Location {f} does not exist in data builder", .{location});
        return error.BadEncoding;
    };

    if (entry.* != null) {
        log.debug("DataBuilder.bindLocation: binary.Location {f} already bound in data builder", .{location});
        return error.BadEncoding;
    }

    entry.* = ref;
}

/// Create a new binary.Fixup entry for the data. `from` must be a currently-valid relative address into the data buffer or to its end.
pub fn bindFixup(self: *DataBuilder, kind: binary.FixupKind, from: binary.RelativeAddress, to: DataRef, bit_offset: ?u6) error{ BadEncoding, OutOfMemory }!void {
    if (from.toInt() > self.writer.getWrittenSize()) {
        log.debug("DataBuilder.bindFixup: Invalid 'from' off set {any} for data builder", .{from});
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
pub fn encode(self: *const DataBuilder, encoder: *binary.Encoder) binary.Encoder.Error!void {
    const location = switch (self.symbol_kind) {
        .constant => encoder.localLocationId(self.id.cast(core.Constant)),
        .global => encoder.localLocationId(self.id.cast(core.Global)),
        else => {
            log.debug("DataBuilder.encode: Invalid symbol kind {s} for data builder", .{@tagName(self.symbol_kind)});
            return error.BadEncoding;
        },
    };

    if (!try encoder.visitLocation(location)) {
        log.debug("DataBuilder.encode: {f} has already been encoded, skipping", .{self.id});
        return;
    }

    // get the final data buffer
    const data_buf = self.writer.getWrittenRegion();

    // get the address of our header entry in the final buffer
    const entry_addr: *core.Constant = try encoder.clone(
        // we can use a `core.Constant` layout for the header entry,
        // since globals and constants share the same layout and simply provide different access semantics
        core.Constant.fromLayout(.{
            .size = @intCast(data_buf.len),
            .alignment = @max(self.alignment, 1),
        }),
    );

    // bind the location for our ID
    const entry_rel_addr = encoder.addressToRelative(entry_addr);
    try encoder.bindLocation(location, entry_rel_addr);

    // ensure our data is aligned to its specified alignment
    try encoder.alignTo(@max(self.alignment, 1));
    // get the relative address of the data buffer
    const data_rel_addr = encoder.getRelativeAddress();

    // sanity check: core.Constant and this algorithm should agree on the start off set
    std.debug.assert(encoder.relativeToAddress(data_rel_addr) == encoder.relativeToPointer(*const core.Constant, entry_rel_addr).asPtr());

    // write our data buffer to the main encoder
    try encoder.writeAll(data_buf);

    // finally, process our local fixups and register them
    for (self.fixups.items) |local_fixup| {
        // calculate the 'from' address of the binary.Fixup in the global context
        const from_rel_addr = data_rel_addr.applyOffset(@intCast(local_fixup.from));

        try encoder.bindFixup(
            local_fixup.kind,
            .{ .relative = from_rel_addr },
            self.resolveRef(data_rel_addr, local_fixup.to, encoder),
            local_fixup.bit_offset,
        );
    }
}

/// Resolves a `DataRef` into a final `binary.FixupRef` for the main encoder.
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
/// 2. `.internal.relative`: A reference to a known binary.Offset within this `DataBuilder`.
///    It is resolved to a global `binary.FixupRef.relative` by adding `data_rel_addr`.
/// 3. `.internal.location`: A symbolic reference within this `DataBuilder`.
///    - If the location has already been bound internally, it is resolved recursively.
///    - **If the location is unbound, it is "promoted" to a global `binary.Location`**.
///      This is a key mechanism that allows data blobs to contain forward-references
///      to other functions or data that have not yet been encoded. The `DataLocation`
///      is combined with the encoder's current region ID to form a unique global
///      `binary.Location` that the linker can resolve later.
pub fn resolveRef(
    self: *const DataBuilder,
    data_rel_addr: binary.RelativeAddress,
    ref: DataRef,
    encoder: *binary.Encoder,
) binary.FixupRef {
    return switch (ref) {
        .internal => |internal_ref| switch (internal_ref) {
            .relative => |rel| binary.FixupRef{ .relative = data_rel_addr.applyOffset(@intCast(rel.toInt())) },
            .location => |loc| {
                if (self.locations.get(loc)) |entry| {
                    if (entry) |binding| {
                        return self.resolveRef(data_rel_addr, binding, encoder);
                    }
                }

                // promote unbound data locations to global locations
                return binary.FixupRef{ .location = encoder.localLocationId(loc) };
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
pub fn getWrittenRegion(self: *const DataBuilder) []align(core.PAGE_SIZE) u8 {
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
pub fn getRelativeAddress(self: *const DataBuilder) binary.RelativeAddress {
    return self.writer.getRelativeAddress();
}

/// Convert an unstable address in the data builder, such as those acquired through `alloc`, into a stable relative address.
pub fn addressToRelative(self: *const DataBuilder, address: anytype) binary.RelativeAddress {
    return self.writer.addressToRelative(address);
}

/// Convert a stable relative address in the data builder into an unstable absolute address.
pub fn relativeToAddress(self: *const DataBuilder, relative: binary.RelativeAddress) [*]u8 {
    return self.writer.relativeToAddress(relative);
}

/// Convert a stable relative address in the data builder into an unstable, typed pointer.
pub fn relativeToPointer(self: *const DataBuilder, comptime T: type, relative: binary.RelativeAddress) T {
    return self.writer.relativeToPointer(T, relative);
}

/// Reallocate the data builder's memory as necessary to support the given capacity.
pub fn ensureCapacity(self: *DataBuilder, cap: u64) common.AllocWriter.Error!void {
    return self.writer.ensureCapacity(cap);
}

/// Reallocate the data builder's memory as necessary to support the given additional capacity.
pub fn ensureAdditionalCapacity(self: *DataBuilder, additional: u64) common.AllocWriter.Error!void {
    return self.writer.ensureAdditionalCapacity(additional);
}

/// Allocates an aligned byte buffer from the address space of the data builder.
pub fn alignedAlloc(self: *DataBuilder, alignment: core.Alignment, len: usize) common.AllocWriter.Error![]u8 {
    return self.writer.alignedAlloc(alignment, len);
}

/// Same as `std.mem.Allocator.alloc`, but allocates from the address space of the data builder.
pub fn alloc(self: *DataBuilder, comptime T: type, len: usize) common.AllocWriter.Error![]T {
    return self.writer.alloc(T, len);
}

/// Same as `alloc`, but returns a binary.RelativeAddress instead of a pointer.
pub fn allocRel(self: *DataBuilder, comptime T: type, len: usize) common.AllocWriter.Error!binary.RelativeAddress {
    return self.writer.allocRel(T, len);
}

/// Same as `std.mem.Allocator.dupe`, but copies a slice into the address space of the data builder.
pub fn dupe(self: *DataBuilder, comptime T: type, slice: []const T) common.AllocWriter.Error![]T {
    return self.writer.dupe(T, slice);
}

/// Same as `dupe`, but returns a binary.RelativeAddress instead of a pointer.
pub fn dupeRel(self: *DataBuilder, comptime T: type, slice: []const T) common.AllocWriter.Error!binary.RelativeAddress {
    return self.writer.dupeRel(T, slice);
}

/// Same as `std.mem.Allocator.create`, but allocates from the address space of the data builder.
pub fn create(self: *DataBuilder, comptime T: type) common.AllocWriter.Error!*T {
    return self.writer.create(T);
}

/// Same as `create`, but returns a binary.RelativeAddress instead of a pointer.
pub fn createRel(self: *DataBuilder, comptime T: type) common.AllocWriter.Error!binary.RelativeAddress {
    return self.writer.createRel(T);
}

/// Same as `create`, but takes an initializer.
pub fn clone(self: *DataBuilder, value: anytype) common.AllocWriter.Error!*@TypeOf(value) {
    return self.writer.clone(value);
}

/// Same as `create`, but returns a binary.RelativeAddress instead of a pointer.
pub fn cloneRel(self: *DataBuilder, value: anytype) common.AllocWriter.Error!binary.RelativeAddress {
    return self.writer.cloneRel(value);
}

/// Writes as much of a slice of bytes to the data builder as will fit without an allocation.
/// Returns the number of bytes written.
pub fn write(self: *DataBuilder, noalias bytes: []const u8) common.AllocWriter.Error!usize {
    return self.writer.write(bytes);
}

/// Writes all bytes from a slice to the data builder.
pub fn writeAll(self: *DataBuilder, bytes: []const u8) common.AllocWriter.Error!void {
    return self.writer.writeAll(bytes);
}

/// Writes a single byte to the data builder.
pub fn writeByte(self: *DataBuilder, byte: u8) common.AllocWriter.Error!void {
    return self.writer.writeByte(byte);
}

/// Writes a byte to the data builder `n` times.
pub fn writeByteNTimes(self: *DataBuilder, byte: u8, n: usize) common.AllocWriter.Error!void {
    return self.writer.writeByteNTimes(byte, n);
}

/// Writes a slice of bytes to the data builder `n` times.
pub fn writeBytesNTimes(self: *DataBuilder, bytes: []const u8, n: usize) common.AllocWriter.Error!void {
    return self.writer.writeBytesNTimes(bytes, n);
}

/// Writes an integer to the data builder.
/// * This function is provided for backward compatibility with Zig's writer interface. Prefer `writeValue` instead.
pub fn writeInt(
    self: *DataBuilder,
    comptime T: type,
    value: T,
    comptime _: enum { little }, // allows backward compat with writer api; but only in provably compatible use-cases
) common.AllocWriter.Error!void {
    return self.writer.writeInt(T, value, .little);
}

/// Generalized version of `writeInt`;
/// Works for any value with a unique representation.
/// * Does not consider or provide value alignment
/// * See `std.meta.hasUniqueRepresentation`
pub fn writeValue(
    self: *DataBuilder,
    value: anytype,
) common.AllocWriter.Error!void {
    const T = @TypeOf(value);

    if (comptime !std.meta.hasUniqueRepresentation(T)) {
        @compileError("DataBuilder.writeValue: Type `" ++ @typeName(T) ++ "` does not have a unique representation");
    }

    const bytes = std.mem.asBytes(&value);
    try self.writeAll(bytes);
}

/// Pushes zero bytes (if necessary) to align the current offset of the builder to the provided alignment value.
pub fn alignTo(self: *DataBuilder, alignment: core.Alignment) common.AllocWriter.Error!void {
    const delta = common.alignDelta(self.writer.cursor, alignment);
    try self.writer.writeByteNTimes(0, delta);
}

/// Asserts that the current offset of the builder is aligned to the given value.
pub fn ensureAligned(self: *DataBuilder, alignment: core.Alignment) DataBuilder.Error!void {
    if (common.alignDelta(self.writer.cursor, alignment) != 0) {
        return error.UnalignedWrite;
    }
}
