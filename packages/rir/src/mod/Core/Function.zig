const std = @import("std");

const Core = @import("../Core.zig");

const Function = @This();


module: *Core.Module,
id: Core.FunctionId,
name: Core.Name,
type: Core.TypeId,
blocks: std.ArrayListUnmanaged(*Core.Block),
locals: std.ArrayListUnmanaged(Local),
parent: ?*Function = null,
upvalue_indices: std.ArrayListUnmanaged(Core.LocalId) = .{},
handler_sets: std.ArrayListUnmanaged(*Core.HandlerSet) = .{},


pub const Local = struct {
    id: Core.LocalId,
    name: Core.Name,
    type: Core.TypeId,
};


pub fn init(module: *Core.Module, id: Core.FunctionId, name: Core.Name, tyId: Core.TypeId) !*Function {
    const ptr = try module.root.allocator.create(Function);
    errdefer module.root.allocator.destroy(ptr);

    const ty = try module.getType(tyId);
    const funcTy = try ty.asFunction();

    var blocks = std.ArrayListUnmanaged(*Core.Block){};
    errdefer blocks.deinit(module.root.allocator);

    var locals = std.ArrayListUnmanaged(Local){};
    errdefer locals.deinit(module.root.allocator);

    for (funcTy.parameters, 0..) |param, i| {
        try locals.append(module.root.allocator, Local {
            .id = @enumFromInt(i),
            .name = param.name,
            .type = param.type,
        });
    }

    ptr.* = Function {
        .module = module,
        .id = id,
        .name = name,
        .type = tyId,
        .blocks = blocks,
        .locals = locals,
    };

    const entryName = try module.root.intern("entry");
    const entryBlock = try Core.Block.init(ptr, null, @enumFromInt(0), entryName);
    errdefer entryBlock.deinit();

    try ptr.blocks.append(module.root.allocator, entryBlock);

    return ptr;
}

pub fn deinit(self: *Function) void {
    for (self.blocks.items) |b| {
        b.deinit();
    }

    self.blocks.deinit(self.module.root.allocator);

    self.locals.deinit(self.module.root.allocator);

    self.upvalue_indices.deinit(self.module.root.allocator);

    for (self.handler_sets.items) |hs| {
        hs.deinit();
    }

    self.handler_sets.deinit(self.module.root.allocator);

    self.module.root.allocator.destroy(self);
}

pub fn onFormat(self: *const Function, formatter: Core.Formatter) !void {
    const oldActiveFunction = formatter.setFunction(self);
    defer _ = formatter.setFunction(oldActiveFunction);

    try formatter.fmt(self.name);
    try formatter.writeAll(": ; ");
    try formatter.fmt(self.type);
    try formatter.beginBlock();
        for (self.blocks.items) |b| {
            try formatter.fmt(b);
        }
    try formatter.endBlock();
}

pub fn getTypeInfo(self: *const Function) !Core.types.Function {
    return (try self.module.getType(self.type)).asFunction();
}

pub fn getParameters(self: *const Function) ![]Core.types.Function.Parameter {
    return (try self.getTypeInfo()).parameters;
}

pub fn getReturnType(self: *const Function) !Core.TypeId {
    return (try self.getTypeInfo()).return_type;
}

pub fn getEffects(self: *const Function) ![]Core.TypeId {
    return (try self.getTypeInfo()).effects;
}

pub fn getArity(self: *const Function) !Core.Arity {
    return @intCast((try self.getParameters()).len);
}

pub fn getArgument(self: *const Function, argIndex: Core.Arity) !*Local {
    if (argIndex >= try self.getArity()) {
        return error.InvalidArgument;
    }

    return &self.locals.items[argIndex];
}

pub fn getLocal(self: *const Function, id: Core.LocalId) !*Local {
    if (@intFromEnum(id) >= self.locals.items.len) {
        return error.InvalidLocal;
    }

    return &self.locals.items[@intFromEnum(id)];
}

pub fn local(self: *Function, name: Core.Name, tyId: Core.TypeId) !Core.LocalId {
    const numParams = (try self.getParameterTypes()).len;
    const index = self.locals.items.len + numParams;

    if (index >= Core.MAX_LOCALS) {
        return error.TooManyLocals;
    }

    try self.locals.append(self.module.root.allocator, Local { .name = name, .type = tyId });

    return @truncate(index);
}

pub fn upvalue(self: *Function, parentLocal: Core.LocalId) !Core.UpvalueId {
    if (self.parent) |parent| {
        _ = try parent.getLocalType(parentLocal);

        const index = self.upvalue_indices.items.len;

        if (index >= Core.MAX_LOCALS) {
            return error.TooManyUpvalues;
        }

        try self.upvalue_indices.append(self.module.root.allocator, parentLocal);

        return @truncate(index);
    } else {
        return error.InvalidUpvalue;
    }
}

pub fn getUpvalueType(self: *const Function, u: Core.UpvalueId) !Core.TypeId {
    if (self.parent) |parent| {
        if (u >= self.upvalue_indices.items.len) {
            return error.InvalidRegister;
        }

        return parent.getLocalType(self.upvalue_indices.items[u]);
    } else {
        return error.InvalidUpvalue;
    }
}

pub fn entry(self: *Function) *Core.Block {
    return self.blocks.items[0];
}

pub fn block(self: *Function, parent: *Core.Block) !*Core.Block {
    const index = self.blocks.items.len;

    if (index >= Core.MAX_BLOCKS) {
        return error.TooManyBlocks;
    }

    const newBlock = try Core.Block.init(self, parent, @enumFromInt(index));

    try self.blocks.append(self.module.root.allocator, newBlock);

    return newBlock;
}

pub fn getBlock(self: *const Function, id: Core.BlockId) !*Core.Block {
    if (@intFromEnum(id) >= self.blocks.items.len) {
        return error.InvalidBlock;
    }

    return self.blocks.items[@intFromEnum(id)];
}

pub fn handlerSet(self: *Function) !*Core.HandlerSet {
    const index = self.handler_sets.items.len;

    if (index >= Core.MAX_HANDLER_SETS) {
        return error.TooManyHandlerSets;
    }

    const builder = try Core.HandlerSet.init(self, @enumFromInt(index));

    try self.handler_sets.append(self.module.root.allocator, builder);

    return builder;
}

pub fn getHandlerSet(self: *const Function, id: Core.HandlerSetId) !*Core.HandlerSet {
    if (id >= self.handler_sets.items.len) {
        return error.InvalidHandlerSet;
    }

    return self.handler_sets.items[id];
}
