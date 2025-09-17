//! initializers for builtin constructs. See `ir.Context.getBuiltin`.
const builtins = @This();

const std = @import("std");
const log = std.log.scoped(.ir_builtins);

const ir = @import("../ir.zig");

test {
    // std.debug.print("semantic analysis for ir builtins\n", .{});
    std.testing.refAllDecls(@This());
}

pub fn data_kind(ctx: *ir.Context) !ir.Ref {
    return ctx.internStructure(.kind, .{
        .output_tag = try ctx.internPrimitive(ir.KindTag.data),
        .input_kinds = ir.Ref.nil,
    });
}

pub fn interned_bytes_constructor(ctx: *ir.Context) !ir.Ref {
    return ctx.internStructure(.constructor, .{
        .kind = try ctx.getBuiltin(.primitive_kind),
    });
}

pub fn interned_bytes_type(ctx: *ir.Context) !ir.Ref {
    return ctx.internStructure(.type, .{
        .constructor = try ctx.getBuiltin(.interned_bytes_constructor),
        .input_types = try ctx.internList(.type, &.{}),
    });
}

pub fn primitive_kind(ctx: *ir.Context) !ir.Ref {
    return ctx.internStructure(.kind, .{
        .output_tag = try ctx.internPrimitive(ir.KindTag.primitive),
        .input_kinds = ir.Ref.nil,
    });
}

pub fn data_type_set_kind(ctx: *ir.Context) !ir.Ref {
    return ctx.builder.type_set_kind(try ctx.getBuiltin(.data_kind));
}

pub fn data_type_map_kind(ctx: *ir.Context) !ir.Ref {
    return ctx.builder.type_map_kind(
        try ctx.getBuiltin(.data_type_set_kind),
        try ctx.getBuiltin(.data_type_set_kind),
    );
}

pub fn integer_constructor(ctx: *ir.Context) !ir.Ref {
    const k_primitive = try ctx.getBuiltin(.primitive_kind);

    return ctx.internStructure(.constructor, .{
        .kind = try ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(ir.KindTag.primitive),
            .input_kinds = try ctx.internList(.kind, &.{ k_primitive, k_primitive }),
        }),
    });
}

pub fn symbol_constructor(ctx: *ir.Context) !ir.Ref {
    const k_arrow = try ctx.internStructure(.kind, .{
        .output_tag = try ctx.internPrimitive(ir.KindTag.primitive),
        .input_kinds = try ctx.internList(.kind, &.{try ctx.getBuiltin(.primitive_kind)}),
    });

    return ctx.internStructure(.constructor, .{
        .kind = k_arrow,
    });
}

pub fn struct_constructor(ctx: *ir.Context) !ir.Ref {
    return ctx.internStructure(.constructor, .{
        .kind = try ctx.internStructure(.kind, .{
            .output_tag = try ctx.internPrimitive(ir.KindTag.structure),
            .input_kinds = try ctx.internList(.kind, &.{
                try ctx.getBuiltin(.primitive_kind), // layout
                try ctx.getBuiltin(.data_type_map_kind), // field names -> types
            }),
        }),
    });
}

pub fn c_symbol(ctx: *ir.Context) !ir.Ref {
    return ctx.builder.symbol("c");
}

pub fn packed_symbol(ctx: *ir.Context) !ir.Ref {
    return ctx.builder.symbol("packed");
}
