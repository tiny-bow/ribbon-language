const RbcBuilder = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");

pub const log = std.log.scoped(.rbc_builder);

test {
    std.testing.refAllDecls(@This());
}

allocator: std.mem.Allocator,
globals: GlobalList,
functions: FunctionList,
handler_sets: HandlerSetList,
evidences: usize,
main_function: ?Rbc.FunctionIndex,

/// The allocator provided should be an arena,
/// or a similar allocator that doesn't care about freeing individual allocations
pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!RbcBuilder {
    var globals = GlobalList{};
    try globals.ensureTotalCapacity(allocator, 256);

    var functions = FunctionList{};
    try functions.ensureTotalCapacity(allocator, 256);

    var handler_sets = HandlerSetList{};
    try handler_sets.ensureTotalCapacity(allocator, 256);

    return RbcBuilder{
        .allocator = allocator,
        .globals = globals,
        .functions = functions,
        .handler_sets = handler_sets,
        .evidences = 0,
        .main_function = null,
    };
}

pub const Error = std.mem.Allocator.Error || error{
    TooManyGlobals,
    TooManyFunctions,
    TooManyBlocks,
    TooManyRegisters,
    TooManyHandlerSets,
    TooManyEvidences,
    TooManyUpvalues,
    TooManyInstructions,
    GlobalMemoryTooLarge,
    LayoutFailed,
    TooManyArguments,
    EvidenceOverlap,
    MissingEvidence,
    MissingHandler,
    NotEnoughArguments,
    InstructionsAfterExit,
    ArgumentAfterLocals,
    MultipleExits,
    MultipleMains,
    InvalidIndex,
    InvalidOffset,
    InvalidOperand,
    UnregisteredOperand,
    UnfinishedBlock,
};

pub const Global = struct {
    index: Rbc.GlobalIndex,
    alignment: Rbc.Alignment,
    initial: []u8,
};

const GlobalList = std.ArrayListUnmanaged(Global);
const FunctionList = std.ArrayListUnmanaged(*Function);
const HandlerSetList = std.ArrayListUnmanaged(*HandlerSet);

/// this does not have to be the same allocator as the one passed to `init`,
/// a long-term allocator is preferred. In the event of an error, the builder
/// will clean-up any allocations made by this function
pub fn assemble(self: *const RbcBuilder, allocator: std.mem.Allocator) Error!Rbc {
    const globals = try self.generateGlobalSet(allocator);
    errdefer {
        allocator.free(globals[0]);
        allocator.free(globals[1]);
    }

    const functions, const foreign_functions = try self.generateFunctionLists(allocator);
    errdefer {
        for (functions) |f| f.deinit(allocator);
        allocator.free(functions);
        allocator.free(foreign_functions);
    }

    const handler_sets = try self.generateHandlerSetList(allocator);
    errdefer {
        for (handler_sets) |h| allocator.free(h);
        allocator.free(handler_sets);
    }

    return .{
        .globals = globals[0],
        .global_memory = globals[1],
        .functions = functions,
        .foreign_functions = foreign_functions,
        .handler_sets = handler_sets,
        .main = self.main_function orelse Rbc.FUNCTION_SENTINEL,
    };
}

pub fn generateGlobalSet(self: *const RbcBuilder, allocator: std.mem.Allocator) Error!struct { []const [*]u8, []u8 } {
    const values = try allocator.alloc([*]u8, self.globals.items.len);
    errdefer allocator.free(values);

    var buf = std.ArrayListAlignedUnmanaged(u8, std.mem.page_size){};
    defer buf.deinit(allocator);

    for (self.globals.items) |global| {
        const padding = utils.alignmentDelta(buf.items.len, global.alignment);
        try buf.appendNTimes(allocator, 0, padding);
        try buf.appendSlice(allocator, global.initial);
    }

    const memory = try buf.toOwnedSlice(allocator);

    var offset: usize = 0;
    for (self.globals.items, 0..) |global, i| {
        const padding = utils.alignmentDelta(offset, global.alignment);
        offset += padding;
        values[i] = memory.ptr + offset;
        offset += global.initial.len;
    }

    return .{ values, memory };
}

pub fn generateFunctionLists(self: *const RbcBuilder, allocator: std.mem.Allocator) Error!struct { []Rbc.Function, []Rbc.Foreign } {
    var functions = std.ArrayListUnmanaged(Rbc.Function){};
    var foreign_functions = std.ArrayListUnmanaged(Rbc.Foreign){};

    errdefer {
        for (functions.items) |func| func.deinit(allocator);
        functions.deinit(allocator);
        foreign_functions.deinit(allocator);
    }

    for (self.functions.items) |func| {
        const final = try func.assemble(allocator);
        try functions.append(allocator, final);
    }

    return .{ try functions.toOwnedSlice(allocator), try foreign_functions.toOwnedSlice(allocator) };
}

pub fn generateHandlerSetList(self: *const RbcBuilder, allocator: std.mem.Allocator) Error![]Rbc.HandlerSet {
    const handlerSets = try allocator.alloc(Rbc.HandlerSet, self.handler_sets.items.len);

    var i: usize = 0;
    errdefer {
        for (0..i) |j| allocator.free(handlerSets[j]);
        allocator.free(handlerSets);
    }

    while (i < self.handler_sets.items.len) : (i += 1) {
        handlerSets[i] = try self.handler_sets.items[i].assemble(allocator);
    }

    return handlerSets;
}

pub fn getGlobal(self: *const RbcBuilder, index: Rbc.GlobalIndex) Error!*Global {
    if (index >= self.globals.items.len) {
        return Error.InvalidIndex;
    }

    return &self.globals.items[index];
}

