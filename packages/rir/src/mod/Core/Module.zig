const std = @import("std");
const MiscUtils = @import("Utils").Misc;
const ISA = @import("ISA");
const RbcCore = @import("Rbc:Core");
const RbcBuilder = @import("Rbc:Builder");

const Core = @import("../Core.zig");

const Module = @This();


root: *Core.IR,
id: Core.ModuleId,
name: Core.Name,
global_list: std.ArrayListUnmanaged(*Core.Global) = .{},
function_list: std.ArrayListUnmanaged(*Core.Function) = .{},


pub fn init(root: *Core.IR, id: Core.ModuleId, name: Core.Name) !*Module {
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
    for (self.global_list.items) |g| {
        g.deinit();
    }

    self.global_list.deinit(self.root.allocator);

    for (self.function_list.items) |f| {
        f.deinit();
    }

    self.function_list.deinit(self.root.allocator);

    self.root.allocator.destroy(self);
}

pub fn onFormat(self: *const Module, formatter: Core.Formatter) !void {
    const oldActiveModule = formatter.setModule(self);
    defer _ = formatter.setModule(oldActiveModule);

    try formatter.writeAll("module ");
    if (formatter.getShowIds()) try formatter.print("{} ", .{@intFromEnum(self.id)});
    try formatter.fmt(self.name);
    try formatter.writeAll(" =");
    try formatter.beginBlock();
        try formatter.writeAll("globals =");
        try formatter.beginBlock();
            for (self.global_list.items, 0..) |global, i| {
                if (formatter.getShowIds()) try formatter.print("{} ", .{i});
                try formatter.fmt(global);
                if (i < self.global_list.items.len - 1) try formatter.endLine();
            }
        try formatter.endBlock();
        try formatter.writeAll("functions =");
        try formatter.beginBlock();
            for (self.function_list.items, 0..) |func, i| {
                if (formatter.getShowIds()) try formatter.print("{} ", .{i});
                try formatter.fmt(func);
                if (i < self.function_list.items.len - 1) try formatter.endLine();
            }
        try formatter.endBlock();
    try formatter.endBlock();
}


/// Calls `Type.clone` on the input, if the type is not found in the map
pub inline fn typeId(self: *Module, ty: Core.Type) !Core.TypeId {
    return self.root.typeId(ty);
}

/// Does not call `Type.clone` on the input
pub inline fn typeIdPreallocated(self: *Module, ty: Core.Type) !Core.TypeId {
    return self.root.typeIdPreallocated(ty);
}

pub inline fn typeFromNative(self: *const Core, comptime T: type, parameterNames: ?[]const Core.Name) !Core.Type {
    return self.root.typeFromNative(T, parameterNames);
}

pub inline fn typeIdFromNative(self: *Module, comptime T: type, parameterNames: ?[]const Core.Name) !Core.TypeId {
    return self.root.typeIdFromNative(T, parameterNames);
}

pub inline fn getType(self: *const Module, id: Core.TypeId) !Core.Type {
    return self.root.getType(id);
}

/// Calls `allocator.dupe` on the input locals
pub inline fn foreign(self: *Module, tyId: Core.TypeId, locals: []Core.TypeId) !Core.ForeignId {
    return self.root.foreign(tyId, locals);
}

/// Does not call `allocator.dupe` on the input locals
pub inline fn foreignPreallocated(self: *Module, tyId: Core.TypeId, locals: []Core.TypeId) !Core.ForeignId {
    return self.root.foreignPreallocated(tyId, locals);
}

pub inline fn getForeign(self: *const Module, id: Core.ForeignId) !Core.Foreign {
    return self.root.getForeign(id);
}

/// Calls `allocator.dupe` on the input bytes
pub fn globalFromBytes(self: *Module, name: Core.Name, tyId: Core.TypeId, bytes: []const u8) !*Core.Global {
    const dupeBytes = try self.root.allocator.dupe(u8, bytes);
    errdefer self.root.allocator.free(dupeBytes);

    return self.globalFromBytesPreallocated(name, tyId, dupeBytes);
}

/// Does not call `allocator.dupe` on the input bytes
pub fn globalFromBytesPreallocated(self: *Module, name: Core.Name, tyId: Core.TypeId, bytes: []u8) !*Core.Global {
    const index = self.global_list.items.len;

    if (index >= Core.MAX_GLOBALS) {
        return error.TooManyGlobals;
    }

    const global = try Core.Global.init(self, @enumFromInt(index), name, tyId, bytes);
    errdefer self.root.allocator.destroy(global);

    try self.global_list.append(self.root.allocator, global);

    return global;
}

pub fn globalFromNative(self: *Module, name: Core.Name, value: anytype, parameterNames: ?[]const Core.Name) !*Core.Global {
    const T = @TypeOf(value);
    const tyId = try self.typeIdFromNative(T, parameterNames);

    return self.globalFromBytes(name, tyId, @as([*]const u8, @ptrCast(&value))[0..@sizeOf(T)]);
}

pub fn getGlobal(self: *const Module, id: Core.GlobalId) !*Core.Global {
    if (@intFromEnum(id) >= self.global_list.items.len) {
        return error.InvalidGlobal;
    }

    return self.global_list.items[@intFromEnum(id)];
}

pub fn function(self: *Module, name: Core.Name, tyId: Core.TypeId) !*Core.Function {
    const index = self.function_list.items.len;

    if (index >= Core.MAX_FUNCTIONS) {
        return error.TooManyFunctions;
    }

    const builder = try Core.Function.init(self, @enumFromInt(index), name, tyId);

    try self.function_list.append(self.root.allocator, builder);

    return builder;
}

pub fn getFunction(self: *const Module, id: Core.FunctionId) !*Core.Function {
    if (@intFromEnum(id) >= self.function_list.items.len) {
        return error.InvalidFunction;
    }

    return self.function_list.items[@intFromEnum(id)];
}


test {
    std.testing.refAllDeclsRecursive(Module);
}
