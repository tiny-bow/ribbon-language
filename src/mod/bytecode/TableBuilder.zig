//! Top-level builder for a single, linkable Ribbon bytecode unit.
//! The TableBuilder is the main entry point for the bytecode construction API.
//! It manages the memory encoder, the header, and all functions and statics.
const TableBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_table_builder);

const binary = @import("binary");
const core = @import("core");

const common = @import("common");

const bytecode = @import("../bytecode.zig");

test {
    // std.debug.print("semantic analysis for bytecode TableBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

/// Allocator for all intermediate data. This is the child allocator for `TableBuilder.arena`.
gpa: std.mem.Allocator,
/// Allocator for non-volatile intermediate data.
arena: std.heap.ArenaAllocator,
/// The location map for fixups and relative addresses.
locations: binary.LocationMap,
/// The header builder for the bytecode unit.
header: bytecode.HeaderBuilder = .{},
/// Static value builders owned by this table.
statics: StaticMap = .empty,

/// A map of static values that are referenced by the header in a `TableBuilder`.
pub const StaticMap = common.UniqueReprMap(core.StaticId, Entry);

/// An entry in the `TableBuilder.statics` map.
pub const Entry = struct {
    /// The location of the function in the
    location: binary.Location,
    /// The kind of symbol this entry represents.
    kind: core.SymbolKind,
    /// Not binding a builder before encoding is an error.
    /// To indicate a linked address or a custom encoding, use `external`.
    content: ?union(enum) {
        /// Designates an intentional lack of an attached builder.
        external: void,
        /// A builder for a function.
        function: *bytecode.FunctionBuilder,
        /// A builder for a constant or global data value.
        data: *bytecode.DataBuilder,
        /// A builder for an effect handler set.
        handler_set: *bytecode.HandlerSetBuilder,
        /// An effect identity.
        effect: core.Effect,
        /// A builtin identity.
        builtin: core.Builtin,

        fn deinit(self: *@This()) void {
            switch (self.*) {
                .external, .effect, .builtin => {},
                inline else => |b| b.deinit(),
            }
        }
    },

    fn deinit(self: *Entry) void {
        if (self.content) |*b| b.deinit();
        self.* = undefined;
    }
};

/// Initialize a new table builder.
/// * `identifier` should be any integer that is not also provided to another table builder in the same compilation environment;
///   `null` may be passed if there will only be one table builder in the current compilation environment
pub fn init(allocator: std.mem.Allocator, identifier: ?u32) TableBuilder {
    const id: common.Id.of(TableBuilder, 32) = if (identifier) |i| .fromInt(i) else @enumFromInt(0xAAAA_AAAA);
    return TableBuilder{ .gpa = allocator, .arena = .init(allocator), .locations = .init(allocator, id) };
}

/// Clear the table, retaining allocated storage where possible.
pub fn clear(self: *TableBuilder) void {
    var static_it = self.statics.valueIterator();
    while (static_it.next()) |entry| entry.deinit();
    self.statics.clearRetainingCapacity();

    self.locations.clear();
    self.header.clear();

    _ = self.arena.reset(.retain_capacity);
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
pub fn createHeaderEntry(self: *TableBuilder, comptime kind: core.SymbolKind, name: ?[]const u8) error{ BadEncoding, OutOfMemory }!kind.asIdType() {
    // get the next static id
    const static_id = self.header.getNextId();
    const typed_id = static_id.bitcast(kind.toType(), core.STATIC_ID_BITS);

    // create a location for the static value
    const static_loc = self.locations.localLocationId(static_id.cast(kind.toType()));
    const static_ref = binary.FixupRef{ .location = static_loc };

    try self.locations.registerLocation(static_loc);

    // bind the location to the address table
    const bind_result = try self.header.bindAddress(self.gpa, kind, .{ .relative = static_ref });

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
        .location = static_loc,
        .kind = kind,
        .content = null,
    };

    return typed_id;
}

/// Bind a new `bytecode.FunctionBuilder` to an id.
/// * A fresh `id` can be created with `createHeaderEntry`.
/// * Note that the returned pointer is owned by the `TableBuilder` and should not be deinitialized manually.
/// * Use `getFunctionBuilder` to retrieve the pointer to the function builder by its id (available as a field of the builder).
pub fn createFunctionBuilder(
    self: *TableBuilder,
    id: core.FunctionId,
) error{ BadEncoding, OutOfMemory }!*bytecode.FunctionBuilder {
    // if we're not tracking this id we can't create a builder for it
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse {
        log.debug("TableBuilder.createFunctionBuilder: {f} does not exist", .{id});
        return error.BadEncoding;
    };

    // type check: the entry must be a function
    if (entry.kind != .function) {
        log.debug("TableBuilder.createFunctionBuilder: expected function, got {s}", .{@tagName(entry.kind)});
        return error.BadEncoding;
    }

    // we support local mutations up to and including full replacement of the builder,
    // so if there was an existing builder its not an error, just deinit, and reuse the address.
    const addr = if (entry.content) |*old_builder| existing: {
        old_builder.deinit();

        break :existing old_builder.function;
    } else try self.arena.allocator().create(bytecode.FunctionBuilder);

    addr.* = bytecode.FunctionBuilder.init(self.gpa, self.arena.allocator());

    addr.id = id;

    // setup and return the new builder
    entry.content = .{ .function = addr };

    return addr;
}

/// Bind a new `bytecode.DataBuilder` to an id.
/// * `id` should be a `core.ConstantId` or `core.GlobalId`.
/// * A fresh `id` can be created with `createHeaderEntry`.
/// * Note that the returned pointer is owned by the `TableBuilder` and should not be deinitialized manually.
/// * Use `getDataBuilder` to retrieve the pointer to the function builder by its id (available as a field of the builder).
pub fn createDataBuilder(
    self: *TableBuilder,
    id: anytype,
) error{ BadEncoding, OutOfMemory }!*bytecode.DataBuilder {
    const static_id = id.cast(anyopaque);

    // if we're not tracking this id we can't create a builder for it
    const entry = self.statics.getPtr(static_id) orelse {
        log.debug("TableBuilder.createFunctionBuilder: {f} does not exist", .{id});
        return error.BadEncoding;
    };

    // type check: the entry must be a data value
    if (entry.kind != .constant and entry.kind != .global) {
        log.debug("TableBuilder.createFunctionBuilder: expected constant or global, got {s}", .{@tagName(entry.kind)});
        return error.BadEncoding;
    }

    // we support local mutations up to and including full replacement of the builder,
    // so if there was an existing builder its not an error, just deinit, and reuse the address.
    const addr = if (entry.content) |*old_builder| existing: {
        old_builder.deinit();

        break :existing old_builder.data;
    } else try self.arena.allocator().create(bytecode.DataBuilder);

    addr.* = bytecode.DataBuilder.init(self.gpa, self.arena.allocator());

    addr.id = static_id;
    addr.symbol_kind = entry.kind;

    // setup and return the new builder
    entry.content = .{ .data = addr };

    return addr;
}

/// Bind a new `bytecode.HandlerSetBuilder` to an id.
/// * A fresh `id` can be created with `createHeaderEntry`.
/// * Note that the returned pointer is owned by the `TableBuilder` and should not be deinitialized manually.
/// * Use `getHandlerSetBuilder` to retrieve the pointer to the function builder by its id (available as a field of the builder).
pub fn createHandlerSet(self: *TableBuilder, id: core.HandlerSetId) error{ BadEncoding, OutOfMemory }!*bytecode.HandlerSetBuilder {
    // if we're not tracking this id we can't create a builder for it
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse {
        log.debug("TableBuilder.createHandlerSetBuilder: {f} does not exist", .{id});
        return error.BadEncoding;
    };

    // type check: the entry must be a handler set
    if (entry.kind != .handler_set) {
        log.debug("TableBuilder.createHandlerSetBuilder: expected handler_set, got {s}", .{@tagName(entry.kind)});
        return error.BadEncoding;
    }

    // we support local mutations up to and including full replacement of the builder,
    // so if there was an existing builder its not an error, just deinit, and reuse the address.
    const addr = if (entry.content) |*old_builder| existing: {
        old_builder.deinit();

        break :existing old_builder.handler_set;
    } else try self.arena.allocator().create(bytecode.HandlerSetBuilder);

    addr.* = bytecode.HandlerSetBuilder.init(self.gpa, self.arena.allocator());

    addr.id = id;

    // setup and return the new builder
    entry.content = .{ .handler_set = addr };

    return addr;
}

/// Bind a `core.Effect` to an id.
/// * a fresh id can be created with `createHeaderEntry`
/// * The `core` differentiates between these to allow different tables to find agreement on effect typing
///   without having to share the same effect ids within the table.
/// *
///   - TODO: create an effects manager that does this by name
///   - use effect manager to *get an id* for the effect
///   - run effect manager with the table builder linkermap after encoding, which will link the effect ids to its own table
pub fn bindEffect(self: *TableBuilder, id: core.EffectId, effect: core.Effect) error{ BadEncoding, OutOfMemory }!void {
    // we must be tracking the id to manage the effect
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse {
        log.debug("TableBuilder.createEffect: {f} does not exist", .{id});
        return error.BadEncoding;
    };

    // type check: the entry must be an effect
    if (entry.kind != .effect) {
        log.debug("TableBuilder.createEffect: expected effect, got {s}", .{@tagName(entry.kind)});
        return error.BadEncoding;
    }

    // we support local mutations up to and including full replacement of the builder,
    // so if there was an existing builder its not an error, just deinit.
    if (entry.content) |*old_builder| {
        old_builder.deinit();
    }

    // setup the content
    entry.content = .{ .effect = effect };
}

/// Bind a `core.BuiltinProcedure` to an id.
/// * a fresh id can be created with `createHeaderEntry`
/// * The provided `func` address must outlive any use of the generated bytecode
pub fn bindBuiltinProcedure(self: *TableBuilder, id: core.BuiltinId, func: *const core.Builtin.Procedure) error{ BadEncoding, OutOfMemory }!void {
    // we must be tracking the id to manage the builtin Procedure
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse {
        log.debug("TableBuilder.bindBuiltinProcedure: {f} does not exist", .{id});
        return error.BadEncoding;
    };

    // type check: the entry must be a Procedure
    if (entry.kind != .builtin) {
        log.debug("TableBuilder.bindBuiltinProcedure: expected builtin, got {s}", .{@tagName(entry.kind)});
        return error.BadEncoding;
    }

    // we support local mutations up to and including full replacement of the builder,
    // so if there was an existing builder its not an error, just deinit.
    if (entry.content) |*old_builder| {
        old_builder.deinit();
    }

    // setup the content
    entry.content = .{ .builtin = .fromProcedure(func) };
}

/// Get a function builder by its id.
pub fn getFunctionBuilder(self: *const TableBuilder, id: core.FunctionId) ?*bytecode.FunctionBuilder {
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse return null;
    if (entry.kind != .function) return null;
    return if (entry.content) |*builder| builder.function else null;
}

/// Get a data builder by its id.
/// * `id` should be a `core.ConstantId` or `core.GlobalId`
pub fn getDataBuilder(self: *const TableBuilder, id: anytype) ?*bytecode.DataBuilder {
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse return null;
    if (entry.kind != .constant and entry.kind != .global) return null;
    return if (entry.content) |*builder| builder.data else null;
}

/// Get a handler set builder by its id.
pub fn getHandlerSetBuilder(self: *const TableBuilder, id: core.HandlerSetId) ?*bytecode.HandlerSetBuilder {
    const entry = self.statics.getPtr(id.cast(anyopaque)) orelse return null;
    if (entry.kind != .handler_set) return null;
    return if (entry.content) |*builder| builder.handler_set else null;
}

/// Get the location of a static by its id.
pub fn getStaticLocation(self: *const TableBuilder, id: core.StaticId) ?binary.Location {
    const entry = self.statics.get(id) orelse return null;
    return entry.location;
}

/// Encode the current state of the bytecode.Table.
/// * `allocator` is used for the final `bytecode.Table`.
pub fn encode(self: *TableBuilder, allocator: std.mem.Allocator) binary.Encoder.Error!bytecode.Table {
    // Create the encoder with the provided allocator
    var encoder = try binary.Encoder.init(self.gpa, allocator, &self.locations);
    defer encoder.deinit();

    // Encode the header first
    const header_rel = try self.header.encode(&encoder);

    // Encode the statics the header references, tracking how much data we append
    // to the encoder, so we can finalize the header with the correct size.
    const size_start = encoder.getEncodedSize();

    var static_it = self.statics.iterator();
    while (static_it.next()) |pair| {
        const static_id = pair.key_ptr.*;
        const entry = pair.value_ptr.*;

        if (entry.content) |builder| {
            switch (builder) {
                .external => {},
                .effect => |effect| {
                    const loc = encoder.localLocationId(static_id.cast(core.Effect));
                    const rel = try encoder.cloneRel(effect);

                    try encoder.bindLocation(loc, rel);
                },
                .builtin => |builtin| {
                    const loc = encoder.localLocationId(static_id.cast(core.Builtin));
                    const rel = try encoder.cloneRel(builtin);

                    try encoder.bindLocation(loc, rel);
                },
                .function => |function_builder| try function_builder.encode(null, &encoder),
                .data => |data_builder| try data_builder.encode(&encoder),
                .handler_set => |handler_set_builder| try handler_set_builder.encode(null, &encoder),
            }
        }
    }

    const size_end = encoder.getEncodedSize();

    const statics_size = size_end - size_start;

    // Finalize the encoder and get the bytecode
    const buf = try encoder.finalize();
    errdefer allocator.free(buf);

    // Perform local linking of addresses
    var linker_map = binary.LinkerMap.init(allocator);
    errdefer linker_map.deinit();

    // Run location map finalization on the buffer to fix up all addresses
    try self.locations.finalizeBuffer(&linker_map, buf);

    // sanity check: For core.deinit to work, the header must be the base pointer of the buffer
    std.debug.assert(header_rel.isBase());

    const header = header_rel.toTypedPtr(*core.Bytecode, buf);

    header.size += statics_size;

    // Wrap the encoded header in a `core.Bytecode` structure, and that in a `bytecode.Table` with the linker
    return bytecode.Table{
        .linker_map = linker_map,
        .bytecode = header,
    };
}
