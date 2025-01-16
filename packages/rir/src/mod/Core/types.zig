const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Core = @import("../Core.zig");


pub const TypeTag = std.meta.Tag(Type);

pub const TypeSet = []Core.TypeId;

pub const Type = union(enum) {
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

    pub fn isBasic(self: Type) bool {
        return @intFromEnum(std.meta.activeTag(self)) < @intFromEnum(@as(TypeTag, .pointer));
    }

    pub fn isAllocated(self: Type) bool {
        return switch (self) {
            inline
                .Struct, .Union,
                .Product, .Sum,
                .Function,
            => true,

            inline else => false,
        };
    }

    pub fn clone(self: *const Type, allocator: std.mem.Allocator) !Type {
        switch (self.*) {
            .Struct => |field_types| return Type { .Product = try allocator.dupe(Core.TypeId, field_types) },
            .Union => |sum| return Type { .Union = try sum.clone(allocator) },

            .Product => |field_types| return Type { .Product = try allocator.dupe(Core.TypeId, field_types) },
            .Sum => |field_types| return Type { .Sum = try allocator.dupe(Core.TypeId, field_types) },

            .Function => |fun| return Type { .Function = try fun.clone(allocator) },

            inline else => return self.*,
        }
    }

    pub fn deinit(self: Type, allocator: std.mem.Allocator) void {
        switch (self) {
            .Struct => |prod| prod.deinit(allocator),
            .Union => |sum| sum.deinit(allocator),

            .Product => |field_types| allocator.free(field_types),
            .Sum => |field_types| allocator.free(field_types),

            .Function => |fun| fun.deinit(allocator),

            inline else => {},
        }
    }

    pub fn asFunction(self: Type) !Function {
        switch (self) {
            .Function => |fun| return fun,
            inline else => return error.InvalidType,
        }
    }

    pub fn formatMemory(self: Type, formatter: Core.Formatter, memory: []const u8) !void {
        switch (self) {
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
                const elem = try formatter.getIR().getType(info.element);
                try formatter.print("array({})[", .{info.length});
                try formatter.beginBlock();
                    const elemSize = @divExact(memory.len, info.length);
                    for (0..info.length) |i| {
                        try elem.formatMemory(formatter, memory[i * elemSize..]);
                        if (i < info.length - 1) {
                            try formatter.writeAll(",");
                            try formatter.endLine();
                        }
                    }
                try formatter.endBlock();
                try formatter.writeAll("]");
            },

            .Struct => |info| {
                try formatter.fmt(info.name);
                try formatter.writeAll("{");
                try formatter.beginBlock();
                    for (info.fields, 0..) |field, i| {
                        const T = try formatter.getIR().getType(field.type);
                        try formatter.print("{} {} = ", .{formatter.wrap(field.location), formatter.wrap(field.name)});
                        // FIXME: layout should be known by formatMemory, but
                        // we haven't yet implemented a cache for it. Locations are not field offsets.
                        try T.formatMemory(formatter, memory[@intFromEnum(field.location)..]);
                        if (i < info.fields.len - 1) {
                            try formatter.writeAll(",");
                            try formatter.endLine();
                        }
                    }
                try formatter.endBlock();
                try formatter.writeAll("}");
            },

            .Union => @panic("TODO union types"),

            .Product => |types| {
                try formatter.writeAll("(");
                try formatter.beginBlock();
                    for (types, 0..) |typeId, i| {
                        const T = try formatter.getIR().getType(typeId);
                        try T.formatMemory(formatter, memory);
                        if (i < types.len - 1) {
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

    pub fn onFormat(self: Type, formatter: Core.Formatter) !void {
        switch (self) {
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

            .Pointer => try formatter.fmt(self.Pointer),
            .Slice => try formatter.fmt(self.Slice),
            .Array => try formatter.fmt(self.Array),

            .Struct => try formatter.fmt(self.Struct),
            .Union => try formatter.fmt(self.Union),

            .Product => try formatter.fmt(self.Product),
            .Sum => try formatter.fmt(self.Sum),

            .Function => try formatter.fmt(self.Function),
        }
    }
};

pub const Array = struct {
    length: u64,
    element: Core.TypeId,

    pub fn onFormat(self: Array, formatter: Core.Formatter) !void {
        try formatter.writeAll("[");
        try formatter.fmt(self.length);
        try formatter.writeAll("]");
        try formatter.fmt(self.element);
    }
};

pub const Alignment = u12; // 2^12 = 4096 = page size; should be enough for anyone (famous last words)

pub const Pointer = struct {
    alignment_override: ?Alignment,
    element: Core.TypeId,
};

pub const Slice = struct {
    alignment_override: ?Alignment,
    element: Core.TypeId,
};

pub const Struct = struct {
    name: Core.Name,
    fields: []Field,

    pub const Field = struct {
        location: Core.FieldId,
        name: Core.Name,
        type: Core.TypeId,

        pub fn onFormat(self: Field, formatter: Core.Formatter) !void {
            try formatter.parens(self.location);
            try formatter.writeAll(" ");
            try formatter.fmt(self.name);
            try formatter.writeAll(": ");
            try formatter.fmt(self.type);
        }
    };

    pub fn clone(self: *const Struct, allocator: std.mem.Allocator) !Struct {
        return Struct {
            .discriminator = self.discriminator,
            .fields = try allocator.dupe(Core.TypeId, self.fields),
        };
    }

    pub fn deinit(self: Struct, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }

    pub fn onFormat(self: Struct, formatter: Core.Formatter) !void {
        switch (formatter.getTypeMode()) {
            .name_only => try formatter.fmt(self.name),

            else => {
                try formatter.writeAll("struct ");
                try formatter.fmt(self.name);
                try formatter.writeAll(" {");

                for (self.fields, 0..) |field, i| {
                    if (i != 0) try formatter.writeAll(", ");

                    try formatter.fmt(field);
                }

                try formatter.writeAll("}");
            },
        }
    }
};

pub const Union = struct {
    name: Core.Name,
    discriminator: Core.TypeId,
    fields: []Field,

    pub const Field = struct {
        discriminant: Core.Operand,
        name: Core.Name,
        type: Core.TypeId,

        pub fn onFormat(self: Field, formatter: Core.Formatter) !void {
            switch (formatter.getTypeMode()) {
                .name_only => try formatter.fmt(self.name),

                else => {
                    try formatter.fmt(self.name);
                    try formatter.writeAll(": ");
                    try formatter.fmt(self.type);
                    try formatter.writeAll(" ");
                    try formatter.parens(self.discriminant);
                },
            }
        }
    };

    pub fn clone(self: *const Union, allocator: std.mem.Allocator) !Union {
        return Union {
            .discriminator = self.discriminator,
            .fields = try allocator.dupe(Core.TypeId, self.fields),
        };
    }

    pub fn deinit(self: Union, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }

    pub fn onFormat(self: Union, formatter: Core.Formatter) !void {
        try formatter.writeAll("sum ");
        try formatter.fmt(self.name);
        try formatter.writeAll(" {");
        for (self.fields, 0..) |field, i| {
            if (i != 0) try formatter.writeAll(", ");
            try formatter.fmt(field);
        }
        try formatter.writeAll("}");
    }
};

pub const Function = struct {
    return_type: Core.TypeId,
    termination_type: Core.TypeId,
    effects: []Core.TypeId,
    parameters: []Parameter,

    pub const Parameter = struct {
        name: Core.Name,
        type: Core.TypeId,

        pub fn onFormat(self: Parameter, formatter: Core.Formatter) !void {
            try formatter.writeAll(self.name);
            try formatter.writeAll(": ");
            try formatter.fmt(self.type);
        }
    };

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        allocator.free(self.effects);
        allocator.free(self.parameters);
    }

    pub fn clone(self: *const Function, allocator: std.mem.Allocator) !Function {
        const effects = try allocator.dupe(Core.TypeId, self.effects);
        errdefer allocator.free(effects);

        const parameters = try allocator.dupe(Core.TypeId, self.parameters);
        errdefer allocator.free(parameters);

        return Function {
            .return_type = self.return_type,
            .termination_type = self.termination_type,
            .effects = effects,
            .parameters = parameters,
        };
    }

    pub fn onFormat(self: Function, formatter: Core.Formatter) !void {
        try formatter.writeAll("(");
        try formatter.commaList(self.parameters);
        try formatter.writeAll(") -> ");
        try formatter.fmt(self.return_type);
        if (self.effects.len > 0) {
            try formatter.writeAll(" with {");
            try formatter.commaList(self.effects);
            try formatter.writeAll("}");
        }
    }
};

const BASIC_TYPE_NAMES = [_][:0]const u8 {
    "void",
    "bool",
    "u8", "u16", "u32", "u64",
    "s8", "s16", "s32", "s64",
    "f32", "f64",

    "block",
    "handler_set",
    "type",
};

pub const BASIC_TYPE_IDS = type_ids: {
    var type_ids = [1]Core.TypeId { undefined } ** BASIC_TYPE_NAMES.len;

    for (0..BASIC_TYPE_NAMES.len) |i| {
        type_ids[i] = @truncate(i);
    }

    break :type_ids type_ids;
};

pub const BASIC_TYPES = types: {
    var types = [1]Type { undefined } ** BASIC_TYPE_NAMES.len;

    for (BASIC_TYPE_NAMES, 0..) |name, i| {
        types[i] = @unionInit(Type, name, {});
    }

    break :types types;
};

pub const TypeMap = struct {
    inner: std.ArrayHashMapUnmanaged(Core.Type, void, MiscUtils.SimpleHashContext, true) = .{},

    pub fn init() !TypeMap {
        return TypeMap { };
    }

    pub fn deinit(self: *TypeMap, allocator: std.mem.Allocator) void {
        for (self.inner.keys()) |t| {
            t.deinit(allocator);
        }

        self.inner.deinit(allocator);
    }

    /// Calls `Core.Type.clone` on the input, if the type is not found in the map
    pub fn typeId(self: *TypeMap, allocator: std.mem.Allocator, ty: Core.Type) !Core.TypeId {
        if (self.inner.getIndex(ty)) |index| {
            return @truncate(index);
        }

        const index = self.inner.count();

        if (index >= Core.MAX_TYPES) {
            return error.TooManyTypes;
        }

        try self.inner.put(allocator, try ty.clone(allocator), {});

        return @enumFromInt(index);
    }

    /// Does not call `Core.Type.clone` on the input
    pub fn typeIdPreallocated(self: *TypeMap, allocator: std.mem.Allocator, ty: Core.Type) !Core.TypeId {
        if (self.inner.getIndex(ty)) |index| {
            return @enumFromInt(index);
        }

        const index = self.inner.count();

        if (index >= Core.MAX_TYPES) {
            return error.TooManyTypes;
        }

        try self.inner.put(allocator, ty, {});

        return @enumFromInt(index);
    }

    pub fn typeFromNative(self: *TypeMap, comptime T: type, allocator: std.mem.Allocator, parameterNames: ?[]const Core.Name) !Core.Type {
        switch (T) {
            void => return .Nil,
            bool => return .Bool,
            u8 => return .U8, u16 => return .U16, u32 => return .U32, u64 => return .U64,
            i8 => return .S8, i16 => return .S16, i32 => return .S32, i64 => return .S64,
            f32 => return .F32, f64 => return .F64,

            else => switch (@typeInfo(T)) {
                .pointer => |info| return Core.Type { .Pointer = try self.typeIdFromNative(info.child, allocator, null) },
                .array => |info| return Core.Type { .Array = .{
                    .length = info.len,
                    .element = try self.typeIdFromNative(info.child, allocator, null),
                } },
                .@"struct" => |info| {
                    var field_types = try allocator.alloc(Core.TypeId, info.fields.len);
                    errdefer allocator.free(field_types);

                    for (info.fields, 0..) |field, i| {
                        field_types[i] = try self.typeIdFromNative(field.type, allocator, null);
                    }

                    return Core.Type { .Product = field_types };
                },
                .@"enum" => |info| return self.typeFromNative(info.tag_type, allocator, null),
                .@"union" => |info| {
                    var field_types = try allocator.alloc(Core.TypeId, info.fields.len);
                    errdefer allocator.free(field_types);

                    for (info.fields, 0..) |field, i| {
                        field_types[i] = try self.typeIdFromNative(field.type, allocator, null);
                    }

                    if (info.tag_type) |TT| {
                        return Core.Type { .Union = .{
                            .discriminator = try self.typeIdFromNative(TT, allocator, null),
                            .types = field_types,
                        } };
                    } else {
                        return Core.Type { .Sum = field_types };
                    }
                },
                .@"fn" => |info| {
                    const return_type = try self.typeIdFromNative(info.return_type.?, allocator, null);
                    const termination_type = try self.typeIdFromNative(void, allocator, null);

                    const effects = try allocator.alloc(Core.TypeId, 0);
                    errdefer allocator.free(effects);

                    var parameters = try allocator.alloc(Core.types.Function.Parameter, info.params.len);
                    errdefer allocator.free(parameters);

                    inline for (info.params, 0..) |param, i| {
                        parameters[i] = Core.types.Function.Parameter {
                            .name = if (parameterNames) |names| names[i] else std.fmt.comptimePrint("arg{}", .{i}),
                            .type = try self.typeIdFromNative(param.type.?, allocator, null),
                        };
                    }

                    return Core.Type { .Function = .{
                        .return_type = return_type,
                        .termination_type = termination_type,
                        .effects = effects,
                        .parameters = parameters,
                    } };
                },

                else => @compileError("cannot convert type `" ++ @typeName(T) ++ "` to Core.Type"),
            }
        }
    }

    pub fn typeIdFromNative(self: *TypeMap, comptime T: type, allocator: std.mem.Allocator, parameterNames: ?[]const Core.Name) !Core.TypeId {
        const ty = try self.typeFromNative(T, allocator, parameterNames);
        errdefer ty.deinit(allocator);

        return self.typeIdPreallocated(allocator, ty);
    }

    pub fn getType(self: *const TypeMap, id: Core.TypeId) !Core.Type {
        if (@intFromEnum(id) >= self.inner.count()) {
            return error.InvalidType;
        }

        return self.inner.keys()[@intFromEnum(id)];
    }
};
