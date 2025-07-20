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

const common = @import("common");
const core = @import("core");
const Id = common.Id;
const Buffer = common.Buffer;
const AllocWriter = common.AllocWriter;
const RelativeAddress = AllocWriter.RelativeAddress;
const RelativeBuffer = AllocWriter.RelativeBuffer;
const binary = @import("binary");
const Location = binary.Location;
const Encoder = binary.Encoder;
const LinkerMap = binary.LinkerMap;
const LocationMap = binary.LocationMap;
const FixupRef = binary.FixupRef;
const FixupKind = binary.FixupKind;
const Region = binary.Region;
const Offset = binary.Offset;
const Fixup = binary.Fixup;
const LinkerFixup = binary.LinkerFixup;

pub const Instruction = @import("Instruction");

test {
    // ensure all module decls are semantically analyzed
    std.testing.refAllDecls(@This());
}

/// Error type shared by bytecode apis.
pub const Error = binary.Error;

/// A table of bytecode, containing the unit, statics, and linker map.
pub const Table = struct {
    /// The map of unbound locations and their fixups.
    linker_map: LinkerMap,
    /// The bytecode unit.
    bytecode: *core.Bytecode,

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
    pub const StaticMap = common.UniqueReprMap(core.StaticId, Entry);

    /// An entry in the `TableBuilder.statics` map, which can either be a `DataBuilder` or a `FunctionBuilder`.
    pub const Entry = struct {
        /// The location of the function in the
        location: Location,
        /// The kind of symbol this entry represents.
        kind: core.SymbolKind,
        /// Not binding a builder before encoding is an error.
        /// To indicate a linked address or a custom encoding, use `external`.
        content: ?union(enum) {
            /// Designates an intentional lack of an attached builder.
            external: void,
            /// A builder for a function.
            function: *FunctionBuilder,
            /// A builder for a constant or global data value.
            data: *DataBuilder,
            /// A builder for an effect handler set.
            handler_set: *HandlerSetBuilder,
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
        const id: Id.of(TableBuilder, 32) = if (identifier) |i| .fromInt(i) else @enumFromInt(0xAAAA_AAAA);
        return TableBuilder{ .gpa = allocator, .arena = .init(allocator), .locations = .init(allocator, id) };
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
        const typed_id = static_id.bitcast(kind.toType(), core.STATIC_ID_BITS);

        // create a location for the static value
        const static_loc = self.locations.localLocationId(static_id.cast(kind.toType()));
        const static_ref = FixupRef{ .location = static_loc };

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
            log.debug("TableBuilder.createFunctionBuilder: {} does not exist", .{id});
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
        } else try self.arena.allocator().create(FunctionBuilder);

        addr.* = FunctionBuilder.init(self.gpa, self.arena.allocator());

        addr.id = id;

        // setup and return the new builder
        entry.content = .{ .function = addr };

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
            log.debug("TableBuilder.createFunctionBuilder: {} does not exist", .{id});
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
        } else try self.arena.allocator().create(DataBuilder);

        addr.* = DataBuilder.init(self.gpa, self.arena.allocator());

        addr.id = static_id;
        addr.symbol_kind = entry.kind;

        // setup and return the new builder
        entry.content = .{ .data = addr };

        return addr;
    }

    /// Bind a new `HandlerSetBuilder` to an id.
    /// * A fresh `id` can be created with `createHeaderEntry`.
    /// * Note that the returned pointer is owned by the `TableBuilder` and should not be deinitialized manually.
    /// * Use `getHandlerSetBuilder` to retrieve the pointer to the function builder by its id (available as a field of the builder).
    pub fn createHandlerSet(self: *TableBuilder, id: core.HandlerSetId) error{ BadEncoding, OutOfMemory }!*HandlerSetBuilder {
        // if we're not tracking this id we can't create a builder for it
        const entry = self.statics.getPtr(id.cast(anyopaque)) orelse {
            log.debug("TableBuilder.createHandlerSetBuilder: {} does not exist", .{id});
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
        } else try self.arena.allocator().create(HandlerSetBuilder);

        addr.* = HandlerSetBuilder.init(self.gpa, self.arena.allocator());

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
            log.debug("TableBuilder.createEffect: {} does not exist", .{id});
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
            log.debug("TableBuilder.bindBuiltinProcedure: {} does not exist", .{id});
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
    pub fn getFunctionBuilder(self: *const TableBuilder, id: core.FunctionId) ?*FunctionBuilder {
        const entry = self.statics.getPtr(id) orelse return null;
        if (entry.kind != .function) return null;
        return if (entry.content) |*builder| &builder.function else null;
    }

    /// Get a data builder by its id.
    /// * `id` should be a `core.ConstantId` or `core.GlobalId`
    pub fn getDataBuilder(self: *const TableBuilder, id: anytype) ?*DataBuilder {
        const entry = self.statics.getPtr(id) orelse return null;
        if (entry.kind != .constant and entry.kind != .global) return null;
        return if (entry.content) |*builder| &builder.data else null;
    }

    /// Get a handler set builder by its id.
    pub fn getHandlerSetBuilder(self: *const TableBuilder, id: core.HandlerSetId) ?*HandlerSetBuilder {
        const entry = self.statics.getPtr(id) orelse return null;
        if (entry.kind != .handler_set) return null;
        return if (entry.content) |*builder| &builder.handler_set else null;
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
        var linker_map = LinkerMap.init(allocator);
        errdefer linker_map.deinit();

        // Run location map finalization on the buffer to fixup all addresses
        try self.locations.finalizeBuffer(&linker_map, buf);

        // sanity check: For core.deinit to work, the header must be the base pointer of the buffer
        std.debug.assert(header_rel.isBase());

        const header = header_rel.toTypedPtr(*core.Bytecode, buf);

        header.size += statics_size;

        // Wrap the encoded header in a `core.Bytecode` structure, and that in a `Table` with the linker
        return Table{
            .linker_map = linker_map,
            .bytecode = header,
        };
    }
};

/// Builder for bytecode headers. See `core.Bytecode`.
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

    /// Encode the current state of the table into a `core.Bytecode` structure, returning its relative address.
    pub fn encode(self: *const HeaderBuilder, encoder: *Encoder) Encoder.Error!RelativeAddress {
        const header_rel = try encoder.createRel(core.Bytecode);

        const start_size = encoder.getEncodedSize();

        const symbol_table = try self.symbol_table.encode(encoder);
        const address_table = try self.address_table.encode(encoder);

        const end_size = encoder.getEncodedSize();

        const header = encoder.relativeToPointer(*core.Bytecode, header_rel);
        header.size = end_size - start_size;

        try symbol_table.write(encoder, header_rel.applyOffset(@intCast(@offsetOf(core.Bytecode, "symbol_table"))));
        try address_table.write(encoder, header_rel.applyOffset(@intCast(@offsetOf(core.Bytecode, "address_table"))));

        return header_rel;
    }
};