pub fn globalBytes(self: *RbcBuilder, alignment: Rbc.Alignment, initial: []u8) Error!*Global {
    const index = self.globals.items.len;
    if (index >= std.math.maxInt(Rbc.GlobalIndex)) {
        return Error.TooManyGlobals;
    }

    try self.globals.append(self.allocator, .{
        .index = @truncate(index),
        .alignment = alignment,
        .initial = try self.allocator.dupe(u8, initial),
    });

    return &self.globals.items[index];
}

pub fn globalNative(self: *RbcBuilder, value: anytype) Error!*Global {
    const T = @TypeOf(value);
    const initial = try self.allocator.create(T);
    initial.* = value;
    return self.globalBytes(@alignOf(T), @as([*]u8, @ptrCast(initial))[0..@sizeOf(T)]);
}

pub fn getFunction(self: *const RbcBuilder, index: Rbc.FunctionIndex) Error!*Function {
    if (index >= self.functions.items.len) {
        return Error.InvalidIndex;
    }

    return self.functions.items[index];
}

pub fn createFunction(self: *RbcBuilder) Error!*Function {
    const index = self.functions.items.len;
    if (index >= std.math.maxInt(Rbc.FunctionIndex)) {
        return Error.TooManyFunctions;
    }

    const func = try Function.init(self, @truncate(index));

    try self.functions.append(self.allocator, func);

    return func;
}

pub fn hasMain(self: *const RbcBuilder) bool {
    return self.main_function != null;
}

pub fn main(self: *RbcBuilder) Error!*Function {
    if (self.hasMain()) return Error.MultipleMains;

    const func = try self.createFunction();

    self.main_function = func.index;

    return func;
}

// pub fn foreign(self: *RbcBuilder, num_arguments: Rbc.RegisterIndex, num_registers: Rbc.RegisterIndex) Error! *Function.Foreign {
//     const index = self.functions.items.len;
//     if (index >= std.math.maxInt(Rbc.FunctionIndex)) {
//         return Error.TooManyFunctions;
//     }

//     const func = try self.allocator.create(Function);
//     func.* = .{.foreign = .{ .parent = self, .num_arguments = num_arguments, .num_registers = num_registers, .evidence = null, .index = @truncate(index) }};

//     try self.functions.append(self.allocator, func);

//     return &func.foreign;
// }

pub fn evidence(self: *RbcBuilder) Error!Rbc.EvidenceIndex {
    const index = self.evidences;
    if (index >= Rbc.EVIDENCE_SENTINEL) {
        return Error.TooManyEvidences;
    }

    return @truncate(index);
}

pub fn getHandlerSet(self: *const RbcBuilder, index: Rbc.HandlerSetIndex) Error!*HandlerSet {
    if (index >= self.handler_sets.items.len) {
        return Error.InvalidIndex;
    }

    return self.handler_sets.items[index];
}

pub fn createHandlerSet(self: *RbcBuilder) Error!*HandlerSet {
    const index = self.handler_sets.items.len;
    if (index >= std.math.maxInt(Rbc.HandlerSetIndex)) {
        return Error.TooManyHandlerSets;
    }

    const handlerSet = try HandlerSet.init(self, @truncate(index));

    try self.handler_sets.append(self.allocator, handlerSet);

    return handlerSet;
}

pub fn extractFunctionIndex(self: *const RbcBuilder, f: anytype) Error!Rbc.FunctionIndex {
    switch (@TypeOf(f)) {
        *Rbc.FunctionIndex => return extractFunctionIndex(self, f.*),
        Rbc.FunctionIndex => {
            if (f >= self.functions.items.len) {
                return Error.InvalidIndex;
            }
            return f;
        },

        Function => return extractFunctionIndex(self, &f),
        *Function => return extractFunctionIndex(self, @as(*const Function, f)),
        *const Function => {
            if (f.parent != self) {
                return Error.InvalidIndex;
            }
            return f.index;
        },

        else => @compileError(std.fmt.comptimePrint("invalid block index parameter, expected either `Rbc.FunctionIndex` or `*RbcRbcBuilder.Function`, got `{s}`", .{@typeName(@TypeOf(f))})),
    }
}

pub fn extractHandlerSetIndex(self: *const RbcBuilder, h: anytype) Error!Rbc.HandlerSetIndex {
    switch (@TypeOf(h)) {
        *Rbc.HandlerSetIndex => return extractHandlerSetIndex(self, h.*),
        Rbc.HandlerSetIndex => {
            if (h >= self.handler_sets.items.len) {
                return Error.InvalidIndex;
            }
            return h;
        },

        HandlerSet => return extractHandlerSetIndex(self, &h),
        *HandlerSet => return extractHandlerSetIndex(self, @as(*const HandlerSet, h)),
        *const HandlerSet => {
            if (h.parent != self) {
                return Error.InvalidIndex;
            }
            return h.index;
        },

        else => @compileError(std.fmt.comptimePrint("invalid handler set index parameter, expected either `Rbc.HandlerSetIndex` or `*RbcRbcBuilder.HandlerSetBuilder`, got `{s}`", .{@typeName(@TypeOf(h))})),
    }
}

const BlockList = std.ArrayListUnmanaged(*RbcBuilder.Block);

