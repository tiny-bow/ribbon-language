const Rir = @import("../Rir.zig");

const value = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");

pub const ZeroCheck = enum(u1) { zero, non_zero };
pub const OptZeroCheck = enum(u2) { none, zero, non_zero };
pub const BitSize = enum(u2) { b8, b16, b32, b64 };

pub const Instruction = packed struct {
    code: OpCode,
    data: OpData,

    pub fn onFormat(self: Instruction, formatter: Rir.Formatter) !void {
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
    // Isa instructions matching Isa semantics:
    nop,
    halt,
    trap,

    call,
    prompt,
    ret,
    cancel,

    alloca,
    addr,
    read,
    write,
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

    ext,
    trunc,
    cast,

    // re-purposed Isa instructions:
    clear,
    swap,
    copy,

    // Rir-specific instructions:
    block,
    with,
    @"if",
    when,
    br,
    re,

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
        module_id: Rir.ModuleId,
        id: T.Id,
    };
}

pub const OpImmediate = packed struct {
    data: u32,
    type_id: Rir.TypeId,

    pub fn getType(self: OpImmediate, ir: *Rir) error{InvalidType}!*Rir.Type {
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

    pub fn fromNative(typeIr: *Rir.Type, val: anytype) error{ TypeMismatch, TooManyTypes, TooManyNames, OutOfMemory }!OpImmediate {
        try typeIr.checkNative(@TypeOf(val));

        return OpImmediate{
            .type_id = typeIr.id,
            .data = convert(val),
        };
    }

    pub fn onFormat(self: *const OpImmediate, formatter: Rir.Formatter) !void {
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

    call: void,
    prompt: void,
    ret: void,
    cancel: void,

    alloca: void,
    addr: void,
    read: void,
    write: void,
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

    ext: BitSize,
    trunc: BitSize,
    cast: void,

    clear: Rir.Index,
    swap: Rir.Index,
    copy: Rir.Index,

    block: void,
    with: void,
    @"if": ZeroCheck,
    when: ZeroCheck,
    br: OptZeroCheck,
    re: OptZeroCheck,

    new_local: Rir.NameId,

    ref_local: Rir.LocalId,
    ref_block: Rir.BlockId,
    ref_function: OpRef(Rir.Function),
    ref_foreign: Rir.ForeignId,
    ref_global: OpRef(Rir.Global),
    ref_upvalue: Rir.UpvalueId,

    im_i: OpImmediate,
    im_w: Rir.TypeId,

    pub fn formatWith(self: OpData, formatter: Rir.Formatter, code: OpCode) Rir.Formatter.Error!void {
        switch (code) {
            inline .nop,
            .halt,
            .trap,
            .block,
            .with,
            .call,
            .prompt,
            .ret,
            .cancel,
            .alloca,
            .addr,
            .read,
            .write,
            .load,
            .store,
            .add,
            .sub,
            .mul,
            .div,
            .rem,
            .neg,
            .band,
            .bor,
            .bxor,
            .bnot,
            .bshiftl,
            .bshiftr,
            .eq,
            .ne,
            .lt,
            .gt,
            .le,
            .ge,
            .new_local,
            => return,

            .@"if" => try formatter.fmt(self.@"if"),
            .when => try formatter.fmt(self.when),
            .re => try formatter.fmt(self.re),
            .br => try formatter.fmt(self.br),

            .ext => try formatter.fmt(self.ext),
            .trunc => try formatter.fmt(self.trunc),

            .cast => try formatter.fmt(self.cast),

            .clear => try formatter.fmt(self.clear),
            .swap => try formatter.fmt(self.swap),
            .copy => try formatter.fmt(self.copy),

            .ref_local => try formatter.fmt(self.ref_local),
            .ref_block => try formatter.fmt(self.ref_block),
            .ref_function => try formatter.fmt(self.ref_function),
            .ref_foreign => try formatter.fmt(self.ref_foreign),
            .ref_global => try formatter.fmt(self.ref_global),
            .ref_upvalue => try formatter.fmt(self.ref_upvalue),

            .im_i => try formatter.fmt(self.im_i),
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
    ir: *Rir,
    block: *Rir.Block,

    id: Rir.RegisterId,
    type: *Rir.Type,
    indices: [Rir.MAX_MULTI_REGISTER]Rbc.RegisterIndex,

    ref_count: usize = 1,

    pub fn getType(self: *const MultiRegister) *Rir.Type {
        return self.type;
    }

    pub fn init(block: *Rir.Block, id: Rir.RegisterId, typeIr: *Rir.Type, indices: [Rir.MAX_MULTI_REGISTER]Rbc.RegisterIndex) error{OutOfMemory}!*MultiRegister {
        const ir = block.ir;

        const self = try ir.allocator.create(MultiRegister);

        self.* = MultiRegister{
            .ir = ir,
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
    ir: *Rir,
    block: *Rir.Block,

    id: Rir.RegisterId,
    type: *Rir.Type,

    ref_count: usize = 1,

    pub fn getType(self: *const Register) *Rir.Type {
        return self.type;
    }

    pub fn getIndex(self: *const Register) Rbc.RegisterIndex {
        std.debug.assert(self.ref_count > 0);
        return @intFromEnum(self.id);
    }

    pub fn init(block: *Rir.Block, id: Rir.RegisterId, typeIr: *Rir.Type) error{OutOfMemory}!*Register {
        const ir = block.ir;

        const self = try ir.allocator.create(Register);

        self.* = Register{
            .ir = ir,
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
    type: *Rir.Type,

    pub fn zero(typeIr: *Rir.Type) Immediate {
        return Immediate{
            .type = typeIr,
            .data = 0,
        };
    }

    pub fn fromNative(rir: *Rir, val: anytype) error{ TooManyTypes, TooManyNames, OutOfMemory }!Immediate {
        return Immediate{
            .type = try rir.createTypeFromNative(@TypeOf(val), null, null),
            .data = convert(val),
        };
    }

    pub fn getType(self: *const Immediate) *Rir.Type {
        return self.type;
    }

    pub fn getMemory(self: anytype) utils.types.CopyConst([]u8, @TypeOf(self)) {
        return @as(utils.types.CopyConst([*]align(@alignOf(OpImmediate)) u8, @TypeOf(self)), @ptrCast(&self.data))[0..@sizeOf(u64)];
    }

    pub fn onFormat(self: *const Immediate, formatter: Rir.Formatter) !void {
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
    register: *Rir.Register,
    multi_register: *Rir.MultiRegister,

    local: *Rir.Local,
    upvalue: *Rir.Upvalue,
    global: *Rir.Global,

    pub fn getType(self: LValue) *Rir.Type {
        return switch (self) {
            inline else => |x| x.type,
        };
    }

    /// Extract a `Register` from an `LValue` or return `error.ExpectedRegister`
    pub fn forceRegister(self: LValue) error{ExpectedRegister}!*Rir.Register {
        return switch (self) {
            .register => |x| x,
            inline else => return error.ExpectedRegister,
        };
    }

    /// Extract a `MultiRegister` from an `LValue` or return `error.ExpectedMultiRegister`
    pub fn forceMultiRegister(self: LValue) error{ExpectedMultiRegister}!*Rir.MultiRegister {
        return switch (self) {
            .multi_register => |x| x,
            inline else => return error.ExpectedMultiRegister,
        };
    }

    /// Extract a `Local` from an `LValue` or return `error.ExpectedLocal`
    pub fn forceLocal(self: LValue) error{ExpectedLocal}!*Rir.Local {
        return switch (self) {
            .local => |x| x,
            inline else => return error.ExpectedLocal,
        };
    }

    /// Extract an `Upvalue` from an `LValue` or return `error.ExpectedUpvalue`
    pub fn forceUpvalue(self: LValue) error{ExpectedUpvalue}!*Rir.Upvalue {
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
    foreign: *Rir.Foreign,
    function: *Rir.Function,

    pub fn getType(self: RValue) *Rir.Type {
        return switch (self) {
            inline else => |x| x.type,
        };
    }

    pub fn getMemory(self: anytype) []const u8 {
        return switch (self) {
            .immediate => |x| x.getMemory(),
            .foreign => |x| @as([*]align(@alignOf(Rir.Foreign)) const u8, @ptrCast(x))[0..@sizeOf(Rir.Foreign)],
            .function => |x| @as([*]align(@alignOf(Rir.Function)) const u8, @ptrCast(x))[0..@sizeOf(Rir.Function)],
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
    pub fn forceForeign(self: RValue) error{ExpectedForeign}!*Rir.Foreign {
        return switch (self) {
            .foreign => |x| x,
            inline else => return error.ExpectedForeign,
        };
    }

    /// Extract a `Function` from an `RValue` or return `error.ExpectedFunction`
    pub fn forceFunction(self: RValue) error{ExpectedFunction}!*Rir.Function {
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
    type: *Rir.Type,
    block: *Rir.Block,
    handler_set: *Rir.HandlerSet,

    pub fn getType(self: Meta) error{ OutOfMemory, TooManyTypes }!*Rir.Type {
        return switch (self) {
            .type => |x| try x.ir.createType(null, .Type),
            .block => |x| try x.ir.createType(null, .Block),
            .handler_set => |x| try x.ir.createType(null, .HandlerSet),
        };
    }

    pub fn getMemory(self: anytype) utils.types.CopyConst([]u8, @TypeOf(self)) {
        return @as(utils.types.CopyConst([*]align(@alignOf(Meta)) u8, @TypeOf(self)), @ptrCast(&self))[0..@sizeOf(Meta)];
    }

    /// Extract a `Type` from a `Meta` value or return `error.ExpectedType`
    pub fn forceType(self: Meta) error{ExpectedType}!*Rir.Type {
        return switch (self) {
            .type => |x| x,
            inline else => return error.ExpectedType,
        };
    }

    /// Extract a `Block` from a `Meta` value or return `error.ExpectedBlock`
    pub fn forceBlock(self: Meta) error{ExpectedBlock}!*Rir.Block {
        return switch (self) {
            .block => |x| x,
            inline else => return error.ExpectedBlock,
        };
    }

    /// Extract a `HandlerSet` from a `Meta` value or return `error.ExpectedHandlerSet`
    pub fn forceHandlerSet(self: Meta) error{ExpectedHandlerSet}!*Rir.HandlerSet {
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

    pub fn getType(self: Operand) error{ OutOfMemory, TooManyTypes }!*Rir.Type {
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

            *Rir.Type => .{ .meta = .{ .type = val } },
            *Rir.Block => .{ .meta = .{ .block = val } },
            *Rir.HandlerSet => .{ .meta = .{ .handler_set = val } },

            *Rir.Register => .{ .l_value = .{ .register = val } },
            *Rir.MultiRegister => .{ .l_value = .{ .multi_register = val } },
            *Rir.Local => .{ .l_value = .{ .local = val } },
            *Rir.Upvalue => .{ .l_value = .{ .upvalue = val } },
            *Rir.Global => .{ .l_value = .{ .global = val } },

            Immediate => .{ .r_value = .{ .immediate = val } },
            *Rir.Foreign => .{ .r_value = .{ .foreign = val } },
            *Rir.Function => .{ .r_value = .{ .function = val } },

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
