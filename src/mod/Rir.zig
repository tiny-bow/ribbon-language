const Rir = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");

pub const log = std.log.scoped(.rir);

test {
    std.testing.refAllDeclsRecursive(Rir);
}

// type Rir

allocator: std.mem.Allocator,
interner: Interner = .{},
type_map: TypeMap = .{},
layout_map: LayoutMap = .{},
foreign_list: ForeignList = .{},
module_list: ModuleList = .{},

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!*Rir {
    var self = try allocator.create(Rir);

    self.* = Rir{
        .allocator = allocator,
    };
    errdefer self.deinit();

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

pub fn onFormat(self: *const Rir, formatter: Formatter) Formatter.Error!void {
    if (self.type_map.count() > 0) {
        const oldTypeMode = formatter.swapFlag(.show_nominative_type_bodies, true);
        defer formatter.setFlag(.show_nominative_type_bodies, oldTypeMode);

        try formatter.writeAll("types = ");
        try formatter.beginBlock();
        for (0..self.type_map.count()) |i| {
            if (i > 0) try formatter.endLine();
            try formatter.fmt(@as(TypeId, @enumFromInt(i)));
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
pub fn internName(self: *Rir, name: []const u8) error{OutOfMemory}!NameId {
    if (self.interner.getIndexAdapted(name, InternerContext{})) |interned| {
        return @enumFromInt(interned);
    }

    const index = self.interner.count();
    if (index >= MAX_NAMES) {
        return error.OutOfMemory;
    }

    const interned = try self.allocator.allocWithOptions(u8, name.len, 1, 0);

    @memcpy(interned, name);

    try self.interner.put(self.allocator, interned, {});

    return @enumFromInt(index);
}

pub fn getName(self: *const Rir, id: NameId) error{InvalidName}![]const u8 {
    if (@intFromEnum(id) >= self.interner.count()) {
        return error.InvalidName;
    }

    return self.interner.keys()[@intFromEnum(id)];
}

pub fn createType(self: *Rir, name: ?NameId, info: TypeInfo) error{ TooManyTypes, OutOfMemory }!*Type {
    const index = self.type_map.count();

    if (index >= MAX_TYPES) {
        return error.TooManyTypes;
    }

    const hash = utils.fnv1a_32(info);

    const getOrPut = try self.type_map.getOrPutAdapted(self.allocator, TypeLookupContext.Lookup{ &info, hash }, TypeLookupContext{});

    if (!getOrPut.found_existing) {
        const typeIr = try Type.init(self, @enumFromInt(index), name, hash, info);

        getOrPut.key_ptr.* = typeIr;
    }

    return getOrPut.key_ptr.*;
}

pub fn createTypeFromNative(self: *Rir, comptime T: type, name: ?NameId, parameterNames: ?[]const NameId) error{ TooManyTypes, OutOfMemory }!*Type {
    const info = try TypeInfo.fromNative(T, self, parameterNames);
    errdefer info.deinit(self.allocator);

    return self.createType(name, info);
}

pub fn getType(self: *const Rir, id: TypeId) error{InvalidType}!*Type {
    if (@intFromEnum(id) >= self.type_map.count()) {
        return error.InvalidType;
    }

    return self.type_map.keys()[@intFromEnum(id)];
}

pub fn getTypeLayout(self: *Rir, id: TypeId) error{ InvalidType, OutOfMemory }!*const Layout {
    const getOrPut = try self.layout_map.getOrPut(self.allocator, id);

    if (!getOrPut.found_existing) {
        const ty = try self.getType(id);

        getOrPut.value_ptr.* = try ty.info.computeLayout(self);
    }

    return getOrPut.value_ptr;
}

pub fn createForeign(self: *Rir, name: NameId, typeIr: *Type) error{ InvalidCallConv, ExpectedFunctionType, TooManyForeignAddresses, OutOfMemory }!*Foreign {
    const index = self.foreign_list.items.len;

    if (index >= MAX_FOREIGN_ADDRESSES) {
        return error.TooManyForeignAddresses;
    }

    const f = try Foreign.init(self, @enumFromInt(index), name, typeIr);
    errdefer self.allocator.destroy(f);

    try self.foreign_list.append(self.allocator, f);

    return f;
}

pub fn getForeign(self: *Rir, id: ForeignId) error{InvalidForeign}!*Foreign {
    if (@intFromEnum(id) >= self.foreign_list.items.len) {
        return error.InvalidForeign;
    }

    return self.foreign_list.items[@intFromEnum(id)];
}

pub fn createModule(self: *Rir, name: NameId) error{ InvalidModule, OutOfMemory }!*Module {
    const id = self.module_list.items.len;

    if (id >= MAX_MODULES) {
        return error.InvalidModule;
    }

    const mod = try Module.init(self, @enumFromInt(id), name);
    errdefer self.allocator.destroy(mod);

    try self.module_list.append(self.allocator, mod);

    return mod;
}

pub fn getModule(self: *const Rir, id: ModuleId) error{InvalidModule}!*Module {
    if (@intFromEnum(id) >= self.module_list.items.len) {
        return error.InvalidModule;
    }

    return self.module_list.items[@intFromEnum(id)];
}

// module Rir

pub const MAX_MODULES = std.math.maxInt(std.meta.Tag(ModuleId));
pub const MAX_TYPES = std.math.maxInt(std.meta.Tag(TypeId));
pub const MAX_GLOBALS = std.math.maxInt(std.meta.Tag(GlobalId));
pub const MAX_FOREIGN_ADDRESSES = std.math.maxInt(std.meta.Tag(ForeignId));
pub const MAX_FUNCTIONS = std.math.maxInt(std.meta.Tag(FunctionId));
pub const MAX_HANDLER_SETS = std.math.maxInt(std.meta.Tag(HandlerSetId));
pub const MAX_EVIDENCE = Rbc.EVIDENCE_SENTINEL;
pub const MAX_BLOCKS = std.math.maxInt(std.meta.Tag(BlockId));
pub const MAX_REGISTERS = Rbc.MAX_REGISTERS;
pub const MAX_LOCALS = std.math.maxInt(std.meta.Tag(LocalId));
pub const MAX_NAMES = std.math.maxInt(std.meta.Tag(NameId));
pub const MAX_MULTI_REGISTER = std.math.maxInt(MultiRegisterIndex);

pub const Error = std.mem.Allocator.Error || error{
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

    MultipleExits,

    ExpectedType,
    ExpectedOperand,
    ExpectedLocal,
    ExpectedUpvalue,
    ExpectedGlobal,
    ExpectedFunction,
    ExpectedModule,
    ExpectedForeign,
    ExpectedEvidence,
    ExpectedBlock,
    ExpectedHandlerSet,
    ExpectedName,

    ExpectedNilType,
    ExpectedBoolType,
    ExpectedU8Type,
    ExpectedU16Type,
    ExpectedU32Type,
    ExpectedU64Type,
    ExpectedS8Type,
    ExpectedS16Type,
    ExpectedS32Type,
    ExpectedS64Type,
    ExpectedF32Type,
    ExpectedF64Type,
    ExpectedBlockType,
    ExpectedHandlerSetType,
    ExpectedTypeType,
    ExpectedPointerType,
    ExpectedSliceType,
    ExpectedArrayType,
    ExpectedStructType,
    ExpectedUnionType,
    ExpectedProductType,
    ExpectedSumType,
    ExpectedFunctionType,
};

pub const RegisterOffset = Rbc.RegisterLocalOffset;
/// 2 ^ 2 = max of 4 registers per multi-register entity
pub const MultiRegisterIndex = std.meta.Int(.unsigned, 2);

// pub const Name = [:0]const u8;

pub const Index = u8;
pub const Arity = u8;
pub const Alignment = u12; // 2^12 = 4096 = page size; should be enough for anyone (famous last words)
pub const Size = u64;
pub const Offset = u64;

pub const TypeId = enum(u16) {
    pub const DataType = Type;

    _,

    pub fn format(self: TypeId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("TypeId-{x}", .{@intFromEnum(self)});
    }
};
pub const ModuleId = enum(u16) {
    pub const DataType = Module;

    _,

    pub fn format(self: ModuleId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("ModuleId-{x}", .{@intFromEnum(self)});
    }
};

pub const RegisterId = enum(Rbc.RegisterIndex) {
    pub const DataType = Register;

    _,

    pub fn format(self: RegisterId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("RegisterId-{x}", .{@intFromEnum(self)});
    }
};

pub const HandlerSetId = enum(Rbc.HandlerSetIndex) {
    pub const DataType = HandlerSet;

    _,

    pub fn format(self: HandlerSetId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("HandlerSetId-{x}", .{@intFromEnum(self)});
    }
};

pub const BlockId = enum(u16) {
    pub const DataType = Block;

    entry = 0,
    _,

    pub fn format(self: BlockId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("BlockId-{x}", .{@intFromEnum(self)});
    }
};

pub const FunctionId = enum(Rbc.FunctionIndex) {
    pub const DataType = Function;

    _,

    pub fn format(self: FunctionId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("FunctionId-{x}", .{@intFromEnum(self)});
    }
};

pub const ForeignId = enum(Rbc.ForeignIndex) {
    pub const DataType = Foreign;

    _,

    pub fn format(self: ForeignId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("ForeignId-{x}", .{@intFromEnum(self)});
    }
};

pub const GlobalId = enum(Rbc.GlobalIndex) {
    pub const DataType = Global;

    _,

    pub fn format(self: GlobalId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("GlobalId-{x}", .{@intFromEnum(self)});
    }
};

pub const UpvalueId = enum(Rbc.UpvalueIndex) {
    pub const DataType = Upvalue;

    _,

    pub fn format(self: UpvalueId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("UpvalueId-{x}", .{@intFromEnum(self)});
    }
};

pub const EvidenceId = enum(Rbc.EvidenceIndex) {
    pub const DataType = Local;

    _,

    pub fn format(self: EvidenceId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("EvidenceId-{x}", .{@intFromEnum(self)});
    }
};

pub const LocalId = enum(u16) {
    pub const DataType = Local;

    _,

    pub fn format(self: LocalId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("LocalId-{x}", .{@intFromEnum(self)});
    }
};

pub const NameId = enum(u16) {
    pub const DataType = [:0]const u8;

    _,

    pub fn format(self: NameId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("NameId-{x}", .{@intFromEnum(self)});
    }
};

pub const FieldId = enum(u16) {
    pub const DataType = void;

    _,

    pub fn format(self: FieldId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return writer.print("FieldId-{x}", .{@intFromEnum(self)});
    }
};

pub const Dimensions = packed struct {
    size: Size = 0,
    alignment: Alignment = 1,

    pub fn fromNativeType(comptime T: type) Dimensions {
        return Dimensions{
            .size = @sizeOf(T),
            .alignment = @intCast(@alignOf(T)),
        };
    }
};

pub const Layout = struct {
    local_storage: LocalStorage,
    dimensions: Dimensions,
    field_offsets: []Offset = &.{},

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.field_offsets);
    }

    pub fn format(self: *const Layout, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}x{}", .{ self.dimensions.size, self.dimensions.alignment });
    }

    pub fn canUseMemory(self: *const Layout, memory: []const u8) bool {
        return std.mem.isAligned(@intFromPtr(memory.ptr), self.dimensions.alignment);
    }

    pub fn fromDimensions(dimensions: Dimensions) Layout {
        return Layout{
            .local_storage = .fromSize(dimensions.size),
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

        return Layout{
            .dimensions = dimensions,
            .field_offsets = field_offsets,
        };
    }
};

const LayoutMap = std.ArrayHashMapUnmanaged(TypeId, Layout, utils.SimpleHashContext, false);
const TypeMap = std.ArrayHashMapUnmanaged(*Type, void, TypeContext, false);
const ForeignList = std.ArrayListUnmanaged(*Foreign);
const ModuleList = std.ArrayListUnmanaged(*Module);

const TypeContext = struct {
    pub fn hash(_: TypeContext, v: *Type) u32 {
        return v.hash;
    }

    pub fn eql(_: TypeContext, a: *Type, b: *Type, _: anytype) bool {
        return utils.equal(a.info, b.info);
    }
};

const TypeLookupContext = struct {
    const Lookup = struct { *const TypeInfo, u32 };

    pub fn hash(_: TypeLookupContext, v: Lookup) u32 {
        return v[1];
    }

    pub fn eql(_: TypeLookupContext, a: Lookup, b: *Type, _: anytype) bool {
        return a[1] == b.hash and utils.equal(a[0].*, b.info);
    }
};

const Interner = std.ArrayHashMapUnmanaged([:0]const u8, void, InternerContext, true);
const InternerContext = struct {
    pub fn eql(_: InternerContext, a: anytype, b: anytype, _: anytype) bool {
        return @intFromPtr(a.ptr) == @intFromPtr(b.ptr) or (a.len == b.len and std.mem.eql(u8, a.ptr[0..a.len], b.ptr[0..b.len]));
    }

    pub fn hash(_: InternerContext, a: anytype) u32 {
        return utils.fnv1a_32(a);
    }
};

pub const FormatError = anyerror;

pub const Formatter = struct {
    pub const Error = FormatError;

    state: *FormatterState,

    pub fn init(rir: *Rir, writer: std.io.AnyWriter) error{OutOfMemory}!Formatter {
        const state = try rir.allocator.create(FormatterState);
        state.* = FormatterState{ .rir = rir, .writer = writer };
        return Formatter{ .state = state };
    }

    pub fn deinit(self: Formatter) void {
        self.state.rir.allocator.destroy(self.state);
    }

    pub fn wrap(self: Formatter, data: anytype) FormatterState.Wrap(@TypeOf(data)) {
        return .{ .formatter = self, .data = data };
    }

    pub fn sliceWrap(self: Formatter, data: anytype) FormatterState.SliceWrap(@TypeOf(data)) {
        return .{ .formatter = self, .data = data };
    }

    pub fn getRir(self: Formatter) *Rir {
        return self.state.rir;
    }

    pub fn setModule(self: Formatter, moduleIr: ?*const Module) void {
        self.state.module = moduleIr;
    }

    pub fn swapModule(self: Formatter, moduleIr: ?*const Module) ?*const Module {
        const oldModule = self.getModule() catch null;
        self.setModule(moduleIr);
        return oldModule;
    }

    pub fn getModule(self: Formatter) !*const Module {
        return self.state.module orelse error.NoFormatterActiveModule;
    }

    pub fn setFunction(self: Formatter, functionIr: ?*const Function) void {
        self.state.function = functionIr;
    }

    pub fn swapFunction(self: Formatter, functionIr: ?*const Function) ?*const Function {
        const oldFunction = self.getFunction() catch null;
        self.setFunction(functionIr);
        return oldFunction;
    }

    pub fn getFunction(self: Formatter) !*const Function {
        return self.state.function orelse error.NoFormatterActiveFunction;
    }

    pub fn getBlock(self: Formatter) !*const Block {
        return self.state.block orelse error.NoFormatterActiveBlock;
    }

    pub fn setBlock(self: Formatter, b: ?*const Block) void {
        self.state.block = b;
    }

    pub fn swapBlock(self: Formatter, b: ?*const Block) ?*const Block {
        const oldBlock = self.getBlock() catch null;
        self.setBlock(b);
        return oldBlock;
    }

    pub fn getOpCodeDataSplit(self: Formatter) ?u21 {
        return self.state.op_code_data_split;
    }

    pub fn setOpCodeDataSplit(self: Formatter, split: ?u21) void {
        self.state.op_code_data_split = split;
    }

    pub fn swapOpCodeDataSplit(self: Formatter, split: ?u21) ?u21 {
        const old = self.getOpCodeDataSplit();
        self.setOpCodeDataSplit(split);
        return old;
    }

    pub fn getFlags(self: Formatter) FormatterState.Flags {
        return self.state.flags;
    }

    pub fn setFlags(self: Formatter, flags: FormatterState.Flags) void {
        self.state.flags = flags;
    }

    pub fn swapFlags(self: Formatter, flags: FormatterState.Flags) FormatterState.Flags {
        const old = self.getFlags();
        self.setFlags(flags);
        return old;
    }

    pub fn getFlag(self: Formatter, comptime flag: FormatterState.FlagKind) bool {
        return @field(self.state.flags, @tagName(flag));
    }

    pub fn setFlag(self: Formatter, comptime flag: FormatterState.FlagKind, val: bool) void {
        @field(self.state.flags, @tagName(flag)) = val;
    }

    pub fn swapFlag(self: Formatter, comptime flag: FormatterState.FlagKind, val: bool) bool {
        const old = self.getFlag(flag);
        self.setFlag(flag, val);
        return old;
    }

    pub fn fmt(self: Formatter, val: anytype) FormatError!void {
        const T = @TypeOf(val);

        if (std.meta.hasMethod(T, "onFormat")) {
            try val.onFormat(self);
        } else switch (T) {
            NameId => {
                try self.writeAll(try self.getRir().getName(val));
            },
            ModuleId => {
                const x = self.wrap((try self.getRir().getModule(val)).name);
                if (self.getFlag(.show_ids)) try self.print("{}#{}", .{ x, @intFromEnum(val) }) else try x.fmt();
            },
            TypeId => {
                const x = try self.getRir().getType(val);
                try x.onFormat(self);
            },
            BlockId => {
                if (self.getFunction()) |func| {
                    const x = self.wrap((try func.getBlock(val)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{ x, @intFromEnum(val) }) else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(val)});
                }
            },
            LocalId => {
                if (self.getBlock()) |bl| {
                    const x = self.wrap((try bl.getLocal(val)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{ x, @intFromEnum(val) }) else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(val)});
                }
            },
            GlobalId => {
                if (self.getModule()) |mod| {
                    const x = self.wrap((try mod.getGlobal(val)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{ x, @intFromEnum(val) }) else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(val)});
                }
            },
            FunctionId => {
                if (self.getModule()) |mod| {
                    const x = self.wrap((try mod.getFunction(val)).name);
                    if (self.getFlag(.show_ids)) try self.print("{}#{}", .{ x, @intFromEnum(val) }) else try x.fmt();
                } else |_| {
                    try self.print("#{}", .{@intFromEnum(val)});
                }
            },
            else => if (std.meta.hasMethod(T, "format")) try self.print("{}", .{val}) else switch (@typeInfo(T)) {
                .@"enum" => try self.writeAll(@tagName(val)),
                else => if (comptime utils.types.isString(T)) try self.writeAll(val) else try self.print("{any}", .{val}),
            },
        }
    }

    pub fn commaList(self: Formatter, iterableWithFor: anytype) FormatError!void {
        return self.list(", ", iterableWithFor);
    }

    pub fn list(self: Formatter, separator: anytype, iterableWithFor: anytype) FormatError!void {
        var nth = false;
        for (iterableWithFor) |x| {
            if (nth) {
                try self.fmt(separator);
            } else {
                nth = true;
            }

            try self.fmt(x);
        }
    }

    pub fn block(self: Formatter, iterableWithFor: anytype) FormatError!void {
        var nth = false;

        try self.beginBlock();
        for (iterableWithFor) |func| {
            if (nth) {
                try self.endLine();
            } else {
                nth = true;
            }

            try self.fmt(func);
        }
        try self.endBlock();
    }

    pub fn parens(self: Formatter, val: anytype) FormatError!void {
        try self.writeByte('(');
        try self.fmt(val);
        try self.writeByte(')');
    }

    pub fn braces(self: Formatter, val: anytype) FormatError!void {
        try self.writeByte('{');
        try self.fmt(val);
        try self.writeByte('}');
    }

    pub fn brackets(self: Formatter, val: anytype) FormatError!void {
        try self.writeByte('[');
        try self.fmt(val);
        try self.writeByte(']');
    }

    pub fn writeByte(self: Formatter, byte: u8) FormatError!void {
        try self.state.writer.writeByte(byte);

        if (byte == '\n') {
            try self.state.writer.writeByteNTimes(' ', self.state.indent_size * self.state.indent_level);
        }
    }

    pub fn write(self: Formatter, bytes: []const u8) FormatError!usize {
        for (bytes, 0..) |b, i| {
            if (b == '\n') {
                const sub = bytes[0 .. i + 1];
                try self.state.writer.writeAll(sub);
                try self.state.writer.writeByteNTimes(' ', self.state.indent_size * self.state.indent_level);

                return sub.len;
            }
        }

        try self.state.writer.writeAll(bytes);

        return bytes.len;
    }

    pub fn writeBytesNTimes(self: Formatter, bytes: []const u8, n: usize) FormatError!void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.writeAll(bytes);
        }
    }

    pub fn writeAll(self: Formatter, bytes: []const u8) FormatError!void {
        var index: usize = 0;
        while (index != bytes.len) {
            index += try self.write(bytes[index..]);
        }
    }

    pub fn print(self: Formatter, comptime fmtStr: []const u8, args: anytype) FormatError!void {
        return std.fmt.format(self, fmtStr, args);
    }

    pub fn endLine(self: Formatter) FormatError!void {
        try self.writeByte('\n');
    }

    pub fn beginBlock(self: Formatter) FormatError!void {
        self.state.indent_level += 1;
        try self.endLine();
    }

    pub fn endBlock(self: Formatter) FormatError!void {
        self.state.indent_level -= 1;
    }
};

