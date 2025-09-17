//! Builder for bytecode headers. See `core.Bytecode`.
//! * This is a lower-level utility api used by the `TableBuilder`.
const HeaderBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_header_builder);

const binary = @import("binary");
const core = @import("core");
const common = @import("common");

const bytecode = @import("../bytecode.zig");

test {
    // std.debug.print("semantic analysis for bytecode HeaderBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

/// Binds *fully-qualified* names to AddressTable ids
symbol_table: bytecode.SymbolTableBuilder = .{},
/// Binds bytecode ids to addresses for the function being compiled
address_table: bytecode.AddressTableBuilder = .{},

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
    address: bytecode.AddressTableBuilder.Entry,
) error{OutOfMemory}!core.StaticId {
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
    address: bytecode.AddressTableBuilder.Entry,
) error{ BadEncoding, OutOfMemory }!core.StaticId {
    const id = try self.bindAddress(allocator, kind, address);
    try self.exportStatic(allocator, name, id);
    return id;
}

/// Encode the current state of the table into a `core.Bytecode` structure, returning its relative address.
pub fn encode(self: *const HeaderBuilder, encoder: *binary.Encoder) binary.Encoder.Error!binary.RelativeAddress {
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