pub const Function = struct {
    parent: *RbcBuilder,
    index: Rbc.FunctionIndex,
    blocks: BlockList,
    entry: *RbcBuilder.Block = undefined,
    evidence: ?Rbc.EvidenceIndex = null,
    num_arguments: usize = 0,
    num_locals: usize = 0,
    num_upvalues: usize = 0,

    pub fn init(parent: *RbcBuilder, index: Rbc.FunctionIndex) RbcBuilder.Error!*Function {
        const ptr = try parent.allocator.create(Function);

        var blocks = BlockList{};
        try blocks.ensureTotalCapacity(parent.allocator, Rbc.MAX_BLOCKS);

        ptr.* = Function{
            .parent = parent,
            .index = index,
            .blocks = blocks,
        };

        ptr.entry = try RbcBuilder.Block.init(ptr, null, 0, .basic);

        ptr.blocks.appendAssumeCapacity(ptr.entry);

        return ptr;
    }

    pub fn assemble(self: *const Function, allocator: std.mem.Allocator) RbcBuilder.Error!Rbc.Function {
        var num_instrs: usize = 0;

        for (self.blocks.items) |builder| {
            num_instrs += try builder.preassemble();
        }

        const blocks = try allocator.alloc([*]const Rbc.Instruction, self.blocks.items.len);
        errdefer allocator.free(blocks);

        const instructions = try allocator.alloc(Rbc.Instruction, num_instrs);
        errdefer allocator.free(instructions);

        var instr_offset: usize = 0;
        for (self.blocks.items, 0..) |builder, i| {
            const nextBlock = builder.assemble(instructions, &instr_offset);
            blocks[i] = nextBlock;
        }

        return Rbc.Function{
            .num_arguments = @truncate(self.num_arguments),
            .num_registers = @truncate(self.num_arguments + self.num_locals),
            .bytecode = .{
                .blocks = blocks,
                .instructions = instructions,
            },
        };
    }

    pub fn getBlock(self: *const Function, index: Rbc.BlockIndex) RbcBuilder.Error!*RbcBuilder.Block {
        if (index >= self.blocks.items.len) {
            return RbcBuilder.Error.InvalidIndex;
        }

        return self.blocks.items[index];
    }

    pub fn newBlock(self: *Function, parent: ?Rbc.BlockIndex, kind: RbcBuilder.BlockKind) RbcBuilder.Error!*RbcBuilder.Block {
        const index = self.blocks.items.len;
        if (index >= Rbc.MAX_BLOCKS) return RbcBuilder.Error.TooManyBlocks;

        const freshBlock = try RbcBuilder.Block.init(self, parent, @truncate(index), kind);
        self.blocks.appendAssumeCapacity(freshBlock);

        return freshBlock;
    }

    pub fn arg(self: *Function) RbcBuilder.Error!Rbc.RegisterIndex {
        if (self.num_locals > 0) return RbcBuilder.Error.ArgumentAfterLocals;

        const index = self.num_arguments;
        if (index >= Rbc.MAX_REGISTERS) return RbcBuilder.Error.TooManyRegisters;

        self.num_arguments += 1;

        return @truncate(index);
    }

    pub fn local(self: *Function) RbcBuilder.Error!Rbc.RegisterIndex {
        const index = self.num_arguments + self.num_locals;
        if (index >= Rbc.MAX_REGISTERS) return RbcBuilder.Error.TooManyRegisters;

        self.num_locals += 1;

        return @truncate(index);
    }

    pub fn upvalue(self: *Function) RbcBuilder.Error!Rbc.UpvalueIndex {
        const index = self.num_upvalues;
        if (index >= Rbc.MAX_REGISTERS) return RbcBuilder.Error.TooManyUpvalues;

        self.num_upvalues += 1;

        return @truncate(index);
    }
};

pub const HandlerMap = std.ArrayHashMapUnmanaged(Rbc.EvidenceIndex, Rbc.FunctionIndex, utils.SimpleHashContext, false);

pub const HandlerSet = struct {
    parent: *RbcBuilder,
    index: Rbc.HandlerSetIndex,
    handler_map: HandlerMap,

    pub fn init(parent: *RbcBuilder, index: Rbc.HandlerSetIndex) std.mem.Allocator.Error!*HandlerSet {
        const ptr = try parent.allocator.create(HandlerSet);

        var handler_map = HandlerMap{};
        try handler_map.ensureTotalCapacity(parent.allocator, 8);

        ptr.* = HandlerSet{
            .parent = parent,
            .index = index,
            .handler_map = handler_map,
        };

        return ptr;
    }

    pub fn assemble(self: *const HandlerSet, allocator: std.mem.Allocator) RbcBuilder.Error!Rbc.HandlerSet {
        const handlerSet = try allocator.alloc(Rbc.HandlerBinding, self.handler_map.count());
        errdefer allocator.free(handlerSet);

        for (self.handler_map.keys(), 0..) |e, i| {
            const funIndex = try self.getHandler(e);
            handlerSet[i] = Rbc.HandlerBinding{ .id = e, .handler = funIndex };
        }

        return handlerSet;
    }

    pub fn getEvidence(self: *const HandlerSet) []const Rbc.EvidenceIndex {
        return self.handler_map.keys();
    }

    pub fn containsEvidence(self: *const HandlerSet, e: Rbc.EvidenceIndex) bool {
        return self.handler_map.contains(e);
    }

    pub fn getHandler(self: *const HandlerSet, e: Rbc.EvidenceIndex) RbcBuilder.Error!Rbc.FunctionIndex {
        return self.handler_map.get(e) orelse RbcBuilder.Error.MissingHandler;
    }

    pub fn handler(self: *HandlerSet, e: Rbc.EvidenceIndex) RbcBuilder.Error!*RbcBuilder.Function {
        if (self.handler_map.contains(e)) {
            return RbcBuilder.Error.EvidenceOverlap;
        }

        const fun = try self.parent.createFunction();

        fun.evidence = e;

        try self.handler_map.put(self.parent.allocator, e, fun.index);

        return fun;
    }

    pub fn foreignHandler(self: *HandlerSet, e: Rbc.EvidenceIndex, num_arguments: Rbc.RegisterIndex, num_registers: Rbc.RegisterIndex) RbcBuilder.Error!*RbcBuilder.Function.Foreign {
        if (self.handler_map.contains(e)) {
            return RbcBuilder.Error.EvidenceOverlap;
        }

        const fun = try self.parent.foreign(num_arguments, num_registers);

        fun.evidence = e;

        try self.handler_map.put(self.parent.allocator, e, fun.index);

        return fun;
    }

    pub fn foreignNativeHandler(self: *HandlerSet, e: Rbc.EvidenceIndex, comptime T: type) RbcBuilder.Error!*RbcBuilder.Foreign {
        if (self.handler_map.contains(e)) {
            return RbcBuilder.Error.EvidenceOverlap;
        }

        const ev = try self.parent.getEvidence(e);

        const fun = try self.parent.foreignNative(ev.type, T);

        fun.evidence = e;

        try self.handler_map.put(self.parent.allocator, e, fun.index);

        return fun;
    }
};