const FormatterState = struct {
    rir: *Rir,

    module: ?*const Module = null,
    function: ?*const Function = null,
    block: ?*const Block = null,

    writer: std.io.AnyWriter,

    indent_size: u4 = 4,
    indent_level: u8 = 0,
    op_code_data_split: ?u21 = null,

    flags: Flags = .{},

    const Flags = packed struct {
        show_nominative_type_bodies: bool = false,
        show_ids: bool = false,
        show_indices: bool = false,
        show_op_code_bytes: bool = false,
        show_op_data_bytes: bool = false,
        raw_immediates: bool = false,
    };

    pub const FlagKind = std.meta.FieldEnum(Flags);

    fn Wrap(comptime T: type) type {
        return struct {
            const Self = @This();

            formatter: Formatter,
            data: T,

            pub fn onFormat(self: Self, _: Formatter) FormatError!void {
                return self.fmt();
            }

            pub fn format(self: Self, comptime _: []const u8, _: anytype, _: anytype) FormatError!void {
                return self.fmt();
            }

            pub fn fmt(self: Self) FormatError!void {
                return self.formatter.fmt(self.data);
            }
        };
    }

    pub fn SliceWrap(comptime T: type) type {
        return struct {
            const Self = @This();

            formatter: Formatter,
            data: []const T,

            pub fn onFormat(self: Self, _: Formatter) FormatError!void {
                return self.fmt();
            }

            pub fn format(self: Self, comptime _: []const u8, _: anytype, _: anytype) FormatError!void {
                return self.fmt();
            }

            pub fn fmt(self: Self) FormatError!void {
                return self.formatter.commaList(self.data);
            }
        };
    }
};

const GlobalList = std.ArrayListUnmanaged(*Global);
const FunctionList = std.ArrayListUnmanaged(*Function);
const HandlerSetList = std.ArrayListUnmanaged(*HandlerSet);

