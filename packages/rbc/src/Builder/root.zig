const std = @import("std");

const MiscUtils = @import("Utils").Misc;
const Core = @import("Core");


const Builder = @This();
pub const BlockBuilder = @import("./BlockBuilder.zig");
pub const FunctionBuilder = @import("./FunctionBuilder.zig");
pub const HandlerSetBuilder = @import("./HandlerSetBuilder.zig");


allocator: std.mem.Allocator,
globals: GlobalList,
functions: FunctionList,
handler_sets: HandlerSetList,
evidences: usize,
main_function: ?Core.FunctionIndex,


pub const Error = std.mem.Allocator.Error || error {
    TooManyGlobals,
    TooManyFunctions,
    TooManyBlocks,
    TooManyRegisters,
    TooManyHandlerSets,
    TooManyEvidences,
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


pub const TypeMap = std.ArrayHashMapUnmanaged(Core.Info.Type, void, MiscUtils.SimpleHashContext, true);
pub const TypeList = std.ArrayListUnmanaged(Core.Info.TypeIndex);
pub const GlobalList = std.ArrayListUnmanaged(Global);
pub const FunctionList = std.ArrayListUnmanaged(*Function);
pub const BlockList = std.ArrayListUnmanaged(*BlockBuilder);
pub const HandlerSetList = std.ArrayListUnmanaged(*HandlerSetBuilder);
pub const HandlerMap = EvidenceMap(Core.FunctionIndex);
pub const InstrList = std.ArrayListUnmanaged(Core.Instruction);

fn EvidenceMap(comptime T: type) type {
    return std.ArrayHashMapUnmanaged(Core.EvidenceIndex, T, MiscUtils.SimpleHashContext, false);
}


pub const Global = struct {
    index: Core.GlobalIndex,
    alignment: Core.Info.ValueAlignment,
    initial: []u8,
};

pub const Function = union(enum) {
    bytecode: *FunctionBuilder,
    foreign: Foreign,

    pub const Foreign = struct {
        parent: *Builder,
        evidence: ?Core.EvidenceIndex,
        index: Core.FunctionIndex,
        num_arguments: Core.RegisterIndex,
        num_registers: Core.RegisterIndex,

        pub fn assemble(self: *const Foreign) Core.Function.Foreign {
            return Core.Function.Foreign {
                .num_arguments = self.num_arguments,
                .num_registers = self.num_registers,
            };
        }
    };

    pub fn assemble(self: Function, allocator: std.mem.Allocator) Error!union(enum) {bytecode: Core.Function, foreign: Core.Function.Foreign} {
        // TODO: the builder should be handling this
        var foreignId: Core.ForeignId = 0;

        switch (self) {
            .bytecode => |builder| return .{.bytecode = try builder.assemble(allocator) },
            .foreign => |forn| {
                const out = forn.assemble();
                foreignId += 1;
                return .{.foreign = out};
            },
        }
    }
};


/// The allocator passed in should be an arena or a similar allocator that doesn't care about freeing individual allocations
pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Builder {
    var globals = GlobalList {};
    try globals.ensureTotalCapacity(allocator, 256);

    var functions = FunctionList {};
    try functions.ensureTotalCapacity(allocator, 256);

    var handler_sets = HandlerSetList {};
    try handler_sets.ensureTotalCapacity(allocator, 256);

    return Builder {
        .allocator = allocator,
        .globals = globals,
        .functions = functions,
        .handler_sets = handler_sets,
        .evidences = 0,
        .main_function = null,
    };
}

/// this does not have to be the same allocator as the one passed to `init`,
/// a long-term allocator is preferred. In the event of an error, the builder
/// will clean-up any allocations made by this function
pub fn assemble(self: *const Builder, allocator: std.mem.Allocator) Error!Core.Program {
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
        .main = self.main_function orelse Core.FUNCTION_SENTINEL,
    };
}