/// Builder for bytecode symbol tables. See `core.SymbolTable`.
/// This is used to bind fully qualified names to static ids, which are then used in the `AddressTableBuilder` to bind addresses to those ids.
/// The symbol table is used to resolve names to addresses in the bytecode, which is a core part of capabilities like dynamic linking and debug symbol reference.
/// * This is a lower-level utility api used by the `HeaderBuilder`.
pub const SymbolTableBuilder = struct {
    /// Binds fully-qualified names to AddressTable ids
    map: common.StringArrayMap(core.StaticId) = .empty,

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
        /// 3. Offset the header address with `rel_addr.applyOffset(@offsetOf(core.Bytecode), "symbol_table")`.
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
                .hash = common.hash64(new_name),
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
    data: common.MultiArrayList(struct {
        kind: core.SymbolKind,
        address: Entry,
    }) = .empty,

    /// A to-be-encoded binding in an address table builder.
    pub const Entry = union(enum) {
        relative: FixupRef,
        absolute: *const anyopaque,
        inlined: struct {
            bytes: []const u8,
            alignment: core.Alignment,
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
        /// 3. Offset the header address with `rel_addr.applyOffset(@offsetOf(core.Bytecode), "address_table")`.
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
    alignment: core.Alignment = 0,
    /// A map of data locations to their references.
    /// * This is used to track locations in the data builder's memory that are yet to be determined.
    /// * The map is keyed by `DataLocation`, which is a symbolic type for locations in the data builder's memory.
    /// * The values are `DataRef`, which can either be a reference to the data builder's own memory or a standard `FixupRef`.
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
    pub const DataLocation = Id.of(DLoc, core.STATIC_ID_BITS);

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
        const location = switch (self.symbol_kind) {
            .constant => encoder.localLocationId(self.id.cast(core.Constant)),
            .global => encoder.localLocationId(self.id.cast(core.Global)),
            else => {
                log.debug("DataBuilder.encode: Invalid symbol kind {s} for data builder", .{@tagName(self.symbol_kind)});
                return error.BadEncoding;
            },
        };

        if (!try encoder.visitLocation(location)) {
            log.debug("DataBuilder.encode: {} has already been encoded, skipping", .{self.id});
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
    pub fn alignedAlloc(self: *DataBuilder, alignment: core.Alignment, len: usize) AllocWriter.Error![]u8 {
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
    pub fn alignTo(self: *DataBuilder, alignment: core.Alignment) AllocWriter.Error!void {
        const delta = common.alignDelta(self.writer.cursor, alignment);
        try self.writer.writeByteNTimes(0, delta);
    }

    /// Asserts that the current offset of the builder is aligned to the given value.
    pub fn ensureAligned(self: *DataBuilder, alignment: core.Alignment) DataBuilder.Error!void {
        if (common.alignDelta(self.writer.cursor, alignment) != 0) {
            return error.UnalignedWrite;
        }
    }
};

/// A builder for effect handler collections.
pub const HandlerSetBuilder = struct {
    /// The general allocator used by this handler set for collections.
    gpa: std.mem.Allocator,
    /// The arena allocator used by this handler set for non-volatile data.
    arena: std.mem.Allocator,
    /// The function that utilizes this handler set.
    function: ?core.FunctionId = null,
    /// The unique identifier of the handler set.
    id: core.HandlerSetId = .fromInt(0),
    /// The handlers in this set, keyed by their unique identifiers.
    handlers: HandlerMap = .empty,
    /// The register to place the cancellation operand in if this handler set is cancelled at runtime.
    register: core.Register = .r(0),
    /// A map from the upvalue ids of this handler to the local variable ids they reference in its parent function.
    upvalues: UpvalueMap = .empty,

    /// A map from upvalue ids to local variable ids, representing the immediate lexical closure of an effect within a handler set builder entry.
    pub const UpvalueMap = common.UniqueReprMap(core.UpvalueId, core.LocalId);

    /// A map from handler ids to their entries in a handler set builder.
    pub const HandlerMap = common.UniqueReprMap(core.HandlerId, Entry);

    /// Binding for an effect handler within a handler set builder.
    /// * The HandlerSetBuilder does not own the function builder
    pub const Entry = struct {
        /// The id of the effect that this handler can process.
        effect: core.EffectId = .fromInt(0),
        /// The function that implements the handler.
        function: *FunctionBuilder,
    };

    /// Initialize a new handler set builder.
    pub fn init(gpa: std.mem.Allocator, arena: std.mem.Allocator) HandlerSetBuilder {
        return HandlerSetBuilder{
            .gpa = gpa,
            .arena = arena,
        };
    }

    /// Clear the handler set builder, retaining the current memory capacity.
    pub fn clear(self: *HandlerSetBuilder) void {
        var it = self.handlers.valueIterator();
        while (it.next()) |entry| entry.deinit(self.gpa);
        self.handlers.clearRetainingCapacity();

        self.function = null;
        self.id = .fromInt(0);
        self.parent_location = .{};
        self.upvalues.clearRetainingCapacity();
        self.register = .r(0);
    }

    /// Deinitialize the handler set builder, freeing all memory associated with it.
    pub fn deinit(self: *HandlerSetBuilder) void {
        self.handlers.deinit(self.gpa);
        self.upvalues.deinit(self.gpa);
        self.* = undefined;
    }

    /// Bind a function builder to a handler set entry for a given effect identity, returning its HandlerId.
    /// * The handler id can be used with `getHandlerFunction` to retrieve the bound function builder address later.
    /// * The handler set builder does not own the function builder, so it must be deinitialized separately.
    ///   Recommended usage pattern is to use `TableBuilder` to manage statics.
    pub fn bindHandler(self: *HandlerSetBuilder, effect: core.EffectId, function: *FunctionBuilder) error{ BadEncoding, OutOfMemory }!core.HandlerId {
        if (function.parent) |parent| {
            log.debug("HandlerSetBuilder.bindHandlerFunction: function already bound to {}", .{parent});
            return error.BadEncoding;
        }

        const index = self.handlers.count();

        if (index > core.HandlerId.MAX_INT) {
            log.debug("HandlerSetBuilder.createHandler: cannot create more than {d} handlers", .{core.HandlerId.MAX_INT});
            return error.OutOfMemory;
        }

        const handler_id = core.HandlerId.fromInt(index);

        const gop = try self.handlers.getOrPut(self.gpa, handler_id);

        // sanity check: handler_id should be fresh if the map has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        gop.value_ptr.* = Entry{
            .effect = effect,
            .function = function,
        };

        return handler_id;
    }

    /// Get a handler function builder by its local handler id.
    pub fn getHandler(self: *const HandlerSetBuilder, id: core.HandlerId) ?*FunctionBuilder {
        const entry = self.handlers.getPtr(id) orelse return null;
        return entry.function;
    }

    /// Create a new upvalue within this handler, returning an id for it.
    pub fn createUpvalue(self: *HandlerSetBuilder, local_id: core.LocalId) error{OutOfMemory}!core.UpvalueId {
        const index = self.upvalues.count();

        if (index > core.UpvalueId.MAX_INT) {
            log.debug("HandlerSetBuilder.createUpvalue: Cannot create more than {d} upvalues", .{core.UpvalueId.MAX_INT});
            return error.OutOfMemory;
        }

        const upvalue_id = core.UpvalueId.fromInt(index);

        const gop = try self.upvalues.getOrPut(self.gpa, upvalue_id);

        // sanity check: upvalue_id should be fresh if the map has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        gop.value_ptr.* = local_id;

        return upvalue_id;
    }

    /// Get the local variable id of an upvalue by its id.
    /// * Returns the core.LocalId of the upvalue, inside the parent function; or null if the upvalue does not exist.
    pub fn getUpvalue(self: *const HandlerSetBuilder, id: core.UpvalueId) ?core.LocalId {
        return self.upvalues.get(id);
    }

    /// Get the location to bind for this handler set's cancellation address.
    pub fn cancellationLocation(self: *const HandlerSetBuilder) error{BadEncoding}!Location {
        return .from(self.function orelse {
            log.debug("HandlerSetBuilder.cancellationLocation: parent function not set", .{});
            return error.BadEncoding;
        }, self.id);
    }

    /// Encode the handler set into the provided encoder.
    pub fn encode(self: *const HandlerSetBuilder, maybe_upvalue_fixups: ?*const UpvalueFixupMap, encoder: *Encoder) Encoder.Error!void {
        const location = encoder.localLocationId(self.id);

        const upvalue_fixups = if (maybe_upvalue_fixups) |x| x else {
            log.debug("HandlerSetBuilder.encode: No upvalue fixups provided, skipping upvalue encoding", .{});
            return encoder.skipLocation(location);
        };

        if (!try encoder.visitLocation(location)) {
            log.debug("HandlerSetBuilder.encode: {} has already been encoded, skipping", .{self.id});
            return;
        }

        // create the core.HandlerSet and bind it to the header table
        const handler_set_rel = try encoder.createRel(core.HandlerSet);

        // bind the table entry
        try encoder.bindLocation(location, handler_set_rel);

        // create the buffer memory for the handlers
        const handlers_buf_rel = try encoder.allocRel(core.Handler, self.handlers.count());

        // write the handler set header
        const handler_set = encoder.relativeToPointer(*core.HandlerSet, handler_set_rel);
        handler_set.handlers.len = @intCast(self.handlers.count());
        handler_set.cancellation.register = self.register;

        const cancel_loc = try self.cancellationLocation();

        try encoder.bindFixup(
            .absolute,
            .{ .relative = handler_set_rel.applyOffset(@intCast(@offsetOf(core.HandlerSet, "cancellation"))).applyOffset(@intCast(@offsetOf(core.Cancellation, "address"))) },
            .{ .location = cancel_loc },
            null,
        );

        // bind the buffer to the handler set
        try encoder.bindFixup(
            .absolute,
            .{ .relative = handler_set_rel.applyOffset(@intCast(@offsetOf(core.HandlerSet, "handlers"))) },
            .{ .relative = handlers_buf_rel },
            @bitOffsetOf(core.HandlerBuffer, "ptr"),
        );

        // encode each handler in the set and create a fixup for it
        var handler_it = self.handlers.valueIterator();
        var i: usize = 0;
        while (handler_it.next()) |entry| {
            const handler_rel = handlers_buf_rel.applyOffset(@intCast(i * @sizeOf(core.Handler)));
            const handler = encoder.relativeToPointer(*core.Handler, handler_rel);

            handler.effect = entry.effect;

            try encoder.bindFixup(
                .absolute,
                .{ .relative = handler_rel.applyOffset(@intCast(@offsetOf(core.Handler, "function"))) },
                .{ .location = encoder.localLocationId(entry.function.id) },
                null,
            );

            try entry.function.encode(upvalue_fixups, encoder);

            i += 1;
        }
    }
};

/// A map from core.LocalId to core.Layout, representing the local variables of a function.
pub const LocalMap = common.UniqueReprArrayMap(core.LocalId, core.Layout);

/// A map from core.LocalId to a stack operand offset. Used by address-of instructions to resolve local variable addresses.
pub const LocalFixupMap = common.UniqueReprArrayMap(core.LocalId, u64);

/// A map from UpvalueId to a stack operand offset. Used by address-of instructions to resolve local variable addresses.
pub const UpvalueFixupMap = common.UniqueReprArrayMap(core.UpvalueId, u64);

/// A map from core.BlockId to BlockBuilder pointers, representing the basic blocks of a function.
pub const BlockMap = common.UniqueReprMap(core.BlockId, *BlockBuilder);

/// A map from HandlerSetId to HandlerSetBuilder pointers, representing the basic blocks of a function.
pub const HandlerSetMap = common.UniqueReprMap(core.HandlerSetId, *HandlerSetBuilder);

/// A simple builder API for bytecode functions.
pub const FunctionBuilder = struct {
    /// The general allocator used by this function for collections.
    gpa: std.mem.Allocator,
    /// The arena allocator used by this function for non-volatile data.
    arena: std.mem.Allocator,
    /// The function's unique identifier.
    id: core.FunctionId = .fromInt(0),
    /// The function's parent, if it is an effect handler.
    parent: ?core.FunctionId = null,
    /// The function's basic blocks, unordered.
    blocks: BlockMap = .empty,
    /// The function's local variables, unordered.
    locals: LocalMap = .empty,
    /// The function's local handler set definitions.
    handler_sets: HandlerSetMap = .empty,

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

        self.locals.clearRetainingCapacity();

        self.handler_sets.clearRetainingCapacity();

        self.id = .fromInt(0);
        self.parent = null;
    }

    /// Deinitialize the builder, freeing all memory associated with it.
    pub fn deinit(self: *FunctionBuilder) void {
        var block_it = self.blocks.valueIterator();
        while (block_it.next()) |ptr2ptr| ptr2ptr.*.deinit();

        self.blocks.deinit(self.gpa);
        self.locals.deinit(self.gpa);
        self.handler_sets.deinit(self.gpa);

        self.* = undefined;
    }

    /// Create a new local variable within this function, returning an id for it.
    pub fn createLocal(self: *FunctionBuilder, layout: core.Layout) error{OutOfMemory}!core.LocalId {
        const index = self.locals.count();

        if (index > core.LocalId.MAX_INT) {
            log.debug("FunctionBuilder.createLocal: Cannot create more than {d} locals", .{core.LocalId.MAX_INT});
            return error.OutOfMemory;
        }

        const local_id = core.LocalId.fromInt(index);
        const gop = try self.locals.getOrPut(self.gpa, local_id);

        // sanity check: local_id should be fresh if the map has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        gop.value_ptr.* = layout;

        return local_id;
    }

    /// Get the layout of a local variable by its id.
    pub fn getLocal(self: *const FunctionBuilder, id: core.LocalId) ?core.Layout {
        return self.locals.get(id);
    }

    /// Bind a handler set builder to this function builder.
    /// * The handler set builder address may be retrieved later with `getHandlerSet` and the id of the handler set,
    ///   which is accessible as a field of the builder.
    /// * The function builder does not own the handler set builder, so it must be deinitialized separately.
    ///   Recommended usage pattern is to use `TableBuilder` to manage statics.
    pub fn bindHandlerSet(self: *FunctionBuilder, builder: *HandlerSetBuilder) error{OutOfMemory}!void {
        if (builder.function) |old_function| {
            log.debug("FunctionBuilder.bindHandlerSet: Handler set builder already bound to function {}", .{old_function});
            return error.OutOfMemory;
        }

        builder.function = self.id;

        try self.handler_sets.put(self.gpa, builder.id, builder);
    }

    /// Get a pointer to a handler set builder by its handler set id.
    pub fn getHandlerSet(self: *const FunctionBuilder, id: core.HandlerSetId) ?*HandlerSetBuilder {
        return self.handler_sets.get(id);
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

        const block_id = core.BlockId.fromInt(index);
        const addr = try self.arena.create(BlockBuilder);

        const gop = try self.blocks.getOrPut(self.gpa, block_id);

        // sanity check: block_id should be fresh if the map has been mutated in append-only fashion
        std.debug.assert(!gop.found_existing);

        addr.* = BlockBuilder.init(self.gpa, self.arena);
        addr.id = block_id;
        addr.body.function = self.id;

        gop.value_ptr.* = addr;

        return addr;
    }

    /// Get a pointer to a block builder by its block id.
    pub fn getBlock(self: *const FunctionBuilder, id: core.BlockId) ?*BlockBuilder {
        return self.blocks.get(id);
    }

    /// Encode the function and all blocks into the provided encoder, inserting a fixup location for the function itself into the current region.
    pub fn encode(self: *const FunctionBuilder, maybe_upvalue_fixups: ?*const UpvalueFixupMap, encoder: *Encoder) Encoder.Error!void {
        const location = encoder.localLocationId(self.id);

        if (maybe_upvalue_fixups == null and self.parent != null) {
            log.debug("FunctionBuilder.encode: {} has a parent but no parent locals map was provided; assuming this is the top-level TableBuilder hitting a pre-declared handler function, skipping", .{self.id});
            return encoder.skipLocation(location);
        }

        if (!try encoder.visitLocation(location)) {
            log.debug("FunctionBuilder.encode: {} has already been encoded, skipping", .{self.id});
            return;
        }

        // compute stack layout and set up the local fixup map for the function
        const layouts = self.locals.values();

        const indices = try encoder.temp_allocator.alloc(u64, layouts.len);
        defer encoder.temp_allocator.free(indices);

        const offsets = try encoder.temp_allocator.alloc(u64, layouts.len);
        defer encoder.temp_allocator.free(offsets);

        const stack_layout = core.Layout.computeOptimalCommonLayout(layouts, indices, offsets);

        var local_fixups = try LocalFixupMap.init(encoder.temp_allocator, self.locals.keys(), offsets);
        defer local_fixups.deinit(encoder.temp_allocator);

        // create our header entry
        const entry_addr_rel = try encoder.createRel(core.Function);

        // bind its location to the function id
        try encoder.bindLocation(location, entry_addr_rel);

        { // function block region
            const region_token = encoder.enterRegion(self.id);
            defer encoder.leaveRegion(region_token);

            var queue: BlockVisitorQueue = .init(encoder.temp_allocator);
            defer queue.deinit();

            // write the function body

            // ensure the function's instructions are aligned
            try encoder.alignTo(core.BYTECODE_ALIGNMENT);

            const base_rel = encoder.getRelativeAddress();

            try queue.add(BlockBuilder.entry_point_id);

            while (queue.visit()) |block_id| {
                const block = self.blocks.get(block_id).?;

                try block.encode(&queue, maybe_upvalue_fixups, &local_fixups, encoder);
            }

            // certain situations, such as a block that is only reached via effect cancellation,
            // may result in a block not being encoded at all.
            // while one might argue for a "dead code elimination" principled motivation here,
            // dead code removal is not an intended feature of this api; it is an expectation
            // placed upon the caller, as with any assembler.

            // thus, we simply ensure any blocks we didn't touch via traversal get encoded at the end
            var block_it = self.blocks.valueIterator();
            while (block_it.next()) |ptr2ptr| {
                const block = ptr2ptr.*;
                try block.encode(&queue, maybe_upvalue_fixups, &local_fixups, encoder);
            }

            const upper_rel = encoder.getRelativeAddress();

            // write the function header
            const func = encoder.relativeToPointer(*core.Function, entry_addr_rel);

            func.kind = .bytecode;
            func.layout = stack_layout;

            // Add a fixup for the function's header reference
            try encoder.bindFixup(
                .absolute,
                .{ .relative = entry_addr_rel.applyOffset(@intCast(@offsetOf(core.Function, "unit"))) },
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

        // encode descendents
        var set_it = self.handler_sets.valueIterator();
        while (set_it.next()) |ptr2ptr| {
            const handler_set = ptr2ptr.*;

            // we need to create a map from UpvalueId to our local fixups;
            // we can do this by using the handler set builder's upvalues map to create a buffer of UpvalueIds matched with our existing local fixups.
            var new_upvalue_fixups: UpvalueFixupMap = .{};
            defer new_upvalue_fixups.deinit(encoder.temp_allocator);

            var handler_it = handler_set.upvalues.iterator();
            while (handler_it.next()) |pair| {
                const upvalue_id = pair.key_ptr.*;
                const local_id = pair.value_ptr.*;

                try new_upvalue_fixups.put(
                    encoder.temp_allocator,
                    upvalue_id,
                    local_fixups.get(local_id) orelse {
                        log.err("FunctionBuilder.encode: Local variable {} referenced by upvalue {} in handler set {} does not exist", .{ local_id, upvalue_id, handler_set.id });
                        return error.BadEncoding;
                    },
                );
            }

            try handler_set.encode(&new_upvalue_fixups, encoder);
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
    body: common.ArrayList(ProtoInstr) = .empty,
    /// The function that this sequence belongs to.
    function: core.FunctionId = .fromInt(0),

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
    /// * Violating some sequence invariants will result in a `BadEncoding` error, but this method is generally unsafe,
    ///   and should be considered an escape hatch where comptime bounds on the other instruction methods are too restrictive.
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
    pub fn instr(self: *SequenceBuilder, comptime code: Instruction.BasicOpCode, data: Instruction.OperandSet(code.upcast())) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .none,
        });
    }

    /// Append a two-word instruction to the sequence.
    pub fn instrWide(self: *SequenceBuilder, comptime code: Instruction.WideOpCode, data: Instruction.OperandSet(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .{ .wide_imm = wide_operand },
        });
    }

    /// Helper to get the identity type of an AddrOf proto instruction.
    pub fn AddrId(comptime code: Instruction.AddrOpCode) type {
        comptime return switch (code) {
            .addr_l => core.LocalId,
            .addr_u => core.UpvalueId,
            .addr_g => core.GlobalId,
            .addr_f => core.FunctionId,
            .addr_b => core.BuiltinId,
            .addr_x => core.ForeignAddressId,
            .addr_c => core.ConstantId,
        };
    }

    /// Append an address-of instruction to the sequence.
    pub fn instrAddrOf(self: *SequenceBuilder, comptime code: Instruction.AddrOpCode, register: core.Register, id: AddrId(code)) Encoder.Error!void {
        const Set = comptime Instruction.OperandSet(code.upcast());
        const fields = comptime std.meta.fieldNames(Set);
        const id_field = comptime fields[1];
        const set_is_enum = comptime @typeInfo(@FieldType(Set, id_field)) == .@"enum";

        comptime {
            if (std.mem.eql(u8, id_field, "R") or fields.len != 2) {
                @compileError("SequenceBuilder.instrAddrOf: out of sync with ISA; expected 'R' field to be first of two fields.");
            }
        }

        var set: Set = undefined;

        set.R = register;
        @field(set, id_field) = if (comptime !set_is_enum) @intFromEnum(id) else id;

        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), set),
            },
            .additional = .none,
        });
    }

    /// Append a call instruction to the sequence.
    pub fn instrCall(self: *SequenceBuilder, comptime code: Instruction.CallOpCode, data: Instruction.OperandSet(code.upcast()), args: Buffer.fixed(core.Register, core.MAX_REGISTERS)) Error!void {
        try self.proto(.{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .{ .call_args = args },
        });
    }

    /// Push an effect handler set onto the stack at the current sequence position.
    pub fn pushHandlerSet(self: *SequenceBuilder, handler_set: *HandlerSetBuilder) Encoder.Error!void {
        if (handler_set.function != self.function) {
            log.err("BlockBuilder.pushHandlerSet: {} does not belong to the block's parent {}", .{ handler_set.id, self.function });
            return error.BadEncoding;
        }

        try self.proto(.{
            .instruction = .{
                .code = .push_set,
                .data = .{ .push_set = .{ .H = handler_set.id } },
            },
            .additional = .none,
        });
    }

    /// Pop an effect handler set from the stack at the current sequence position.
    pub fn popHandlerSet(self: *SequenceBuilder, handler_set: *HandlerSetBuilder) Encoder.Error!void {
        if (handler_set.function != self.function) {
            log.err("BlockBuilder.popHandlerSet: {} does not belong to the block's parent {}", .{ handler_set.id, self.function });
            return error.BadEncoding;
        }

        try self.proto(.{
            .instruction = .{
                .code = .pop_set,
                .data = .{ .pop_set = .{} },
            },
            .additional = .none,
        });
    }

    /// Bind a handler set's cancellation location to the current offset in the sequence.
    /// * The instruction that is encoded next *after this call*, will be executed first after the handler set is cancelled
    /// * This allows cancellation to terminate a block and still use its terminator
    pub fn bindHandlerSetCancellationLocation(self: *SequenceBuilder, handler_set: *HandlerSetBuilder) Encoder.Error!void {
        if (handler_set.function != self.function) {
            log.err("BlockBuilder.bindHandlerSetCancellationLocation: {} does not belong to the block's parent {}", .{ handler_set.id, self.function });
            return error.BadEncoding;
        }

        try self.proto(.{
            .instruction = undefined,
            .additional = .{ .cancellation_location = try handler_set.cancellationLocation() },
        });
    }

    /// Encodes the instruction sequence into the provided encoder.
    /// Does not encode a terminator; execution will fall through.
    pub fn encode(self: *const SequenceBuilder, upvalue_fixups: ?*const UpvalueFixupMap, local_fixups: *const LocalFixupMap, encoder: *Encoder) Encoder.Error!void {
        for (self.body.items) |*pi| {
            try pi.encode(null, upvalue_fixups, local_fixups, encoder);
        }
    }
};