pub const Module = struct {
    pub const Id = ModuleId;

    rir: *Rir,

    id: ModuleId,
    name: NameId,

    global_list: GlobalList = .{},
    function_list: FunctionList = .{},
    handler_sets: HandlerSetList = .{},

    pub fn init(ir: *Rir, id: ModuleId, name: NameId) error{OutOfMemory}!*Module {
        const ptr = try ir.allocator.create(Module);
        errdefer ir.allocator.destroy(ptr);

        ptr.* = Module{
            .rir = ir,
            .id = id,
            .name = name,
        };

        return ptr;
    }

    pub fn deinit(self: *Module) void {
        for (self.handler_sets.items) |x| x.deinit();
        for (self.global_list.items) |x| x.deinit();
        for (self.function_list.items) |x| x.deinit();

        self.handler_sets.deinit(self.rir.allocator);

        self.global_list.deinit(self.rir.allocator);

        self.function_list.deinit(self.rir.allocator);

        self.rir.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Module, formatter: Formatter) Formatter.Error!void {
        const oldActiveModule = formatter.swapModule(self);
        defer formatter.setModule(oldActiveModule);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});

        if (self.global_list.items.len > 0 or self.function_list.items.len > 0) {
            try formatter.writeAll(" =");
            try formatter.beginBlock();
            if (self.global_list.items.len > 0) {
                try formatter.writeAll("globals =");
                try formatter.block(self.global_list.items);
                try formatter.endLine();
            }
            if (self.function_list.items.len > 0) {
                try formatter.writeAll("functions =");
                try formatter.block(self.function_list.items);
            }
            try formatter.endBlock();
        }
    }

    pub fn get(self: *const Module, comptime T: type, id: T.Id) !*T {
        return switch (T) {
            Global => try self.getGlobal(id),
            Function => try self.getFunction(id),
            HandlerSet => try self.getHandlerSet(id),
            Foreign => try self.rir.getForeign(id),
            else => @compileError("Unsupported type for Module.get: " ++ @typeName(T)),
        };
    }

    pub fn createGlobal(self: *Module, name: NameId, typeIr: *Type) error{ TooManyGlobals, OutOfMemory }!*Global {
        const index = self.global_list.items.len;

        if (index >= MAX_GLOBALS) {
            return error.TooManyGlobals;
        }

        const global = try Global.init(self, @enumFromInt(index), name, typeIr);
        errdefer self.rir.allocator.destroy(global);

        try self.global_list.append(self.rir.allocator, global);

        return global;
    }

    pub fn getGlobal(self: *const Module, id: GlobalId) error{InvalidGlobal}!*Global {
        if (@intFromEnum(id) >= self.global_list.items.len) {
            return error.InvalidGlobal;
        }

        return self.global_list.items[@intFromEnum(id)];
    }

    pub fn createFunction(self: *Module, name: NameId, typeIr: *Type) error{ ExpectedFunctionType, TooManyFunctions, OutOfMemory }!*Function {
        const index = self.function_list.items.len;

        if (index >= MAX_FUNCTIONS) {
            return error.TooManyFunctions;
        }

        const builder = try Function.init(self, @enumFromInt(index), name, typeIr);

        try self.function_list.append(self.rir.allocator, builder);

        return builder;
    }

    pub fn getFunction(self: *const Module, id: FunctionId) error{InvalidFunction}!*Function {
        if (@intFromEnum(id) >= self.function_list.items.len) {
            return error.InvalidFunction;
        }

        return self.function_list.items[@intFromEnum(id)];
    }

    pub fn createHandlerSet(self: *Module) error{ TooManyHandlerSets, OutOfMemory }!*HandlerSet {
        const index = self.handler_sets.items.len;

        if (index >= MAX_HANDLER_SETS) {
            return error.TooManyHandlerSets;
        }

        const builder = try HandlerSet.init(self, @enumFromInt(index));

        try self.handler_sets.append(self.rir.allocator, builder);

        return builder;
    }

    pub fn getHandlerSet(self: *const Module, id: HandlerSetId) error{InvalidHandlerSet}!*HandlerSet {
        if (@intFromEnum(id) >= self.handler_sets.items.len) {
            return error.InvalidHandlerSet;
        }

        return self.handler_sets.items[@intFromEnum(id)];
    }
};