pub fn generateGlobalSet(self: *const Builder, allocator: std.mem.Allocator) Error!struct { []const [*]u8, []u8 } {
    const values = try allocator.alloc([*]u8, self.globals.items.len);
    errdefer allocator.free(values);

    var buf = std.ArrayListAlignedUnmanaged(u8, std.mem.page_size){};
    defer buf.deinit(allocator);

    for (self.globals.items) |global| {
        const padding = MiscUtils.alignmentDelta(buf.items.len, global.alignment);
        try buf.appendNTimes(allocator, 0, padding);
        try buf.appendSlice(allocator, global.initial);
    }

    const memory = try buf.toOwnedSlice(allocator);

    var offset: usize = 0;
    for (self.globals.items, 0..) |global, i| {
        const padding = MiscUtils.alignmentDelta(offset, global.alignment);
        offset += padding;
        values[i] = memory.ptr + offset;
        offset += global.initial.len;
    }

    return .{ values, memory };
}

pub fn generateFunctionLists(self: *const Builder, allocator: std.mem.Allocator) Error!struct {[]Core.Function, []Core.Function.Foreign} {
    var functions = std.ArrayListUnmanaged(Core.Function){};
    var foreign_functions = std.ArrayListUnmanaged(Core.Function.Foreign){};

    errdefer {
        for (functions.items) |func| func.deinit(allocator);
        functions.deinit(allocator);
        foreign_functions.deinit(allocator);
    }

    for (self.functions.items) |func| {
        switch (try func.assemble(allocator)) {
            .bytecode => |final| try functions.append(allocator, final),
            .foreign => |final| try foreign_functions.append(allocator, final),
        }
    }

    return .{try functions.toOwnedSlice(allocator), try foreign_functions.toOwnedSlice(allocator)};
}

