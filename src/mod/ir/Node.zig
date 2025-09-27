//! Body data type for data nodes.
const Node = @This();

const std = @import("std");
const log = std.log.scoped(.ir_node);

const common = @import("common");

const ir = @import("../ir.zig");

test {
    // std.debug.print("semantic analysis for ir Node\n", .{});
    std.testing.refAllDecls(@This());
}

/// The kind of the data stored here.
kind: ir.NodeKind,
/// The untagged union of the data that can be stored here.
content: ir.Data,

/// Creates a deep copy of the node, duplicating any owned memory.
pub fn dupe(self: *const Node, allocator: std.mem.Allocator) !Node {
    var new_node = self.*;

    switch (self.kind.getTag()) {
        .data => switch (ir.discriminants.force(ir.DataKind, self.kind.getDiscriminator())) {
            // Buffer is the only data kind that owns memory
            .buffer => new_node.content.buffer = try self.content.buffer.clone(allocator),
            // Name and Source are always interned
            .nil, .name, .source => {},
        },
        // Structures and collections both use ref_list, which owns memory
        .structure, .collection => {
            new_node.content.ref_list = try self.content.ref_list.clone(allocator);
        },
        .nil, .primitive => {},
    }

    return new_node;
}

/// Deinitialize the node, freeing any owned memory.
/// * This is a no-op for nodes that do not own memory.
/// * This should only be called on nodes that were created outside of a context and never added to one.
pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
    switch (self.kind.getTag()) {
        .data => switch (self.kind.getDiscriminator()) {
            .buffer => self.content.buffer.deinit(allocator),
            else => {},
        },
        .structure, .collection => self.content.ref_list.deinit(allocator),
        else => {},
    }
}

/// Create a data node outside of a context, given a data kind and data.
pub fn data(comptime kind: ir.DataKind, value: ir.DataType(kind)) !Node {
    return Node{
        .kind = ir.NodeKind.data(kind),
        .content = @unionInit(ir.Data, @tagName(kind), value),
    };
}

/// Create a primitive node outside of a context, given a primitive value.
/// * The value must be a primitive type, such as an integer, index, or opcode.
pub fn primitive(value: anytype) !Node {
    const T = comptime @TypeOf(value);

    inline for (comptime std.meta.fieldNames(@TypeOf(ir.primitives))) |field| {
        const field_type = comptime @field(ir.primitives, field);

        if (comptime T == field_type) {
            const converter = @field(ir.primitive_converters, field);

            return Node{
                .kind = ir.NodeKind.primitive(@field(ir.PrimitiveKind, field)),
                .content = .{ .primitive = converter(value) },
            };
        }
    } else {
        @compileError("Non-primitive type " ++ @typeName(T));
    }
}

/// Create a structure node outside of a context, given a structure kind and data.
/// * The initializer must be a struct with the same fields as the structure kind.
/// * Comptime and runtime checking is employed to ensure the initializer field refs are the right kinds.
/// * Allocator should be that of the context that will own the node.
pub fn structure(allocator: std.mem.Allocator, comptime kind: ir.StructureKind, value: anytype) !Node {
    const struct_name = comptime @tagName(kind);
    const T = comptime @FieldType(@TypeOf(ir.structures), struct_name);
    const structure_decls = comptime std.meta.fields(T);
    const structure_value = @field(ir.structures, struct_name);

    var ref_list = common.ArrayList(ir.Ref).empty;
    try ref_list.ensureTotalCapacity(allocator, structure_decls.len);
    errdefer ref_list.deinit(allocator);

    inline for (structure_decls) |decl| {
        const decl_info = @typeInfo(decl.type);
        const decl_value = @field(structure_value, decl.name);
        const init_value: ir.Ref = @field(value, decl.name);

        switch (decl_info) {
            .enum_literal => {
                if (comptime std.mem.eql(u8, @tagName(decl_value), "any")) {
                    ref_list.appendAssumeCapacity(init_value);
                } else {
                    @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));
                }
            },
            .@"struct" => |info| {
                if (!info.is_tuple) @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));
                if (info.fields.len != 2) @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));

                const node_kind = comptime ir.NodeKind{
                    .tag = @intFromEnum(@field(ir.Tag, @tagName(decl_value[0]))),
                    .discriminator = @intFromEnum(@field(ir.Discriminator, @tagName(decl_value[1]))),
                };

                const ta = node_kind.getTag();
                const tb = init_value.node_kind.getTag();

                const da = node_kind.getDiscriminator();
                const db = init_value.node_kind.getDiscriminator();

                if ((tb == ta or ta == .nil or tb == .nil) and
                    (db == da or da == .nil or db == .nil))
                {
                    ref_list.appendAssumeCapacity(init_value);
                } else {
                    log.debug("Unexpected node kind for structure {s} field decl {s}: expected {f}, got {f}", .{
                        struct_name,
                        decl.name,
                        node_kind,
                        init_value.node_kind,
                    });

                    return error.InvalidNodeKind;
                }
            },
            else => {
                @compileError("Unexpected type for structure " ++ struct_name ++ " field decl " ++ decl.name ++ ": " ++ @typeName(decl.type));
            },
        }
    }

    return Node{
        .kind = ir.NodeKind.structure(kind),
        .content = .{
            .ref_list = ref_list,
        },
    };
}

/// Create a data buffer node outside of a context, given a buffer of bytes.
/// * Allocator should be that of the context that will own the node.
pub fn buffer(allocator: std.mem.Allocator, init: []const u8) !Node {
    var arr = try common.ArrayList(u8).initCapacity(allocator, init.len);
    errdefer arr.deinit(allocator);

    arr.appendSliceAssumeCapacity(init);

    return Node{
        .kind = ir.NodeKind.data(.buffer),
        .content = .{ .buffer = arr },
    };
}

/// Create a ref list node outside of a context, given a list of references.
/// * Allocator should be that of the context that will own the node.
pub fn list(allocator: std.mem.Allocator, element_kind: ir.Discriminator, init: []const ir.Ref) !Node {
    var arr = try common.ArrayList(ir.Ref).initCapacity(allocator, init.len);
    errdefer arr.deinit(allocator);

    arr.appendSliceAssumeCapacity(init);

    return Node{
        .kind = ir.NodeKind.collection(element_kind),
        .content = .{ .ref_list = arr },
    };
}