/// Type representation for all values in Rir;
///
/// Essentially, this is a wrapper for `TypeInfo` that
/// provides additional functionality for working with types.
pub const Type = struct {
    pub const Id = TypeId;

    rir: *Rir,

    id: TypeId,
    name: ?NameId,

    hash: u32,

    info: TypeInfo,

    pub fn init(ir: *Rir, id: TypeId, name: ?NameId, hash: u32, info: TypeInfo) error{OutOfMemory}!*Type {
        const self = try ir.allocator.create(Type);

        self.* = Type{
            .rir = ir,
            .id = id,
            .name = name orelse switch (info) {
                .Nil => try ir.internName("Nil"),
                .Bool => try ir.internName("Bool"),
                .U8 => try ir.internName("U8"),
                .U16 => try ir.internName("U16"),
                .U32 => try ir.internName("U32"),
                .U64 => try ir.internName("U64"),
                .S8 => try ir.internName("S8"),
                .S16 => try ir.internName("S16"),
                .S32 => try ir.internName("S32"),
                .S64 => try ir.internName("S64"),
                .F32 => try ir.internName("F32"),
                .F64 => try ir.internName("F64"),
                .Block => try ir.internName("Block"),
                .HandlerSet => try ir.internName("HandlerSet"),
                .Type => try ir.internName("Type"),
                else => null,
            },
            .hash = hash,
            .info = info,
        };

        return self;
    }

    pub fn deinit(self: Type) void {
        self.info.deinit(self.rir.allocator);
    }

    pub fn hashWith(self: Type, hasher: anytype) void {
        utils.hashWith(hasher, self.hash);
    }

    pub fn compare(self: Type, other: Type) std.math.Order {
        const ord = utils.compare(std.meta.activeTag(self.info), std.meta.activeTag(other.info));

        if (ord != .eq or self.info.isBasic()) return ord;

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
                break :any try Formatter.init(self.rir, writer);
            },

            Formatter => writer,

            else => other: {
                ownFormatter = true;
                break :other try Formatter.init(self.rir, writer.any());
            },
        };
        defer if (ownFormatter) formatter.deinit();

        try self.onFormat(formatter);
    }

    pub fn formatBody(self: *const Type, formatter: Formatter) !void {
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

    pub fn onFormat(self: *const Type, formatter: Formatter) !void {
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

    pub fn compareMemory(self: *const Type, a: []const u8, b: []const u8) !std.math.Order {
        if (a.ptr == b.ptr and a.len == b.len) return .eq;

        const layout = try self.rir.getTypeLayout(self.id);

        switch (self.info) {
            .Nil => return .eq,

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

            inline .Block,
            .HandlerSet,
            .Pointer,
            => return utils.compare(a, b),

            .Type => return @as(*const Type, @alignCast(@ptrCast(a.ptr))).compare(@as(*const Type, @alignCast(@ptrCast(b.ptr))).*),

            .Slice => |info| {
                const elemLayout = try info.element.getLayout();

                const aPtr: *const [*]u8 = @alignCast(@ptrCast(a.ptr));
                const aLength: *const Size = @alignCast(@ptrCast(a.ptr + 8));
                const aBuf: []const u8 = aPtr.*[0..aLength.*];

                const bPtr: *const [*]u8 = @alignCast(@ptrCast(b.ptr));
                const bLength: *const Size = @alignCast(@ptrCast(b.ptr + 8));
                const bBuf: []const u8 = bPtr.*[0..bLength.*];

                if (aPtr.* == bPtr.* and aLength.* == bLength.*) return .eq;

                var ord = utils.compare(aLength.*, bLength.*);

                if (ord == .eq) {
                    for (0..aLength.*) |i| {
                        const j = i * elemLayout.dimensions.size;
                        const aElem = aBuf[j .. j + elemLayout.dimensions.size];
                        const bElem = bBuf[j .. j + elemLayout.dimensions.size];

                        ord = try info.element.compareMemory(aElem, bElem);

                        if (ord != .eq) break;
                    }
                }

                return ord;
            },

            .Array => |info| {
                const elemLayout = try info.element.getLayout();

                for (0..info.length) |i| {
                    const j = i * elemLayout.dimensions.size;
                    const aElem = a[j .. j + elemLayout.dimensions.size];
                    const bElem = b[j .. j + elemLayout.dimensions.size];

                    const ord = try info.element.compareMemory(aElem, bElem);
                    if (ord != .eq) return ord;
                }

                return .eq;
            },

            .Struct => |info| {
                for (info.fields, 0..) |field, i| {
                    const fieldLayout = try field.type.getLayout();
                    const fieldOffset = layout.field_offsets[i];
                    const fieldMemoryA = a[fieldOffset .. fieldOffset + fieldLayout.dimensions.size];
                    const fieldMemoryB = b[fieldOffset .. fieldOffset + fieldLayout.dimensions.size];

                    const ord = try field.type.compareMemory(fieldMemoryA, fieldMemoryB);
                    if (ord != .eq) return ord;
                }

                return .eq;
            },
            .Union => |info| {
                const discriminatorLayout = try info.discriminator.getLayout();
                const discMemA = a[0..discriminatorLayout.dimensions.size];
                const discMemB = b[0..discriminatorLayout.dimensions.size];

                const discOrd = try info.discriminator.compareMemory(discMemA, discMemB);
                if (discOrd != .eq) return discOrd;

                for (info.fields) |field| {
                    const fieldDiscMem = field.discriminant.getMemory();

                    if (try info.discriminator.compareMemory(discMemA, fieldDiscMem) == .eq) {
                        const fieldLayout = try field.type.getLayout();
                        const fieldMemoryA = a[layout.field_offsets[1] .. layout.field_offsets[1] + fieldLayout.dimensions.size];
                        const fieldMemoryB = b[layout.field_offsets[1] .. layout.field_offsets[1] + fieldLayout.dimensions.size];

                        return field.type.compareMemory(fieldMemoryA, fieldMemoryB);
                    }
                }

                unreachable;
            },

            .Product => |type_set| {
                for (type_set, 0..) |T, i| {
                    const TLayout = try T.getLayout();
                    const offset = layout.field_offsets[i];
                    const memoryA = a[offset .. offset + TLayout.dimensions.size];
                    const memoryB = b[offset .. offset + TLayout.dimensions.size];

                    const ord = try T.compareMemory(memoryA, memoryB);
                    if (ord != .eq) return ord;
                }

                return .eq;
            },

            .Sum => |_| return utils.compare(a, b),

            .Function => |_| return utils.compare(a, b),
        }
    }

    pub fn formatMemory(self: *const Type, formatter: Formatter, memory: []const u8) !void {
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

            inline .Block,
            .HandlerSet,
            .Pointer,
            .Sum,
            => try formatter.print("[{} @ {x}]", .{ formatter.wrap(self), @intFromPtr(memory.ptr) }),

            .Type => try @as(*const Type, @alignCast(@ptrCast(memory.ptr))).onFormat(formatter),

            .Slice => try formatter.print("[{} @ {x} + {}]", .{ formatter.wrap(self), @intFromPtr(memory.ptr), memory.len }),

            .Array => |info| {
                try formatter.print("array({})[", .{info.length});
                try formatter.beginBlock();
                const elemSize = @divExact(memory.len, info.length);
                for (0..info.length) |i| {
                    if (i > 0) {
                        try formatter.writeAll(",");
                        try formatter.endLine();
                    }
                    try info.element.formatMemory(formatter, memory[i * elemSize ..]);
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

                    if (try info.discriminator.compareMemory(discMem, fieldDiscMem) == .eq) {
                        const fieldLayout = try field.type.getLayout();
                        const fieldMemory = (memory.ptr + layout.field_offsets[1])[0..fieldLayout.dimensions.size];

                        try formatter.print("{}.{}(", .{ formatter.wrap(self.id), formatter.wrap(field.name) });

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

            .Function => try formatter.print("[{} @ {x}]", .{ formatter.wrap(self), @intFromPtr(memory.ptr) }),
        }
    }

    pub fn getLayout(self: *const Type) error{ InvalidType, OutOfMemory }!*const Layout {
        return self.rir.getTypeLayout(self.id);
    }

    pub fn createPointer(self: *const Type) error{ OutOfMemory, TooManyTypes }!*Type {
        return self.rir.createType(null, .{ .Pointer = .{ .element = @constCast(self) } });
    }

    pub fn checkNative(self: *const Type, comptime T: type) error{ TypeMismatch, TooManyTypes, OutOfMemory }!void {
        const t = try self.rir.createTypeFromNative(T, null, null);

        if (t.compare(self.*) != .eq) {
            return error.TypeMismatch;
        }
    }
};

/// A set of un-discriminated types (i.e. a product or sum type)
pub const TypeSet = []*Type;

/// The discriminator type of `TypeInfo`
pub const TypeTag = std.meta.Tag(TypeInfo);

/// This is a union representing all possible Rir operand types
///
/// To use `TypeInfo` within an Rir instance, it must be wrapped in a de-duplicated `Type` via `createType`
pub const TypeInfo = union(enum) {
    Nil: void,
    Bool: void,
    U8: void,
    U16: void,
    U32: void,
    U64: void,
    S8: void,
    S16: void,
    S32: void,
    S64: void,
    F32: void,
    F64: void,

    Block: void,
    HandlerSet: void,
    Type: void,

    Pointer: PointerTypeInfo,
    Slice: SliceTypeInfo,
    Array: ArrayTypeInfo,

    Struct: StructTypeInfo,
    Union: UnionTypeInfo,

    Product: TypeSet,
    Sum: TypeSet,

    Function: FunctionTypeInfo,

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
            .Struct => |x| .{ .Struct = try x.clone(allocator) },
            .Union => |x| .{ .Union = try x.clone(allocator) },

            .Product => |x| .{ .Product = try allocator.dupe(*Type, x) },
            .Sum => |x| .{ .Sum = try allocator.dupe(*Type, x) },

            .Function => |x| .{ .Function = try x.clone(allocator) },

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
            inline .Struct,
            .Union,
            .Product,
            .Sum,
            .Function,
            => true,

            inline else => false,
        };
    }

    /// Extract a `Nil` from a `Type` or return `error.ExpectedNilType`
    pub fn forceNil(self: *const TypeInfo) error{ExpectedNilType}!void {
        switch (self.*) {
            .Nil => return,
            inline else => return error.ExpectedNilType,
        }
    }

    /// Extract a `Bool` from a `Type` or return `error.ExpectedBoolType`
    pub fn forceBool(self: *const TypeInfo) error{ExpectedBoolType}!void {
        switch (self.*) {
            .Bool => return,
            inline else => return error.ExpectedBoolType,
        }
    }

    /// Extract a `U8` from a `Type` or return `error.ExpectedU8Type`
    pub fn forceU8(self: *const TypeInfo) error{ExpectedU8Type}!void {
        switch (self.*) {
            .U8 => return,
            inline else => return error.ExpectedU8Type,
        }
    }

    /// Extract a `U16` from a `Type` or return `error.ExpectedU16Type`
    pub fn forceU16(self: *const TypeInfo) error{ExpectedU16Type}!void {
        switch (self.*) {
            .U16 => return,
            inline else => return error.ExpectedU16Type,
        }
    }

    /// Extract a `U32` from a `Type` or return `error.ExpectedU32Type`
    pub fn forceU32(self: *const TypeInfo) error{ExpectedU32Type}!void {
        switch (self.*) {
            .U32 => return,
            inline else => return error.ExpectedU32Type,
        }
    }

    /// Extract a `U64` from a `Type` or return `error.ExpectedU64Type`
    pub fn forceU64(self: *const TypeInfo) error{ExpectedU64Type}!void {
        switch (self.*) {
            .U64 => return,
            inline else => return error.ExpectedU64Type,
        }
    }

    /// Extract a `S8` from a `Type` or return `error.ExpectedS8Type`
    pub fn forceS8(self: *const TypeInfo) error{ExpectedS8Type}!void {
        switch (self.*) {
            .S8 => return,
            inline else => return error.ExpectedS8Type,
        }
    }

    /// Extract a `S16` from a `Type` or return `error.ExpectedS16Type`
    pub fn forceS16(self: *const TypeInfo) error{ExpectedS16Type}!void {
        switch (self.*) {
            .S16 => return,
            inline else => return error.ExpectedS16Type,
        }
    }

    /// Extract a `S32` from a `Type` or return `error.ExpectedS32Type`
    pub fn forceS32(self: *const TypeInfo) error{ExpectedS32Type}!void {
        switch (self.*) {
            .S32 => return,
            inline else => return error.ExpectedS32Type,
        }
    }

    /// Extract a `S32` from a `Type` or return `error.ExpectedS32Type`
    pub fn forceS64(self: *const TypeInfo) error{ExpectedS64Type}!void {
        switch (self.*) {
            .S64 => return,
            inline else => return error.ExpectedS64Type,
        }
    }

    /// Extract a `F32` from a `Type` or return `error.ExpectedF32Type`
    pub fn forceF32(self: *const TypeInfo) error{ExpectedF32Type}!void {
        switch (self.*) {
            .F32 => return,
            inline else => return error.ExpectedF32Type,
        }
    }

    /// Extract a `F64` from a `Type` or return `error.ExpectedF64Type`
    pub fn forceF64(self: *const TypeInfo) error{ExpectedF64Type}!void {
        switch (self.*) {
            .F64 => return,
            inline else => return error.ExpectedF64Type,
        }
    }

    /// Extract a `Block` from a `Type` or return `error.ExpectedBlockType`
    pub fn forceBlock(self: *const TypeInfo) error{ExpectedBlockType}!void {
        switch (self.*) {
            .Block => return,
            inline else => return error.ExpectedBlockType,
        }
    }

    /// Extract a `HandlerSet` from a `Type` or return `error.ExpectedHandlerSetType`
    pub fn forceHandlerSet(self: *const TypeInfo) error{ExpectedHandlerSetType}!void {
        switch (self.*) {
            .HandlerSet => return,
            inline else => return error.ExpectedHandlerSetType,
        }
    }

    /// Ensure a `Type` is of the variant `Type` or return `error.ExpectedTypeType`
    pub fn forceType(self: *const TypeInfo) error{ExpectedTypeType}!void {
        switch (self.*) {
            .Type => return,
            inline else => return error.ExpectedTypeType,
        }
    }

    /// Extract a `Pointer` from a `Type` or return `error.ExpectedPointerType`
    pub fn forcePointer(self: *const TypeInfo) error{ExpectedPointerType}!*const PointerTypeInfo {
        switch (self.*) {
            .Pointer => |*ptr| return ptr,
            inline else => return error.ExpectedPointerType,
        }
    }

    /// Extract a `Slice` from a `Type` or return `error.ExpectedSliceType`
    pub fn forceSlice(self: *const TypeInfo) error{ExpectedSliceType}!*const SliceTypeInfo {
        switch (self.*) {
            .Slice => |*slice| return slice,
            inline else => return error.ExpectedSliceType,
        }
    }

    /// Extract an `Array` from a `Type` or return `error.ExpectedArrayType`
    pub fn forceArray(self: *const TypeInfo) error{ExpectedArrayType}!*const ArrayTypeInfo {
        switch (self.*) {
            .Array => |*array| return array,
            inline else => return error.ExpectedArrayType,
        }
    }

    /// Extract a `Struct` from a `Type` or return `error.ExpectedStructType`
    pub fn forceStruct(self: *const TypeInfo) error{ExpectedStructType}!*const StructTypeInfo {
        switch (self.*) {
            .Struct => |*str| return str,
            inline else => return error.ExpectedStructType,
        }
    }

    /// Extract a `Union` from a `Type` or return `error.ExpectedUnionType`
    pub fn forceUnion(self: *const TypeInfo) error{ExpectedUnionType}!*const UnionTypeInfo {
        switch (self.*) {
            .Union => |*@"union"| return @"union",
            inline else => return error.ExpectedUnionType,
        }
    }

    /// Extract a `Product` from a `Type` or return `error.ExpectedProductType`
    pub fn forceProduct(self: *const TypeInfo) error{ExpectedProductType}!TypeSet {
        switch (self.*) {
            .Product => |set| return set,
            inline else => return error.ExpectedProductType,
        }
    }

    /// Extract a `Sum` from a `Type` or return `error.ExpectedSumType`
    pub fn forceSum(self: *const TypeInfo) error{ExpectedSumType}!TypeSet {
        switch (self.*) {
            .Sum => |set| return set,
            inline else => return error.ExpectedSumType,
        }
    }

    /// Extract a `Function` from a `Type` or return `error.ExpectedFunctionType`
    pub fn forceFunction(self: *const TypeInfo) error{ExpectedFunctionType}!*const FunctionTypeInfo {
        switch (self.*) {
            .Function => |*fun| return fun,
            inline else => return error.ExpectedFunctionType,
        }
    }

    /// Generate an `Layout` based on this `TypeInfo`
    pub fn computeLayout(self: *const TypeInfo, ir: *Rir) error{ InvalidType, OutOfMemory }!Layout {
        return switch (self.*) {
            .Nil => .{ .local_storage = .zero_size, .dimensions = .{ .size = 0, .alignment = 1 } },

            .Bool => .{ .local_storage = .register, .dimensions = .{ .size = 1, .alignment = 1 } },

            .U8 => .{ .local_storage = .register, .dimensions = .{ .size = 1, .alignment = 1 } },
            .U16 => .{ .local_storage = .register, .dimensions = .{ .size = 2, .alignment = 2 } },
            .U32 => .{ .local_storage = .register, .dimensions = .{ .size = 4, .alignment = 4 } },
            .U64 => .{ .local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 } },

            .S8 => .{ .local_storage = .register, .dimensions = .{ .size = 1, .alignment = 1 } },
            .S16 => .{ .local_storage = .register, .dimensions = .{ .size = 2, .alignment = 2 } },
            .S32 => .{ .local_storage = .register, .dimensions = .{ .size = 4, .alignment = 4 } },
            .S64 => .{ .local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 } },

            .F32 => .{ .local_storage = .register, .dimensions = .{ .size = 4, .alignment = 4 } },
            .F64 => .{ .local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 } },

            .Block => .{ .local_storage = .none, .dimensions = .fromNativeType(BlockId) },
            .HandlerSet => .{ .local_storage = .none, .dimensions = .fromNativeType(HandlerSetId) },
            .Type => .{ .local_storage = .none, .dimensions = .fromNativeType(TypeId) },

            .Pointer => .{ .local_storage = .register, .dimensions = .{ .size = 8, .alignment = 8 } },
            .Slice => .{
                .local_storage = .fromRegisters(2),
                .dimensions = .{ .size = 16, .alignment = 8 },
                .field_offsets = try ir.allocator.dupe(Offset, &.{ 0, 8 }),
            },

            .Array => |info| Array: {
                const elemLayout = try info.element.getLayout();

                const size = utils.alignTo(elemLayout.dimensions.size, elemLayout.dimensions.alignment) * info.length;

                break :Array .{ .local_storage = .fromSize(size), .dimensions = .{
                    .size = size,
                    .alignment = elemLayout.dimensions.alignment,
                } };
            },

            .Struct => |info| Struct: {
                var dimensions = Dimensions{};
                var maxAlignment: Alignment = 1;

                const offsets = try ir.allocator.alloc(Offset, info.fields.len);
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
                var dimensions = Dimensions{};

                const discriminatorLayout = try info.discriminator.getLayout();

                for (info.fields) |field| {
                    const fieldLayout = try field.type.getLayout();

                    dimensions.alignment = @max(dimensions.alignment, fieldLayout.dimensions.alignment);
                    dimensions.size = @max(dimensions.size, fieldLayout.dimensions.size);
                }

                var offsets = try ir.allocator.alloc(Offset, 2);
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
                var dimensions = Dimensions{};
                var maxAlignment: Alignment = 1;

                const offsets = try ir.allocator.alloc(Offset, type_set.len);
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
                var dimensions = Dimensions{};

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

            .Function => .{ .local_storage = .register, .dimensions = .{ .size = 2, .alignment = 2 } },
        };
    }

    /// Create a `TypeInfo` from a native type
    ///
    /// `parameterNames` is used, if provided, to give names for (top-level) function parameters if the native type is a function type
    pub fn fromNative(comptime T: type, rir: *Rir, parameterNames: ?[]const NameId) !TypeInfo {
        switch (T) {
            void => return .Nil,
            bool => return .Bool,
            u8 => return .U8,
            u16 => return .U16,
            u32 => return .U32,
            u64 => return .U64,
            i8 => return .S8,
            i16 => return .S16,
            i32 => return .S32,
            i64 => return .S64,
            f32 => return .F32,
            f64 => return .F64,

            else => switch (@typeInfo(T)) {
                .pointer => |info| {
                    const elementType = try rir.createTypeIdFromNative(info.child, null, null);
                    return TypeInfo{ .Pointer = elementType.id };
                },
                .array => |info| {
                    const elementType = try rir.createTypeIdFromNative(info.child, null, null);
                    return TypeInfo{ .Array = .{
                        .length = info.len,
                        .element = elementType,
                    } };
                },
                .@"struct" => |info| {
                    var field_types = try rir.allocator.alloc(TypeId, info.fields.len);
                    errdefer rir.allocator.free(field_types);

                    for (info.fields, 0..) |field, i| {
                        const fieldType = try rir.createTypeIdFromNative(field.type, null, null);
                        field_types[i] = fieldType.id;
                    }

                    return TypeInfo{ .Product = field_types };
                },
                .@"enum" => |info| return rir.typeFromNative(info.tag_type, null),
                .@"union" => |info| {
                    var field_types = try rir.allocator.alloc(TypeId, info.fields.len);
                    errdefer rir.allocator.free(field_types);

                    for (info.fields, 0..) |field, i| {
                        const fieldType = try rir.createTypeFromNative(field.type, null, null);
                        field_types[i] = fieldType.id;
                    }

                    if (info.tag_type) |TT| {
                        const discType = try rir.createTypeFromNative(TT, null, null);
                        return Type{ .Union = .{
                            .discriminator = discType.id,
                            .types = field_types,
                        } };
                    } else {
                        return TypeInfo{ .Sum = field_types };
                    }
                },
                .@"fn" => |info| {
                    const returnType = try rir.createTypeFromNative(info.return_type.?, null, null);
                    const terminationType = try rir.createTypeFromNative(void, null, null);

                    const effects = try rir.allocator.alloc(*Type, 0);
                    errdefer rir.allocator.free(effects);

                    var parameters = try rir.allocator.alloc(Parameter, info.params.len);
                    errdefer rir.allocator.free(parameters);

                    inline for (info.params, 0..) |param, i| {
                        const paramType = try rir.createTypeFromNative(param.type.?, null, null);

                        parameters[i] = Parameter{
                            .name = if (parameterNames) |names| names[i] else try rir.internName(std.fmt.comptimePrint("arg{}", .{i})),
                            .type = paramType,
                        };
                    }

                    return TypeInfo{ .Function = .{
                        .call_conv = .foreign,
                        .return_type = returnType,
                        .termination_type = terminationType,
                        .effects = effects,
                        .parameters = parameters,
                    } };
                },

                else => @compileError("cannot convert type `" ++ @typeName(T) ++ "` to Type"),
            },
        }
    }
};

