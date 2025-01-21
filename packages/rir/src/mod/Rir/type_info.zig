const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Rir = @import("../Rir.zig");

pub const Type = struct {
    ir: *Rir,
    id: Rir.TypeId,
    name: ?Rir.Name,
    hash: u32,
    info: TypeInfo,

    pub fn init(ir: *Rir, id: Rir.TypeId, name: ?Rir.Name, info: TypeInfo) Type {
        return Type {
            .ir = ir,
            .id = id,
            .name = name,
            .hash = MiscUtils.fnv1a_32(info),
            .info = info,
        };
    }

    pub fn deinit(self: Type) void {
        self.info.deinit(self.ir.allocator);
    }

    pub fn compare(self: Type, other: Type) MiscUtils.Ordering {
        const ord = MiscUtils.compare(std.meta.activeTag(self.info), std.meta.activeTag(other.info));

        if (ord != .Equal or self.info.isBasic()) return ord;

        return switch (self.info) {
            .Pointer => MiscUtils.compare(self.info.Pointer, other.info.Pointer),
            .Slice => MiscUtils.compare(self.info.Slice, other.info.Slice),
            .Array => MiscUtils.compare(self.info.Array, other.info.Array),

            .Struct => MiscUtils.compare(self.info.Struct, other.info.Struct),
            .Union => MiscUtils.compare(self.info.Union, other.info.Union),

            .Product => MiscUtils.compare(self.info.Product, other.info.Product),
            .Sum => MiscUtils.compare(self.info.Sum, other.info.Sum),

            .Function => MiscUtils.compare(self.info.Function, other.info.Function),

            inline else => unreachable,
        };
    }

    pub fn format(self: *const Type, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const formatter = try Rir.Formatter.init(self.ir, if (@TypeOf(writer) == std.io.AnyWriter) writer else writer.any());
        defer formatter.deinit();
        try self.onFormat(formatter);
    }

    pub fn formatBody(self: *const Type, formatter: Rir.Formatter) !void {
        switch (self.info) {
            .Nil => try formatter.writeAll("Nil"),

            .Bool => try formatter.writeAll("Bool"),

            .U8 => try formatter.writeAll("U8"),
            .U16 => try formatter.writeAll("U16"),
            .U32 => try formatter.writeAll("U32"),
            .U64 => try formatter.writeAll("U64"),

            .S8 => try formatter.writeAll("S8"),
            .S16 => try formatter.writeAll("S16"),
            .S32 => try formatter.writeAll("S32"),
            .S64 => try formatter.writeAll("S64"),

            .F32 => try formatter.writeAll("F32"),
            .F64 => try formatter.writeAll("F64"),

            .Block => try formatter.writeAll("Block"),
            .HandlerSet => try formatter.writeAll("HandlerSet"),
            .Type => try formatter.writeAll("Type"),

            .Pointer => |x| try formatter.fmt(x),
            .Slice => |x| try formatter.fmt(x),
            .Array => |x| try formatter.fmt(x),

            .Struct => |x| try formatter.fmt(x),
            .Union => |x| try formatter.fmt(x),

            .Product => |x| try formatter.fmt(x),
            .Sum => |x| try formatter.fmt(x),

            .Function => |x| try formatter.fmt(x),
        }
    }

    pub fn onFormat(self: *const Type, formatter: Rir.Formatter) !void {
        const oldShowNominative = formatter.swapFlag(.show_nominative_type_bodies, false);
        defer formatter.setFlag(.show_nominative_type_bodies, oldShowNominative);

        if (self.name) |name| {
            try formatter.fmt(name);

            if (formatter.getFlag(.show_ids)) {
                try formatter.print("#{}", .{@intFromEnum(self.id)});
            }

            if (!oldShowNominative) return;

            try formatter.writeAll(" = ");

            try self.formatBody(formatter);
        } else if (oldShowNominative) {
            try formatter.print("#{} = ", .{@intFromEnum(self.id)});

            try self.formatBody(formatter);
        } else {
            try self.formatBody(formatter);

            if (formatter.getFlag(.show_ids)) {
                try formatter.print("#{}", .{@intFromEnum(self.id)});
            }
        }
    }

    pub fn compareMemory(self: *const Type, a: []const u8, b: []const u8) ! MiscUtils.Ordering {
        if (a.ptr == b.ptr and a.len == b.len) return .Equal;

        const layout = try self.ir.getTypeLayout(self.id);

        switch (self.info) {
            .Nil => return .Equal,

            .Bool => return MiscUtils.compare(a[0], b[0]),

            .U8 => return MiscUtils.compare(@as(*const u8, @alignCast(@ptrCast(a.ptr))).*, @as(*const u8, @alignCast(@ptrCast(b.ptr))).*),
            .U16 => return MiscUtils.compare(@as(*const u16, @alignCast(@ptrCast(a.ptr))).*, @as(*const u16, @alignCast(@ptrCast(b.ptr))).*),
            .U32 => return MiscUtils.compare(@as(*const u32, @alignCast(@ptrCast(a.ptr))).*, @as(*const u32, @alignCast(@ptrCast(b.ptr))).*),
            .U64 => return MiscUtils.compare(@as(*const u64, @alignCast(@ptrCast(a.ptr))).*, @as(*const u64, @alignCast(@ptrCast(b.ptr))).*),

            .S8 => return MiscUtils.compare(@as(*const i8, @alignCast(@ptrCast(a.ptr))).*, @as(*const i8, @alignCast(@ptrCast(b.ptr))).*),
            .S16 => return MiscUtils.compare(@as(*const i16, @alignCast(@ptrCast(a.ptr))).*, @as(*const i16, @alignCast(@ptrCast(b.ptr))).*),
            .S32 => return MiscUtils.compare(@as(*const i32, @alignCast(@ptrCast(a.ptr))).*, @as(*const i32, @alignCast(@ptrCast(b.ptr))).*),
            .S64 => return MiscUtils.compare(@as(*const i64, @alignCast(@ptrCast(a.ptr))).*, @as(*const i64, @alignCast(@ptrCast(b.ptr))).*),

            .F32 => return MiscUtils.compare(@as(*const f32, @alignCast(@ptrCast(a.ptr))).*, @as(*const f32, @alignCast(@ptrCast(b.ptr))).*),
            .F64 => return MiscUtils.compare(@as(*const f64, @alignCast(@ptrCast(a.ptr))).*, @as(*const f64, @alignCast(@ptrCast(b.ptr))).*),

            inline
                .Block,
                .HandlerSet,
                .Pointer,
            => return MiscUtils.compare(a, b),

            .Type => return @as(*const Type, @alignCast(@ptrCast(a.ptr))).compare(@as(*const Type, @alignCast(@ptrCast(b.ptr))).*),

            .Slice => |info| {
                const elemType = try self.ir.getType(info.element);
                const elemLayout = try self.ir.getTypeLayout(info.element);

                const aPtr: *const [*]u8 = @alignCast(@ptrCast(a.ptr));
                const aLength: *const Rir.Size = @alignCast(@ptrCast(a.ptr + 8));
                const aBuf: []const u8 = aPtr.*[0..aLength.*];

                const bPtr: *const [*]u8 = @alignCast(@ptrCast(b.ptr));
                const bLength: *const Rir.Size = @alignCast(@ptrCast(b.ptr + 8));
                const bBuf: []const u8 = bPtr.*[0..bLength.*];

                if (aPtr.* == bPtr.* and aLength.* == bLength.*) return .Equal;

                var ord = MiscUtils.compare(aLength.*, bLength.*);

                if (ord == .Equal) {
                    for (0..aLength.*) |i| {
                        const j = i * elemLayout.dimensions.size;
                        const aElem = aBuf[j..j + elemLayout.dimensions.size];
                        const bElem = bBuf[j..j + elemLayout.dimensions.size];

                        ord = try elemType.compareMemory(aElem, bElem);

                        if (ord != .Equal) break;
                    }
                }

                return ord;
            },

            .Array => |info| {
                const elemType = try self.ir.getType(info.element);
                const elemLayout = try self.ir.getTypeLayout(info.element);

                for (0..info.length) |i| {
                    const j = i * elemLayout.dimensions.size;
                    const aElem = a[j..j + elemLayout.dimensions.size];
                    const bElem = b[j..j + elemLayout.dimensions.size];

                    const ord = try elemType.compareMemory(aElem, bElem);
                    if (ord != .Equal) return ord;
                }

                return .Equal;
            },

            .Struct => |info| {
                for (info.fields, 0..) |field, i| {
                    const fieldType = try self.ir.getType(field.type);
                    const fieldLayout = try self.ir.getTypeLayout(field.type);
                    const fieldOffset = layout.field_offsets[i];
                    const fieldMemoryA = a[fieldOffset..fieldOffset + fieldLayout.dimensions.size];
                    const fieldMemoryB = b[fieldOffset..fieldOffset + fieldLayout.dimensions.size];

                    const ord = try fieldType.compareMemory(fieldMemoryA, fieldMemoryB);
                    if (ord != .Equal) return ord;
                }

                return .Equal;
            },
            .Union => |info| {
                const discriminatorType = try self.ir.getType(info.discriminator);
                const discriminatorLayout = try self.ir.getTypeLayout(info.discriminator);
                const discMemA = a[0..discriminatorLayout.dimensions.size];
                const discMemB = b[0..discriminatorLayout.dimensions.size];

                const discOrd = try discriminatorType.compareMemory(discMemA, discMemB);
                if (discOrd != .Equal) return discOrd;

                for (info.fields) |field| {
                    const fieldDiscMem = field.discriminant.mem_const();

                    if (try discriminatorType.compareMemory(discMemA, fieldDiscMem) == .Equal) {
                        const fieldType = try self.ir.getType(field.type);
                        const fieldLayout = try self.ir.getTypeLayout(field.type);
                        const fieldMemoryA = a[layout.field_offsets[1]..layout.field_offsets[1] + fieldLayout.dimensions.size];
                        const fieldMemoryB = b[layout.field_offsets[1]..layout.field_offsets[1] + fieldLayout.dimensions.size];

                        return fieldType.compareMemory(fieldMemoryA, fieldMemoryB);
                    }
                }

                unreachable;
            },

            .Product => |type_set| {
                for (type_set, 0..) |id, i| {
                    const T = try self.ir.getType(id);
                    const TLayout = try self.ir.getTypeLayout(id);
                    const offset = layout.field_offsets[i];
                    const memoryA = a[offset..offset + TLayout.dimensions.size];
                    const memoryB = b[offset..offset + TLayout.dimensions.size];

                    const ord = try T.compareMemory(memoryA, memoryB);
                    if (ord != .Equal) return ord;
                }

                return .Equal;
            },

            .Sum => |_| return MiscUtils.compare(a, b),

            .Function => |_| return MiscUtils.compare(a, b),
        }
    }

    pub fn formatMemory(self: *const Type, formatter: Rir.Formatter, memory: []const u8) !void {
        const layout = try self.ir.getTypeLayout(self.id);

        std.debug.assert(layout.canUseMemory(memory));

        switch (self.info) {
            .Nil => try formatter.writeAll("Nil"),

            .Bool => try formatter.writeAll(if (memory[0] == 1) "true" else "false"),

            .U8 => try formatter.fmt(memory[0]),
            .U16 => try formatter.fmt(@as(*const u16, @alignCast(@ptrCast(memory.ptr))).*),
            .U32 => try formatter.fmt(@as(*const u32, @alignCast(@ptrCast(memory.ptr))).*),
            .U64 => try formatter.fmt(@as(*const u64, @alignCast(@ptrCast(memory.ptr))).*),

            .S8 => try formatter.fmt(@as(*const i8, @alignCast(@ptrCast(memory.ptr))).*),
            .S16 => try formatter.fmt(@as(*const i16, @alignCast(@ptrCast(memory.ptr))).*),
            .S32 => try formatter.fmt(@as(*const i32, @alignCast(@ptrCast(memory.ptr))).*),
            .S64 => try formatter.fmt(@as(*const i64, @alignCast(@ptrCast(memory.ptr))).*),

            .F32 => try formatter.fmt(@as(*const f32, @alignCast(@ptrCast(memory.ptr))).*),
            .F64 => try formatter.fmt(@as(*const f64, @alignCast(@ptrCast(memory.ptr))).*),

            inline
                .Block,
                .HandlerSet,
                .Pointer,
                .Sum,
            => try formatter.print("[{} @ {x}]", .{formatter.wrap(self), @intFromPtr(memory.ptr)}),

            .Type => try @as(*const Type, @alignCast(@ptrCast(memory.ptr))).onFormat(formatter),

            .Slice => try formatter.print("[{} @ {x} + {}]", .{formatter.wrap(self), @intFromPtr(memory.ptr), memory.len}),

            .Array => |info| {
                const elem = try self.ir.getType(info.element);
                try formatter.print("array({})[", .{info.length});
                try formatter.beginBlock();
                    const elemSize = @divExact(memory.len, info.length);
                    for (0..info.length) |i| {
                        if (i > 0) {
                            try formatter.writeAll(",");
                            try formatter.endLine();
                        }
                        try elem.formatMemory(formatter, memory[i * elemSize..]);
                    }
                try formatter.endBlock();
                try formatter.endLine();
                try formatter.writeAll("]");
            },

            .Struct => |info| {
                try formatter.writeAll("{");
                try formatter.beginBlock();
                    for (info.fields, 0..) |field, i| {
                        if (i > 0) {
                            try formatter.writeAll(",");
                            try formatter.endLine();
                        }

                        const fieldType = try self.ir.getType(field.type);
                        const fieldLayout = try self.ir.getTypeLayout(field.type);
                        const fieldOffset = layout.field_offsets[i];
                        const fieldMemory = (memory.ptr + fieldOffset)[0..fieldLayout.dimensions.size];
                        Rir.log.err(
                            \\name = {s}
                            \\  type = {}
                            \\  layout = {}
                            \\  offset = {}
                            \\  memory_base = {x}
                            \\  memory_len = {d}
                            ,.{
                                field.name,
                                fieldType,
                                fieldLayout,
                                fieldOffset,
                                @intFromPtr(fieldMemory.ptr),
                                fieldMemory.len,
                            }
                        );

                        try formatter.print("{} = ", .{formatter.wrap(field.name)});

                        try fieldType.formatMemory(formatter, fieldMemory);
                    }
                try formatter.endBlock();
                try formatter.endLine();
                try formatter.writeAll("}");
            },

            .Union => |info| {
                const discriminatorType = try self.ir.getType(info.discriminator);
                const discriminatorLayout = try self.ir.getTypeLayout(info.discriminator);
                const discMem = memory[0..discriminatorLayout.dimensions.size];

                for (info.fields) |field| {
                    const fieldDiscMem = field.discriminant.mem_const();

                    if (try discriminatorType.compareMemory(discMem, fieldDiscMem) == .Equal) {
                        const fieldType = try self.ir.getType(field.type);
                        const fieldLayout = try self.ir.getTypeLayout(field.type);
                        const fieldMemory = (memory.ptr + layout.field_offsets[1])[0..fieldLayout.dimensions.size];

                        try formatter.print("{}.{}(", .{formatter.wrap(self.id), formatter.wrap(field.name)});

                        try fieldType.formatMemory(formatter, fieldMemory);

                        try formatter.writeAll(")");

                        return;
                    }
                }

                unreachable;
            },

            .Product => |type_set| {
                try formatter.writeAll("(");
                try formatter.beginBlock();
                    for (type_set, 0..) |id, i| {
                        const T = try self.ir.getType(id);
                        try T.formatMemory(formatter, memory);
                        if (i < type_set.len - 1) {
                            try formatter.writeAll(",");
                            try formatter.endLine();
                        }
                    }
                try formatter.endBlock();
                try formatter.writeAll(")");
            },

            .Function => try formatter.print("[{} @ {x}]", .{formatter.wrap(self), @intFromPtr(memory.ptr)}),
        }
    }
};

