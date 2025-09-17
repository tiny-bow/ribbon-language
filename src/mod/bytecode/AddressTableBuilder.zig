//! A builder for bytecode address tables. See `core.AddressTable`.
//! This is used to bind static ids to addresses of constants, functions, and other static values.
//! The address table is a core part of the bytecode, as it allows the bytecode to reference static values by id,
//! which can then be resolved to addresses at runtime or during linking.
//! The address table builder supports both relative and absolute addresses, as well as inlined data for static values that are not directly addressable.
//! Like the rest of the `bytecode` module infrastructure, this supports fixups, which are used to resolve addresses that are not known at the time of encoding.
//! * This is a lower-level utility api used by the `HeaderBuilder`.

const AddressTableBuilder = @This();

const std = @import("std");
const log = std.log.scoped(.bytecode_address_table_builder);

const core = @import("core");
const common = @import("common");
const binary = @import("binary");

test {
    // std.debug.print("semantic analysis for bytecode AddressTableBuilder\n", .{});
    std.testing.refAllDecls(@This());
}

data: common.MultiArrayList(struct {
    kind: core.SymbolKind,
    address: Entry,
}) = .empty,

/// A to-be-encoded binding in an address table builder.
pub const Entry = union(enum) {
    relative: binary.FixupRef,
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
    addresses: binary.RelativeAddress,
    kinds: binary.RelativeAddress,
    len: u32,

    /// Helper function
    /// Expected usage:
    /// 1. Reserve bytecode header space at the start of encoding region.
    /// 2. Generate the address table with `AddressTableBuilder.encode`, returning this structure.
    /// 3. Off set the header address with `rel_addr.applyOffset(@offsetOf(core.Bytecode), "address_table")`.
    /// 4. Pass the off set relative address to this method.
    /// 5. Finalize the encoder with `binary.Encoder.finalize` in order for fixups added by this function to complete patching of the header.
    pub fn write(self: *const ProtoAddressTable, encoder: *binary.Encoder, table_rel: binary.RelativeAddress) binary.Encoder.Error!void {
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
pub fn encode(self: *const AddressTableBuilder, encoder: *binary.Encoder) binary.Encoder.Error!ProtoAddressTable {
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