pub const PointerTypeInfo = struct {
    alignment_override: ?Alignment = null,
    element: *Type,
};

pub const SliceTypeInfo = struct {
    alignment_override: ?Alignment = null,
    element: *Type,
};

pub const ArrayTypeInfo = struct {
    length: u64,
    element: *Type,

    pub fn onFormat(self: ArrayTypeInfo, formatter: Formatter) !void {
        try formatter.writeAll("[");
        try formatter.fmt(self.length);
        try formatter.writeAll("]");
        try formatter.fmt(self.element);
    }
};

pub const StructField = struct {
    name: NameId,
    type: *Type,

    pub fn onFormat(self: StructField, formatter: Formatter) !void {
        try formatter.fmt(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
    }
};

pub const StructTypeInfo = struct {
    fields: []const StructField,

    pub fn clone(self: *const StructTypeInfo, allocator: std.mem.Allocator) !StructTypeInfo {
        return StructTypeInfo{
            .fields = try allocator.dupe(StructField, self.fields),
        };
    }

    pub fn deinit(self: StructTypeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }

    pub fn onFormat(self: StructTypeInfo, formatter: Formatter) !void {
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
    discriminant: Immediate,
    name: NameId,
    type: *Type,

    pub fn onFormat(self: UnionField, formatter: Formatter) !void {
        const oldTypeMode = formatter.swapFlag(.show_nominative_type_bodies, false);
        defer formatter.setFlag(.show_nominative_type_bodies, oldTypeMode);

        try formatter.fmt(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" ");
        try formatter.parens(self.discriminant);
    }
};

pub const UnionTypeInfo = struct {
    discriminator: *Type,
    fields: []const UnionField,

    pub fn clone(self: *const UnionTypeInfo, allocator: std.mem.Allocator) !UnionTypeInfo {
        return UnionTypeInfo{
            .discriminator = self.discriminator,
            .fields = try allocator.dupe(UnionField, self.fields),
        };
    }

    pub fn deinit(self: UnionTypeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.fields);
    }

    pub fn onFormat(self: UnionTypeInfo, formatter: Formatter) !void {
        try formatter.writeAll("union{");
        for (self.fields, 0..) |field, i| {
            if (i != 0) try formatter.writeAll(", ");
            try formatter.fmt(field);
        }
        try formatter.writeAll("}");
    }
};

pub const Parameter = struct {
    name: NameId,
    type: *Type,

    pub fn onFormat(self: Parameter, formatter: Formatter) !void {
        try formatter.fmt(self.name);
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
    }
};

pub const CallConv = enum {
    auto,
    foreign,
};

pub const FunctionTypeInfo = struct {
    call_conv: CallConv,
    return_type: *Type,
    termination_type: *Type,
    effects: []const *Type,
    parameters: []const Parameter,

    pub fn deinit(self: FunctionTypeInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.effects);
        allocator.free(self.parameters);
    }

    pub fn clone(self: *const FunctionTypeInfo, allocator: std.mem.Allocator) !FunctionTypeInfo {
        const effects = try allocator.dupe(*Type, self.effects);
        errdefer allocator.free(effects);

        const parameters = try allocator.dupe(Parameter, self.parameters);
        errdefer allocator.free(parameters);

        return FunctionTypeInfo{
            .call_conv = self.call_conv,
            .return_type = self.return_type,
            .termination_type = self.termination_type,
            .effects = effects,
            .parameters = parameters,
        };
    }

    pub fn onFormat(self: FunctionTypeInfo, formatter: Formatter) !void {
        if (self.call_conv != .auto) {
            try formatter.writeAll(@tagName(self.call_conv));
        }
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

const HandlerList = std.ArrayHashMapUnmanaged(EvidenceId, *Function, utils.SimpleHashContext, false);

pub const HandlerSet = struct {
    pub const Id = HandlerSetId;

    rir: *Rir,

    module: *Module,

    id: HandlerSetId,

    parent: ?*Block = null,
    handlers: HandlerList = .{},

    pub fn init(module: *Module, id: HandlerSetId) !*HandlerSet {
        const ir = module.rir;

        const ptr = try ir.allocator.create(HandlerSet);
        errdefer ir.allocator.destroy(ptr);

        ptr.* = HandlerSet{
            .rir = ir,
            .module = module,
            .id = id,
        };

        return ptr;
    }

    pub fn deinit(self: *HandlerSet) void {
        for (self.handlers.values()) |h| {
            h.deinit();
        }

        self.handlers.deinit(self.rir.allocator);

        self.rir.allocator.destroy(self);
    }

    pub fn createHandler(self: *HandlerSet, name: NameId, evId: EvidenceId, typeIr: *Type) !*Function {
        if (self.handlers.contains(evId)) {
            return error.EvidenceOverlap;
        }

        // TODO: check type against evidence signature

        const func = try self.module.createFunction(name, typeIr);

        func.parent = self.parent;
        func.evidence = evId;

        try self.handlers.put(self.rir.allocator, evId, func);

        return func;
    }

    pub fn getHandler(self: *HandlerSet, evId: EvidenceId) !*Function {
        return self.handlers.get(evId) orelse error.InvalidEvidenceId;
    }
};

pub const Foreign = struct {
    pub const Id = ForeignId;

    root: *Rir,
    id: ForeignId,
    name: NameId,
    type: *Type,

    pub fn init(root: *Rir, id: ForeignId, name: NameId, typeIr: *Type) error{ InvalidCallConv, ExpectedFunctionType, OutOfMemory }!*Foreign {
        const ptr = try root.allocator.create(Foreign);
        errdefer root.allocator.destroy(ptr);

        const functionTypeInfo = try typeIr.info.forceFunction();

        if (functionTypeInfo.call_conv != .foreign) {
            return error.InvalidCallConv;
        }

        ptr.* = Foreign{
            .root = root,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return ptr;
    }

    pub fn deinit(self: *Foreign) void {
        self.root.allocator.destroy(self);
    }
};

const BlockList = std.ArrayListUnmanaged(*Block);
const UpvalueList = std.ArrayListUnmanaged(LocalId);

pub const Function = struct {
    pub const Id = FunctionId;

    rir: *Rir,
    module: *Module,

    id: FunctionId,
    name: NameId,

    type: *Type,

    evidence: ?EvidenceId = null,
    blocks: BlockList = .{},
    parent: ?*Block = null,
    upvalue_indices: UpvalueList = .{},
    local_id_counter: usize = 0,

    pub fn getRef(self: *const Function) OpRef(Function) {
        return OpRef(Function){
            .module_id = self.module.id,
            .id = self.id,
        };
    }

    pub fn init(moduleIr: *Module, id: FunctionId, name: NameId, typeIr: *Type) error{ ExpectedFunctionType, OutOfMemory }!*Function {
        const rir = moduleIr.rir;

        const self = try rir.allocator.create(Function);
        errdefer rir.allocator.destroy(self);

        self.* = Function{
            .rir = rir,
            .module = moduleIr,

            .id = id,
            .name = name,

            .type = typeIr,
        };

        const funcTyInfo = try self.getTypeInfo();

        if (funcTyInfo.call_conv == .foreign) {
            return error.ExpectedFunctionType;
        }

        const entryName = try rir.internName("entry");

        const entryBlock = try Block.init(self, null, @enumFromInt(0), entryName);
        errdefer entryBlock.deinit();

        try self.blocks.append(rir.allocator, entryBlock);

        for (funcTyInfo.parameters) |param| {
            _ = entryBlock.createLocal(param.name, param.type) // shouldn't be able to get error.TooManyLocals here; the type was already checked
            catch |err| return utils.types.forceErrorSet(error{OutOfMemory}, err);
        }

        return self;
    }

    pub fn deinit(self: *Function) void {
        for (self.blocks.items) |b| b.deinit();

        self.blocks.deinit(self.rir.allocator);

        self.upvalue_indices.deinit(self.rir.allocator);

        self.rir.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Function, formatter: Formatter) !void {
        const oldActiveFunction = formatter.swapFunction(self);
        defer formatter.setFunction(oldActiveFunction);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" =");
        try formatter.beginBlock();
        for (self.blocks.items, 0..) |b, i| {
            if (i > 0) try formatter.endLine();
            try formatter.fmt(b);
        }
        try formatter.endBlock();
    }

    pub fn freshLocalId(self: *Function) error{TooManyLocals}!LocalId {
        const id = self.local_id_counter;

        if (id > MAX_LOCALS) {
            return error.TooManyLocals;
        }

        self.local_id_counter += 1;

        return @enumFromInt(id);
    }

    pub fn getTypeInfo(self: *const Function) error{ExpectedFunctionType}!*const FunctionTypeInfo {
        return self.type.info.forceFunction();
    }

    pub fn getParameters(self: *const Function) error{ExpectedFunctionType}![]const Parameter {
        return (try self.getTypeInfo()).parameters;
    }

    pub fn getReturnType(self: *const Function) error{ExpectedFunctionType}!*Type {
        return (try self.getTypeInfo()).return_type;
    }

    pub fn getEffects(self: *const Function) error{ExpectedFunctionType}![]const *Type {
        return (try self.getTypeInfo()).effects;
    }

    pub fn getArity(self: *const Function) error{ExpectedFunctionType}!Arity {
        return @intCast((try self.getParameters()).len);
    }

    pub fn getArgument(self: *const Function, argIndex: Arity) error{ InvalidArgument, ExpectedFunctionType }!*Local {
        if (argIndex >= try self.getArity()) {
            return error.InvalidArgument;
        }

        return self.getEntryBlock().local_map.values()[argIndex];
    }

    pub fn createUpvalue(self: *Function, parentLocal: LocalId) error{ TooManyUpvalues, InvalidLocal, InvalidUpvalue, OutOfMemory }!UpvalueId {
        if (self.parent) |parent| {
            _ = try parent.getLocal(parentLocal);

            const index = self.upvalue_indices.items.len;

            if (index >= MAX_LOCALS) {
                return error.TooManyUpvalues;
            }

            try self.upvalue_indices.append(self.rir.allocator, parentLocal);

            return @enumFromInt(index);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getUpvalue(self: *const Function, u: UpvalueId) error{ InvalidUpvalue, InvalidLocal }!*Local {
        if (self.parent) |parent| {
            if (@intFromEnum(u) >= self.upvalue_indices.items.len) {
                return error.InvalidUpvalue;
            }

            return parent.getLocal(self.upvalue_indices.items[@intFromEnum(u)]);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getEntryBlock(self: *const Function) *Block {
        return self.blocks.items[0];
    }

    pub fn createBlock(self: *Function, parent: *Block, name: NameId) error{ TooManyBlocks, OutOfMemory }!*Block {
        const index = self.blocks.items.len;

        if (index >= MAX_BLOCKS) {
            return error.TooManyBlocks;
        }

        const newBlock = try Block.init(self, parent, @enumFromInt(index), name);

        try self.blocks.append(self.rir.allocator, newBlock);

        return newBlock;
    }

    pub fn getBlock(self: *const Function, id: BlockId) error{InvalidBlock}!*Block {
        if (@intFromEnum(id) >= self.blocks.items.len) {
            return error.InvalidBlock;
        }

        return self.blocks.items[@intFromEnum(id)];
    }
};

pub const Check = enum(u1) { none, non_zero };
pub const BitSize = enum(u2) { b8, b16, b32, b64 };

pub const Instruction = packed struct {
    code: OpCode,
    data: OpData,
    _padding: std.meta.Int(.unsigned, 64 - (@bitSizeOf(OpCode) + @bitSizeOf(OpData))) = 0,

    pub fn onFormat(self: Instruction, formatter: Formatter) !void {
        const flags = formatter.getFlags();
        if (flags.show_op_code_bytes) {
            try formatter.print("{x:0<2}", .{@intFromEnum(self.code)});
            if (flags.show_op_data_bytes) {
                if (formatter.getOpCodeDataSplit()) |c| try formatter.print("{u}", .{c});
            }
        }
        if (flags.show_op_data_bytes) try formatter.print("{x:0<12} ", .{@as(u48, @bitCast(self.data))});
        try formatter.fmt(self.code);
        try formatter.writeAll(" ");
        try self.data.formatWith(formatter, self.code);
    }

    comptime {
        if (@sizeOf(Instruction) != 8) {
            @compileError(std.fmt.comptimePrint("Instruction size changed: {}", .{@sizeOf(Instruction)}));
        }
    }
};

pub const OpCode = enum(u8) {
    nop,
    halt,
    trap,

    block,
    with,
    @"if",
    when,
    br,
    re,

    call,
    ret,
    cancel,

    addr,
    load,
    store,

    add,
    sub,
    mul,
    div,
    rem,
    neg,

    band,
    bor,
    bxor,
    bnot,
    bshiftl,
    bshiftr,

    eq,
    ne,
    lt,
    gt,
    le,
    ge,

    cast,

    clear,
    swap,
    copy,

    read,
    write,

    new_local,

    ref_local,
    ref_block,
    ref_function,
    ref_foreign,
    ref_global,
    ref_upvalue,

    im_i,
    im_w,

    pub fn format(self: OpCode, comptime _: []const u8, _: anytype, writer: anytype) !void {
        try writer.writeAll(@tagName(self));
    }

    comptime {
        for (std.meta.fieldNames(OpData)) |opName| {
            if (!@hasField(OpCode, opName)) {
                @compileError("missing OpCode: `" ++ opName ++ "`");
            }
        }
    }
};

pub fn OpRef(comptime T: type) type {
    return packed struct {
        module_id: ModuleId,
        id: T.Id,
    };
}

pub const OpLocal = packed struct {
    name: NameId,
    type_id: TypeId,

    pub fn onFormat(self: OpLocal, formatter: Formatter) !void {
        try formatter.writeAll("{");
        try formatter.fmt(self.name);
        try formatter.writeAll(" : ");
        try formatter.fmt(self.type_id);
        try formatter.writeAll("}");
    }
};

pub const OpImmediate = packed struct {
    data: u32,
    type_id: TypeId,

    pub fn getType(self: OpImmediate, ir: *Rir) error{InvalidType}!*Type {
        return ir.getType(self.type_id);
    }

    pub fn getMemory(self: anytype) utils.types.CopyConst([]u8, @TypeOf(self)) {
        return @as(utils.types.CopyConst([*]align(@alignOf(OpImmediate)) u8, @TypeOf(self)), @ptrCast(&self.data))[0..@sizeOf(u32)];
    }

    fn convert(val: anytype) u32 {
        return switch (@typeInfo(@TypeOf(val))) {
            .comptime_int => @as(u32, val),
            .int => |info| if (info.bits <= 32) switch (info.signedness) {
                .unsigned => @as(u32, val),
                .signed => @as(u32, @as(std.meta.Int(.unsigned, info.bits), @bitCast(val))),
            } else @bitCast(@as(std.meta.Int(info.signedness, 32), @intCast(val))),
            .@"enum" => |info| convert(@as(info.tag_type, @intFromEnum(val))),
            else => @as(u32, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(val))), @bitCast(val))),
        };
    }

    pub fn fromNative(typeIr: *Type, val: anytype) error{ TypeMismatch, TooManyTypes, OutOfMemory }!OpImmediate {
        try typeIr.checkNative(@TypeOf(val));

        return OpImmediate{
            .type_id = typeIr.id,
            .data = convert(val),
        };
    }

    pub fn onFormat(self: *const OpImmediate, formatter: Formatter) !void {
        if (formatter.getFlag(.raw_immediates)) {
            try formatter.writeAll("0x");
            try std.fmt.formatInt(self.data, 16, .lower, .{
                .alignment = .left,
                .width = 2 * @sizeOf(u32),
                .fill = '0',
            }, formatter);
        } else {
            const T = try self.getType(formatter.getRir());

            try formatter.writeAll("{");
            try T.formatMemory(formatter, self.getMemory());
            try formatter.writeAll(" : ");
            try formatter.fmt(T);
            try formatter.writeAll("}");
        }
    }
};

pub const OpData = packed union {
    nop: void,
    halt: void,
    trap: void,

    block: TypeId,
    with: TypeId,
    @"if": TypeId,
    when: void,

    br: Check,
    re: Check,

    call: Arity,
    ret: void,
    cancel: void,

    addr: void,
    load: void,
    store: void,

    add: void,
    sub: void,
    mul: void,
    div: void,
    rem: void,
    neg: void,

    band: void,
    bor: void,
    bxor: void,
    bnot: void,
    bshiftl: void,
    bshiftr: void,

    eq: void,
    ne: void,
    lt: void,
    gt: void,
    le: void,
    ge: void,

    cast: TypeId,

    clear: Index,
    swap: Index,
    copy: Index,

    read: void,
    write: void,

    new_local: OpLocal,

    ref_local: LocalId,
    ref_block: BlockId,
    ref_function: OpRef(Function),
    ref_foreign: ForeignId,
    ref_global: OpRef(Global),
    ref_upvalue: UpvalueId,

    im_i: OpImmediate,
    im_w: TypeId,

    pub fn formatWith(self: OpData, formatter: Formatter, code: OpCode) Formatter.Error!void {
        switch (code) {
            .nop => {},
            .halt => {},
            .trap => {},

            .block => try formatter.fmt(self.block),
            .with => try formatter.fmt(self.with),
            .@"if" => try formatter.fmt(self.@"if"),
            .when => {},
            .br => try formatter.fmt(self.br),
            .re => try formatter.fmt(self.re),

            .call => try formatter.fmt(self.call),
            .ret => {},
            .cancel => {},

            .addr => {},
            .load => {},
            .store => {},

            .add => {},
            .sub => {},
            .mul => {},
            .div => {},
            .rem => {},
            .neg => {},

            .band => {},
            .bor => {},
            .bxor => {},
            .bnot => {},
            .bshiftl => {},
            .bshiftr => {},

            .eq => {},
            .ne => {},
            .lt => {},
            .gt => {},
            .le => {},
            .ge => {},

            .cast => try formatter.fmt(self.cast),

            .clear => try formatter.fmt(self.clear),
            .swap => try formatter.fmt(self.swap),
            .copy => try formatter.fmt(self.copy),

            .read => {},
            .write => {},

            .new_local => try formatter.fmt(self.new_local),

            .ref_local => try formatter.fmt(self.ref_local),
            .ref_block => try formatter.fmt(self.ref_block),
            .ref_function => try formatter.fmt(self.ref_function),
            .ref_foreign => try formatter.fmt(self.ref_foreign),
            .ref_global => try formatter.fmt(self.ref_global),
            .ref_upvalue => try formatter.fmt(self.ref_upvalue),

            .im_i => try self.im_i.onFormat(formatter),
            .im_w => try formatter.fmt(self.im_w),
        }
    }

    comptime {
        for (std.meta.fieldNames(OpCode)) |opName| {
            if (!@hasField(OpData, opName)) {
                @compileError("missing OpData: `" ++ opName ++ "`");
            }
        }
    }

    pub fn Of(comptime code: OpCode) type {
        @setEvalBranchQuota(2000);
        inline for (std.meta.fieldNames(OpCode)) |name| {
            if (@field(OpCode, name) == code) {
                for (std.meta.fields(OpData)) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        return field.type;
                    }
                }
                unreachable;
            }
        }
        unreachable;
    }
};

/// Used as operands when compiling instructions
/// * Not comptime known
/// * Writable
/// * Un-addressable
/// * Maximum 4 Registers in size
pub const MultiRegister = struct {
    rir: *Rir,
    block: *Block,

    id: RegisterId,
    type: *Type,
    indices: [MAX_MULTI_REGISTER]Rbc.RegisterIndex,

    pub fn getType(self: *const MultiRegister) *Type {
        return self.type;
    }

    pub fn init(block: *Block, id: RegisterId, typeIr: *Type, indices: [MAX_MULTI_REGISTER]Rbc.RegisterIndex) error{OutOfMemory}!*MultiRegister {
        const rir = block.rir;

        const self = try rir.allocator.create(MultiRegister);

        self.* = MultiRegister{
            .rir = rir,
            .block = block,
            .id = id,
            .type = typeIr,
            .indices = indices,
        };

        return self;
    }
};

/// Used as operands when compiling instructions
/// * Not comptime known
/// * Writable
/// * Un-addressable
/// * Maximum 64 bits in size
pub const Register = struct {
    rir: *Rir,
    block: *Block,

    id: RegisterId,
    type: *Type,

    pub fn getType(self: *const Register) *Type {
        return self.type;
    }

    pub fn getIndex(self: *const Register) Rbc.RegisterIndex {
        return @intFromEnum(self.id);
    }

    pub fn init(block: *Block, id: RegisterId, typeIr: *Type) error{OutOfMemory}!*Register {
        const rir = block.rir;

        const self = try rir.allocator.create(Register);

        self.* = Register{
            .rir = rir,
            .block = block,
            .id = id,
            .type = typeIr,
        };

        return self;
    }
};

pub const SimpleImmediateSize = enum(u16) {
    @"inline" = 32,
    wide = 64,
};

/// Used as operands when compiling instructions
/// * Comptime known
/// * Constant
/// * Un-addressable
/// * Maximum 64 bits in size
pub const Immediate = struct {
    data: u64,
    type: *Type,

    pub fn zero(typeIr: *Type) Immediate {
        return Immediate{
            .type = typeIr,
            .data = 0,
        };
    }

    pub fn fromNative(rir: *Rir, val: anytype) error{ TooManyTypes, OutOfMemory }!Immediate {
        return Immediate{
            .type = try rir.createTypeFromNative(@TypeOf(val), null, null),
            .data = convert(val),
        };
    }

    pub fn getType(self: *const Immediate) *Type {
        return self.type;
    }

    pub fn getMemory(self: anytype) utils.types.CopyConst([]u8, @TypeOf(self)) {
        return @as(utils.types.CopyConst([*]align(@alignOf(OpImmediate)) u8, @TypeOf(self)), @ptrCast(&self.data))[0..@sizeOf(u64)];
    }

    pub fn onFormat(self: *const Immediate, formatter: Formatter) !void {
        if (formatter.getFlag(.raw_immediates)) {
            try formatter.writeAll("0x");
            try std.fmt.formatInt(self.data, 16, .lower, .{
                .alignment = .left,
                .width = 2 * @sizeOf(u64),
                .fill = '0',
            }, formatter);
        } else {
            try formatter.writeAll("{");
            try self.type.formatMemory(formatter, &std.mem.toBytes(self.data));
            try formatter.writeAll(" : ");
            try formatter.fmt(self.type);
            try formatter.writeAll("}");
        }
    }

    fn convert(val: anytype) u64 {
        return switch (@typeInfo(@TypeOf(val))) {
            .comptime_int => @as(u64, val),
            .int => |info| if (info.bits <= 64) switch (info.signedness) {
                .unsigned => @as(u64, val),
                .signed => @as(u64, @as(std.meta.Int(.unsigned, info.bits), @bitCast(val))),
            } else @bitCast(@as(std.meta.Int(info.signedness, 64), @intCast(val))),
            .@"enum" => |info| convert(@as(info.tag_type, @intFromEnum(val))),
            else => @as(u64, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(val))), @bitCast(val))),
        };
    }
};

