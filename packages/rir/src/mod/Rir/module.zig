const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const ISA = @import("ISA");
const RbcCore = @import("Rbc");
const RbcBuilder = @import("RbcBuilder");

const Rir = @import("../Rir.zig");


const GlobalList = std.ArrayListUnmanaged(*Rir.Global);
const FunctionList = std.ArrayListUnmanaged(*Rir.Function);
const HandlerSetList = std.ArrayListUnmanaged(*Rir.HandlerSet);

pub const Module = struct {
    root: *Rir,
    id: Rir.ModuleId,
    name: Rir.NameId,
    global_list: GlobalList = .{},
    function_list: FunctionList = .{},
    handler_sets: HandlerSetList = .{},

    pub fn init(root: *Rir, id: Rir.ModuleId, name: Rir.NameId) error{OutOfMemory}! *Module {
        const ptr = try root.allocator.create(Module);
        errdefer root.allocator.destroy(ptr);

        ptr.* = Module {
            .root = root,
            .id = id,
            .name = name,
        };

        return ptr;
    }

    pub fn deinit(self: *Module) void {
        for (self.handler_sets.items) |x| x.deinit();
        for (self.global_list.items) |x| x.deinit();
        for (self.function_list.items) |x| x.deinit();

        self.handler_sets.deinit(self.root.allocator);

        self.global_list.deinit(self.root.allocator);

        self.function_list.deinit(self.root.allocator);

        self.root.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Module, formatter: Rir.Formatter) Rir.Formatter.Error! void {
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



    /// Calls `allocator.dupe` on the input bytes
    pub fn createGlobal(self: *Module, name: Rir.NameId, tyId: Rir.TypeId, bytes: []const u8) error{TooManyGlobals, OutOfMemory}! *Rir.Global {
        const dupeBytes = try self.root.allocator.dupe(u8, bytes);
        errdefer self.root.allocator.free(dupeBytes);

        return self.createGlobalPreallocated(name, tyId, dupeBytes);
    }

    /// Does not call `allocator.dupe` on the input bytes
    pub fn createGlobalPreallocated(self: *Module, name: Rir.NameId, tyId: Rir.TypeId, bytes: []u8) error{TooManyGlobals, OutOfMemory}! *Rir.Global {
        const index = self.global_list.items.len;

        if (index >= Rir.MAX_GLOBALS) {
            return error.TooManyGlobals;
        }

        const global = try Rir.Global.init(self, @enumFromInt(index), name, tyId, bytes);
        errdefer self.root.allocator.destroy(global);

        try self.global_list.append(self.root.allocator, global);

        return global;
    }

    pub fn createGlobalFromNative(self: *Module, name: Rir.NameId, value: anytype) error{TooManyGlobals, TooManyTypes, TooManyNames, OutOfMemory}! *Rir.Global {
        const T = @TypeOf(value);
        const ty = try self.root.createTypeFromNative(T, null, null);

        return self.createGlobal(name, ty.id, @as([*]const u8, @ptrCast(&value))[0..@sizeOf(T)]);
    }

    pub fn getGlobal(self: *const Module, id: Rir.GlobalId) error{InvalidGlobal}! *Rir.Global {
        if (@intFromEnum(id) >= self.global_list.items.len) {
            return error.InvalidGlobal;
        }

        return self.global_list.items[@intFromEnum(id)];
    }

    pub fn createFunction(self: *Module, name: Rir.NameId, tyId: Rir.TypeId) error{InvalidType, TooManyFunctions, OutOfMemory}! *Rir.Function {
        const index = self.function_list.items.len;

        if (index >= Rir.MAX_FUNCTIONS) {
            return error.TooManyFunctions;
        }

        const builder = try Rir.Function.init(self, @enumFromInt(index), name, tyId);

        try self.function_list.append(self.root.allocator, builder);

        return builder;
    }

    pub fn getFunction(self: *const Module, id: Rir.FunctionId) !*Rir.Function {
        if (@intFromEnum(id) >= self.function_list.items.len) {
            return error.InvalidFunction;
        }

        return self.function_list.items[@intFromEnum(id)];
    }

    pub fn createHandlerSet(self: *Module) error{TooManyHandlerSets, OutOfMemory}! *Rir.HandlerSet {
        const index = self.handler_sets.items.len;

        if (index >= Rir.MAX_HANDLER_SETS) {
            return error.TooManyHandlerSets;
        }

        const builder = try Rir.HandlerSet.init(self, @enumFromInt(index));

        try self.handler_sets.append(self.root.allocator, builder);

        return builder;
    }

    pub fn getHandlerSet(self: *const Module, id: Rir.HandlerSetId) error{InvalidHandlerSet}! *Rir.HandlerSet {
        if (@intFromEnum(id) >= self.handler_sets.items.len) {
            return error.InvalidHandlerSet;
        }

        return self.handler_sets.items[@intFromEnum(id)];
    }
};