pub const TypeSet = []const Rir.TypeId;

pub const TypeTag = std.meta.Tag(TypeInfo);
pub const TypeInfo = union(enum) {
    Nil: void,
    Bool: void,
    U8: void, U16: void, U32: void, U64: void,
    S8: void, S16: void, S32: void, S64: void,
    F32: void, F64: void,

    Block: void,
    HandlerSet: void,
    Type: void,

    Pointer: Pointer,
    Slice: Slice,
    Array: Array,

    Struct: Struct,
    Union: Union,

    Product: TypeSet,
    Sum: TypeSet,

    Function: Function,

    pub fn deinit(self: TypeInfo, allocator: std.mem.Allocator) void {
        switch (self) {
            .Struct => |x| x.deinit(allocator),
            .Union => |x| x.deinit(allocator),

            .Product => |x| allocator.free(x),
            .Sum => |x| allocator.free(x),

            .Function => |x| x.deinit(allocator),

            inline else => std.debug.assert(!self.isAllocated()),
        }
    }

    pub fn clone(self: *const TypeInfo, allocator: std.mem.Allocator) !TypeInfo {
        return switch (self.*) {
            .Struct => |x| .{.Struct = try x.clone(allocator)},
            .Union => |x| .{.Union = try x.clone(allocator)},

            .Product => |x| .{.Product = try allocator.dupe(Rir.TypeId, x)},
            .Sum => |x| .{.Sum = try allocator.dupe(Rir.TypeId, x)},

            .Function => |x| .{.Function = try x.clone(allocator)},

            inline else => pod: {
                std.debug.assert(!self.isAllocated());
                break :pod self.*;
            },
        };
    }

    pub fn isBasic(self: *const TypeInfo) bool {
        return @intFromEnum(std.meta.activeTag(self.*)) < @intFromEnum(@as(TypeTag, .Pointer));
    }

    pub fn isAllocated(self: *const TypeInfo) bool {
        return switch (self.*) {
            inline
                .Struct, .Union,
                .Product, .Sum,
                .Function,
            => true,

            inline else => false,
        };
    }

    pub fn asFunction(self: *const TypeInfo) !Function {
        switch (self.*) {
            .Function => |fun| return fun,
            inline else => return error.InvalidType,
        }
    }

    pub fn computeLayout(self: *const TypeInfo, ir: *Rir) error{InvalidType, OutOfMemory}!Rir.Layout {
        return switch (self.*) {
            .Nil => .{.dimensions = .{ .size = 0, .alignment = 1 }},

            .Bool => .{.dimensions = .{ .size = 1, .alignment = 1 }},

            .U8 => .{.dimensions = .{ .size = 1, .alignment = 1 }},
            .U16 => .{.dimensions = .{ .size = 2, .alignment = 2 }},
            .U32 => .{.dimensions = .{ .size = 4, .alignment = 4 }},
            .U64 => .{.dimensions = .{ .size = 8, .alignment = 8 }},

            .S8 => .{.dimensions = .{ .size = 1, .alignment = 1 }},
            .S16 => .{.dimensions = .{ .size = 2, .alignment = 2 }},
            .S32 => .{.dimensions = .{ .size = 4, .alignment = 4 }},
            .S64 => .{.dimensions = .{ .size = 8, .alignment = 8 }},
            .F32 => .{.dimensions = .{ .size = 4, .alignment = 4 }},
            .F64 => .{.dimensions = .{ .size = 8, .alignment = 8 }},

            .Block => .{.dimensions = .fromNativeType(Rir.BlockId)},
            .HandlerSet => .{.dimensions = .fromNativeType(Rir.HandlerSetId)},
            .Type => .{.dimensions = .fromNativeType(Rir.TypeId)},

            .Pointer => .{.dimensions = .{ .size = 8, .alignment = 8 }},
            .Slice => .{
                .dimensions = .{ .size = 16, .alignment = 8 },
                .field_offsets = try ir.allocator.dupe(Rir.Offset, &.{0, 8}),
            },

            .Array => |info| Array: {
                const elemLayout = try ir.getTypeLayout(info.element);

                break :Array .{
                    .dimensions = .{
                        .size = MiscUtils.alignTo(elemLayout.dimensions.size, elemLayout.dimensions.alignment) * info.length,
                        .alignment = elemLayout.dimensions.alignment,
                    }
                };
            },

            .Struct => |info| Struct: {
                var dimensions = Rir.Dimensions {};
                var maxAlignment: Rir.Alignment = 1;

                const offsets = try ir.allocator.alloc(Rir.Offset, info.fields.len);
                errdefer ir.allocator.free(offsets);

                for (info.fields, 0..) |*field, i| {
                    const fieldLayout = try ir.getTypeLayout(field.type);

                    maxAlignment = @max(maxAlignment, fieldLayout.dimensions.alignment);

                    if (dimensions.alignment < fieldLayout.dimensions.alignment) {
                        dimensions.size += MiscUtils.alignmentDelta(dimensions.size, fieldLayout.dimensions.alignment);
                    }

                    dimensions.alignment = fieldLayout.dimensions.alignment;

                    offsets[i] = dimensions.size;

                    dimensions.size += MiscUtils.alignTo(fieldLayout.dimensions.size, fieldLayout.dimensions.alignment);
                }

                dimensions.alignment = maxAlignment;
                dimensions.size += MiscUtils.alignmentDelta(dimensions.size, maxAlignment);

                break :Struct .{
                    .dimensions = dimensions,
                    .field_offsets = offsets,
                };
            },

            .Union => |info| Union: {
                var dimensions = Rir.Dimensions {};

                const discriminatorLayout = try ir.getTypeLayout(info.discriminator);

                for (info.fields) |field| {
                    const fieldLayout = try ir.getTypeLayout(field.type);

                    dimensions.alignment = @max(dimensions.alignment, fieldLayout.dimensions.alignment);
                    dimensions.size = @max(dimensions.size, fieldLayout.dimensions.size);
                }

                var offsets = try ir.allocator.alloc(Rir.Offset, 2);
                errdefer ir.allocator.free(offsets);

                const sumDimensions = dimensions;
                const sumPadding = MiscUtils.alignmentDelta(discriminatorLayout.dimensions.size, dimensions.alignment);

                offsets[0] = 0;
                offsets[1] = discriminatorLayout.dimensions.size + sumPadding;

                dimensions.alignment = @max(dimensions.alignment, discriminatorLayout.dimensions.alignment);
                dimensions.size += discriminatorLayout.dimensions.size;
                dimensions.size += sumPadding;

                if (sumDimensions.alignment < dimensions.alignment) {
                    dimensions.size += MiscUtils.alignmentDelta(dimensions.size, dimensions.alignment);
                }

                break :Union .{
                    .dimensions = dimensions,
                    .field_offsets = offsets,
                };
            },

            .Product => |type_set| Product: {
                var dimensions = Rir.Dimensions {};
                var maxAlignment: Rir.Alignment = 1;

                const offsets = try ir.allocator.alloc(Rir.Offset, type_set.len);
                errdefer ir.allocator.free(offsets);

                for (type_set, 0..) |T, i| {
                    const fieldLayout = try ir.getTypeLayout(T);

                    maxAlignment = @max(maxAlignment, fieldLayout.dimensions.alignment);

                    if (dimensions.alignment < fieldLayout.dimensions.alignment) dimensions.size += MiscUtils.alignmentDelta(dimensions.size, fieldLayout.dimensions.alignment);

                    dimensions.alignment = fieldLayout.dimensions.alignment;

                    offsets[i] = dimensions.size;
                }

                dimensions.alignment = maxAlignment;
                dimensions.size += MiscUtils.alignmentDelta(dimensions.size, maxAlignment);

                break :Product .{
                    .dimensions = dimensions,
                    .field_offsets = offsets,
                };
            },

            .Sum => |type_set| Sum: {
                var dimensions = Rir.Dimensions {};

                for (type_set) |variant| {
                    const variantLayout = try ir.getTypeLayout(variant);

                    dimensions.alignment = @max(dimensions.alignment, variantLayout.dimensions.alignment);
                    dimensions.size = @max(dimensions.size, variantLayout.dimensions.size);
                }

                break :Sum .{
                    .dimensions = dimensions,
                };
            },

            .Function => .{.dimensions = .{.size = 2, .alignment = 2}},
        };
    }

    pub fn fromNative(comptime T: type, rir: *Rir, parameterNames: ?[]const Rir.Name) !Rir.TypeInfo {
        switch (T) {
            void => return .Nil,
            bool => return .Bool,
            u8 => return .U8, u16 => return .U16, u32 => return .U32, u64 => return .U64,
            i8 => return .S8, i16 => return .S16, i32 => return .S32, i64 => return .S64,
            f32 => return .F32, f64 => return .F64,

            else => switch (@typeInfo(T)) {
                .pointer => |info| {
                    const elementType = try rir.createTypeIdFromNative(info.child, null, null);
                    return Rir.TypeInfo { .Pointer = elementType.id };
                },
                .array => |info| {
                    const elementType = try rir.createTypeIdFromNative(info.child, null, null);
                    return Rir.TypeInfo { .Array = .{
                        .length = info.len,
                        .element = elementType,
                    }};
                },
                .@"struct" => |info| {
                    var field_types = try rir.allocator.alloc(Rir.TypeId, info.fields.len);
                    errdefer rir.allocator.free(field_types);

                    for (info.fields, 0..) |field, i| {
                        const fieldType = try rir.createTypeIdFromNative(field.type, null, null);
                        field_types[i] = fieldType.id;
                    }

                    return Rir.TypeInfo { .Product = field_types };
                },
                .@"enum" => |info| return rir.typeFromNative(info.tag_type, null),
                .@"union" => |info| {
                    var field_types = try rir.allocator.alloc(Rir.TypeId, info.fields.len);
                    errdefer rir.allocator.free(field_types);

                    for (info.fields, 0..) |field, i| {
                        const fieldType = try rir.createTypeFromNative(field.type, null, null);
                        field_types[i] = fieldType.id;
                    }

                    if (info.tag_type) |TT| {
                        const discType = try rir.createTypeFromNative(TT, null, null);
                        return Rir.Type { .Union = .{
                            .discriminator = discType.id,
                            .types = field_types,
                        } };
                    } else {
                        return Rir.TypeInfo { .Sum = field_types };
                    }
                },
                .@"fn" => |info| {
                    const returnType = try rir.createTypeFromNative(info.return_type.?, null, null);
                    const terminationType = try rir.createTypeFromNative(void, null, null);

                    const effects = try rir.allocator.alloc(Rir.TypeId, 0);
                    errdefer rir.allocator.free(effects);

                    var parameters = try rir.allocator.alloc(Rir.type_info.Parameter, info.params.len);
                    errdefer rir.allocator.free(parameters);

                    inline for (info.params, 0..) |param, i| {
                        const paramType = try rir.createTypeFromNative(param.type.?, null, null);

                        parameters[i] = Rir.type_info.Parameter {
                            .name = if (parameterNames) |names| names[i] else std.fmt.comptimePrint("arg{}", .{i}),
                            .type = paramType.id,
                        };
                    }

                    return Rir.TypeInfo { .Function = .{
                        .return_type = returnType.id,
                        .termination_type = terminationType.id,
                        .effects = effects,
                        .parameters = parameters,
                    } };
                },

                else => @compileError("cannot convert type `" ++ @typeName(T) ++ "` to Rir.Type"),
            }
        }
    }
};

