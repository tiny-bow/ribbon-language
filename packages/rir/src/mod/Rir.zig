const Rir = @This();

test {
    std.testing.refAllDeclsRecursive(Rir);
}

const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const TypeUtils = @import("Utils").Type;
const Rbc = @import("Rbc");

pub const log = std.log.scoped(.Rir);

pub const block = @import("Rir/block.zig");
pub const Block = block.Block;

pub const foreign = @import("Rir/foreign.zig");
pub const ForeignAddress = foreign.ForeignAddress;

pub const fmt = @import("Rir/fmt.zig");
pub const Formatter = fmt.Formatter;

pub const function = @import("Rir/function.zig");
pub const Function = function.Function;

pub const handler_set = @import("Rir/handler_set.zig");
pub const HandlerSet = handler_set.HandlerSet;

pub const module = @import("Rir/module.zig");
pub const Module = module.Module;

pub const instruction = @import("Rir/instruction.zig");
pub const Instruction = instruction.Instruction;
pub const Operand = instruction.Operand;
pub const OpCode = instruction.OpCode;
pub const OpData = instruction.OpData;
pub const Register = instruction.Register;
pub const RValue = instruction.RValue;

pub const type_info = @import("Rir/type_info.zig");
pub const Type = type_info.Type;
pub const TypeInfo = type_info.TypeInfo;

pub const variable = @import("Rir/variable.zig");
pub const Local = variable.Local;
pub const Global = variable.Global;

pub const Error = std.mem.Allocator.Error || error {
    InvalidIndex,

    InvalidType,
    InvalidOperand,
    InvalidLocal,
    InvalidUpvalue,
    InvalidGlobal,
    InvalidFunction,
    InvalidModule,
    InvalidForeign,
    InvalidEvidence,
    InvalidBlock,
    InvalidHandlerSet,
    InvalidName,

    TooManyTypes,
    TooManyLocals,
    TooManyUpvalues,
    TooManyGlobals,
    TooManyEvidences,
    TooManyFunctions,
    TooManyForeignAddresses,
    TooManyBlocks,
    TooManyHandlerSets,
    TooManyNames,

    MultipleExits,
};

pub const MAX_MODULES = std.math.maxInt(std.meta.Tag(Rir.ModuleId));
pub const MAX_TYPES = std.math.maxInt(std.meta.Tag(Rir.TypeId));
pub const MAX_GLOBALS = std.math.maxInt(std.meta.Tag(Rir.GlobalId));
pub const MAX_FOREIGN_ADDRESSES = std.math.maxInt(std.meta.Tag(Rir.ForeignId));
pub const MAX_FUNCTIONS = std.math.maxInt(std.meta.Tag(Rir.FunctionId));
pub const MAX_HANDLER_SETS = std.math.maxInt(std.meta.Tag(Rir.HandlerSetId));
pub const MAX_EVIDENCE = Rbc.EVIDENCE_SENTINEL;
pub const MAX_BLOCKS = Rbc.MAX_BLOCKS;
pub const MAX_REGISTERS = Rbc.MAX_REGISTERS;
pub const MAX_LOCALS = std.math.maxInt(std.meta.Tag(Rir.LocalId));
pub const MAX_NAMES = std.math.maxInt(std.meta.Tag(Rir.NameId));

pub const ModuleId = NewType("ModuleId", u16);
pub const RegisterId = NewType("RegisterId", Rbc.RegisterIndex);
pub const RegisterOffset = NewType("RegisterOffset", Rbc.RegisterLocalOffset);
pub const HandlerSetId = NewType("HandlerSetId", Rbc.HandlerSetIndex);
pub const TypeId = NewType("TypeId", Rbc.Info.TypeIndex);
pub const BlockId = NewType("BlockId", Rbc.BlockIndex);
pub const FunctionId = NewType("FunctionId", Rbc.FunctionIndex);
pub const ForeignId = NewType("ForeignId", Rbc.ForeignId);
pub const GlobalId = NewType("GlobalId", Rbc.GlobalIndex);
pub const UpvalueId = NewType("UpvalueId", Rbc.UpvalueIndex);
pub const EvidenceId = NewType("EvidenceId", Rbc.EvidenceIndex);
pub const LocalId = NewType("LocalId", u16);
pub const NameId = NewType("NameId", u16);
pub const FieldId = NewType("FieldId", u16);

