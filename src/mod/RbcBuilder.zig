const RbcBuilder = @This();

const std = @import("std");
const utils = @import("utils");
const Rbc = @import("Rbc");

pub const log = std.log.scoped(.rbc_builder);

pub const block = @import("RbcBuilder/block.zig");
pub const function = @import("RbcBuilder/function.zig");
pub const handler_set = @import("RbcBuilder/handler_set.zig");

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

pub const Block = block.Block;
pub const Function = function.Function;
pub const HandlerSet = handler_set.HandlerSet;

pub const Global = struct {
    index: Rbc.GlobalIndex,
    alignment: Rbc.Alignment,
    initial: []u8,
};

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

// pub fn foreign(self: *Builder, num_arguments: Rbc.RegisterIndex, num_registers: Rbc.RegisterIndex) Error! *Function.Foreign {
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

        else => @compileError(std.fmt.comptimePrint("invalid block index parameter, expected either `Rbc.FunctionIndex` or `*RbcBuilder.Function`, got `{s}`", .{@typeName(@TypeOf(f))})),
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

        else => @compileError(std.fmt.comptimePrint("invalid handler set index parameter, expected either `Rbc.HandlerSetIndex` or `*RbcBuilder.HandlerSetBuilder`, got `{s}`", .{@typeName(@TypeOf(h))})),
    }
}
