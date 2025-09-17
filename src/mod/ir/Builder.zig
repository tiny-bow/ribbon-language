const Builder = @This();

const std = @import("std");
const log = std.log.scoped(.ir_builder);

const core = @import("core");

const ir = @import("../ir.zig");

test {
    // std.debug.print("semantic analysis for ir builder\n", .{});
    std.testing.refAllDecls(@This());
}

fn getContext(self: *Builder) *ir.Context {
    return @alignCast(@fieldParentPtr("builder", self));
}

pub fn type_set_kind(self: *Builder, key_kind: ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.kind, .{
        .output_tag = try ctx.internPrimitive(ir.KindTag.set),
        .input_kinds = try ctx.internList(.kind, &.{key_kind}),
    });
}

pub fn type_map_kind(self: *Builder, key_set_kind: ir.Ref, val_set_kind: ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.kind, .{
        .output_tag = try ctx.internPrimitive(ir.KindTag.map),
        .input_kinds = try ctx.internList(.kind, &.{
            key_set_kind,
            val_set_kind,
        }),
    });
}

pub fn type_set_constructor(self: *Builder, key_kind: ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.constructor, .{
        .kind = try self.type_set_kind(key_kind),
    });
}

pub fn type_map_constructor(self: *Builder, key_set_kind: ir.Ref, val_set_kind: ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.constructor, .{
        .kind = try self.type_map_kind(key_set_kind, val_set_kind),
    });
}

pub fn integer_type(self: *Builder, signedness: core.Signedness, bit_size: core.Alignment) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.type, .{
        .constructor = try ctx.getBuiltin(.integer_constructor),
        .input_types = try ctx.internList(.type, &.{
            try ctx.internStructure(.constant, .{
                .type = try ctx.getBuiltin(.interned_bytes_type),
                .value = try ctx.internBuffer(std.mem.asBytes(&signedness)),
            }),
            try ctx.internStructure(.constant, .{
                .type = try ctx.getBuiltin(.interned_bytes_type),
                .value = try ctx.internBuffer(std.mem.asBytes(&bit_size)),
            }),
        }),
    });
}

pub fn symbol(self: *Builder, name: []const u8) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.type, .{
        .constructor = try ctx.getBuiltin(.symbol_constructor),
        .input_types = try ctx.internList(.type, &.{try ctx.internName(name)}),
    });
}

pub fn type_set_type(self: *Builder, key_kind: ir.Ref, keys: []const ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.type, .{
        .constructor = try self.type_set_constructor(key_kind),
        .input_types = try ctx.internList(.type, keys),
    });
}

pub fn type_map_type(self: *Builder, key_kind: ir.Ref, val_kind: ir.Ref, keys: []const ir.Ref, vals: []const ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    return ctx.internStructure(.type, .{
        .constructor = try self.type_map_constructor(
            try self.type_set_kind(key_kind),
            try self.type_set_kind(val_kind),
        ),
        .input_types = try ctx.internList(.type, &.{
            try self.type_set_type(key_kind, keys),
            try self.type_set_type(val_kind, vals),
        }),
    });
}

/// * Note: While the frontend type system uses marker types to distinguish the order of structure fields,
/// here we do not use unordered sets; thus the order of the lists is used to encode the order.
/// * The `layout` must be a symbol of the set `{'c, 'packed}`
pub fn struct_type(self: *Builder, layout: ir.Ref, names: []const ir.Ref, types: []const ir.Ref) !ir.Ref {
    const ctx = self.getContext();

    const k_data = try ctx.getBuiltin(.data_kind);

    return ctx.internStructure(.type, .{
        .constructor = try ctx.getBuiltin(.struct_constructor),
        .input_types = try ctx.internList(.type, &.{
            layout,
            try self.type_map_type(
                k_data,
                k_data,
                names,
                types,
            ),
        }),
    });
}