// pub const Name = [:0]const u8;

pub const Index = u8;
pub const Arity = u8;
pub const Alignment = u12; // 2^12 = 4096 = page size; should be enough for anyone (famous last words)
pub const Size = u64;
pub const Offset = u64;

pub const RegisterIndex = Rbc.RegisterIndex;

pub const Dimensions = packed struct {
    size: Size = 0,
    alignment: Alignment = 1,

    pub fn fromNativeType(comptime T: type) Dimensions {
        return Dimensions {
            .size = @sizeOf(T),
            .alignment = @intCast(@alignOf(T)),
        };
    }
};

pub const Layout = struct {
    dimensions: Dimensions,
    field_offsets: []Offset = &.{},

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.field_offsets);
    }

    pub fn format(self: *const Layout, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}x{}", .{self.dimensions.size, self.dimensions.alignment});
    }

    pub fn canUseMemory(self: *const Layout, memory: []const u8) bool {
        return std.mem.isAligned(@intFromPtr(memory.ptr), self.dimensions.alignment);
    }

    pub fn fromDimensions(dimensions: Dimensions) Layout {
        return Layout {
            .dimensions = dimensions,
        };
    }

    pub fn fromNativeType(comptime T: type, allocator: std.mem.Allocator) Layout {
        const dimensions = Dimensions.fromNativeType(T);

        const field_offsets = switch (@typeInfo(T)) {
            .@"struct" => |info| structure: {
                const offsets = try allocator.alloc(Offset, info.field_count);

                const base: *T = @bitCast(0);

                inline for (info.fields, 0..) |field, i| {
                    offsets[i] = @field(base.*, field.name);
                }

                break :structure offsets;
            },
            inline else => &[0]Offset{},
        };

        return Layout {
            .dimensions = dimensions,
            .field_offsets = field_offsets,
        };
    }
};

pub fn Ref (comptime T: type) type {
    return packed struct {
        module: Rir.ModuleId,
        id: T,

        const Self = @This();

        pub fn onFormat(self: Self, formatter: Rir.Formatter) !void {
            try formatter.fmt(self.module);
            try formatter.writeAll("/");
            try formatter.fmt(self.id);
        }

        pub fn format(self: Self, comptime _: []const u8, _: anytype, writer: anytype) !void {
            try writer.print("[{}:{}]", .{self.module, self.id});
        }
    };
}


fn NewType(comptime NewTypeName: []const u8, comptime Tag: type) type {
    return enum(Tag) {
        const Self = @This();

        _,

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) ! void {
            return writer.print("{s}-{x}", .{NewTypeName, @intFromEnum(self)});
        }
    };
}


const LayoutMap = std.ArrayHashMapUnmanaged(Rir.TypeId, Rir.Layout, MiscUtils.SimpleHashContext, false);
const TypeMap = std.ArrayHashMapUnmanaged(Rir.Type, void, TypeContext, false);
const ForeignList = std.ArrayListUnmanaged(*Rir.ForeignAddress);
const ModuleList = std.ArrayListUnmanaged(*Rir.Module);

const TypeContext = struct {
    pub fn hash(_: TypeContext, v: Rir.Type) u32 {
        return v.hash;
    }

    pub fn eql(_: TypeContext, a: Rir.Type, b: Rir.Type, _: anytype) bool {
        return MiscUtils.equal(a.info, b.info);
    }
};

pub const Interner = std.ArrayHashMapUnmanaged([:0]const u8, void, InternerContext, true);
pub const InternerContext = struct {
    pub fn eql(_: InternerContext, a: anytype, b: anytype, _: anytype) bool {
        return @intFromPtr(a.ptr) == @intFromPtr(b.ptr)
            or (a.len == b.len and std.mem.eql(u8, a.ptr[0..a.len], b.ptr[0..b.len]));
    }

    pub fn hash(_: InternerContext, a: anytype) u32 {
        return MiscUtils.fnv1a_32(a);
    }
};



allocator: std.mem.Allocator,
interner: Interner = .{},
type_map: TypeMap = .{},
layout_map: LayoutMap = .{},
foreign_list: ForeignList = .{},
module_list: ModuleList = .{},


pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}! *Rir {
    var self = try allocator.create(Rir);

    self.* = Rir {
        .allocator = allocator,
    };
    errdefer self.deinit();

    for (Rir.type_info.BASIC_TYPE_INFO, 0..) |bt, i| {
        const name = self.internName(Rir.type_info.BASIC_TYPE_NAMES[i])
            catch |err| return TypeUtils.forceErrorSet(error{OutOfMemory}, err);

        _ = self.createType(name, bt)
            catch |err| return TypeUtils.forceErrorSet(error{OutOfMemory}, err);
    }

    return self;
}

pub fn deinit(self: *Rir) void {
    for (self.interner.keys()) |name| {
        self.allocator.free(name);
    }

    self.interner.deinit(self.allocator);

    for (self.type_map.keys()) |t| {
        t.deinit();
    }

    self.type_map.deinit(self.allocator);

    for (self.foreign_list.items) |f| {
        f.deinit();
    }

    for (self.layout_map.values()) |l| {
        l.deinit(self.allocator);
    }

    self.layout_map.deinit(self.allocator);

    self.foreign_list.deinit(self.allocator);

    for (self.module_list.items) |mod| {
        mod.deinit();
    }

    self.module_list.deinit(self.allocator);

    self.allocator.destroy(self);
}

pub fn onFormat(self: *const Rir, formatter: Rir.Formatter) Rir.Formatter.Error! void {
    if (self.type_map.count() > Rir.type_info.BASIC_TYPE_NAMES.len) {
        const oldTypeMode = formatter.swapFlag(.show_nominative_type_bodies, true);
        defer formatter.setFlag(.show_nominative_type_bodies, oldTypeMode);

        try formatter.writeAll("types = ");
        try formatter.beginBlock();
        for (Rir.type_info.BASIC_TYPE_NAMES.len..self.type_map.count()) |i| {
            if (i > Rir.type_info.BASIC_TYPE_NAMES.len) try formatter.endLine();
            try formatter.fmt(@as(Rir.TypeId, @enumFromInt(i)));
        }
        try formatter.endBlock();
        try formatter.endLine();
    }

    if (self.foreign_list.items.len > 0) {
        try formatter.writeAll("foreign = ");
        try formatter.block(self.foreign_list.items);
        try formatter.endLine();
    }

    if (self.module_list.items.len > 0) {
        try formatter.writeAll("modules = ");
        try formatter.block(self.module_list.items);
        try formatter.endLine();
    }
}


/// Intern a string, yielding a Name
pub fn internName(self: *Rir, name: []const u8) error{TooManyNames, OutOfMemory}! Rir.NameId {
    if (self.interner.getIndexAdapted(name, InternerContext{})) |interned| {
        return @enumFromInt(interned);
    }

    const index = self.interner.count();
    if (index >= Rir.MAX_NAMES) {
        return error.TooManyNames;
    }

    const interned = try self.allocator.allocWithOptions(u8, name.len, 1, 0);

    @memcpy(interned, name);

    try self.interner.put(self.allocator, interned, {});

    return @enumFromInt(index);
}

pub fn getName(self: *const Rir, id: Rir.NameId) error{InvalidName}! []const u8 {
    if (@intFromEnum(id) >= self.interner.count()) {
        return error.InvalidName;
    }

    return self.interner.keys()[@intFromEnum(id)];
}

/// Calls `Rir.Type.clone` on the input, if the type is not found in the map
pub fn createType(self: *Rir, name: ?Rir.NameId, info: Rir.TypeInfo) error{OutOfMemory, TooManyTypes}! *Rir.Type {
    const index = self.type_map.count();

    if (index >= Rir.MAX_TYPES) {
        return error.TooManyTypes;
    }

    var ty = Rir.Type {
        .ir = self,
        .id = @enumFromInt(index),
        .name = name,
        .hash = MiscUtils.fnv1a_32(info),
        .info = info,
    };

    const getOrPut = try self.type_map.getOrPut(self.allocator, ty);

    if (!getOrPut.found_existing) {
        getOrPut.key_ptr.info = try ty.info.clone(self.allocator);
        getOrPut.value_ptr.* = {};
    }

    return getOrPut.key_ptr;
}