pub fn generateHandlerSetList(self: *const Builder, allocator: std.mem.Allocator) Error![]Core.Handler.Set {
    const handlerSets = try allocator.alloc(Core.Handler.Set, self.handler_sets.items.len);

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

pub fn getGlobal(self: *const Builder, index: Core.GlobalIndex) Error! *Global {
    if (index >= self.globals.items.len) {
        return Error.InvalidIndex;
    }

    return &self.globals.items[index];
}

pub fn globalBytes(self: *Builder, alignment: Core.Info.ValueAlignment, initial: []u8) Error! *Global {
    const index = self.globals.items.len;
    if (index >= std.math.maxInt(Core.GlobalIndex)) {
        return Error.TooManyGlobals;
    }

    try self.globals.append(self.allocator, .{
        .index = @truncate(index),
        .alignment = alignment,
        .initial = try self.allocator.dupe(u8, initial),
    });

    return &self.globals.items[index];
}

pub fn globalNative(self: *Builder, value: anytype) Error! *Global {
    const T = @TypeOf(value);
    const initial = try self.allocator.create(T);
    initial.* = value;
    return self.globalBytes(@alignOf(T), @as([*]u8, @ptrCast(initial))[0..@sizeOf(T)]);
}

pub fn getFunction(self: *const Builder, index: Core.FunctionIndex) Error! *Function {
    if (index >= self.functions.items.len) {
        return Error.InvalidIndex;
    }

    return self.functions.items[index];
}

pub fn function(self: *Builder) Error!*FunctionBuilder {
    const index = self.functions.items.len;
    if (index >= std.math.maxInt(Core.FunctionIndex)) {
        return Error.TooManyFunctions;
    }

    const func = try self.allocator.create(Function);
    func.* = .{.bytecode = try FunctionBuilder.init(self, @truncate(index))};

    try self.functions.append(self.allocator, func);

    return func.bytecode;
}

pub fn hasMain(self: *const Builder) bool {
    return self.main_function != null;
}

pub fn main(self: *Builder) Error! *FunctionBuilder {
    if (self.hasMain()) return Error.MultipleMains;

    const func = try self.function();

    self.main_function = func.index;

    return func;
}

pub fn foreign(self: *Builder, num_arguments: Core.RegisterIndex, num_registers: Core.RegisterIndex) Error! *Function.Foreign {
    const index = self.functions.items.len;
    if (index >= std.math.maxInt(Core.FunctionIndex)) {
        return Error.TooManyFunctions;
    }

    const func = try self.allocator.create(Function);
    func.* = .{.foreign = .{ .parent = self, .num_arguments = num_arguments, .num_registers = num_registers, .evidence = null, .index = @truncate(index) }};

    try self.functions.append(self.allocator, func);

    return &func.foreign;
}

pub fn evidence(self: *Builder) Error! Core.EvidenceIndex {
    const index = self.evidences;
    if (index >= Core.EVIDENCE_SENTINEL) {
        return Error.TooManyEvidences;
    }

    return @truncate(index);
}


pub fn getHandlerSet(self: *const Builder, index: Core.HandlerSetIndex) Error! *HandlerSetBuilder {
    if (index >= self.handler_sets.items.len) {
        return Error.InvalidIndex;
    }

    return self.handler_sets.items[index];
}

pub fn handlerSet(self: *Builder) Error! *HandlerSetBuilder {
    const index = self.handler_sets.items.len;
    if (index >= std.math.maxInt(Core.HandlerSetIndex)) {
        return Error.TooManyHandlerSets;
    }

    const handler_set = try HandlerSetBuilder.init(self, @truncate(index));

    try self.handler_sets.append(self.allocator, handler_set);

    return handler_set;
}


pub fn extractFunctionIndex(self: *const Builder, f: anytype) Error! Core.FunctionIndex {
    switch (@TypeOf(f)) {
        *Core.FunctionIndex => return extractFunctionIndex(self, f.*),
        Core.FunctionIndex => {
            if (f >= self.functions.items.len) {
                return Error.InvalidIndex;
            }
            return f;
        },

        Function => return extractFunctionIndex(self, &f),
        *Function => return extractFunctionIndex(self, @as(*const Function, f)),
        *const Function => switch(f.value) {
            .bytecode => |builder| return extractFunctionIndex(self, builder),
            .foreign => |forn| {
                if (forn.parent != self) {
                    return Error.InvalidIndex;
                }
                return forn.index;
            },
        },

        FunctionBuilder => return extractFunctionIndex(self, &f),
        *FunctionBuilder => return extractFunctionIndex(self, @as(*const FunctionBuilder, f)),
        *const FunctionBuilder => {
            if (f.parent != self) {
                return Error.InvalidIndex;
            }
            return f.index;
        },

        else => @compileError(std.fmt.comptimePrint(
            "invalid block index parameter, expected either `Core.FunctionIndex`, `*Builder.FunctionBuilder` or `Builder.Function`, got `{s}`",
            .{@typeName(@TypeOf(f))}
        )),
    }
}

pub fn extractHandlerSetIndex(self: *const Builder, h: anytype) Error! Core.HandlerSetIndex {
    switch (@TypeOf(h)) {
        *Core.HandlerSetIndex => return extractHandlerSetIndex(self, h.*),
        Core.HandlerSetIndex => {
            if (h >= self.handler_sets.items.len) {
                return Error.InvalidIndex;
            }
            return h;
        },

        HandlerSetBuilder => return extractHandlerSetIndex(self, &h),
        *HandlerSetBuilder => return extractHandlerSetIndex(self, @as(*const HandlerSetBuilder, h)),
        *const HandlerSetBuilder => {
            if (h.parent != self) {
                return Error.InvalidIndex;
            }
            return h.index;
        },

        else => @compileError(std.fmt.comptimePrint(
            "invalid handler set index parameter, expected either `Core.HandlerSetIndex` or `*Builder.HandlerSetBuilder`, got `{s}`",
            .{@typeName(@TypeOf(h))}
        )),
    }
}


test {
    std.testing.refAllDecls(@This());
}