/// A dynamic value that can be used as an operand for instructions
/// * Not comptime known unless marked as `comptime` (as a `Local`) or as `immutable` (as a `Global`)
/// * Writable, unless marked as `immutable` (as a `Global`)
pub const LValue = union(enum) {
    register: *Register,
    multi_register: *MultiRegister,

    local: *Local,
    upvalue: *Upvalue,
    global: *Global,

    pub fn getType(self: LValue) *Type {
        return switch (self) {
            inline else => |x| x.type,
        };
    }

    /// Extract a `Register` from an `LValue` or return `error.ExpectedRegister`
    pub fn forceRegister(self: LValue) error{ExpectedRegister}!*Register {
        return switch (self) {
            .register => |x| x,
            inline else => return error.ExpectedRegister,
        };
    }

    /// Extract a `MultiRegister` from an `LValue` or return `error.ExpectedMultiRegister`
    pub fn forceMultiRegister(self: LValue) error{ExpectedMultiRegister}!*MultiRegister {
        return switch (self) {
            .multi_register => |x| x,
            inline else => return error.ExpectedMultiRegister,
        };
    }

    /// Extract a `Local` from an `LValue` or return `error.ExpectedLocal`
    pub fn forceLocal(self: LValue) error{ExpectedLocal}!*Local {
        return switch (self) {
            .local => |x| x,
            inline else => return error.ExpectedLocal,
        };
    }

    /// Extract an `Upvalue` from an `LValue` or return `error.ExpectedUpvalue`
    pub fn forceUpvalue(self: LValue) error{ExpectedUpvalue}!*Upvalue {
        return switch (self) {
            .upvalue => |x| x,
            inline else => return error.ExpectedUpvalue,
        };
    }

    /// Determine if an `LValue` is known at compile time
    ///
    /// | Kind | Comptime Known | Reasoning |
    /// |-|-|-|
    /// | `register` | `false` | Registers exist at runtime |
    /// | `multi_register` | `false` | Registers exist at runtime |
    /// | `local` | See `Local.isComptimeKnown` |
    /// | `upvalue` | See `Upvalue.isComptimeKnown` |
    /// | `global` | See `Global.isComptimeKnown` |
    pub fn isComptimeKnown(self: LValue) bool {
        return switch (self) {
            .local => |x| x.isComptimeKnown(),
            .global => |x| x.isComptimeKnown(),
            inline else => false,
        };
    }

    /// Determine if an `LValue` is writable
    /// | Kind | Writable | Reasoning |
    /// |-|-|-|
    /// | `register` | `true` | Registers are writable |
    /// | `multi_register` | `true` | Registers are writable |
    /// | `local` | See `Local.isWritable` |
    /// | `upvalue` | See `Upvalue.isWritable` |
    /// | `global` | See `Global.isWritable` |
    pub fn isWritable(self: LValue) bool {
        return switch (self) {
            .global => |x| x.mutability == .mutable,
            inline else => true,
        };
    }
};