/// Does not call `Rir.Type.clone` on the input
pub fn createTypePreallocated(self: *Rir, name: ?Rir.NameId, deinitInfoIfExisting: bool, info: Rir.TypeInfo) error{OutOfMemory, TooManyTypes}! *Rir.Type {
    const index = self.type_map.count();

    if (index >= Rir.MAX_TYPES) {
        return error.TooManyTypes;
    }

    const ty = Rir.Type {
        .ir = self,
        .id = @enumFromInt(index),
        .name = name,
        .hash = MiscUtils.fnv1a_32(info),
        .info = info,
    };

    const getOrPut = try self.type_map.getOrPut(self.allocator, ty);

    if (!getOrPut.found_existing) {
        getOrPut.value_ptr.* = {};
    } else if (deinitInfoIfExisting) {
        info.deinit(self.allocator);
    }

    return getOrPut.key_ptr;
}

pub fn createTypeFromNative(self: *Rir, comptime T: type, name: ?Rir.NameId, parameterNames: ?[]const Rir.NameId) error{TooManyTypes, TooManyNames, OutOfMemory}! *Rir.Type {
    const info = try TypeInfo.fromNative(T, self, parameterNames);
    errdefer info.deinit(self.allocator);

    return self.createTypePreallocated(name, true, info);
}

pub fn getType(self: *const Rir, id: Rir.TypeId) error{InvalidType}! *Rir.Type {
    if (@intFromEnum(id) >= self.type_map.count()) {
        return error.InvalidType;
    }

    return &self.type_map.keys()[@intFromEnum(id)];
}

pub fn getTypeLayout(self: *Rir, id: Rir.TypeId) error{InvalidType, OutOfMemory}! *const Rir.Layout {
    const getOrPut = try self.layout_map.getOrPut(self.allocator, id);

    if (!getOrPut.found_existing) {
        const ty = try self.getType(id);

        getOrPut.value_ptr.* = try ty.info.computeLayout(self);
    }

    return getOrPut.value_ptr;
}


/// Calls `allocator.dupe` on the input locals
pub fn createForeign(self: *Rir, name: Rir.NameId, tyId: Rir.TypeId, locals: []Rir.TypeId) error{TooManyForeignAddresses, OutOfMemory}! *Rir.ForeignAddress {
    const dupeLocals = try self.allocator.dupe(Rir.TypeId, locals);
    errdefer self.allocator.free(dupeLocals);

    return self.foreignPreallocated(name, tyId, dupeLocals);
}

/// Does not call `allocator.dupe` on the input locals
pub fn foreignPreallocated(self: *Rir, name: Rir.NameId, tyId: Rir.TypeId, locals: []Rir.TypeId) error{TooManyForeignAddresses, OutOfMemory}! *Rir.ForeignAddress {
    const index = self.foreign_list.items.len;

    if (index >= Rir.MAX_FOREIGN_ADDRESSES) {
        return error.TooManyForeignAddresses;
    }

    const f = try Rir.ForeignAddress.init(self, @enumFromInt(index), name, tyId, locals);
    errdefer self.allocator.destroy(f);

    try self.foreign_list.append(self.allocator, f);

    return f;
}

pub fn getForeign(self: *Rir, id: Rir.ForeignId) error{InvalidForeign}! *Rir.ForeignAddress {
    if (@intFromEnum(id) >= self.foreign_list.items.len) {
        return error.InvalidForeign;
    }

    return self.foreign_list.items[@intFromEnum(id)];
}


pub fn createModule(self: *Rir, name: Rir.NameId) error{InvalidModule, OutOfMemory}! *Rir.Module {
    const id = self.module_list.items.len;

    if (id >= Rir.MAX_MODULES) {
        return error.InvalidModule;
    }

    const mod = try Rir.Module.init(self, @enumFromInt(id), name);
    errdefer self.allocator.destroy(mod);

    try self.module_list.append(self.allocator, mod);

    return mod;
}

pub fn getModule(self: *const Rir, id: Rir.ModuleId) error{InvalidModule}! *Rir.Module {
    if (@intFromEnum(id) >= self.module_list.items.len) {
        return error.InvalidModule;
    }

    return self.module_list.items[@intFromEnum(id)];
}

pub fn getGlobal(self: *const Rir, ref: Rir.Ref(Rir.GlobalId)) error{InvalidModule, InvalidGlobal}! *Rir.Global {
    const mod = try self.getModule(ref.module);

    return mod.getGlobal(ref.id);
}

pub fn getFunction(self: *const Rir, ref: Rir.Ref(Rir.FunctionId)) error{InvalidModule, InvalidFunction}! *Rir.Function {
    const mod = try self.getModule(ref.module);

    return mod.getFunction(ref.id);
}
