const std = @import("std");
const MiscUtils = @import("Utils").Misc;

const Core = @import("../Core.zig");
const IR = @This();


allocator: std.mem.Allocator,
interner: Interner = .{},
type_map: Core.types.TypeMap,
foreign_list: std.ArrayListUnmanaged(*Core.Foreign) = .{},
module_list: std.ArrayListUnmanaged(*Core.Module) = .{},

pub const Interner = std.ArrayHashMapUnmanaged(Core.Name, void, InternerContext, true);
pub const InternerContext = struct {
    pub fn eql(_: InternerContext, a: anytype, b: anytype, _: anytype) bool {
        return @intFromPtr(a.ptr) == @intFromPtr(b.ptr)
            or (a.len == b.len and std.mem.eql(u8, a.ptr[0..a.len], b.ptr[0..b.len]));
    }

    pub fn hash(_: InternerContext, a: anytype) u32 {
        return MiscUtils.fnv1a_32(a);
    }
};


pub fn init(alloc: std.mem.Allocator) !IR {
    return IR {
        .allocator = alloc,
        .type_map = try Core.types.TypeMap.init(alloc),
    };
}

pub fn deinit(self: *IR) void {
    for (self.interner.keys()) |name| {
        self.allocator.free(name);
    }

    self.interner.deinit(self.allocator);

    self.type_map.deinit(self.allocator);

    for (self.foreign_list.items) |f| {
        f.deinit();
    }

    self.foreign_list.deinit(self.allocator);

    for (self.module_list.items) |mod| {
        mod.deinit();
    }

    self.module_list.deinit(self.allocator);
}


pub fn onFormat(self: *const IR, formatter: Core.Formatter) !void {
    if (self.type_map.count() > Core.types.BASIC_TYPES.len) {
        try formatter.writeAll("types = ");
        try formatter.beginBlock();
        {
            const oldTypeMode = formatter.setTypeMode(.full);
            defer _ = formatter.setTypeMode(oldTypeMode);
            for (Core.types.BASIC_TYPES.len..self.type_map.count()) |i| {
                if (i > Core.types.BASIC_TYPES.len) try formatter.endLine();
                if (formatter.getShowIds()) try formatter.print("{} ", .{i});
                try formatter.fmt(self.type_map.getType(@enumFromInt(i)) catch unreachable);
            }
        }
        try formatter.endBlock();
        try formatter.endLine();
    }
    if (self.foreign_list.items.len > 0) {
        try formatter.writeAll("foreign = ");
        try formatter.beginBlock();
            for (self.foreign_list.items, 0..) |f, i| {
                if (i > 0) try formatter.endLine();
                if (formatter.getShowIds()) try formatter.print("{} ", .{i});
                try formatter.fmt(f);
            }
        try formatter.endBlock();
        try formatter.endLine();
    }
    if (self.module_list.items.len > 0) {
        try formatter.writeAll("modules = ");
        try formatter.beginBlock();
            for (self.module_list.items, 0..) |mod, i| {
                if (i > 0) try formatter.endLine();
                if (formatter.getShowIds()) try formatter.print("{} ", .{i});
                try formatter.fmt(mod);
            }
        try formatter.endBlock();
        try formatter.endLine();
    }
}


/// Intern a string, yielding a Name
pub fn intern(self: *IR, name: []const u8) !Core.Name {
    if (self.interner.getKeyAdapted(name, InternerContext{})) |interned| {
        return interned;
    }

    const interned = try self.allocator.allocWithOptions(u8, name.len, 1, 0);

    @memcpy(interned, name);

    try self.interner.put(self.allocator, interned, {});

    return interned;
}


/// If the type is not found in the map,
/// calls `Type.clone` on the input and puts the clone in the map
pub inline fn typeId(self: *IR, ty: Core.Type) !Core.TypeId {
    return self.type_map.typeId(self.allocator, ty);
}

/// Does not call `Type.clone` on the input
pub inline fn typeIdPreallocated(self: *IR, ty: Core.Type) !Core.TypeId {
    return self.type_map.typeIdPreallocated(self.allocator, ty);
}

pub inline fn typeFromNative(self: *const Core, comptime T: type, parameterNames: ?[]const Core.Name) !Core.Type {
    return self.type_map.typeFromNative(T, self.allocator, parameterNames);
}

pub inline fn typeIdFromNative(self: *IR, comptime T: type, parameterNames: ?[]const Core.Name) !Core.TypeId {
    return self.type_map.typeIdFromNative(T, self.allocator, parameterNames);
}

pub inline fn getType(self: *const IR, id: Core.TypeId) !Core.Type {
    return self.type_map.getType(id);
}




/// Calls `allocator.dupe` on the input locals
pub fn foreign(self: *IR, tyId: Core.TypeId, locals: []Core.TypeId) !*Core.Foreign {
    const dupeLocals = try self.allocator.dupe(Core.TypeId, locals);
    errdefer self.allocator.free(dupeLocals);

    return self.foreignPreallocated(tyId, dupeLocals);
}

/// Does not call `allocator.dupe` on the input locals
pub fn foreignPreallocated(self: *IR, tyId: Core.TypeId, locals: []Core.TypeId) !*Core.Foreign {
    const index = self.foreign_list.items.len;

    if (index >= Core.MAX_FUNCTIONS) {
        return error.TooManyForeignFunctions;
    }

    const f = try Core.Foreign.init(self, @truncate(index), tyId, locals);
    errdefer self.allocator.destroy(f);

    try self.foreign_list.append(self.allocator, f);

    return f;
}

pub fn getForeign(self: *IR, id: Core.ForeignId) !*Core.Foreign {
    if (id >= self.foreign_list.items.len) {
        return error.InvalidForeignFunction;
    }

    return self.foreign_list.items[id];
}


pub fn module(self: *IR, name: Core.Name) !*Core.Module {
    const id = self.module_list.items.len;

    if (id >= Core.MAX_MODULES) {
        return error.InvalidModule;
    }

    const mod = try Core.Module.init(self, @enumFromInt(id), name);
    errdefer self.allocator.destroy(mod);

    try self.module_list.append(self.allocator, mod);

    return mod;
}

pub fn getModule(self: *const IR, id: Core.ModuleId) !*Core.Module {
    if (@intFromEnum(id) >= self.module_list.items.len) {
        return error.InvalidModule;
    }

    return self.module_list.items[@intFromEnum(id)];
}

pub fn getGlobal(self: *const IR, ref: Core.Ref(Core.GlobalId)) !*Core.Global {
    const mod = try self.getModule(ref.module);

    return mod.getGlobal(ref.id);
}

pub fn getFunction(self: *const IR, ref: Core.Ref(Core.FunctionId)) !*Core.Function {
    const mod = try self.getModule(ref.module);

    return mod.getFunction(ref.id);
}


test {
    std.testing.refAllDeclsRecursive(Core);
}
