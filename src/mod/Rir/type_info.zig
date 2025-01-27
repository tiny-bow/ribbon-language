const Rir = @import("../Rir.zig");

const type_info = @This();

const std = @import("std");
const utils = @import("utils");



/// Type representation for all values in Rir;
///
/// Essentially, this is a wrapper for `TypeInfo` that
/// provides additional functionality for working with types.
pub const Type = struct {
    pub const Id = Rir.TypeId;

    ir: *Rir,

    id: Rir.TypeId,
    name: ?Rir.NameId,

    hash: u32,

    info: TypeInfo,


    pub fn init(ir: *Rir, id: Rir.TypeId, name: ?Rir.NameId, info: TypeInfo) Type {
        return Type {
            .ir = ir,
            .id = id,
            .name = name,
            .hash = utils.fnv1a_32(info),
            .info = info,
        };
    }

    pub fn deinit(self: Type) void {
        self.info.deinit(self.ir.allocator);
    }

    pub fn hashWith(self: Type, hasher: anytype) void {
        utils.hashWith(hasher, self.hash);
    }

    pub fn compare(self: Type, other: Type) utils.Ordering {
        const ord = utils.compare(std.meta.activeTag(self.info), std.meta.activeTag(other.info));

        if (ord != .Equal or self.info.isBasic()) return ord;

        return switch (self.info) {
            .Pointer => utils.compare(self.info.Pointer, other.info.Pointer),
            .Slice => utils.compare(self.info.Slice, other.info.Slice),
            .Array => utils.compare(self.info.Array, other.info.Array),

            .Struct => utils.compare(self.info.Struct, other.info.Struct),
            .Union => utils.compare(self.info.Union, other.info.Union),

            .Product => utils.compare(self.info.Product, other.info.Product),
            .Sum => utils.compare(self.info.Sum, other.info.Sum),

            .Function => utils.compare(self.info.Function, other.info.Function),

            inline else => unreachable,
        };
    }

    pub fn format(self: *const Type, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var ownFormatter = false;
        const formatter = switch (@TypeOf(writer)) {
            std.io.AnyWriter => any: {
                ownFormatter = true;
                break :any try Rir.Formatter.init(self.ir, writer);
            },

            Rir.Formatter => writer,

            else => other: {
                ownFormatter = true;
                break :other try Rir.Formatter.init(self.ir, writer.any());
            },
        };
        defer if (ownFormatter) formatter.deinit();

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

    pub fn compareMemory(self: *const Type, a: []const u8, b: []const u8) ! utils.Ordering {
        if (a.ptr == b.ptr and a.len == b.len) return .Equal;

        const layout = try self.ir.getTypeLayout(self.id);

        switch (self.info) {
            .Nil => return .Equal,

            .Bool => return utils.compare(a[0], b[0]),

            .U8 => return utils.compare(@as(*const u8, @alignCast(@ptrCast(a.ptr))).*, @as(*const u8, @alignCast(@ptrCast(b.ptr))).*),
            .U16 => return utils.compare(@as(*const u16, @alignCast(@ptrCast(a.ptr))).*, @as(*const u16, @alignCast(@ptrCast(b.ptr))).*),
            .U32 => return utils.compare(@as(*const u32, @alignCast(@ptrCast(a.ptr))).*, @as(*const u32, @alignCast(@ptrCast(b.ptr))).*),
            .U64 => return utils.compare(@as(*const u64, @alignCast(@ptrCast(a.ptr))).*, @as(*const u64, @alignCast(@ptrCast(b.ptr))).*),

            .S8 => return utils.compare(@as(*const i8, @alignCast(@ptrCast(a.ptr))).*, @as(*const i8, @alignCast(@ptrCast(b.ptr))).*),
            .S16 => return utils.compare(@as(*const i16, @alignCast(@ptrCast(a.ptr))).*, @as(*const i16, @alignCast(@ptrCast(b.ptr))).*),
            .S32 => return utils.compare(@as(*const i32, @alignCast(@ptrCast(a.ptr))).*, @as(*const i32, @alignCast(@ptrCast(b.ptr))).*),
            .S64 => return utils.compare(@as(*const i64, @alignCast(@ptrCast(a.ptr))).*, @as(*const i64, @alignCast(@ptrCast(b.ptr))).*),

            .F32 => return utils.compare(@as(*const f32, @alignCast(@ptrCast(a.ptr))).*, @as(*const f32, @alignCast(@ptrCast(b.ptr))).*),
            .F64 => return utils.compare(@as(*const f64, @alignCast(@ptrCast(a.ptr))).*, @as(*const f64, @alignCast(@ptrCast(b.ptr))).*),

            inline
                .Block,
                .HandlerSet,
                .Pointer,
            => return utils.compare(a, b),

            .Type => return @as(*const Type, @alignCast(@ptrCast(a.ptr))).compare(@as(*const Type, @alignCast(@ptrCast(b.ptr))).*),

            .Slice => |info| {
                const elemLayout = try info.element.getLayout();

                const aPtr: *const [*]u8 = @alignCast(@ptrCast(a.ptr));
                const aLength: *const Rir.Size = @alignCast(@ptrCast(a.ptr + 8));
                const aBuf: []const u8 = aPtr.*[0..aLength.*];

                const bPtr: *const [*]u8 = @alignCast(@ptrCast(b.ptr));
                const bLength: *const Rir.Size = @alignCast(@ptrCast(b.ptr + 8));
                const bBuf: []const u8 = bPtr.*[0..bLength.*];

                if (aPtr.* == bPtr.* and aLength.* == bLength.*) return .Equal;

                var ord = utils.compare(aLength.*, bLength.*);

                if (ord == .Equal) {
                    for (0..aLength.*) |i| {
                        const j = i * elemLayout.dimensions.size;
                        const aElem = aBuf[j..j + elemLayout.dimensions.size];
                        const bElem = bBuf[j..j + elemLayout.dimensions.size];

                        ord = try info.element.compareMemory(aElem, bElem);

                        if (ord != .Equal) break;
                    }
                }

                return ord;
            },

            .Array => |info| {
                const elemLayout = try info.element.getLayout();

                for (0..info.length) |i| {
                    const j = i * elemLayout.dimensions.size;
                    const aElem = a[j..j + elemLayout.dimensions.size];
                    const bElem = b[j..j + elemLayout.dimensions.size];

                    const ord = try info.element.compareMemory(aElem, bElem);
                    if (ord != .Equal) return ord;
                }

                return .Equal;
            },

            .Struct => |info| {
                for (info.fields, 0..) |field, i| {
                    const fieldLayout = try field.type.getLayout();
                    const fieldOffset = layout.field_offsets[i];
                    const fieldMemoryA = a[fieldOffset..fieldOffset + fieldLayout.dimensions.size];
                    const fieldMemoryB = b[fieldOffset..fieldOffset + fieldLayout.dimensions.size];

                    const ord = try field.type.compareMemory(fieldMemoryA, fieldMemoryB);
                    if (ord != .Equal) return ord;
                }

                return .Equal;
            },
            .Union => |info| {
                const discriminatorLayout = try info.discriminator.getLayout();
                const discMemA = a[0..discriminatorLayout.dimensions.size];
                const discMemB = b[0..discriminatorLayout.dimensions.size];

                const discOrd = try info.discriminator.compareMemory(discMemA, discMemB);
                if (discOrd != .Equal) return discOrd;

                for (info.fields) |field| {
                    const fieldDiscMem = field.discriminant.getMemory();

                    if (try info.discriminator.compareMemory(discMemA, fieldDiscMem) == .Equal) {
                        const fieldLayout = try field.type.getLayout();
                        const fieldMemoryA = a[layout.field_offsets[1]..layout.field_offsets[1] + fieldLayout.dimensions.size];
                        const fieldMemoryB = b[layout.field_offsets[1]..layout.field_offsets[1] + fieldLayout.dimensions.size];

                        return field.type.compareMemory(fieldMemoryA, fieldMemoryB);
                    }
                }

                unreachable;
            },

            .Product => |type_set| {
                for (type_set, 0..) |T, i| {
                    const TLayout = try T.getLayout();
                    const offset = layout.field_offsets[i];
                    const memoryA = a[offset..offset + TLayout.dimensions.size];
                    const memoryB = b[offset..offset + TLayout.dimensions.size];

                    const ord = try T.compareMemory(memoryA, memoryB);
                    if (ord != .Equal) return ord;
                }

                return .Equal;
            },

            .Sum => |_| return utils.compare(a, b),

            .Function => |_| return utils.compare(a, b),
        }
    }

    pub fn formatMemory(self: *const Type, formatter: Rir.Formatter, memory: []const u8) !void {
        const layout = try self.getLayout();

        if (!layout.canUseMemory(memory)) {
            return error.InvalidMemory;
        }

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
                try formatter.print("array({})[", .{info.length});
                try formatter.beginBlock();
                    const elemSize = @divExact(memory.len, info.length);
                    for (0..info.length) |i| {
                        if (i > 0) {
                            try formatter.writeAll(",");
                            try formatter.endLine();
                        }
                        try info.element.formatMemory(formatter, memory[i * elemSize..]);
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

                        const fieldLayout = try field.type.getLayout();
                        const fieldOffset = layout.field_offsets[i];
                        const fieldMemory = (memory.ptr + fieldOffset)[0..fieldLayout.dimensions.size];

                        try formatter.print("{} = ", .{formatter.wrap(field.name)});

                        try field.type.formatMemory(formatter, fieldMemory);
                    }
                try formatter.endBlock();
                try formatter.endLine();
                try formatter.writeAll("}");
            },

            .Union => |info| {
                const discriminatorLayout = try info.discriminator.getLayout();
                const discMem = memory[0..discriminatorLayout.dimensions.size];

                for (info.fields) |field| {
                    const fieldDiscMem = field.discriminant.getMemory();

                    if (try info.discriminator.compareMemory(discMem, fieldDiscMem) == .Equal) {
                        const fieldLayout = try field.type.getLayout();
                        const fieldMemory = (memory.ptr + layout.field_offsets[1])[0..fieldLayout.dimensions.size];

                        try formatter.print("{}.{}(", .{formatter.wrap(self.id), formatter.wrap(field.name)});

                        try field.type.formatMemory(formatter, fieldMemory);

                        try formatter.writeAll(")");

                        return;
                    }
                }

                unreachable;
            },

            .Product => |type_set| {
                try formatter.writeAll("(");
                try formatter.beginBlock();
                    for (type_set, 0..) |T, i| {
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

    pub fn getLayout(self: *const Type) error{InvalidType, OutOfMemory}! *const Rir.Layout {
        return self.ir.getTypeLayout(self.id);
    }

    pub fn createPointer(self: *const Type) error{OutOfMemory, TooManyTypes}! *Type {
        return self.ir.createType(null, .{ .Pointer = .{ .element = @constCast(self) } });
    }

    pub fn checkNative(self: *const Type, comptime T: type) error{TypeMismatch, TooManyTypes, TooManyNames, OutOfMemory}! void {
        const t = try self.ir.createTypeFromNative(T, null, null);

        if (t.compare(self.*) != .Equal) {
            return error.TypeMismatch;
        }
    }
};

/// A set of un-discriminated types (i.e. a product or sum type)
pub const TypeSet = []*Rir.Type;

/// The discriminator type of `TypeInfo`
pub const TypeTag = std.meta.Tag(TypeInfo);

/// This is a union representing all possible Rir operand types
///
/// To use `TypeInfo` within an Rir instance, it must be wrapped in a de-duplicated `Type` via `Rir.createType`
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

            .Product => |x| .{.Product = try allocator.dupe(*Rir.Type, x)},
            .Sum => |x| .{.Sum = try allocator.dupe(*Rir.Type, x)},

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

    /// Extract a `Nil` from a `Type` or return `error.ExpectedNilType`
    pub fn forceNil(self: *const TypeInfo) error{ExpectedNilType}! void {
        switch (self.*) {
            .Nil => return,
            inline else => return error.ExpectedNilType,
        }
    }

    /// Extract a `Bool` from a `Type` or return `error.ExpectedBoolType`
    pub fn forceBool(self: *const TypeInfo) error{ExpectedBoolType}! void {
        switch (self.*) {
            .Bool => return,
            inline else => return error.ExpectedBoolType,
        }
    }

    /// Extract a `U8` from a `Type` or return `error.ExpectedU8Type`
    pub fn forceU8(self: *const TypeInfo) error{ExpectedU8Type}! void {
        switch (self.*) {
            .U8 => return,
            inline else => return error.ExpectedU8Type,
        }
    }

    /// Extract a `U16` from a `Type` or return `error.ExpectedU16Type`
    pub fn forceU16(self: *const TypeInfo) error{ExpectedU16Type}! void {
        switch (self.*) {
            .U16 => return,
            inline else => return error.ExpectedU16Type,
        }
    }

    /// Extract a `U32` from a `Type` or return `error.ExpectedU32Type`
    pub fn forceU32(self: *const TypeInfo) error{ExpectedU32Type}! void {
        switch (self.*) {
            .U32 => return,
            inline else => return error.ExpectedU32Type,
        }
    }

    /// Extract a `U64` from a `Type` or return `error.ExpectedU64Type`
    pub fn forceU64(self: *const TypeInfo) error{ExpectedU64Type}! void {
        switch (self.*) {
            .U64 => return,
            inline else => return error.ExpectedU64Type,
        }
    }

    /// Extract a `S8` from a `Type` or return `error.ExpectedS8Type`
    pub fn forceS8(self: *const TypeInfo) error{ExpectedS8Type}! void {
        switch (self.*) {
            .S8 => return,
            inline else => return error.ExpectedS8Type,
        }
    }

    /// Extract a `S16` from a `Type` or return `error.ExpectedS16Type`
    pub fn forceS16(self: *const TypeInfo) error{ExpectedS16Type}! void {
        switch (self.*) {
            .S16 => return,
            inline else => return error.ExpectedS16Type,
        }
    }

    /// Extract a `S32` from a `Type` or return `error.ExpectedS32Type`
    pub fn forceS32(self: *const TypeInfo) error{ExpectedS32Type}! void {
        switch (self.*) {
            .S32 => return,
            inline else => return error.ExpectedS32Type,
        }
    }

    /// Extract a `S32` from a `Type` or return `error.ExpectedS32Type`
    pub fn forceS64(self: *const TypeInfo) error{ExpectedS64Type}! void {
        switch (self.*) {
            .S64 => return,
            inline else => return error.ExpectedS64Type,
        }
    }

    /// Extract a `F32` from a `Type` or return `error.ExpectedF32Type`
    pub fn forceF32(self: *const TypeInfo) error{ExpectedF32Type}! void {
        switch (self.*) {
            .F32 => return,
            inline else => return error.ExpectedF32Type,
        }
    }

    /// Extract a `F64` from a `Type` or return `error.ExpectedF64Type`
    pub fn forceF64(self: *const TypeInfo) error{ExpectedF64Type}! void {
        switch (self.*) {
            .F64 => return,
            inline else => return error.ExpectedF64Type,
        }
    }

    /// Extract a `Block` from a `Type` or return `error.ExpectedBlockType`
    pub fn forceBlock(self: *const TypeInfo) error{ExpectedBlockType}! void {
        switch (self.*) {
            .Block => return,
            inline else => return error.ExpectedBlockType,
        }
    }

    /// Extract a `HandlerSet` from a `Type` or return `error.ExpectedHandlerSetType`
    pub fn forceHandlerSet(self: *const TypeInfo) error{ExpectedHandlerSetType}! void {
        switch (self.*) {
            .HandlerSet => return,
            inline else => return error.ExpectedHandlerSetType,
        }
    }

    /// Extract a `Type` from a `Type` or return `error.ExpectedTypeType`
    pub fn forceType(self: *const TypeInfo) error{ExpectedTypeType}! void {
        switch (self.*) {
            .Type => return,
            inline else => return error.ExpectedTypeType,
        }
    }

    /// Extract a `Pointer` from a `Type` or return `error.ExpectedPointerType`
    pub fn forcePointer(self: *const TypeInfo) error{ExpectedPointerType}! Pointer {
        switch (self.*) {
            .Pointer => |ptr| return ptr,
            inline else => return error.ExpectedPointerType,
        }
    }

    /// Extract a `Slice` from a `Type` or return `error.ExpectedSliceType`
    pub fn forceSlice(self: *const TypeInfo) error{ExpectedSliceType}! Slice {
        switch (self.*) {
            .Slice => |slice| return slice,
            inline else => return error.ExpectedSliceType,
        }
    }

    /// Extract an `Array` from a `Type` or return `error.ExpectedArrayType`
    pub fn forceArray(self: *const TypeInfo) error{ExpectedArrayType}! Array {
        switch (self.*) {
            .Array => |array| return array,
            inline else => return error.ExpectedArrayType,
        }
    }

    /// Extract a `Struct` from a `Type` or return `error.ExpectedStructType`
    pub fn forceStruct(self: *const TypeInfo) error{ExpectedStructType}! Struct {
        switch (self.*) {
            .Struct => |str| return str,
            inline else => return error.ExpectedStructType,
        }
    }

    /// Extract a `Union` from a `Type` or return `error.ExpectedUnionType`
    pub fn forceUnion(self: *const TypeInfo) error{ExpectedUnionType}! Union {
        switch (self.*) {
            .Union => |@"union"| return @"union",
            inline else => return error.ExpectedUnionType,
        }
    }

    /// Extract a `Product` from a `Type` or return `error.ExpectedProductType`
    pub fn forceProduct(self: *const TypeInfo) error{ExpectedProductType}! TypeSet {
        switch (self.*) {
            .Product => |set| return set,
            inline else => return error.ExpectedProductType,
        }
    }

    /// Extract a `Sum` from a `Type` or return `error.ExpectedSumType`
    pub fn forceSum(self: *const TypeInfo) error{ExpectedSumType}! TypeSet {
        switch (self.*) {
            .Sum => |set| return set,
            inline else => return error.ExpectedSumType,
        }
    }

    /// Extract a `Function` from a `Type` or return `error.ExpectedFunctionType`
    pub fn forceFunction(self: *const TypeInfo) error{ExpectedFunctionType}! Function {
        switch (self.*) {
            .Function => |fun| return fun,
            inline else => return error.ExpectedFunctionType,
        }
    }

    /// Generate an `Rir.Layout` based on this `TypeInfo`
    pub fn computeLayout(self: *const TypeInfo, ir: *Rir) error{InvalidType, OutOfMemory}!Rir.Layout {
        return switch (self.*) {
            .Nil => .{.local_storage = .zero_size, .dimensions = .{ .size = 0, .alignment = 1 }},

            .Bool => .{.local_storage = .register, .dimensions = .{ .size = 1, .alignment = 1 }},

            .U8  => .{.local_storage = .register, .dimensions = .{ .size = 1, .alignment = 1 }},
            .U16 => .{.local_storage = .register, .dimensions = .{ .size = 2, .alignment = 2 }},
            .U32 => .{.local_storage = .register, .dimensions = .{ .size = 4, .alignment = 4 }},
            .U64 => .{.local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 }},

            .S8  => .{.local_storage = .register, .dimensions = .{ .size = 1, .alignment = 1 }},
            .S16 => .{.local_storage = .register, .dimensions = .{ .size = 2, .alignment = 2 }},
            .S32 => .{.local_storage = .register, .dimensions = .{ .size = 4, .alignment = 4 }},
            .S64 => .{.local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 }},

            .F32 => .{.local_storage = .register, .dimensions = .{ .size = 4, .alignment = 4 }},
            .F64 => .{.local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 }},

            .Block => .{.local_storage = .none, .dimensions = .fromNativeType(Rir.BlockId)},
            .HandlerSet => .{.local_storage = .none, .dimensions = .fromNativeType(Rir.HandlerSetId)},
            .Type => .{.local_storage = .none, .dimensions = .fromNativeType(Rir.TypeId)},

            .Pointer => .{.local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 }},
            .Slice => .{
                .local_storage = .fromRegisters(2),
                .dimensions = .{ .size = 16, .alignment = 8 },
                .field_offsets = try ir.allocator.dupe(Rir.Offset, &.{0, 8}),
            },

            .Array => |info| Array: {
                const elemLayout = try info.element.getLayout();

                const size = utils.alignTo(elemLayout.dimensions.size, elemLayout.dimensions.alignment) * info.length;

                break :Array .{
                    .local_storage = .fromSize(size),
                    .dimensions = .{
                        .size = size,
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
                    const fieldLayout = try field.type.getLayout();

                    maxAlignment = @max(maxAlignment, fieldLayout.dimensions.alignment);

                    if (dimensions.alignment < fieldLayout.dimensions.alignment) {
                        dimensions.size += utils.alignmentDelta(dimensions.size, fieldLayout.dimensions.alignment);
                    }

                    dimensions.alignment = fieldLayout.dimensions.alignment;

                    offsets[i] = dimensions.size;

                    dimensions.size += utils.alignTo(fieldLayout.dimensions.size, fieldLayout.dimensions.alignment);
                }

                dimensions.alignment = maxAlignment;
                dimensions.size += utils.alignmentDelta(dimensions.size, maxAlignment);

                break :Struct .{
                    .local_storage = .fromSize(dimensions.size),
                    .dimensions = dimensions,
                    .field_offsets = offsets,
                };
            },

            .Union => |info| Union: {
                var dimensions = Rir.Dimensions {};

                const discriminatorLayout = try info.discriminator.getLayout();

                for (info.fields) |field| {
                    const fieldLayout = try field.type.getLayout();

                    dimensions.alignment = @max(dimensions.alignment, fieldLayout.dimensions.alignment);
                    dimensions.size = @max(dimensions.size, fieldLayout.dimensions.size);
                }

                var offsets = try ir.allocator.alloc(Rir.Offset, 2);
                errdefer ir.allocator.free(offsets);

                const sumDimensions = dimensions;
                const sumPadding = utils.alignmentDelta(discriminatorLayout.dimensions.size, dimensions.alignment);

                offsets[0] = 0;
                offsets[1] = discriminatorLayout.dimensions.size + sumPadding;

                dimensions.alignment = @max(dimensions.alignment, discriminatorLayout.dimensions.alignment);
                dimensions.size += discriminatorLayout.dimensions.size;
                dimensions.size += sumPadding;

                if (sumDimensions.alignment < dimensions.alignment) {
                    dimensions.size += utils.alignmentDelta(dimensions.size, dimensions.alignment);
                }

                break :Union .{
                    .local_storage = .fromSize(dimensions.size),
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
                    const fieldLayout = try T.getLayout();

                    maxAlignment = @max(maxAlignment, fieldLayout.dimensions.alignment);

                    if (dimensions.alignment < fieldLayout.dimensions.alignment) dimensions.size += utils.alignmentDelta(dimensions.size, fieldLayout.dimensions.alignment);

                    dimensions.alignment = fieldLayout.dimensions.alignment;

                    offsets[i] = dimensions.size;
                }

                dimensions.alignment = maxAlignment;
                dimensions.size += utils.alignmentDelta(dimensions.size, maxAlignment);

                break :Product .{
                    .local_storage = .fromSize(dimensions.size),
                    .dimensions = dimensions,
                    .field_offsets = offsets,
                };
            },

            .Sum => |type_set| Sum: {
                var dimensions = Rir.Dimensions {};

                for (type_set) |T| {
                    const variantLayout = try T.getLayout();

                    dimensions.alignment = @max(dimensions.alignment, variantLayout.dimensions.alignment);
                    dimensions.size = @max(dimensions.size, variantLayout.dimensions.size);
                }

                break :Sum .{
                    .local_storage = .fromSize(dimensions.size),
                    .dimensions = dimensions,
                };
            },

            .Function => .{
                .local_storage = .register,
                .dimensions = .{ .size = 2, .alignment = 2 }
            },
        };
    }

    /// Create a `TypeInfo` from a native type
    ///
    /// `parameterNames` is used, if provided, to give names for (top-level) function parameters if the native type is a function type
    pub fn fromNative(comptime T: type, rir: *Rir, parameterNames: ?[]const Rir.NameId) !Rir.TypeInfo {
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

                    const effects = try rir.allocator.alloc(*Rir.Type, 0);
                    errdefer rir.allocator.free(effects);

                    var parameters = try rir.allocator.alloc(Rir.type_info.Parameter, info.params.len);
                    errdefer rir.allocator.free(parameters);

                    inline for (info.params, 0..) |param, i| {
                        const paramType = try rir.createTypeFromNative(param.type.?, null, null);

                        parameters[i] = Rir.type_info.Parameter {
                            .name =
                                if (parameterNames) |names| names[i]
                                else try rir.internName(std.fmt.comptimePrint("arg{}", .{i})),
                            .type = paramType,
                        };
                    }

                    return Rir.TypeInfo { .Function = .{
                        .return_type = returnType,
                        .termination_type = terminationType,
                        .effects = effects,
                        .parameters = parameters,
                    } };
                },

                else => @compileError("cannot convert type `" ++ @typeName(T) ++ "` to Rir.Type"),
            }
        }
    }
};


