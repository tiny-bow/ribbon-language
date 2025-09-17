//! Builder for bytecode symbol tables. See `core.SymbolTable`.
//! This is used to bind fully qualified names to static ids, which are then used in the `AddressTableBuilder` to bind addresses to those ids.
//! The symbol table is used to resolve names to addresses in the bytecode, which is a core part of capabilities like dynamic linking and debug symbol reference.
//! * This is a lower-level utility api used by the `HeaderBuilder`.

const SymbolTableBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_symbol_table_builder);

const core = @import("core");
const common = @import("common");
const binary = @import("binary");

test {
    // std.debug.print("semantic analysis for bytecode SymbolTableBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

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
        log.debug("SymbolTableBuilder.bind: Failed to export {f}; Name string cannot be empty", .{id});
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
    keys: binary.RelativeAddress,
    values: binary.RelativeAddress,
    len: u32,

    /// Helper function
    /// Expected usage:
    /// 1. Reserve bytecode header space at the start of encoding region.
    /// 2. Generate the address table with `SymbolTableBuilder.encode`, returning this structure.
    /// 3. Off set the header address with `rel_addr.applyOffset(@offsetOf(core.Bytecode), "symbol_table")`.
    /// 4. Pass the off set relative address to this method.
    /// 5. Finalize the encoder with `binary.Encoder.finalize` in order for fixups added by this function to complete patching of the header.
    pub fn write(self: *const ProtoSymbolTable, encoder: *binary.Encoder, table_rel: binary.RelativeAddress) binary.Encoder.Error!void {
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
pub fn encode(self: *const SymbolTableBuilder, encoder: *binary.Encoder) binary.Encoder.Error!ProtoSymbolTable {
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