pub const Array = struct {
    length: u64,
    element: Rir.TypeId,

    pub fn onFormat(self: Array, formatter: Rir.Formatter) !void {
        try formatter.writeAll("[");
        try formatter.fmt(self.length);
        try formatter.writeAll("]");
        try formatter.fmt(self.element);
    }
};


pub const Pointer = struct {
    alignment_override: ?Rir.Alignment,
    element: Rir.TypeId,
};

pub const Slice = struct {
    alignment_override: ?Rir.Alignment,
    element: Rir.TypeId,
};

pub const StructField = struct {
    name: Rir.Name,
    type: Rir.TypeId,

    pub fn onFormat(self: StructField, formatter: Rir.Formatter) !void {
        try formatter.fmt(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
    }
};

pub const Struct = struct {
    fields: []const StructField,

    pub fn clone(self: *const Struct, allocator: std.mem.Allocator) !Struct {
        return Struct {
            .fields = try allocator.dupe(StructField, self.fields),
        };
    }

    pub fn deinit(self: Struct, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }

    pub fn onFormat(self: Struct, formatter: Rir.Formatter) !void {
        const oldTypeMode = formatter.swapFlag(.show_nominative_type_bodies, false);
        defer formatter.setFlag(.show_nominative_type_bodies, oldTypeMode);

        try formatter.writeAll("struct{");

        for (self.fields, 0..) |field, i| {
            if (i != 0) try formatter.writeAll(", ");

            try formatter.fmt(field);
        }

        try formatter.writeAll("}");
    }
};

pub const UnionField = struct {
    discriminant: Rir.Operand,
    name: Rir.Name,
    type: Rir.TypeId,

    pub fn onFormat(self: UnionField, formatter: Rir.Formatter) !void {
        const oldTypeMode = formatter.swapFlag(.show_nominative_type_bodies, false);
        defer formatter.setFlag(.show_nominative_type_bodies, oldTypeMode);

        try formatter.fmt(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" ");
        try formatter.parens(self.discriminant);
    }
};

pub const Union = struct {
    discriminator: Rir.TypeId,
    fields: []const UnionField,

    pub fn clone(self: *const Union, allocator: std.mem.Allocator) !Union {
        return Union {
            .discriminator = self.discriminator,
            .fields = try allocator.dupe(UnionField, self.fields),
        };
    }

    pub fn deinit(self: Union, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }

    pub fn onFormat(self: Union, formatter: Rir.Formatter) !void {
        try formatter.writeAll("union{");
        for (self.fields, 0..) |field, i| {
            if (i != 0) try formatter.writeAll(", ");
            try formatter.fmt(field);
        }
        try formatter.writeAll("}");
    }
};

pub const Parameter = struct {
    name: Rir.Name,
    type: Rir.TypeId,

    pub fn onFormat(self: Parameter, formatter: Rir.Formatter) !void {
        try formatter.writeAll(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
    }
};

pub const Function = struct {
    return_type: Rir.TypeId,
    termination_type: Rir.TypeId,
    effects: []const Rir.TypeId,
    parameters: []const Parameter,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        allocator.free(self.effects);
        allocator.free(self.parameters);
    }

    pub fn clone(self: *const Function, allocator: std.mem.Allocator) !Function {
        const effects = try allocator.dupe(Rir.TypeId, self.effects);
        errdefer allocator.free(effects);

        const parameters = try allocator.dupe(Parameter, self.parameters);
        errdefer allocator.free(parameters);

        return Function {
            .return_type = self.return_type,
            .termination_type = self.termination_type,
            .effects = effects,
            .parameters = parameters,
        };
    }

    pub fn onFormat(self: Function, formatter: Rir.Formatter) !void {
        try formatter.writeAll("(");
        try formatter.commaList(self.parameters);
        try formatter.writeAll(" -> ");
        try formatter.fmt(self.return_type);
        if (self.effects.len > 0) {
            try formatter.writeAll(" with {");
            try formatter.commaList(self.effects);
            try formatter.writeAll("}");
        }
        try formatter.writeAll(")");
    }
};

pub const BASIC_TYPE_NAMES = [_][:0]const u8 {
    "Nil",
    "Bool",
    "U8", "U16", "U32", "U64",
    "S8", "S16", "S32", "S64",
    "F32", "F64",

    "Block",
    "HandlerSet",
    "Type",
};

pub const BASIC_TYPE_IDS = type_ids: {
    var type_ids = [1]Rir.TypeId { undefined } ** BASIC_TYPE_NAMES.len;

    for (0..BASIC_TYPE_NAMES.len) |i| {
        type_ids[i] = @enumFromInt(i);
    }

    break :type_ids type_ids;
};

pub const BASIC_TYPE_INFO = types: {
    var types = [1]TypeInfo { undefined } ** BASIC_TYPE_NAMES.len;

    for (BASIC_TYPE_NAMES, 0..) |name, i| {
        types[i] = @unionInit(TypeInfo, name, {});
    }

    break :types types;
};
