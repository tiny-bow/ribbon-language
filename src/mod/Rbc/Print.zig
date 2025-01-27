const std = @import("std");

const utils = @import("utils");

const Rbc = @import("../Rbc.zig");
const Info = Rbc.Info;


pub fn printType(types: []const Info.Type, ty: Info.TypeIndex, writer: anytype) !void {
    switch (types[ty]) {
        .void => try writer.writeAll("void"),
        .bool => try writer.writeAll("bool"),
        .int => |info| try writer.print("i{}", .{ info.bit_width.toInt() }),
        .float => |info| try writer.print("f{}", .{ info.bit_width.toInt() }),
        .pointer => |info| {
            try writer.writeAll("*");
            try printType(types, info.target, writer);
        },
        .array => |info| {
            try writer.print("[{}]", .{info.length});
            try printType(types, info.element, writer);
        },
        .product => |info| {
            try writer.writeAll("(prod: ");
            for (info.types, 0..) |field, i| {
                try printType(types, field, writer);
                if (i < info.types.len - 1) {
                    try writer.writeAll(" * ");
                }
            }
            try writer.writeAll(")");
        },
        .sum => |info| {
            try writer.writeAll("(sum ");
            try printType(types, info.discriminator, writer);
            try writer.writeAll(": ");
            for (info.types, 0..) |field, i| {
                try printType(types, field, writer);
                if (i < info.types.len - 1) {
                    try writer.writeAll(" + ");
                }
            }
            try writer.writeAll(")");
        },
        .raw_sum => |info| {
            try writer.writeAll("(raw_sum: ");
            for (info.types, 0..) |field, i| {
                try printType(types, field, writer);
                if (i < info.types.len - 1) {
                    try writer.writeAll(" + ");
                }
            }
            try writer.writeAll(")");
        },
        .function => |info| {
            try writer.writeAll("(fn: ");
            for (info.params, 0..) |arg, i| {
                try printType(types, arg, writer);
                if (i < info.params.len - 1) {
                    try writer.writeAll(", ");
                }
            }
            try writer.writeAll(" -> ");
            try printType(types, info.result, writer);
            try writer.writeAll(" / ");
            try printType(types, info.term, writer);
            if (info.evidence.len > 0) {
                try writer.writeAll("(in: ");
                for (info.evidence, 0..) |e, i| {
                    try writer.print("{}", .{e});
                    if (i < info.evidence.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll(")");
            }
            try writer.writeAll(")");
        },
    }
}

pub fn printValue(types: []const Info.Type, ty: Info.TypeIndex, bytes: [*]const u8, len: ?usize, writer: anytype) !void {
    switch (types[ty]) {
        .void => if (len) |l| try writer.print("{any}", .{bytes[0..l]}) else try writer.writeAll("[cannot display]"),
        .bool => try writer.print("{}", .{ @as(*const align(1) bool, @ptrCast(bytes)).* }),
        .int => |info| {
            switch (info.bit_width) {
                .i8 => try writer.print("0x{x:0>2}", .{ @as(*const align(1) u8, @ptrCast(bytes)).* }),
                .i16 => try writer.print("0x{x:0>4}", .{ @as(*const align(1) u16, @ptrCast(bytes)).* }),
                .i32 => try writer.print("0x{x:0>8}", .{ @as(*const align(1) u32, @ptrCast(bytes)).* }),
                .i64 => try writer.print("0x{x:0>16}", .{ @as(*const align(1) u64, @ptrCast(bytes)).* }),
            }
        },
        .float => |info| switch (info.bit_width) {
            .f32 => try writer.print("{}", .{ @as(*const align(1) f32, @ptrCast(bytes)).* }),
            .f64 => try writer.print("{}", .{ @as(*const align(1) f64, @ptrCast(bytes)).* }),
        },
        .pointer => |info| {
            const ptr = @as(*const align(1) [*]const u8, @ptrCast(bytes)).*;
            try writer.print("@{x:0>16} => ", .{ @intFromPtr(ptr) });
            try printValue(types, info.target, ptr, null, writer);
        },
        .array => |info| {
            if (typeLayout(types, info.element)) |layout| {
                try writer.writeAll("[");
                for (0..info.length) |i| {
                    try printValue(types, info.element, bytes + layout.size * i, layout.size, writer);
                    if (i < info.length - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll("]");
            } else {
                try writer.writeAll("[cannot display]");
            }
        },
        .product => |info| {
            var offset: usize = 0;
            try writer.writeAll("(");
            for (info.types, 0..) |field, i| {
                if (typeLayout(types, field)) |fieldLayout| {
                    offset += utils.alignmentDelta(offset, fieldLayout.alignment);
                    try printValue(types, field, bytes + offset, fieldLayout.size, writer);
                    if (i < info.types.len - 1) {
                        try writer.writeAll(" * ");
                    }
                    offset += fieldLayout.size;
                } else {
                    try writer.writeAll("... cannot display");
                    break;
                }
            }
            try writer.writeAll(")");
        },
        .sum => |info| {
            var offset: usize, const disc = if (typeLayout(types, info.discriminator)) |discLayout| layout: {
                try printValue(types, info.discriminator, bytes, discLayout.size, writer);
                const discValue: usize = switch (discLayout.size) {
                    1 => @as(*const align(1) u8, @ptrCast(bytes)).*,
                    2 => @as(*const align(1) u16, @ptrCast(bytes)).*,
                    4 => @as(*const align(1) u32, @ptrCast(bytes)).*,
                    8 => @as(*const align(1) u64, @ptrCast(bytes)).*,
                    else => return writer.writeAll("[cannot display]"),
                };
                break :layout .{discLayout.size, discValue};
            } else {
                return writer.writeAll("[cannot display]");
            };

            const fieldType = info.types[disc];

            if (typeLayout(types, fieldType)) |fieldLayout| {
                offset += utils.alignmentDelta(offset, fieldLayout.alignment);
                try printValue(types, fieldType, bytes + offset, fieldLayout.size, writer);
            } else {
                try writer.writeAll("[cannot display]");
            }
        },
        .raw_sum => if (len) |l| {
            try writer.print("{any}", .{bytes[0..l]});
        } else {
            try writer.writeAll("[cannot display]");
        },
        .function => try writer.print("(fn {})", .{ @as(*const align(1) u64, @ptrCast(bytes)).* }),
    }
}

pub fn typeLayout(types: []const Info.Type, ty: Info.TypeIndex) ?Info.Layout {
    switch (types[ty]) {
        .void => return .{ .size = 0, .alignment = 1 },
        .bool => return .{ .size = 1, .alignment = 1 },
        .int => |info| switch (info.bit_width) {
            .i8 => return .{ .size = 1, .alignment = 1 },
            .i16 => return .{ .size = 2, .alignment = 2 },
            .i32 => return .{ .size = 4, .alignment = 4 },
            .i64 => return .{ .size = 8, .alignment = 8 },
        },
        .float => |info| switch (info.bit_width) {
            .f32 => return .{ .size = 4, .alignment = 4 },
            .f64 => return .{ .size = 8, .alignment = 8 },
        },
        .pointer => return .{ .size = 8, .alignment = 8 },
        .array => |info| if (typeLayout(types, info.element)) |elementLayout| {
            return .{
                .size = @intCast(elementLayout.size * info.length),
                .alignment = elementLayout.alignment,
            };
        } else {
            return null;
        },
        .product => |info| {
            var size: u16 = 0;
            var alignment: u16 = 1;

            for (info.types) |field| {
                if (typeLayout(types, field)) |fieldLayout| {
                    alignment = @max(alignment, fieldLayout.alignment);

                    const padding = utils.alignmentDelta(size, alignment);

                    size += padding + fieldLayout.size;
                } else {
                    return null;
                }
            }

            return .{ .size = size, .alignment = alignment };
        },
        .sum => |info| {
            var size: u16 = 0;
            var alignment: u16 = 1;

            if (typeLayout(types, info.discriminator)) |discInfo| {
                size += discInfo.size;
                alignment = @max(alignment, discInfo.alignment);
            } else {
                return null;
            }

            const baseSize = size;

            for (info.types) |field| {
                if (typeLayout(types, field)) |fieldLayout| {
                    size = @max(size, fieldLayout.size);
                    alignment = @max(alignment, fieldLayout.alignment);
                } else {
                    return null;
                }
            }

            const padding = utils.alignmentDelta(baseSize, alignment);
            size += padding;

            return .{ .size = size, .alignment = alignment };
        },
        .raw_sum => |info| {
            var size: u16 = 0;
            var alignment: u16 = 1;

            for (info.types) |field| {
                if (typeLayout(types, field)) |fieldLayout| {
                    size = @max(size, fieldLayout.size);
                    alignment = @max(alignment, fieldLayout.alignment);
                } else {
                    return null;
                }
            }

            return .{ .size = size, .alignment = alignment };
        },
        .function => return .{ .size = 8, .alignment = 8 },
    }
}

pub fn offsetType(types: []const Info.Type, ty: Info.TypeIndex, offset: usize) ?Info.TypeIndex {
    if (offset == 0) return ty;

    switch (types[ty]) {
        .void => return ty,
        .bool => return null,
        .int => |info| {
            if (offset < info.bit_width.byteSize()) {
                return 0;
            }

            return null;
        },
        .float => |info| {
            if (offset < info.bit_width.byteSize()) {
                return 0;
            }

            return null;
        },
        .pointer => {
            if (offset < 8) {
                return 0;
            }

            return null;
        },
        .array => |info| {
            const elemLayout = typeLayout(types, info.element) orelse return null;

            if (offset < elemLayout.size * info.length) {
                return offsetType(types, info.element, offset % elemLayout.size);
            }

            return null;
        },
        .product => |info| {
            var fieldOffset: u16 = 0;

            const prodLayout = typeLayout(types, ty) orelse return null;

            if (offset < prodLayout.size) {
                for (info.types) |field| {
                    if (typeLayout(types, field)) |fieldLayout| {
                        fieldOffset += utils.alignmentDelta(fieldOffset, fieldLayout.alignment);

                        if (fieldOffset == offset) {
                            return field;
                        }

                        if (offset < fieldOffset + fieldLayout.size) {
                            return offsetType(types, field, offset - fieldOffset);
                        }

                        fieldOffset += fieldLayout.size;
                    } else {
                        return 0;
                    }
                }
            }

            return null;
        },
        .sum => |info| {
            const sumLayout = typeLayout(types, ty) orelse return null;

            if (offset < sumLayout.size) {
                if (typeLayout(types, info.discriminator)) |discLayout| {
                    if (offset < discLayout.size) {
                        return offsetType(types, info.discriminator, offset);
                    } else {
                        return 0;
                    }
                }
            }

            return null;
        },
        .raw_sum => {
            const sumLayout = typeLayout(types, ty) orelse return null;

            if (offset < sumLayout.size) {
                return 0;
            }

            return null;
        },
        .function => {
            if (offset < 8) {
                return 0;
            }

            return null;
        },
    }
}
