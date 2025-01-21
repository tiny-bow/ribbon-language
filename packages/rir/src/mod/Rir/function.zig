const std = @import("std");
const TypeUtils = @import("Utils").Type;

const Rir = @import("../Rir.zig");


const BlockList = std.ArrayListUnmanaged(*Rir.Block);
const LocalList = std.ArrayListUnmanaged(*Rir.Local);
const UpvalueList = std.ArrayListUnmanaged(Rir.LocalId);
const HandlerSetList = std.ArrayListUnmanaged(*Rir.HandlerSet);

pub const Function = struct {
    module: *Rir.Module,
    id: Rir.FunctionId,
    name: Rir.Name,
    type: Rir.TypeId,
    evidence: ?Rir.EvidenceId = null,
    blocks: BlockList = .{},
    locals: LocalList = .{},
    parent: ?*Function = null,
    upvalue_indices: UpvalueList = .{},
    handler_sets: HandlerSetList = .{},


    pub fn getRef(self: *const Function) Rir.Ref(Rir.FunctionId) {
        return Rir.Ref(Rir.FunctionId) {
            .id = self.id,
            .module = self.module.id,
        };
    }


    pub fn init(module: *Rir.Module, id: Rir.FunctionId, name: Rir.Name, tyId: Rir.TypeId) error{InvalidType, OutOfMemory}! *Function {
        const self = try module.root.allocator.create(Function);
        errdefer module.root.allocator.destroy(self);

        self.* = Function {
            .module = module,
            .id = id,
            .name = name,
            .type = tyId,
        };

        const funcTyInfo = try self.getTypeInfo();

        const entryName = try module.root.internName("entry");
        const entryBlock = try Rir.Block.init(self, null, @enumFromInt(0), entryName);
        errdefer entryBlock.deinit();

        try self.blocks.append(module.root.allocator, entryBlock);

        for (funcTyInfo.parameters) |param| {
            _ = self.createLocal(entryBlock, param.name, param.type)
                catch |err| {
                    return TypeUtils.narrowErrorSet(error{OutOfMemory}, err)
                        orelse @panic("unexpected error creating function argument locals");
                };
        }

        return self;
    }

    pub fn deinit(self: *Function) void {
        for (self.handler_sets.items) |hs| hs.deinit();
        for (self.locals.items) |l| l.deinit();
        for (self.blocks.items) |b| b.deinit();

        self.locals.deinit(self.module.root.allocator);

        self.blocks.deinit(self.module.root.allocator);

        self.upvalue_indices.deinit(self.module.root.allocator);

        self.handler_sets.deinit(self.module.root.allocator);

        self.module.root.allocator.destroy(self);
    }

    pub fn onFormat(self: *const Function, formatter: Rir.Formatter) !void {
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

    pub fn getTypeInfo(self: *const Function) error{InvalidType}! Rir.type_info.Function {
        return (try self.module.root.getType(self.type)).info.asFunction();
    }

    pub fn getParameters(self: *const Function) error{InvalidType}! []const Rir.type_info.Parameter {
        return (try self.getTypeInfo()).parameters;
    }

    pub fn getReturnType(self: *const Function) error{InvalidType}! Rir.TypeId {
        return (try self.getTypeInfo()).return_type;
    }

    pub fn getEffects(self: *const Function) error{InvalidType}! []const Rir.TypeId {
        return (try self.getTypeInfo()).effects;
    }

    pub fn getArity(self: *const Function) error{InvalidType}! Rir.Arity {
        return @intCast((try self.getParameters()).len);
    }

    pub fn getArgument(self: *const Function, argIndex: Rir.Arity) error{InvalidArgument, InvalidType}! *Rir.Local {
        if (argIndex >= try self.getArity()) {
            return error.InvalidArgument;
        }

        return self.locals.items[argIndex];
    }

    pub fn getLocal(self: *const Function, id: Rir.LocalId) error{InvalidLocal}! *Rir.Local {
        if (@intFromEnum(id) >= self.locals.items.len) {
            return error.InvalidLocal;
        }

        return self.locals.items[@intFromEnum(id)];
    }

    pub fn createLocal(self: *Function, parent: *Rir.Block, name: Rir.Name, tyId: Rir.TypeId) error{TooManyLocals, OutOfMemory}! *Rir.Local {
        const index = self.locals.items.len;

        if (index >= Rir.MAX_LOCALS) {
            return error.TooManyLocals;
        }

        const local = try Rir.Local.init(parent, @enumFromInt(index), name, tyId);
        errdefer local.deinit();

        try self.locals.append(self.module.root.allocator, local);

        return local;
    }

    pub fn createUpvalue(self: *Function, parentLocal: Rir.LocalId) error{TooManyUpvalues, InvalidLocal, InvalidUpvalue, OutOfMemory}! Rir.UpvalueId {
        if (self.parent) |parent| {
            _ = try parent.getLocal(parentLocal);

            const index = self.upvalue_indices.items.len;

            if (index >= Rir.MAX_LOCALS) {
                return error.TooManyUpvalues;
            }

            try self.upvalue_indices.append(self.module.root.allocator, parentLocal);

            return @enumFromInt(index);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getUpvalue(self: *const Function, u: Rir.UpvalueId) error{InvalidUpvalue, InvalidLocal}! *Rir.Local {
        if (self.parent) |parent| {
            if (@intFromEnum(u) >= self.upvalue_indices.items.len) {
                return error.InvalidUpvalue;
            }

            return parent.getLocal(self.upvalue_indices.items[@intFromEnum(u)]);
        } else {
            return error.InvalidUpvalue;
        }
    }

    pub fn getEntryBlock(self: *Function) *Rir.Block {
        return self.blocks.items[0];
    }

    pub fn createBlock(self: *Function, parent: *Rir.Block, name: Rir.Name) error{TooManyBlocks, OutOfMemory}! *Rir.Block {
        const index = self.blocks.items.len;

        if (index >= Rir.MAX_BLOCKS) {
            return error.TooManyBlocks;
        }

        const newBlock = try Rir.Block.init(self, parent, @enumFromInt(index), name);

        try self.blocks.append(self.module.root.allocator, newBlock);

        return newBlock;
    }

    pub fn getBlock(self: *const Function, id: Rir.BlockId) error{InvalidBlock}! *Rir.Block {
        if (@intFromEnum(id) >= self.blocks.items.len) {
            return error.InvalidBlock;
        }

        return self.blocks.items[@intFromEnum(id)];
    }

    pub fn createHandlerSet(self: *Function) error{TooManyHandlerSets, OutOfMemory}! *Rir.HandlerSet {
        const index = self.handler_sets.items.len;

        if (index >= Rir.MAX_HANDLER_SETS) {
            return error.TooManyHandlerSets;
        }

        const builder = try Rir.HandlerSet.init(self, @enumFromInt(index));

        try self.handler_sets.append(self.module.root.allocator, builder);

        return builder;
    }

    pub fn getHandlerSet(self: *const Function, id: Rir.HandlerSetId) error{InvalidHandlerSet}! *Rir.HandlerSet {
        if (@intFromEnum(id) >= self.handler_sets.items.len) {
            return error.InvalidHandlerSet;
        }

        return self.handler_sets.items[@intFromEnum(id)];
    }
};