pub const Pointer = struct {
    alignment_override: ?Rir.Alignment = null,
    element: *Rir.Type,
};

pub const Slice = struct {
    alignment_override: ?Rir.Alignment = null,
    element: *Rir.Type,
};

pub const Array = struct {
    length: u64,
    element: *Rir.Type,

    pub fn onFormat(self: Array, formatter: Rir.Formatter) !void {
        try formatter.writeAll("[");
        try formatter.fmt(self.length);
        try formatter.writeAll("]");
        try formatter.fmt(self.element);
    }
};

pub const StructField = struct {
    name: Rir.NameId,
    type: *Rir.Type,

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
    discriminant: Rir.Immediate,
    name: Rir.NameId,
    type: *Rir.Type,

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
    discriminator: *Rir.Type,
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
    name: Rir.NameId,
    type: *Rir.Type,

    pub fn onFormat(self: Parameter, formatter: Rir.Formatter) !void {
        try formatter.fmt(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
    }
};

pub const Function = struct {
    return_type: *Rir.Type,
    termination_type: *Rir.Type,
    effects: []const *Rir.Type,
    parameters: []const Parameter,

    pub fn deinit(self: Function, allocator: std.mem.Allocator) void {
        allocator.free(self.effects);
        allocator.free(self.parameters);
    }

    pub fn clone(self: *const Function, allocator: std.mem.Allocator) !Function {
        const effects = try allocator.dupe(*Rir.Type, self.effects);
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