/// A static value that can be used as an operand for instructions
/// * Comptime known
/// * Constant
/// * Un-addressable
pub const RValue = union(enum) {
    immediate: Immediate,
    foreign: *Foreign,
    function: *Function,

    pub fn getType(self: RValue) *Type {
        return switch (self) {
            inline else => |x| x.type,
        };
    }

    pub fn getMemory(self: anytype) []const u8 {
        return switch (self) {
            .immediate => |x| x.getMemory(),
            .foreign => |x| @as([*]align(@alignOf(Foreign)) const u8, @ptrCast(x))[0..@sizeOf(Foreign)],
            .function => |x| @as([*]align(@alignOf(Function)) const u8, @ptrCast(x))[0..@sizeOf(Function)],
        };
    }

    /// Extract an `Immediate` from an `RValue` or return `error.ExpectedImmediate`
    pub fn forceImmediate(self: RValue) error{ExpectedImmediate}!Immediate {
        return switch (self) {
            .immediate => |x| x,
            inline else => return error.ExpectedImmediate,
        };
    }

    // Extract a `ForeignAddress` from an `RValue` or return `error.ExpectedForeign`
    pub fn forceForeign(self: RValue) error{ExpectedForeign}!*Foreign {
        return switch (self) {
            .foreign => |x| x,
            inline else => return error.ExpectedForeign,
        };
    }

    /// Extract a `Function` from an `RValue` or return `error.ExpectedFunction`
    pub fn forceFunction(self: RValue) error{ExpectedFunction}!*Function {
        return switch (self) {
            .function => |x| x,
            inline else => return error.ExpectedFunction,
        };
    }
};

/// Compile time meta data that can be used as an operand for instructions
/// * Comptime known
/// * Constant
/// * Un-addressable
pub const Meta = union(enum) {
    type: *Type,
    block: *Block,
    handler_set: *HandlerSet,

    pub fn getType(self: Meta) error{ OutOfMemory, TooManyTypes }!*Type {
        return switch (self) {
            .type => |x| try x.rir.createType(null, .Type),
            .block => |x| try x.rir.createType(null, .Block),
            .handler_set => |x| try x.rir.createType(null, .HandlerSet),
        };
    }

    pub fn getMemory(self: anytype) utils.types.CopyConst([]u8, @TypeOf(self)) {
        return @as(utils.types.CopyConst([*]align(@alignOf(Meta)) u8, @TypeOf(self)), @ptrCast(&self))[0..@sizeOf(Meta)];
    }

    /// Extract a `Type` from a `Meta` value or return `error.ExpectedType`
    pub fn forceType(self: Meta) error{ExpectedType}!*Type {
        return switch (self) {
            .type => |x| x,
            inline else => return error.ExpectedType,
        };
    }

    /// Extract a `Block` from a `Meta` value or return `error.ExpectedBlock`
    pub fn forceBlock(self: Meta) error{ExpectedBlock}!*Block {
        return switch (self) {
            .block => |x| x,
            inline else => return error.ExpectedBlock,
        };
    }

    /// Extract a `HandlerSet` from a `Meta` value or return `error.ExpectedHandlerSet`
    pub fn forceHandlerSet(self: Meta) error{ExpectedHandlerSet}!*HandlerSet {
        return switch (self) {
            .handler_set => |x| x,
            inline else => return error.ExpectedHandlerSet,
        };
    }
};

/// Intermediate data used when compiling an `Instruction`
///
/// See variant type definitions for more information
pub const Operand = union(enum) {
    meta: Meta,
    l_value: LValue,
    r_value: RValue,

    pub fn getType(self: Operand) error{ OutOfMemory, TooManyTypes }!*Type {
        return switch (self) {
            .meta => |x| try x.getType(),
            .l_value => |x| x.getType(),
            .r_value => |x| x.getType(),
        };
    }

    pub fn getMemory(self: anytype) utils.types.CopyConst([]u8, @TypeOf(self)) {
        return switch (self) {
            .meta => |x| x.getMemory(),
            .l_value => |x| x.getMemory(),
            .r_value => |x| x.getMemory(),
        };
    }

    pub fn from(val: anytype) Operand {
        const T = @TypeOf(val);
        return switch (T) {
            Operand => val,

            *Type => .{ .meta = .{ .type = val } },
            *Block => .{ .meta = .{ .block = val } },
            *HandlerSet => .{ .meta = .{ .handler_set = val } },

            *Register => .{ .l_value = .{ .register = val } },
            *MultiRegister => .{ .l_value = .{ .multi_register = val } },
            *Local => .{ .l_value = .{ .local = val } },
            *Upvalue => .{ .l_value = .{ .upvalue = val } },
            *Global => .{ .l_value = .{ .global = val } },

            Immediate => .{ .r_value = .{ .immediate = val } },
            *Foreign => .{ .r_value = .{ .foreign = val } },
            *Function => .{ .r_value = .{ .function = val } },

            else => @compileError("Invalid operand type " ++ @typeName(T)),
        };
    }

    /// Extract a `Meta` value from an `Operand` or return `error.ExpectedMeta`
    pub fn forceMeta(self: Operand) error{ExpectedMeta}!Meta {
        switch (self) {
            .meta => |x| return x,
            inline else => return error.ExpectedMeta,
        }
    }

    /// Extract an `LValue` from an `Operand` or return `error.ExpectedLValue`
    pub fn forceLValue(self: Operand) error{ExpectedLValue}!LValue {
        switch (self) {
            .l_value => |x| return x,
            inline else => return error.ExpectedLValue,
        }
    }

    /// Extract an `RValue` from an `Operand` or return `error.ExpectedRValue`
    pub fn forceRValue(self: Operand) error{ExpectedRValue}!RValue {
        switch (self) {
            .r_value => |x| return x,
            inline else => return error.ExpectedRValue,
        }
    }

    /// Determine if an `Operand` is a constant
    ///
    /// An operand is a constant, if:
    /// - It is a `Meta` value
    /// - It is an `RValue`
    /// - It is an `LValue` that is constant. See `LValue.isConstant`.
    pub fn isConstant(self: Operand) bool {
        return switch (self) {
            .l_value => |l| l.isComptimeKnown(),
            inline else => true,
        };
    }
};

/// Describes where a `Local` variable is stored
pub const LocalStorage = union(enum) {
    /// The Local is not stored anywhere
    ///
    /// This is used by types like `Block`, that are compile time only;
    /// and by types that cannot be addressed, like `Function`
    none: void,

    /// The Local can pretend to be stored anywhere, because it has no size
    ///
    /// This is used for `Nil` and similar types
    zero_size: void,

    /// The Local is equal to or smaller than a single register in size
    ///
    /// This is used for ints, floats, etc
    register: void,

    /// The Local is stored in a set of up to 4 registers, with the total provided by the given `u2`
    ///
    /// This is used by special types like `Slice`
    n_registers: u2,

    /// The Local is too large to fit in a register, or has its address taken
    ///
    /// This is used for structs, arrays, etc
    stack: void,

    /// The Local is a compile time variable
    @"comptime": void,

    /// Shortcut to create `LocalStorage.n_registers`
    pub fn fromRegisters(n: u2) LocalStorage {
        return .{ .n_registers = n };
    }

    /// Determine a generic `LocalStorage` for a given value size
    ///
    /// Note that not all types with a given size will use the same `LocalStorage`, this is simply the default
    ///
    /// | Size | Storage |
    /// |-|-|
    /// | 0 |`zero_size` |
    /// | 1 ..= sizeOf(Rbc.Register) | `register` |
    /// | > | `stack` |
    pub fn fromSize(size: usize) LocalStorage {
        return if (size == 0) .zero_size else if (size <= @sizeOf(Rbc.Register)) .register else .stack;
    }

    /// Determine whether a `Local` with this `Storage` can be coerced to a single `Register`
    ///
    /// |Storage|Can Coerce|Reasoning|
    /// |-|-|-|
    /// |`none` | `false` | Not stored anywhere |
    /// |`zero_size` | `true` | Any `Register` is suitable for zero-sized operations |
    /// |`register` | `true` | It *is* a single `Register` |
    /// |`n_registers`| `false` | Ambiguous choice of `Register` |
    /// |`stack` | `false` | Additional instructions needed to `load`/`store` value |
    /// |`comptime`| `false` | In memory at compile time only |
    pub fn canCoerceSingleRegister(self: LocalStorage) bool {
        return self == .register or self == .zero_size;
    }
};