/// A visitor for bytecode blocks, used to track which blocks have been visited during encoding.
pub const BlockVisitor = common.Visitor(core.BlockId);

/// A queue of bytecode blocks to visit, used by the Block encoder to queue references to jump targets.
pub const BlockVisitorQueue = common.VisitorQueue(core.BlockId);

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
    id: core.BlockId = .fromInt(0),
    /// The instruction that terminates this block.
    /// * Adding any instruction when this is non-`null` is a `BadEncoding` error
    /// * For all other purposes, `null` is semantically equivalent to `unreachable`
    terminator: ?ProtoInstr = null,

    /// ID of all functions' entry point block.
    pub const entry_point_id = core.BlockId.fromInt(0);

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

    /// Append a pre-composed instruction to the block.
    /// * Violating some invariants will result in a `BadEncoding` error, but this method is generally unsafe,
    ///   and should be considered an escape hatch where comptime bounds on the other instruction methods are too restrictive.
    pub fn proto(self: *BlockBuilder, pi: ProtoInstr) Encoder.Error!void {
        try self.ensureUnterminated();

        if (pi.instruction.code.isTerm() or pi.instruction.code.isBranch()) {
            self.terminator = pi;
        } else {
            try self.body.proto(pi);
        }
    }

    /// Append a pre-composed
    /// Append a non-terminating one-word instruction to the block body.
    pub fn instr(self: *BlockBuilder, comptime code: Instruction.BasicOpCode, data: Instruction.OperandSet(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instr(code, data);
    }

    /// Append a two-word instruction to the block body.
    pub fn instrWide(self: *BlockBuilder, comptime code: Instruction.WideOpCode, data: Instruction.OperandSet(code.upcast()), wide_operand: Instruction.WideOperand(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instrWide(code, data, wide_operand);
    }

    /// Append a call instruction to the block body.
    pub fn instrCall(self: *BlockBuilder, comptime code: Instruction.CallOpCode, data: Instruction.OperandSet(code.upcast()), args: Buffer.fixed(core.Register, core.MAX_REGISTERS)) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instrCall(code, data, args);
    }

    /// Append an address-of instruction to the block body.
    pub fn instrAddrOf(self: *BlockBuilder, comptime code: Instruction.AddrOpCode, register: core.Register, id: SequenceBuilder.AddrId(code)) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.instrAddrOf(code, register, id);
    }

    /// Set the block terminator to a branch instruction.
    pub fn instrBr(self: *BlockBuilder, target: core.BlockId) Encoder.Error!void {
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
    pub fn instrBrIf(self: *BlockBuilder, condition: core.Register, then_id: core.BlockId, else_id: core.BlockId) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = .br_if,
                .data = .{ .br_if = .{ .R = condition } },
            },
            .additional = .{ .branch_target = .{ then_id, else_id } },
        };
    }

    /// Set the block terminator to a non-branching instruction.
    pub fn instrTerm(self: *BlockBuilder, comptime code: Instruction.TermOpCode, data: Instruction.OperandSet(code.upcast())) Encoder.Error!void {
        try self.ensureUnterminated();
        self.terminator = .{
            .instruction = .{
                .code = code.upcast(),
                .data = @unionInit(Instruction.OpData, @tagName(code), data),
            },
            .additional = .none,
        };
    }

    /// Push an effect handler set onto the stack at the current sequence position.
    pub fn pushHandlerSet(self: *BlockBuilder, handler_set: *HandlerSetBuilder) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.pushHandlerSet(handler_set);
    }

    /// Pop an effect handler set from the stack at the current sequence position.
    pub fn popHandlerSet(self: *BlockBuilder, handler_set: *HandlerSetBuilder) Encoder.Error!void {
        try self.ensureUnterminated();
        try self.body.popHandlerSet(handler_set);
    }

    /// Bind a handler set's cancellation location to the current offset in the sequence.
    /// * The instruction that is encoded next *after this call*, will be executed first after the handler set is cancelled
    /// * This allows cancellation to terminate a block and still use its terminator
    pub fn bindHandlerSetCancellationLocation(self: *BlockBuilder, handler_set: *HandlerSetBuilder) Encoder.Error!void {
        try self.body.bindHandlerSetCancellationLocation(handler_set);
    }

    /// Encode the block into the provided encoder, including the body instructions and the terminator.
    /// * The block's entry point is encoded as a location in the bytecode header, using the current region id and the block's id as the offset
    /// * Other blocks' ids that are referenced by instructions are added to the provided queue in order of use
    pub fn encode(self: *BlockBuilder, queue: *BlockVisitorQueue, upvalue_fixups: ?*const UpvalueFixupMap, local_fixups: *const LocalFixupMap, encoder: *Encoder) Encoder.Error!void {
        const location = encoder.localLocationId(self.id);

        if (!try encoder.visitLocation(location)) {
            log.debug("BlockBuilder.encode: {} has already been encoded, skipping", .{self.id});
            return;
        }

        try encoder.ensureAligned(core.BYTECODE_ALIGNMENT);

        // we can encode the current location as the block entry point
        try encoder.registerLocation(location);
        try encoder.bindLocation(location, encoder.getRelativeAddress());

        // first we emit all the body instructions by encoding the inner sequence
        try self.body.encode(upvalue_fixups, local_fixups, encoder);

        // now the terminator instruction, if any; same as body instructions, but can queue block ids
        if (self.terminator) |*pi| {
            try pi.encode(queue, upvalue_fixups, local_fixups, encoder);
        } else {
            // simply write the scaled opcode for `unreachable`, since it has no operands
            try encoder.writeValue(Instruction.OpCode.@"unreachable".toBits());
        }
    }

    /// Helper method that returns a `BadEncoding` error if the block is already terminated.
    pub fn ensureUnterminated(self: *BlockBuilder) Encoder.Error!void {
        if (self.terminator) |_| {
            log.debug("BlockBuilder.ensureUnterminated: {} is already terminated; cannot append additional instructions", .{self.id});
            return error.BadEncoding;
        }
    }

    comptime {
        const br_instr_names = std.meta.fieldNames(Instruction.BranchOpCode);

        if (br_instr_names.len != 2) {
            @compileError("BlockBuilder: out of sync with ISA, unhandled branch opcodes");
        }

        if (common.indexOfBuf(u8, br_instr_names, "br") == null or common.indexOfBuf(u8, br_instr_names, "br_if") == null) {
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
        call_args: Buffer.fixed(core.Register, core.MAX_REGISTERS),
        /// The destination(s) of branch instructions.
        branch_target: struct { core.BlockId, ?core.BlockId },
        /// The address of a handler set cancellation location.
        cancellation_location: Location,
    };

    /// Encode this instruction into the provided encoder at the current relative address.
    /// * Uses the `Encoder.temp_allocator` to allocate local variable fixups in the provided `LocalFixupMap`.
    /// * This method is used by the `BlockBuilder` to encode instructions into the
    /// * It is not intended to be used directly; instead, use the `BlockBuilder` methods to append instructions.
    /// * Also available are convenience methods in `Encoder` for appending instructions directly.
    /// * The queue is used to track branch targets and ensure they are visited in the correct order. Pass `null` for body sequences to ensure no branches are allowed inside.
    pub fn encode(self: *const ProtoInstr, maybe_queue: ?*BlockVisitorQueue, upvalue_fixups: ?*const UpvalueFixupMap, local_fixups: *const LocalFixupMap, encoder: *Encoder) Encoder.Error!void {
        try encoder.ensureAligned(core.BYTECODE_ALIGNMENT);

        // Cancellation locations do not encode any bytes to the stream, they simply bind a fixup location
        if (self.additional == .cancellation_location) {
            const loc = self.additional.cancellation_location;

            try encoder.registerLocation(loc);
            try encoder.bindLocation(loc, encoder.getRelativeAddress());

            return;
        }

        var instr = self.instruction;

        // We fix up the local and upvalue stack-relative addresses here, before encoding bytes to the stream
        if (self.instruction.code.isAddr()) is_addr: {
            const addr_code: Instruction.AddrOpCode = @enumFromInt(@intFromEnum(self.instruction.code));

            switch (addr_code) {
                .addr_l => {
                    const local_id: core.LocalId = @enumFromInt(self.instruction.data.addr_l.I);
                    instr.data.addr_l.I = @intCast(local_fixups.get(local_id) orelse {
                        log.err("ProtoInstr.encode: Local variable {} not found in local fixup map", .{local_id});
                        return error.BadEncoding;
                    });
                },

                .addr_u => {
                    const map = upvalue_fixups orelse {
                        log.debug("ProtoInstr.encode: Upvalue address instruction without upvalue fixup map; this is not allowed", .{});
                        return error.BadEncoding;
                    };

                    const upvalue_id: core.UpvalueId = @enumFromInt(self.instruction.data.addr_u.I);
                    instr.data.addr_u.I = @intCast(map.get(upvalue_id) orelse {
                        log.err("ProtoInstr.encode: Upvalue {} not found in upvalue fixup map", .{upvalue_id});
                        return error.BadEncoding;
                    });
                },

                .addr_g,
                .addr_f,
                .addr_b,
                .addr_x,
                .addr_c,
                => break :is_addr,
            }
        }

        const rel_addr = encoder.getRelativeAddress();
        try encoder.writeValue(instr.toBits());

        switch (self.additional) {
            .none => {},
            .cancellation_location => unreachable,
            .wide_imm => |bits| try encoder.writeValue(bits),
            .call_args => |args| try encoder.writeAll(std.mem.sliceAsBytes(args.asSlice())),
            .branch_target => |ids| {
                const then_id, const maybe_else_id = ids;
                const then_dest = encoder.localLocationId(then_id);

                const queue = maybe_queue orelse {
                    log.debug("ProtoInstr.encode: Branch instruction without a queue; this is not allowed", .{});
                    return error.BadEncoding;
                };

                switch (instr.code) {
                    .br => {
                        if (maybe_else_id) |_| {
                            log.err("BlockBuilder.encode: Branch instruction `br` cannot have an else target", .{});
                            return error.BadEncoding;
                        }

                        const then_bit_offset = @bitOffsetOf(Instruction.operand_sets.br, "I") + @bitSizeOf(Instruction.OpCode);

                        try encoder.bindFixup(
                            .relative_words,
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
                                .relative_words,
                                .{ .relative = rel_addr },
                                .{ .location = then_dest },
                                then_bit_offset,
                            );

                            try encoder.bindFixup(
                                .relative_words,
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

        try encoder.alignTo(core.BYTECODE_ALIGNMENT);
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
                    const Set = comptime Instruction.OperandSet(code);
                    const operands = &@field(self.instruction.data, opcode_name);

                    inline for (comptime std.meta.fieldNames(Set)) |operand_name| {
                        const operand = @field(operands, operand_name);
                        const Operand = @TypeOf(operand);

                        switch (Operand) {
                            core.Register => try writer.print(" {}", .{operand}),

                            core.UpvalueId,
                            core.GlobalId,
                            core.FunctionId,
                            core.BuiltinId,
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
                    item.trailing = .{ .wide_imm = switch (item.instruction.code.wideOperandKind().?) {
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

const testing = std.testing;

/// A helper struct to reduce boilerplate in tests.
fn TestBed(comptime test_name: []const u8) type {
    return struct {
        gpa: std.mem.Allocator,
        builder: TableBuilder,

        fn init() !TestBed(test_name) {
            log.debug("Begin test \"{s}\"", .{test_name});
            var self: TestBed(test_name) = undefined;
            self.gpa = std.testing.allocator;
            self.builder = TableBuilder.init(self.gpa, null);
            // testing.log_level = .debug;
            return self;
        }

        fn deinit(self: *TestBed(test_name)) void {
            self.builder.deinit();
            log.debug("End test \"{s}\"", .{test_name});
        }
    };
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

    const main_func = table.bytecode.get(main_id);
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

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    const expected =
        \\    bit_copy64c r0 .. I:0000000000000001
        \\    br I:0001
        \\    bit_copy64c r0 .. I:0000000000000002
        \\    return r0
        \\    bit_copy64c r0 .. I:00000000000003e7
        \\    halt
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
        const main_func = table.bytecode.get(main_id);
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
        const add_func = table.bytecode.get(add_id);
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

    try entry_block.instrAddrOf(.addr_c, .r0, const_id);
    try entry_block.instr(.load64, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    try entry_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Check that the loaded constant is correct
    const data: *const core.Constant = table.bytecode.get(const_id);
    const data_ptr: *const u64 = @alignCast(@ptrCast(data.asPtr()));
    try testing.expectEqual(@as(u64, 0xCAFEBABE_DECAF_BAD), data_ptr.*);

    // Check disassembly
    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();
    const main_func = table.bytecode.get(main_id);
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

test "block builder error on double-termination" {
    var tb = try TestBed("block builder error on double-termination").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var block = try main_fn.createBlock();
    try block.instrTerm(.halt, .{});
    try testing.expectError(error.BadEncoding, block.instrTerm(.@"return", .{ .R = .r0 }));
}

test "table builder error on wrong static kind" {
    var tb = try TestBed("table builder error on wrong static kind").init();
    defer tb.deinit();

    // Create a constant ID
    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "my_const");

    // Try to create a function builder with it, should fail.
    try testing.expectError(error.BadEncoding, tb.builder.createFunctionBuilder(const_id.cast(core.Function)));

    // Create a function ID
    const func_id: core.FunctionId = try tb.builder.createHeaderEntry(.function, "my_func");

    // Try to create a data builder with it, should fail.
    try testing.expectError(error.BadEncoding, tb.builder.createDataBuilder(func_id));
}

test "encode local variable reference" {
    var tb = try TestBed("encode local variable reference").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    const local_a = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_b = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_c = try main_fn.createLocal(.{ .size = 32, .alignment = 16 });

    var entry_block = try main_fn.createBlock();

    try entry_block.instrAddrOf(.addr_l, .r1, local_b);
    try entry_block.instrAddrOf(.addr_l, .r1, local_a);
    try entry_block.instrAddrOf(.addr_l, .r1, local_c);

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    const expected =
        \\    addr_l r1 I:0028
        \\    addr_l r1 I:0020
        \\    addr_l r1 I:0000
        \\    unreachable
        \\
    ;
    try testing.expectEqualStrings(expected, disas_buf.items);
}

test "encode function with conditional branch" {
    var tb = try TestBed("encode function with conditional branch").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    var entry_block = try main_fn.createBlock();
    var then_block = try main_fn.createBlock();
    var else_block = try main_fn.createBlock();
    var merge_block = try main_fn.createBlock();

    // entry: if (r0 != 0) goto then_block else goto else_block
    try entry_block.instrWide(.bit_copy64c, .{ .R = .r0 }, 1); // condition will be true
    try entry_block.instrBrIf(.r0, then_block.id, else_block.id);

    // then: r1 = 1; goto merge_block
    try then_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 1);
    try then_block.instrBr(merge_block.id);

    // else: r1 = 2; goto merge_block
    try else_block.instrWide(.bit_copy64c, .{ .R = .r1 }, 2);
    try else_block.instrBr(merge_block.id);

    // merge: return r1
    try merge_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();

    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    // Expected offsets are calculated based on sequential layout of visited blocks: entry, then, else, merge.
    // br_if (word 2) -> then (word 3, offset +1), else (word 6, offset +4)
    // br in then (word 5) -> merge (word 9, offset +4)
    // br in else (word 8) -> merge (word 9, offset +1)
    const expected =
        \\    bit_copy64c r0 .. I:0000000000000001
        \\    br_if r0 Ix:0001 Iy:0004
        \\    bit_copy64c r1 .. I:0000000000000001
        \\    br I:0004
        \\    bit_copy64c r1 .. I:0000000000000002
        \\    br I:0001
        \\    return r1
        \\
    ;
    try testing.expectEqualStrings(expected, disas_buf.items);
}

test "data builder with internal pointer fixup" {
    var tb = try TestBed("data builder with internal pointer fixup").init();
    defer tb.deinit();

    const Node = struct {
        value: u64,
        next: ?*const @This(),
    };

    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "linked_list");
    const data_builder = try tb.builder.createDataBuilder(const_id);
    data_builder.alignment = @alignOf(Node);

    // Node 1
    const node1_rel = data_builder.getRelativeAddress();
    _ = node1_rel;
    try data_builder.writeValue(@as(u64, 111));
    const node1_next_rel = data_builder.getRelativeAddress();
    try data_builder.writeValue(@as(?*const Node, null)); // placeholder for next pointer

    // Node 2
    const node2_rel = data_builder.getRelativeAddress();
    try data_builder.writeValue(@as(u64, 222));
    try data_builder.writeValue(@as(?*const Node, null)); // next is null for the last node

    // Fixup Node 1's next pointer to point to Node 2
    try data_builder.bindFixup(.absolute, node1_next_rel, .{ .internal = .{ .relative = node2_rel } }, null);

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify the structure after encoding and linking
    const data: *const core.Constant = table.bytecode.get(const_id);
    const node1_ptr: *const Node = @alignCast(@ptrCast(data.asPtr()));

    try testing.expectEqual(@as(u64, 111), node1_ptr.value);
    try testing.expect(node1_ptr.next != null);

    const node2_ptr = node1_ptr.next orelse unreachable;
    try testing.expectEqual(@as(u64, 222), node2_ptr.value);
    try testing.expect(node2_ptr.next == null);

    // Check that node2_ptr is at the correct offset from node1_ptr
    const offset = @as(isize, @intCast(@intFromPtr(node2_ptr))) - @as(isize, @intCast(@intFromPtr(node1_ptr)));
    try testing.expectEqual(@as(isize, @sizeOf(Node)), offset);
}

test "data builder with external function pointer fixup" {
    var tb = try TestBed("data builder with external function pointer fixup").init();
    defer tb.deinit();

    const StructWithFnPtr = struct {
        id: u64,
        handler: ?*const fn () void,
    };

    const func_id = try tb.builder.createHeaderEntry(.function, "my_func");
    var fn_builder = try tb.builder.createFunctionBuilder(func_id);
    var entry = try fn_builder.createBlock();
    try entry.instrTerm(.halt, .{});

    const const_id: core.ConstantId = try tb.builder.createHeaderEntry(.constant, "my_struct");
    var data_builder = try tb.builder.createDataBuilder(const_id);
    data_builder.alignment = @alignOf(StructWithFnPtr);

    const func_loc = tb.builder.getStaticLocation(func_id.cast(anyopaque)).?;

    // Write placeholder struct
    try data_builder.writeValue(@as(u64, 42)); // id
    const handler_ptr_rel = data_builder.getRelativeAddress();
    try data_builder.writeValue(@as(?*const fn () void, null)); // handler placeholder

    // Bind a fixup to patch the handler address later
    try data_builder.bindFixup(.absolute, handler_ptr_rel, .{ .standard = .{ .location = func_loc } }, null);

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify
    const data: *const core.Constant = table.bytecode.get(const_id);
    const my_struct_ptr: *const StructWithFnPtr = @alignCast(@ptrCast(data.asPtr()));

    const func_ptr = table.bytecode.get(func_id);

    try testing.expectEqual(@as(u64, 42), my_struct_ptr.id);
    try testing.expect(my_struct_ptr.handler == @as(?*const fn () void, @ptrCast(func_ptr)));
}

test "decoder with incomplete wide instruction" {
    const gpa = testing.allocator;

    var instructions = try gpa.alloc(core.InstructionBits, 1);
    defer gpa.free(instructions);

    // bit_copy64c is a wide instruction, so it requires a second word for its immediate value.
    const instr = Instruction{ .code = .bit_copy64c, .data = .{ .bit_copy64c = .{ .R = .r1 } } };
    instructions[0] = instr.toBits();

    var decoder = Decoder.init(instructions);
    // The decoder should find the first word, but fail to read the second.
    try testing.expectError(error.BadEncoding, decoder.next());
}

test "decoder with incomplete call instruction" {
    const gpa = testing.allocator;
    var instructions = try gpa.alloc(core.InstructionBits, 1);
    defer gpa.free(instructions);

    // call_c with I=2 expects 16 bytes (2 words) of arguments after it.
    const instr = Instruction{ .code = .call_c, .data = .{ .call_c = .{ .R = .r0, .F = .fromInt(1), .I = 2 } } };
    instructions[0] = instr.toBits();

    var decoder = Decoder.init(instructions);
    // The decoder should see the call, but fail to read the arguments.
    try testing.expectError(error.BadEncoding, decoder.next());
}

test "encode handler set" {
    var tb = try TestBed("encode handler set").init();
    defer tb.deinit();

    // IDs for our functions and effects
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.builder.createHeaderEntry(.function, "my_handler");
    const handler_set_id = try tb.builder.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.builder.createHeaderEntry(.effect, "my_effect");
    try tb.builder.bindEffect(effect_id, @enumFromInt(0));

    // Main function builder
    var main_fn = try tb.builder.createFunctionBuilder(main_id);

    // Handler function builder
    var handler_fn = try tb.builder.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();
    try handler_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 42); // return 42
    try handler_entry.instrTerm(.@"return", .{ .R = .r0 });

    // Handler set builder
    var handler_set = try tb.builder.createHandlerSet(handler_set_id);
    _ = try handler_set.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set);

    // Main function body
    var main_entry = try main_fn.createBlock();
    try main_entry.pushHandlerSet(handler_set);
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try main_entry.popHandlerSet(handler_set);
    try main_entry.instrTerm(.@"return", .{ .R = .r0 });

    // Encode
    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify main function disassembly
    {
        var disas_buf = std.ArrayList(u8).init(tb.gpa);
        defer disas_buf.deinit();
        const main_func = table.bytecode.get(main_id);
        const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
        try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

        const expected_main =
            \\    push_set H:00000002
            \\    prompt r0 E:00000003 I:00 .. ()
            \\    pop_set
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_main, disas_buf.items);
    }

    // Verify handler function disassembly
    {
        var disas_buf = std.ArrayList(u8).init(tb.gpa);
        defer disas_buf.deinit();
        const handler_func: *const core.Function = table.bytecode.get(handler_fn_id);
        const code_slice = handler_func.extents.base[0..@divExact(@intFromPtr(handler_func.extents.upper) - @intFromPtr(handler_func.extents.base), @sizeOf(core.InstructionBits))];
        try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

        const expected_handler =
            \\    bit_copy64c r0 .. I:000000000000002a
            \\    return r0
            \\
        ;
        try testing.expectEqualStrings(expected_handler, disas_buf.items);
    }
}

test "encode handler set with cancellation" {
    var tb = try TestBed("encode handler set with cancellation").init();
    defer tb.deinit();

    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.builder.createHeaderEntry(.function, "cancelling_handler");
    const handler_set_id = try tb.builder.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.builder.createHeaderEntry(.effect, "my_effect");
    try tb.builder.bindEffect(effect_id, @enumFromInt(0));

    var handler_fn = try tb.builder.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();
    try handler_entry.instrWide(.bit_copy64c, .{ .R = .r0 }, 99);
    try handler_entry.instrTerm(.cancel, .{ .R = .r0 });

    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();
    var cancel_block = try main_fn.createBlock();

    var handler_set = try tb.builder.createHandlerSet(handler_set_id);
    try main_fn.bindHandlerSet(handler_set);
    handler_set.register = .r1;

    _ = try handler_set.bindHandler(effect_id, handler_fn);

    // Entry block: push, prompt, then branch to the cancellation block to ensure it's assembled
    try entry_block.pushHandlerSet(handler_set);
    try entry_block.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try entry_block.instrTerm(.halt, .{});

    // Cancellation block: pop and return value
    try cancel_block.popHandlerSet(handler_set);
    try cancel_block.bindHandlerSetCancellationLocation(handler_set);
    try cancel_block.instrTerm(.@"return", .{ .R = .r1 });

    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    const main_func = table.bytecode.get(main_id);
    const set: *const core.HandlerSet = table.bytecode.get(handler_set_id);
    const cancel_addr = set.cancellation.address;

    // The entry block has 3 instructions (push, prompt, br), taking 3 words.
    // The cancellation block should therefore start at an offset of 3 words from the function base.
    // The cancellation address should be after the pop instruction, which is the first instruction in the cancel block, meaning a total of 4 word offset.
    const cancel_block_start_addr = @intFromPtr(main_func.extents.base) + 4 * @sizeOf(core.InstructionBits);
    try testing.expectEqual(cancel_block_start_addr, @intFromPtr(cancel_addr));
    try testing.expectEqual(core.Register.r1, set.cancellation.register);
}

test "encode handler set with upvalues" {
    var tb = try TestBed("encode handler set with upvalues").init();
    defer tb.deinit();

    // IDs
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    const handler_fn_id = try tb.builder.createHeaderEntry(.function, "upvalue_handler");
    const handler_set_id = try tb.builder.createHeaderEntry(.handler_set, null);
    const effect_id = try tb.builder.createHeaderEntry(.effect, "my_effect");
    try tb.builder.bindEffect(effect_id, @enumFromInt(0));

    // Main function with locals
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    const local_x = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });
    const local_y = try main_fn.createLocal(.{ .size = 8, .alignment = 8 });

    // Handler function that uses upvalues
    var handler_fn = try tb.builder.createFunctionBuilder(handler_fn_id);
    var handler_entry = try handler_fn.createBlock();

    // Handler set that captures locals as upvalues
    var handler_set = try tb.builder.createHandlerSet(handler_set_id);
    const upvalue_y = try handler_set.createUpvalue(local_y);
    _ = try handler_set.bindHandler(effect_id, handler_fn);
    try main_fn.bindHandlerSet(handler_set);

    // Now define the handler body using the upvalue id
    try handler_entry.instrAddrOf(.addr_u, .r0, upvalue_y);
    try handler_entry.instr(.load64, .{ .Rx = .r1, .Ry = .r0, .I = 0 });
    try handler_entry.instrTerm(.@"return", .{ .R = .r1 });

    // Main function body
    var main_entry = try main_fn.createBlock();
    // Initialize local y to 123
    try main_entry.instrAddrOf(.addr_l, .r0, local_y);
    try main_entry.instrWide(.bit_copy64c, .{ .R = .r1 }, 123);
    try main_entry.instr(.store64, .{ .Rx = .r0, .Ry = .r1, .I = 0 });
    _ = local_x; // to ensure it gets a stack slot and affects layout

    // Prompt the effect
    try main_entry.pushHandlerSet(handler_set);
    try main_entry.instrCall(.prompt, .{ .R = .r0, .E = effect_id, .I = 0 }, .{});
    try main_entry.popHandlerSet(handler_set);
    try main_entry.instrTerm(.halt, .{});

    // Encode
    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verify handler function disassembly
    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();
    const h_func: *const core.Function = table.bytecode.get(handler_fn_id);
    const code_slice = h_func.extents.base[0..@divExact(@intFromPtr(h_func.extents.upper) - @intFromPtr(h_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    const expected_handler =
        \\    addr_u r0 I:0008
        \\    load64 r1 r0 I:00000000
        \\    return r1
        \\
    ;
    try testing.expectEqualStrings(expected_handler, disas_buf.items);
}

// This is just a placeholder for the test. It won't be called.
fn dummyBuiltinProc(fiber: *core.Fiber) callconv(.C) core.Builtin.Signal {
    _ = fiber;
    return core.Builtin.Signal.@"return";
}

test "bind builtin function" {
    var tb = try TestBed("bind builtin function").init();
    defer tb.deinit();

    // Create an entry for the builtin function
    const builtin_id: core.BuiltinId = try tb.builder.createHeaderEntry(.builtin, "my_builtin_func");

    // Bind the native Zig function to the ID
    try tb.builder.bindBuiltinProcedure(builtin_id, dummyBuiltinProc);

    // Create a main function to test calling this builtin
    const main_id = try tb.builder.createHeaderEntry(.function, "main");
    var main_fn = try tb.builder.createFunctionBuilder(main_id);
    var entry_block = try main_fn.createBlock();

    // Call the builtin function
    try entry_block.instrCall(.call_c, .{ .R = .r0, .F = builtin_id.cast(core.Function), .I = 0 }, .{});
    try entry_block.instrTerm(.halt, .{});

    // Encode the table
    var table = try tb.builder.encode(tb.gpa);
    defer table.deinit();

    // Verification
    // 1. Check the address in the header
    const builtin_addr: *const core.Builtin = table.bytecode.get(builtin_id);
    try testing.expectEqual(builtin_addr.kind, .builtin);
    try testing.expectEqual(@intFromPtr(&dummyBuiltinProc), builtin_addr.addr);

    // 2. Check the disassembly
    var disas_buf = std.ArrayList(u8).init(tb.gpa);
    defer disas_buf.deinit();
    const main_func = table.bytecode.get(main_id);
    const code_slice = main_func.extents.base[0..@divExact(@intFromPtr(main_func.extents.upper) - @intFromPtr(main_func.extents.base), @sizeOf(core.InstructionBits))];
    try disas(code_slice, .{ .buffer_address = false }, disas_buf.writer());

    const expected_disas =
        \\    call_c r0 F:00000000 I:00 .. ()
        \\    halt
        \\
    ;
    try testing.expectEqualStrings(expected_disas, disas_buf.items);
}