const InstrList = std.ArrayListUnmanaged(Rbc.Instruction);

pub const BlockKind = union(enum) {
    basic: void,
    with: Rbc.HandlerSetIndex,

    pub fn getHandlerSet(self: Block.Kind) ?Rbc.HandlerSetIndex {
        return switch (self) {
            .basic => null,
            .with => |w| w,
        };
    }
};

pub const Block = struct {
    function: *RbcBuilder.Function,
    parent: ?Rbc.BlockIndex,
    index: Rbc.BlockIndex,
    kind: BlockKind,
    ops: InstrList,
    exited: bool,

    pub fn init(func: *RbcBuilder.Function, parent: ?Rbc.BlockIndex, index: Rbc.BlockIndex, kind: BlockKind) std.mem.Allocator.Error!*Block {
        const ptr = try func.parent.allocator.create(Block);

        var ops = InstrList{};
        try ops.ensureTotalCapacity(func.parent.allocator, 256);

        ptr.* = Block{
            .function = func,
            .parent = parent,
            .index = index,
            .kind = kind,
            .ops = ops,
            .exited = false,
        };

        return ptr;
    }

    pub fn preassemble(self: *const Block) RbcBuilder.Error!usize {
        if (!self.exited) {
            return RbcBuilder.Error.UnfinishedBlock;
        }

        return self.ops.items.len;
    }

    pub fn assemble(self: *const Block, buf: []Rbc.Instruction, offset: *usize) [*]const Rbc.Instruction {
        const start = offset.*;

        for (self.ops.items) |x| {
            buf[offset.*] = x;
            offset.* += 1;
        }

        return buf.ptr + start;
    }

    pub fn findRelativeBlockIndex(self: *const Block, absoluteBlockIndex: Rbc.BlockIndex) RbcBuilder.Error!Rbc.BlockIndex {
        if (self.index == absoluteBlockIndex) {
            return 0;
        }

        if (self.parent) |p| {
            if (p == absoluteBlockIndex) {
                return 1;
            }

            const parent = try self.function.getBlock(p);
            return 1 + try findRelativeBlockIndex(parent, absoluteBlockIndex);
        }

        return RbcBuilder.Error.InvalidIndex;
    }

    pub fn extractBlockIndex(self: *const Block, b: anytype) RbcBuilder.Error!Rbc.BlockIndex {
        switch (@TypeOf(b)) {
            Block => return self.extractBlockIndex(&b),
            *Block => return self.extractBlockIndex(@as(*const Block, b)),
            *const Block => {
                if (b.function != self.function) {
                    return RbcBuilder.Error.InvalidIndex;
                }
                return self.extractBlockIndex(b.index);
            },

            *Rbc.BlockIndex => return self.extractBlockIndex(b.*),
            Rbc.BlockIndex => return b,

            else => @compileError(std.fmt.comptimePrint("invalid block index parameter, expected either `Rbc.BlockIndex` or `*RbcBuilder.BlockBuilder`, got `{s}`", .{@typeName(@TypeOf(b))})),
        }
    }

    pub fn args(self: *Block, rArgs: anytype) RbcBuilder.Error!void {
        if (rArgs.len == 0) {
            return;
        } else if (rArgs.len > Rbc.MAX_REGISTERS) {
            return RbcBuilder.Error.TooManyRegisters;
        }

        var acc = [1]Rbc.RegisterIndex{255} ** (@sizeOf(Rbc.Instruction) / @sizeOf(Rbc.RegisterIndex));

        comptime var i: usize = 0;
        inline while (i < rArgs.len) : (i += 1) {
            acc[i % acc.len] = rArgs[i];
            if (i != 0 and i % acc.len == 0) {
                try self.ops.append(self.function.parent.allocator, @as(Rbc.Instruction, @bitCast(acc)));
            }
        }

        if (i % acc.len != 0) {
            for ((i % acc.len)..acc.len) |j| acc[j] = 255;
            try self.ops.append(self.function.parent.allocator, @as(Rbc.Instruction, @bitCast(acc)));
        }
    }

    pub fn wideImmediate(self: *Block, w: anytype) RbcBuilder.Error!void {
        try self.ops.append(self.function.parent.allocator, @bitCast(wCast(w)));
    }

    pub fn op(self: *Block, code: Rbc.Code, data: *const anyopaque) RbcBuilder.Error!void {
        if (self.exited) return RbcBuilder.Error.InstructionsAfterExit;

        try self.ops.append(self.function.parent.allocator, Rbc.Instruction{
            .code = code,
            .data = inline for (comptime std.meta.fieldNames(Rbc.Code)) |name| {
                if (@field(Rbc.Code, name) == code) {
                    const T = @TypeOf(@field(@as(Rbc.Data, undefined), name));
                    break @unionInit(Rbc.Data, name, if (T == void) {} else @as(*align(1) const T, @ptrCast(@alignCast(data))).*);
                }
            } else unreachable,
        });
    }

    pub fn exitOp(self: *Block, comptime code: Rbc.Code, data: *const anyopaque) RbcBuilder.Error!void {
        if (self.exited) return RbcBuilder.Error.MultipleExits;

        try self.ops.append(self.function.parent.allocator, Rbc.Instruction{
            .code = code,
            .data = inline for (comptime std.meta.fieldNames(Rbc.Code)) |name| {
                if (@field(Rbc.Code, name) == code) {
                    const T = @TypeOf(@field(@as(Rbc.Data, undefined), name));
                    break @unionInit(Rbc.Data, name, if (T == void) {} else @as(*const T, @ptrCast(@alignCast(data))).*);
                }
            } else unreachable,
        });

        self.exited = true;
    }

    pub fn bCast(b: anytype) u8 {
        return switch (@typeInfo(@TypeOf(b))) {
            .comptime_int => @as(u8, b),
            .int => |info| if (info.bits <= 8) switch (info.signedness) {
                .unsigned => @as(u8, b),
                .signed => @as(u8, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            } else @bitCast(@as(std.meta.Int(info.signedness, 8), @intCast(b))),
            .@"enum" => bCast(@intFromEnum(b)),
            else => @as(u8, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
        };
    }

    pub fn sCast(b: anytype) u16 {
        return switch (@typeInfo(@TypeOf(b))) {
            .comptime_int => @as(u16, b),
            .int => |info| if (info.bits <= 16) switch (info.signedness) {
                .unsigned => @as(u16, b),
                .signed => @as(u16, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            } else @bitCast(@as(std.meta.Int(info.signedness, 16), @intCast(b))),
            .@"enum" => bCast(@intFromEnum(b)),
            else => @as(u16, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
        };
    }

    pub fn iCast(b: anytype) u32 {
        return switch (@typeInfo(@TypeOf(b))) {
            .comptime_int => @as(u32, b),
            .int => |info| if (info.bits <= 32) switch (info.signedness) {
                .unsigned => @as(u32, b),
                .signed => @as(u32, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            } else @bitCast(@as(std.meta.Int(info.signedness, 32), @intCast(b))),
            .@"enum" => bCast(@intFromEnum(b)),
            else => @as(u32, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
        };
    }

    pub fn wCast(b: anytype) u64 {
        return switch (@typeInfo(@TypeOf(b))) {
            .comptime_int => @as(u64, b),
            .int => |info| if (info.bits <= 64) switch (info.signedness) {
                .unsigned => @as(u64, b),
                .signed => @as(u64, @as(std.meta.Int(.unsigned, info.bits), @bitCast(b))),
            } else @bitCast(@as(std.meta.Int(info.signedness, 64), @intCast(b))),
            .@"enum" => bCast(@intFromEnum(b)),
            else => @as(u64, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(b))), @bitCast(b))),
        };
    }

    pub fn nop(self: *Block) RbcBuilder.Error!void {
        try self.op(.nop, &{});
    }

    pub fn halt(self: *Block) RbcBuilder.Error!void {
        try self.exitOp(.halt, &{});
    }

    pub fn trap(self: *Block) RbcBuilder.Error!void {
        try self.exitOp(.trap, &{});
    }

    pub fn block(self: *Block) RbcBuilder.Error!*Block {
        const newBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.block, &.{ .B0 = newBlock.index });

        return newBlock;
    }

    pub fn block_v(self: *Block, y: Rbc.RegisterIndex) RbcBuilder.Error!*Block {
        const newBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.block_v, &.{ .B0 = newBlock.index, .R0 = y });

        return newBlock;
    }

    pub fn with(self: *Block, h: anytype) RbcBuilder.Error!*Block {
        const handlerSetIndex = try self.function.parent.extractHandlerSetIndex(h);
        const newBlock = try self.function.newBlock(self.index, .{ .with = handlerSetIndex });

        try self.op(.with, &.{ .B0 = newBlock.index, .H0 = handlerSetIndex });

        return newBlock;
    }

    pub fn with_v(self: *Block, h: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!*Block {
        const handlerSetIndex = try self.function.parent.extractHandlerSetIndex(h);
        const newBlock = try self.function.newBlock(self.index, .{ .with_v = handlerSetIndex });

        try self.op(.with_v, &.{ .B0 = newBlock.index, .H0 = handlerSetIndex, .R0 = y });

        return newBlock;
    }

    pub fn if_nz(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!struct { *Block, *Block } {
        const thenBlock = try self.function.newBlock(self.index, .basic);
        const elseBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.if_nz, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x });

        return .{ thenBlock, elseBlock };
    }

    pub fn if_nz_v(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!struct { *Block, *Block } {
        const thenBlock = try self.function.newBlock(self.index, .basic);
        const elseBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.if_nz_v, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x, .R1 = y });

        return .{ thenBlock, elseBlock };
    }

    pub fn if_z(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!struct { *Block, *Block } {
        const thenBlock = try self.function.newBlock(self.index, .basic);
        const elseBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.if_z, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x });

        return .{ thenBlock, elseBlock };
    }

    pub fn if_z_v(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!struct { *Block, *Block } {
        const thenBlock = try self.function.newBlock(self.index, .basic);
        const elseBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.if_z_v, &.{ .B0 = thenBlock.index, .B1 = elseBlock.index, .R0 = x, .R1 = y });

        return .{ thenBlock, elseBlock };
    }

    pub fn when_nz(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!*Block {
        const newBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.when_nz, &.{ .B0 = newBlock.index, .R0 = x });

        return newBlock;
    }

    pub fn when_z(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!*Block {
        const newBlock = try self.function.newBlock(self.index, .basic);

        try self.op(.when_z, &.{ .B0 = newBlock.index, .R0 = x });

        return newBlock;
    }

    pub fn re(self: *Block, b: anytype) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.re, &.{ .B0 = relativeBlockIndex });
    }

    pub fn re_nz(self: *Block, b: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.re_nz, &.{ .B0 = relativeBlockIndex, .R0 = x });
    }

    pub fn re_z(self: *Block, b: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.re_z, &.{ .B0 = relativeBlockIndex, .R0 = x });
    }

    pub fn br(self: *Block, b: anytype) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br, &.{ .B0 = relativeBlockIndex });
    }

    pub fn br_nz(self: *Block, b: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_nz, &.{ .B0 = relativeBlockIndex, .R0 = x });
    }

    pub fn br_z(self: *Block, b: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_z, &.{ .B0 = relativeBlockIndex, .R0 = x });
    }

    pub fn br_v(self: *Block, b: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_v, &.{ .B0 = relativeBlockIndex, .R0 = y });
    }

    pub fn br_nz_v(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_nz_v, &.{ .B0 = relativeBlockIndex, .R0 = x, .R1 = y });
    }

    pub fn br_z_v(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_z_v, &.{ .B0 = relativeBlockIndex, .R0 = x, .R1 = y });
    }

    pub fn br_im_v(self: *Block, b: anytype, i: anytype) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_im_v, &.{ .B0 = relativeBlockIndex, .i0 = iCast(i) });
    }

    pub fn br_im_w_v(self: *Block, b: anytype, w: anytype) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_im_w_v, &.{ .B0 = relativeBlockIndex });
        try self.wideImmediate(w);
    }

    pub fn br_nz_im_v(self: *Block, b: anytype, x: Rbc.RegisterIndex, w: anytype) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_nz_im_v, &.{ .B0 = relativeBlockIndex, .R0 = x });
        try self.wideImmediate(w);
    }

    pub fn br_z_im_v(self: *Block, b: anytype, x: Rbc.RegisterIndex, w: anytype) RbcBuilder.Error!void {
        const absoluteBlockIndex = try self.extractBlockIndex(b);
        const relativeBlockIndex = try self.findRelativeBlockIndex(absoluteBlockIndex);

        try self.exitOp(.br_z_im_v, &.{ .B0 = relativeBlockIndex, .R0 = x });
        try self.wideImmediate(w);
    }

    pub fn call(self: *Block, f: Rbc.RegisterIndex, as: anytype) RbcBuilder.Error!void {
        try self.op(.call, &.{ .F0 = f });
        try self.args(as);
    }

    pub fn call_v(self: *Block, f: Rbc.RegisterIndex, y: Rbc.RegisterIndex, as: anytype) RbcBuilder.Error!void {
        try self.op(.call_v, &.{ .F0 = f, .R0 = y });
        try self.args(as);
    }

    pub fn call_im(self: *Block, f: anytype, as: anytype) RbcBuilder.Error!void {
        try self.op(.call_im, &.{ .F0 = try self.function.parent.extractFunctionIndex(f) });
        try self.args(as);
    }

    pub fn call_im_v(self: *Block, f: anytype, y: Rbc.RegisterIndex, as: anytype) RbcBuilder.Error!void {
        try self.op(.call_im_v, &.{ .F0 = try self.function.parent.extractFunctionIndex(f), .R0 = y });
        try self.args(as);
    }

    pub fn tail_call(self: *Block, f: Rbc.RegisterIndex, as: anytype) RbcBuilder.Error!void {
        try self.exitOp(.tail_call, &.{ .R0 = f });
        try self.args(as);
    }

    pub fn tail_call_im(self: *Block, f: anytype, as: anytype) RbcBuilder.Error!void {
        try self.exitOp(.tail_call_im, &.{ .F0 = try self.function.parent.extractFunctionIndex(f) });
        try self.args(as);
    }

    pub fn prompt(self: *Block, e: Rbc.EvidenceIndex, as: anytype) RbcBuilder.Error!void {
        try self.op(.prompt, &.{ .E0 = e });
        try self.args(as);
    }

    pub fn prompt_v(self: *Block, e: Rbc.EvidenceIndex, y: Rbc.RegisterIndex, as: anytype) RbcBuilder.Error!void {
        try self.op(.prompt_v, &.{ .E0 = e, .R0 = y });
        try self.args(as);
    }

    pub fn ret(self: *Block) RbcBuilder.Error!void {
        try self.exitOp(.ret, &{});
    }

    pub fn ret_v(self: *Block, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.exitOp(.ret_v, &.{ .R0 = y });
    }

    pub fn ret_im_v(self: *Block, i: anytype) RbcBuilder.Error!void {
        try self.exitOp(.ret_im_v, &.{ .i0 = iCast(i) });
    }

    pub fn ret_im_w_v(self: *Block, w: anytype) RbcBuilder.Error!void {
        try self.exitOp(.ret_im_w_v, {});
        try self.wideImmediate(w);
    }

    pub fn term(self: *Block) RbcBuilder.Error!void {
        try self.exitOp(.term, &{});
    }

    pub fn term_v(self: *Block, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.exitOp(.term_v, &.{ .R0 = y });
    }

    pub fn term_im_v(self: *Block, i: anytype) RbcBuilder.Error!void {
        try self.exitOp(.term_im_v, &.{ .i0 = iCast(i) });
    }

    pub fn term_im_w_v(self: *Block, w: anytype) RbcBuilder.Error!void {
        try self.exitOp(.term_im_w_v, {});
        try self.wideImmediate(w);
    }

    pub fn alloca(self: *Block, s: u16, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.alloca, &.{ .s0 = s, .R0 = x });
    }

    pub fn addr_global(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.addr_global, &.{ .G0 = g, .R0 = x });
    }

    pub fn addr_upvalue(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.addr_upvalue, &.{ .U0 = u, .R0 = x });
    }

    pub fn addr_local(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.addr_local, &.{ .R0 = x, .R1 = y });
    }

    pub fn read_global_8(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_global_8, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_global_16(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_global_16, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_global_32(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_global_32, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_global_64(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_global_64, &.{ .G0 = g, .R0 = x });
    }

    pub fn read_upvalue_8(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_upvalue_8, &.{ .U0 = u, .R0 = x });
    }

    pub fn read_upvalue_16(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_upvalue_16, &.{ .U0 = u, .R0 = x });
    }

    pub fn read_upvalue_32(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_upvalue_32, &.{ .U0 = u, .R0 = x });
    }

    pub fn read_upvalue_64(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.read_upvalue_64, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_global_8(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_global_8, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_16(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_global_16, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_32(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_global_32, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_64(self: *Block, g: Rbc.GlobalIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_global_64, &.{ .G0 = g, .R0 = x });
    }

    pub fn write_global_8_im(self: *Block, b: anytype, g: Rbc.GlobalIndex) RbcBuilder.Error!void {
        try self.op(.write_global_8_im, &.{ .b0 = bCast(b), .G0 = g });
    }

    pub fn write_global_16_im(self: *Block, s: anytype, g: Rbc.GlobalIndex) RbcBuilder.Error!void {
        try self.op(.write_global_16_im, &.{ .s0 = sCast(s), .G0 = g });
    }

    pub fn write_global_32_im(self: *Block, i: anytype, g: Rbc.GlobalIndex) RbcBuilder.Error!void {
        try self.op(.write_global_32_im, &.{ .i0 = iCast(i), .G0 = g });
    }

    pub fn write_global_64_im(self: *Block, w: anytype, g: Rbc.GlobalIndex) RbcBuilder.Error!void {
        try self.op(.write_global_64_im, &.{ .G0 = g });
        try self.wideImmediate(w);
    }

    pub fn write_upvalue_8(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_8, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_16(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_16, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_32(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_32, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_64(self: *Block, u: Rbc.UpvalueIndex, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_64, &.{ .U0 = u, .R0 = x });
    }

    pub fn write_upvalue_8_im(self: *Block, b: anytype, u: Rbc.UpvalueIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_8_im, &.{ .b0 = bCast(b), .U0 = u });
    }

    pub fn write_upvalue_16_im(self: *Block, s: anytype, u: Rbc.UpvalueIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_16_im, &.{ .s0 = sCast(s), .U0 = u });
    }

    pub fn write_upvalue_32_im(self: *Block, i: anytype, u: Rbc.UpvalueIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_32_im, &.{ .i0 = iCast(i), .U0 = u });
    }

    pub fn write_upvalue_64_im(self: *Block, w: anytype, u: Rbc.UpvalueIndex) RbcBuilder.Error!void {
        try self.op(.write_upvalue_64_im, &.{ .U0 = u });
        try self.wideImmediate(w);
    }

    pub fn load_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.load_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn load_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.load_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn load_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.load_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn load_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.load_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn store_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_8_im, &.{ .b0 = bCast(b), .R0 = x });
    }

    pub fn store_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_16_im, &.{ .s0 = sCast(s), .R0 = x });
    }

    pub fn store_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_32_im, &.{ .i0 = iCast(i), .R0 = x });
    }

    pub fn store_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.store_64_im, &.{ .R0 = x });
        try self.wideImmediate(w);
    }

    pub fn clear_8(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.clear_8, &.{ .R0 = x });
    }

    pub fn clear_16(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.clear_16, &.{ .R0 = x });
    }

    pub fn clear_32(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.clear_32, &.{ .R0 = x });
    }

    pub fn clear_64(self: *Block, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.clear_64, &.{ .R0 = x });
    }

    pub fn swap_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.swap_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn swap_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.swap_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn swap_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.swap_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn swap_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.swap_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn copy_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_8_im, &.{ .b0 = bCast(b), .R0 = x });
    }

    pub fn copy_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_16_im, &.{ .s0 = sCast(s), .R0 = x });
    }

    pub fn copy_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_32_im, &.{ .i0 = iCast(i), .R0 = x });
    }

    pub fn copy_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.copy_64_im, &.{ .R0 = x });
        try self.wideImmediate(w);
    }

    pub fn i_add_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_add_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_add_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_add_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_add_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_add_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_add_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_add_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_add_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_add_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_add_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_add_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_add_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_add_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_sub_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_sub_8_im_a(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_sub_16_im_a(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_sub_32_im_a(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_sub_64_im_a(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_sub_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn i_sub_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn i_sub_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn i_sub_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_sub_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_sub_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_sub_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_sub_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_sub_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_sub_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_sub_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_sub_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_sub_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_sub_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_sub_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_sub_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_sub_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_mul_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_mul_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_mul_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_mul_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_mul_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_mul_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_mul_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_mul_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_mul_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_mul_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_mul_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_mul_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_mul_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_mul_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_div_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_div_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_div_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_div_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_div_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_div_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_div_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_div_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_div_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_div_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_div_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_div_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_div_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_div_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_div_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_div_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_div_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_div_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_div_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_div_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_div_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_div_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_div_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_div_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_div_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_div_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_div_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_div_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_div_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_div_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_div_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_div_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_rem_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_rem_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_rem_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_rem_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_rem_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_rem_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_rem_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_rem_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_rem_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_rem_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_rem_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_rem_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_rem_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_rem_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_rem_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_rem_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_rem_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_rem_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_rem_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_rem_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_rem_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_rem_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_rem_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_rem_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_rem_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_rem_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_rem_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_rem_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_rem_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_rem_32_im_b, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_rem_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_rem_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_neg_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_neg_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_neg_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_neg_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_neg_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_neg_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_neg_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_neg_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_neg_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_neg_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_neg_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_neg_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn band_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn band_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn band_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn band_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn band_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.band_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bor_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bor_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn bor_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn bor_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn bor_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bor_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bxor_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bxor_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn bxor_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn bxor_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn bxor_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bxor_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bnot_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bnot_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn bnot_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bnot_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn bnot_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bnot_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn bnot_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bnot_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn bshiftl_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn bshiftl_8_im_a(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn bshiftl_16_im_a(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn bshiftl_32_im_a(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn bshiftl_64_im_a(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn bshiftl_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn bshiftl_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn bshiftl_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn bshiftl_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: anytype, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.bshiftl_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_bshiftr_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_bshiftr_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_bshiftr_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_bshiftr_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_bshiftr_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_bshiftr_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_bshiftr_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_bshiftr_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_bshiftr_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_bshiftr_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_bshiftr_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_bshiftr_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_bshiftr_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_bshiftr_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_bshiftr_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_bshiftr_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_bshiftr_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_bshiftr_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_bshiftr_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_bshiftr_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_eq_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_eq_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_eq_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_eq_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_eq_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_eq_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_eq_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_eq_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_eq_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_eq_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_eq_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_eq_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_eq_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_eq_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn i_ne_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn i_ne_8_im(self: *Block, b: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_8_im, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn i_ne_16_im(self: *Block, s: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_16_im, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn i_ne_32_im(self: *Block, i: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn i_ne_64_im(self: *Block, w: anytype, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_ne_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_ne_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ne_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ne_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ne_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ne_32_im(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ne_32_im, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_ne_64_im(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ne_64_im, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_lt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_lt_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_lt_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_lt_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_lt_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_lt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_lt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_lt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_lt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_lt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_lt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_lt_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_lt_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_lt_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_lt_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_lt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_lt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_lt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_lt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_lt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_lt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_lt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_lt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_lt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_lt_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_lt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_lt_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_lt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_lt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_lt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_lt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_lt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_gt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_gt_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_gt_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_gt_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_gt_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_gt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_gt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_gt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_gt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_gt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_gt_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_gt_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_gt_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_gt_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_gt_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_gt_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_gt_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_gt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_gt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_gt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_gt_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_gt_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_gt_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_gt_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_gt_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_gt_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_gt_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_gt_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_gt_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_gt_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_gt_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_gt_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_le_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_le_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_le_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_le_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_le_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_le_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_le_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_le_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_le_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_le_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_le_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_le_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_le_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_le_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_le_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_le_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_le_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_le_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_le_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_le_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_le_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_le_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_le_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_le_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_le_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_le_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_le_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_le_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_le_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_le_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_le_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_le_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_ge_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn u_ge_8_im_a(self: *Block, b: u8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn u_ge_16_im_a(self: *Block, s: u16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn u_ge_32_im_a(self: *Block, i: u32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn u_ge_64_im_a(self: *Block, w: u64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_ge_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: u8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn u_ge_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: u16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn u_ge_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: u32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn u_ge_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: u64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ge_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_ge_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_8, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_16, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn s_ge_8_im_a(self: *Block, b: i8, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_8_im_a, &.{ .b0 = bCast(b), .R0 = x, .R1 = y });
    }

    pub fn s_ge_16_im_a(self: *Block, s: i16, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_16_im_a, &.{ .s0 = sCast(s), .R0 = x, .R1 = y });
    }

    pub fn s_ge_32_im_a(self: *Block, i: i32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn s_ge_64_im_a(self: *Block, w: i64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn s_ge_8_im_b(self: *Block, x: Rbc.RegisterIndex, b: i8, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_8_im_b, &.{ .R0 = x, .b0 = bCast(b), .R1 = y });
    }

    pub fn s_ge_16_im_b(self: *Block, x: Rbc.RegisterIndex, s: i16, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_16_im_b, &.{ .R0 = x, .s0 = sCast(s), .R1 = y });
    }

    pub fn s_ge_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: i32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn s_ge_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: i64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ge_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_ge_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ge_32, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ge_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex, z: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ge_64, &.{ .R0 = x, .R1 = y, .R2 = z });
    }

    pub fn f_ge_32_im_a(self: *Block, i: f32, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ge_32_im_a, &.{ .i0 = iCast(i), .R0 = x, .R1 = y });
    }

    pub fn f_ge_64_im_a(self: *Block, w: f64, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ge_64_im_a, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn f_ge_32_im_b(self: *Block, x: Rbc.RegisterIndex, i: f32, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ge_32_im_b, &.{ .R0 = x, .i0 = iCast(i), .R1 = y });
    }

    pub fn f_ge_64_im_b(self: *Block, x: Rbc.RegisterIndex, w: f64, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ge_64_im_b, &.{ .R0 = x, .R1 = y });
        try self.wideImmediate(w);
    }

    pub fn u_ext_8_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ext_8_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_8_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ext_8_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_8_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ext_8_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_16_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ext_16_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_16_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ext_16_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u_ext_32_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u_ext_32_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_8_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ext_8_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_8_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ext_8_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_8_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ext_8_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_16_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ext_16_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_16_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ext_16_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s_ext_32_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s_ext_32_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_ext_32_64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_ext_32_64, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_64_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_trunc_64_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_64_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_trunc_64_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_64_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_trunc_64_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_32_16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_trunc_32_16, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_32_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_trunc_32_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn i_trunc_16_8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.i_trunc_16_8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f_trunc_64_32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f_trunc_64_32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u8_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u8_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u16_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u16_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u32_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u32_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn u64_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u64_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s8_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s8_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s16_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s16_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s32_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s32_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn s64_to_f32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s64_to_f32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_u8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_u16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_u32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_u64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_u64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_s8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_s16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_s32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f32_to_s64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f32_to_s64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u8_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u8_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u16_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u16_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u32_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u32_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn u64_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.u64_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s8_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s8_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s16_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s16_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s32_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s32_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn s64_to_f64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.s64_to_f64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_u8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_u16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_u32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_u64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_u64, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s8(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_s8, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s16(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_s16, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s32(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_s32, &.{ .R0 = x, .R1 = y });
    }

    pub fn f64_to_s64(self: *Block, x: Rbc.RegisterIndex, y: Rbc.RegisterIndex) RbcBuilder.Error!void {
        try self.op(.f64_to_s64, &.{ .R0 = x, .R1 = y });
    }
};

comptime {
    for (std.meta.fieldNames(Rbc.Code)) |name| {
        if (!@hasDecl(Block, name)) {
            @compileError("missing method: BlockRbcBuilder." ++ name);
        }
    }
}