pub const Local = struct {
    pub const Id = LocalId;

    rir: *Rir,
    block: *Block,

    id: LocalId,
    name: NameId,
    type: *Type,

    lifetime_start: ?Offset = null,
    lifetime_end: ?Offset = null,
    register: ?*Register = null,
    storage: LocalStorage = .none,

    pub fn init(block: *Block, id: LocalId, name: NameId, typeIr: *Type) error{OutOfMemory}!*Local {
        const rir = block.rir;

        const self = try rir.allocator.create(Local);

        self.* = Local{
            .rir = rir,
            .block = block,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    pub fn deinit(self: *Local) void {
        self.rir.allocator.destroy(self);
    }

    pub fn isComptimeKnown(self: Local) bool {
        return self.storage == .@"comptime";
    }
};

pub const Upvalue = struct {
    pub const Id = UpvalueId;

    rir: *Rir,
    block: *Block,

    id: UpvalueId,
    name: NameId,
    type: *Type,

    pub fn init(block: *Block, id: UpvalueId, name: NameId, typeIr: *Type) error{OutOfMemory}!*Upvalue {
        const rir = block.rir;
        const self = try rir.allocator.create(Upvalue);

        self.* = Upvalue{
            .rir = rir,
            .block = block,
            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    pub fn deinit(self: *Upvalue) void {
        self.rir.allocator.destroy(self);
    }
};

pub const Mutability = enum(u1) {
    immutable = 0,
    mutable = 1,
};

pub const Global = struct {
    pub const Id = GlobalId;

    rir: *Rir,
    module: *Module,

    id: GlobalId,
    name: NameId,
    type: *Type,

    initial_value: ?[]u8 = null,
    mutability: Mutability = .immutable,

    pub fn getRef(self: *const Global) OpRef(Global) {
        return OpRef(Global){
            .module_id = self.module.id,
            .id = self.id,
        };
    }

    pub fn init(moduleIr: *Module, id: GlobalId, name: NameId, typeIr: *Type) error{OutOfMemory}!*Global {
        const rir = moduleIr.rir;

        const self = try rir.allocator.create(Global);
        errdefer rir.allocator.destroy(self);

        self.* = Global{
            .rir = rir,
            .module = moduleIr,

            .id = id,
            .name = name,
            .type = typeIr,
        };

        return self;
    }

    pub fn deinit(self: *Global) void {
        if (self.initial_value) |ini| self.rir.allocator.free(ini);
        self.rir.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Global, formatter: Formatter) !void {
        const oldActiveModule = formatter.swapModule(self.module);
        defer formatter.setModule(oldActiveModule);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(": ");
        try formatter.fmt(self.type);
        try formatter.writeAll(" = ");

        if (self.initial_value) |iv| {
            try self.type.formatMemory(formatter, iv);
        } else {
            try formatter.writeAll("{uninitialized}");
        }
    }

    /// Determine whether the value of this `Global` is known at compile time
    ///
    /// This is `true` for `Globals` that meet the following criteria:
    /// - The global is `immutable`
    /// - The `initial_value` is not `null`
    pub fn isComptimeKnown(self: *const Global) bool {
        return self.mutability == .immutable and self.initial_value != null;
    }

    /// Initialize a `Global` with a native value
    pub fn initializerFromNative(self: *Global, value: anytype) error{ TypeMismatch, TooManyGlobals, TooManyTypes, OutOfMemory }!void {
        const T = @TypeOf(value);
        const typeIr = try self.rir.createTypeFromNative(T, null, null);

        if (typeIr.id != self.type.id) {
            return error.TypeMismatch;
        }

        self.initial_value = try self.rir.allocator.dupe(u8, @as([*]const u8, @ptrCast(&value))[0..@sizeOf(T)]);
    }
};

const LocalMap = std.ArrayHashMapUnmanaged(LocalId, *Local, utils.SimpleHashContext, false);

pub const Block = struct {
    pub const Id = BlockId;

    rir: *Rir,
    function: *Function,

    parent: ?*Block,
    id: BlockId,
    name: NameId,

    has_exit: bool = false,
    handler_set: ?*HandlerSet = null,
    local_map: LocalMap = .{},
    instructions: std.ArrayListUnmanaged(Instruction) = .{},

    pub fn init(functionIr: *Function, parent: ?*Block, id: BlockId, name: NameId) !*Block {
        const rir = functionIr.rir;

        const ptr = try rir.allocator.create(Block);
        errdefer rir.allocator.destroy(ptr);

        ptr.* = Block{
            .rir = rir,
            .function = functionIr,
            .parent = parent,
            .id = id,
            .name = name,
        };

        return ptr;
    }

    pub fn deinit(self: *Block) void {
        for (self.local_map.values()) |x| x.deinit();
        self.local_map.deinit(self.rir.allocator);

        self.instructions.deinit(self.rir.allocator);
        self.rir.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Block, formatter: Formatter) !void {
        const oldBlock = formatter.swapBlock(self);
        defer formatter.setBlock(oldBlock);

        try formatter.fmt(self.name);
        if (formatter.getFlag(.show_ids)) try formatter.print("#{}", .{@intFromEnum(self.id)});
        try formatter.writeAll(" =");
        try formatter.beginBlock();
        for (self.instructions.items, 0..) |inst, i| {
            if (formatter.getFlag(.show_indices)) try formatter.print("{d: <4} ", .{i});
            try formatter.fmt(inst);
            if (i < self.instructions.items.len - 1) try formatter.endLine();
        }
        try formatter.endBlock();
    }

    pub fn length(self: *const Block) Offset {
        return @intCast(self.instructions.items.len);
    }

    pub fn localCount(self: *const Block) usize {
        return self.local_map.count();
    }

    pub fn getLocal(self: *const Block, id: LocalId) error{InvalidLocal}!*Local {
        if (self.local_map.get(id)) |x| {
            return x;
        } else if (self.parent) |p| {
            return p.getLocal(id);
        } else {
            return error.InvalidLocal;
        }
    }

    pub fn createLocal(self: *Block, name: NameId, typeIr: *Type) error{ TooManyLocals, OutOfMemory }!*Local {
        const id = try self.function.freshLocalId();

        const local = try Local.init(self, id, name, typeIr);
        errdefer local.deinit();

        try self.local_map.put(self.rir.allocator, id, local);

        return local;
    }

    pub fn referenceCount(self: *Block, offset: Offset, registerIndex: Rbc.RegisterIndex) usize {
        var count: usize = 0;

        var i = offset;
        while (i < self.instructions.items.len) {
            const instr = self.instructions.items[i];
            i += 1;

            switch (instr.code) {
                .ref_block => {
                    const blockId = instr.data.ref_block;
                    const blockIr = self.function.getBlock(blockId) catch continue;

                    count += blockIr.referenceCount(0, registerIndex);
                },
                .ref_local => {
                    const localId = instr.data.ref_local;
                    const localIr = self.getLocal(localId) catch continue;

                    if (localIr.register) |reg| {
                        if (reg.getIndex() == registerIndex) count += 1;
                    }
                },
                else => {},
            }
        }

        return count;
    }

    pub fn hasReference(self: *Block, offset: Offset, registerIndex: Rbc.RegisterIndex) bool {
        var i = offset;
        while (i < self.instructions.items.len) {
            const instr = self.instructions.items[i];
            i += 1;

            switch (instr.code) {
                .ref_block => {
                    const blockId = instr.data.ref_block;
                    const blockIr = self.function.getBlock(blockId) catch continue;

                    if (blockIr.hasReference(0, registerIndex)) return true;
                },
                .ref_local => {
                    const localId = instr.data.ref_local;
                    const localIr = self.getLocal(localId) catch continue;

                    if (localIr.register) |reg| {
                        if (reg.getIndex() == registerIndex) return true;
                    }
                },
                else => {},
            }
        }

        return false;
    }

    pub fn nop(self: *Block) !void {
        try op(self, .nop, {});
    }

    pub fn halt(self: *Block) !void {
        try exitOp(self, .halt, {});
    }

    pub fn trap(self: *Block) !void {
        try exitOp(self, .trap, {});
    }

    pub fn block(self: *Block, x: *Type) !void {
        try op(self, .block, x.id);
    }

    pub fn with(self: *Block, x: *Type) !void {
        try op(self, .with, x.id);
    }

    pub fn @"if"(self: *Block, x: *Type) !void {
        try op(self, .@"if", x.id);
    }

    pub fn when(self: *Block) !void {
        try op(self, .when, {});
    }

    pub fn re(self: *Block, x: Check) !void {
        if (x != .none) {
            try op(self, .re, x);
        } else {
            try exitOp(self, .re, x);
        }
    }

    pub fn br(self: *Block, x: Check) !void {
        if (x != .none) {
            try op(self, .br, x);
        } else {
            try exitOp(self, .br, x);
        }
    }

    pub fn call(self: *Block, x: Arity) !void {
        try op(self, .call, x);
    }

    pub fn ret(self: *Block) !void {
        try exitOp(self, .ret, {});
    }

    pub fn cancel(self: *Block) !void {
        try exitOp(self, .cancel, {});
    }

    pub fn addr(self: *Block) !void {
        try op(self, .addr, {});
    }

    pub fn read(self: *Block) !void {
        try op(self, .read, {});
    }

    pub fn write(self: *Block) !void {
        try op(self, .write, {});
    }

    pub fn load(self: *Block) !void {
        try op(self, .load, {});
    }

    pub fn store(self: *Block) !void {
        try op(self, .store, {});
    }

    pub fn add(self: *Block) !void {
        try op(self, .add, {});
    }

    pub fn sub(self: *Block) !void {
        try op(self, .sub, {});
    }

    pub fn mul(self: *Block) !void {
        try op(self, .mul, {});
    }

    pub fn div(self: *Block) !void {
        try op(self, .div, {});
    }

    pub fn rem(self: *Block) !void {
        try op(self, .rem, {});
    }

    pub fn neg(self: *Block) !void {
        try op(self, .neg, {});
    }

    pub fn band(self: *Block) !void {
        try op(self, .band, {});
    }

    pub fn bor(self: *Block) !void {
        try op(self, .bor, {});
    }

    pub fn bxor(self: *Block) !void {
        try op(self, .bxor, {});
    }

    pub fn bnot(self: *Block) !void {
        try op(self, .bnot, {});
    }

    pub fn bshiftl(self: *Block) !void {
        try op(self, .bshiftl, {});
    }

    pub fn bshiftr(self: *Block) !void {
        try op(self, .bshiftr, {});
    }

    pub fn eq(self: *Block) !void {
        try op(self, .eq, {});
    }

    pub fn ne(self: *Block) !void {
        try op(self, .ne, {});
    }

    pub fn lt(self: *Block) !void {
        try op(self, .lt, {});
    }

    pub fn gt(self: *Block) !void {
        try op(self, .gt, {});
    }

    pub fn le(self: *Block) !void {
        try op(self, .le, {});
    }

    pub fn ge(self: *Block) !void {
        try op(self, .ge, {});
    }

    pub fn cast(self: *Block, x: *Type) !void {
        try op(self, .cast, x.id);
    }

    pub fn clear(self: *Block, count: Index) !void {
        try op(self, .clear, count);
    }

    pub fn swap(self: *Block, index: Index) !void {
        try op(self, .swap, index);
    }

    pub fn copy(self: *Block, index: Index) !void {
        try op(self, .copy, index);
    }

    pub fn new_local(self: *Block, x: OpLocal) !void {
        try op(self, .new_local, x);
    }

    pub fn ref_local(self: *Block, x: *Local) !void {
        try op(self, .ref_local, x.id);
    }

    pub fn ref_block(self: *Block, x: *Block) !void {
        try op(self, .ref_block, x.id);
    }

    pub fn ref_function(self: *Block, x: *Function) !void {
        try op(self, .ref_function, .{ .module_id = self.function.module.id, .id = x.id });
    }

    pub fn ref_extern_function(self: *Block, m: *Module, x: *Function) !void {
        try op(self, .ref_function, .{ .module_id = m.id, .id = x.id });
    }

    pub fn ref_foreign(self: *Block, x: *Foreign) !void {
        try op(self, .ref_foreign, x.id);
    }

    pub fn ref_global(self: *Block, x: *Global) !void {
        try op(self, .ref_global, .{ .module_id = self.function.module.id, .id = x.id });
    }

    pub fn ref_extern_global(self: *Block, m: *Module, x: *Global) !void {
        try op(self, .ref_global, .{ .module_id = m.id, .id = x.id });
    }

    pub fn ref_upvalue(self: *Block, x: *Upvalue) !void {
        try op(self, .ref_upvalue, x.id);
    }

    pub fn im(self: *Block, x: anytype) !void {
        const size = @bitSizeOf(@TypeOf(x));
        return if (comptime size > 32) @call(.always_inline, im_w, .{ self, x }) else @call(.always_inline, im_i, .{ self, x });
    }

    pub fn im_i(self: *Block, x: anytype) !void {
        const ty = try self.rir.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_i, try OpImmediate.fromNative(ty, x));
    }

    pub fn im_w(self: *Block, x: anytype) !void {
        const ty = try self.rir.createTypeFromNative(@TypeOf(x), null, null);
        try op(self, .im_w, ty.id);
        try @call(.always_inline, std.ArrayListUnmanaged(Instruction).append, .{
            &self.instructions,
            self.rir.allocator,
            @as(Instruction, @bitCast(try Immediate.fromNative(x))),
        });
    }

    pub fn op(self: *Block, comptime code: OpCode, data: OpData.Of(code)) !void {
        try @call(.always_inline, std.ArrayListUnmanaged(Instruction).append, .{
            &self.instructions,
            self.rir.allocator,
            Instruction{
                .code = code,
                .data = @unionInit(OpData, @tagName(code), data),
            },
        });
    }

    pub fn exitOp(self: *Block, comptime code: OpCode, data: OpData.Of(code)) !void {
        if (self.has_exit) {
            return error.MultipleExits;
        }
        try op(self, code, data);
        self.has_exit = true;
    }
};

comptime {
    for (std.meta.fieldNames(OpCode)) |opName| {
        if (!@hasDecl(Block, opName)) {
            @compileError("missing Block method: `" ++ opName ++ "`");
        }
    }
}
